"""
DeviceRegistry — singleton (per apartment) that owns the ADSClient and all
device objects for one Beckhoff CX.

Multi-apartment design
───────────────────────
Apartment-specific data (rooms, DALI channels, relays, switches, ...) lives
in the database now — see find_device.models.Apartment/Room/ApartmentDevice
— not in a hardcoded dict in this file. Adding apartment #501 means adding
rows through the installer workflow / Django admin, not editing source code.

self.apartment_id is the Apartment model's primary key. One Django process
can hold many simultaneous ADS connections: call DeviceRegistry.for_apartment
(apartment_pk) to get (or lazily create) the registry for that apartment —
this is what every /plc/* view does, resolving apartment_pk from the
authenticated user's ApartmentMembership, never from client input.

The registry reads the ADS connection address from that Apartment's own
PLCDevice (a 1:1 relationship) so it can be changed without touching source
code. PLC_MOCK=True in env always wins (safe for dev/CI).
"""
from __future__ import annotations

import logging
import os
import threading
import time
from typing import Dict, List, Optional

import pyads

from .ads_client import ADSClient
from .modbus_client import ModbusClient
from .ads_notifications import NotificationManager
from .devices import (
    DaliChannel, WallRelay, SwitchInput,
    CurtainMotor, ApplianceRelay, NamedRelay, NamedSwitchInput,
    MagneticSensor, MotionSensor, SecurityController,
    pct_to_byte, byte_to_pct,
)

# gvlDALI.bventiliatorRelay is unconditionally overwritten every scan by
# POU_Controller (`:= gvlDALI.bSensor1`) — remote writes would be clobbered
# within 10ms, so it's registered read-only. Every other NamedRelay found
# in the 2026-08-04 TwinCAT scan is a plain button-toggled BOOL with no such
# re-write, so a direct ADS write sticks correctly.
NAMED_RELAY_READONLY = {'bventiliatorRelay'}

logger = logging.getLogger(__name__)


class DeviceRegistry:
    """
    Central registry for all PLC devices in one apartment.

    One instance per apartment, cached in _apt_instances. Use
    DeviceRegistry.for_apartment(apartment_pk) to get the registry for a
    specific apartment — this is the only entry point views.py should use.
    """

    # Per-apartment instances (for multi-tenant use)
    _apt_instances: Dict[int, 'DeviceRegistry'] = {}
    _apt_lock       = threading.Lock()

    def __init__(self, apartment_id: int):
        self.apartment_id = apartment_id
        mock = os.getenv('PLC_MOCK', 'False').lower() == 'true'
        self._client = ADSClient(
            netid=os.getenv('PLC_NETID', '5.168.214.72.1.1'),
            ip   =os.getenv('PLC_IP',    '192.168.0.161'),
            mock =mock,
        )

        # Modbus fallback (TF6250 bridge — see GVL.TcGVL/POU_Modbus on the
        # PLC side and modbus_client.py). Off by default: nothing should try
        # to open a socket to a server that doesn't exist yet on the target
        # until TF6250 is actually installed/licensed there. Same IP as ADS
        # — same physical CX, different port — set once resolved in
        # _start(). Only covers what POU_Modbus bridges: DALI 1-16, relay
        # 1-4. Everything else (switches, sensors, curtains, appliances)
        # has no Modbus path and is unaffected by any of this.
        self._modbus_enabled = os.getenv('PLC_MODBUS_ENABLED', 'False').lower() == 'true'
        self._modbus: Optional[ModbusClient] = (
            ModbusClient(ip=self._client.ip, mock=mock) if self._modbus_enabled else None
        )
        self._dali:           Dict[int, DaliChannel]      = {}
        self._relays:         Dict[int, WallRelay]        = {}
        self._switches:       Dict[int, SwitchInput]      = {}
        self._curtains:       Dict[int, CurtainMotor]     = {}
        self._appliances:     Dict[str, ApplianceRelay]   = {}
        self._toggles:        Dict[str, NamedRelay]      = {}
        self._named_switches: Dict[str, NamedSwitchInput] = {}
        self._fade_generation: Dict[int, int]             = {}  # DALI channel -> current fade token
        self._door_sensors:   Dict[int, MagneticSensor]  = {}
        self._window_sensors: Dict[int, MagneticSensor]  = {}
        self._motion_sensors: Dict[int, MotionSensor]    = {}
        self._security:       Optional[SecurityController] = None
        self._lock    = threading.RLock()
        self._started = False

        # AutomationRule execution — subscribes to trigger inputs via ADS
        # push notifications (event-driven, not polled) and writes the
        # configured action the instant the trigger matches. rule_id ->
        # (var_name, callback) so a rule can be individually unsubscribed
        # on delete/disable without touching any other rule's subscription.
        self._notifications = NotificationManager(self._client)
        self._automation_subs: Dict[int, tuple] = {}

    # ── Startup ───────────────────────────────────────────────────────────────

    def _start(self):
        if self._started:
            return

        from django.apps import apps
        Apartment       = apps.get_model('find_device', 'Apartment')
        ApartmentDevice = apps.get_model('find_device', 'ApartmentDevice')
        PLCDevice       = apps.get_model('find_device', 'PLCDevice')

        apartment = Apartment.objects.filter(pk=self.apartment_id).first()
        if apartment is None:
            logger.warning(
                "DeviceRegistry[apt%s]: no Apartment row with this ID — "
                "registry will start with zero devices.", self.apartment_id,
            )

        # ADS connection target comes from this apartment's own PLCDevice;
        # apartments without one yet (no real hardware commissioned) fall
        # back to the one PLCDevice marked is_default, so every user is
        # controlling the same real CX for now, until each apartment gets
        # its own commissioned hardware.
        #
        # is_active only gates Celery's background poll (tasks.py) — it is
        # NOT checked here. An on-demand request from the app must always
        # be attempted against the real device; background polling being
        # paused for this apartment is a separate, unrelated concern.
        #
        # No mock fallback: PLC_MOCK is an explicit opt-in for automated
        # tests only (default off). A real apartment's connection attempt
        # that fails stays failed and is reported as such — never silently
        # replaced with fake data.
        if not self._client.mock and apartment is not None:
            device = getattr(apartment, 'plc_device', None) or PLCDevice.objects.filter(is_default=True).first()
            if device is not None:
                self._client.netid = device.ams_net_id
                self._client.ip    = device.ip_address
                if self._modbus is not None:
                    self._modbus.ip = device.ip_address
                logger.info(
                    "DeviceRegistry[apt%s]: using PLCDevice '%s' (%s @ %s)",
                    self.apartment_id, device.name,
                    device.ams_net_id, device.ip_address,
                )
            else:
                logger.warning(
                    "DeviceRegistry[apt%s]: no PLCDevice exists anywhere yet — "
                    "install one via the installer workflow.", self.apartment_id,
                )

        ok = self._client.connect()
        if not ok:
            logger.error(
                "DeviceRegistry[apt%s]: real PLC unreachable at %s (%s) — "
                "no mock fallback; this apartment has no live data until "
                "the connection recovers.",
                self.apartment_id, self._client.ip, self._client.netid,
            )

        if self._modbus is not None:
            if not self._modbus.connect():
                logger.warning(
                    "DeviceRegistry[apt%s]: Modbus fallback unreachable at %s "
                    "(PLC_MODBUS_ENABLED=true but TF6250 may not be installed/"
                    "licensed on the target yet) — ADS remains the only path "
                    "until it connects.", self.apartment_id, self._modbus.ip,
                )

        if apartment is not None:
            for d in ApartmentDevice.objects.filter(apartment=apartment).select_related('room'):
                room_name = d.room.name if d.room else 'Unassigned'
                if d.device_type == ApartmentDevice.TYPE_DALI:
                    self.add_dali(channel=d.channel_or_index, name=d.name, room=room_name,
                                  apartment_device_id=d.pk)
                elif d.device_type == ApartmentDevice.TYPE_RELAY:
                    self.add_relay(channel=d.channel_or_index, name=d.name, room=room_name)
                elif d.device_type == ApartmentDevice.TYPE_SWITCH:
                    self.add_switch(index=d.channel_or_index, name=d.name, room=room_name)
                elif d.device_type == ApartmentDevice.TYPE_CURTAIN:
                    self.add_curtain(index=d.channel_or_index, name=d.name, room=room_name)
                elif d.device_type == ApartmentDevice.TYPE_APPLIANCE:
                    self.add_appliance(gvl_name=d.gvl_name, display_name=d.name, room=room_name)
                elif d.device_type == ApartmentDevice.TYPE_TOGGLE:
                    self.add_toggle(var_name=d.gvl_name, name=d.name, room=room_name,
                                     writable=d.gvl_name not in NAMED_RELAY_READONLY)
                elif d.device_type == ApartmentDevice.TYPE_NAMED_SWITCH:
                    self.add_named_switch(var_name=d.gvl_name, name=d.name, room=room_name)
                elif d.device_type == ApartmentDevice.TYPE_DOOR_SENSOR:
                    self.add_door_sensor(index=d.channel_or_index, name=d.name, room=room_name)
                elif d.device_type == ApartmentDevice.TYPE_WINDOW_SENSOR:
                    self.add_window_sensor(index=d.channel_or_index, name=d.name, room=room_name)
                elif d.device_type == ApartmentDevice.TYPE_MOTION_SENSOR:
                    self.add_motion_sensor(index=d.channel_or_index, name=d.name, room=room_name)

        # No security hardware exists in any apartment's I/O config yet
        # (no gvlIO, no key-switch/alarm/lockdown terminals). Wire this up
        # once a real ApartmentDevice/security row exists.

        self._started = True
        logger.info(
            "DeviceRegistry[apt%s] ready: %d DALI, %d relays, %d curtains, "
            "%d switches, %d door, %d window, %d motion, %d appliances, "
            "%d toggles, %d named switches  mock=%s",
            self.apartment_id,
            len(self._dali), len(self._relays), len(self._curtains),
            len(self._switches), len(self._door_sensors),
            len(self._window_sensors), len(self._motion_sensors),
            len(self._appliances), len(self._toggles),
            len(self._named_switches), self._client.mock,
        )

        self._load_automations()

    # ── Automation rules ──────────────────────────────────────────────────────
    # "When this input does X, do Y to that output" — configured entirely on
    # the phone (find_device/automation_views.py), executed here by
    # subscribing to the trigger's raw ADS variable via NotificationManager
    # (instant, event-driven — not polled) and writing the action the
    # moment the trigger matches. See AutomationRule's docstring: this is
    # additive, never a replacement for whatever's already hardwired inside
    # the PLC's own program for that input.

    def _trigger_object(self, device_type: str, index):
        if device_type == 'named_switch':
            return self._named_switches.get(index)
        return {
            'switch':        self._switches,
            'motion_sensor': self._motion_sensors,
            'door_sensor':   self._door_sensors,
            'window_sensor': self._window_sensors,
        }.get(device_type, {}).get(index)

    def _load_automations(self):
        from django.apps import apps
        AutomationRule = apps.get_model('find_device', 'AutomationRule')

        for rule in AutomationRule.objects.filter(
            apartment_id=self.apartment_id, enabled=True,
        ).select_related('trigger_device'):
            self._subscribe_automation(rule)

    def _subscribe_automation(self, rule) -> bool:
        trig = rule.trigger_device
        trig_ident = trig.gvl_name if trig.device_type == 'named_switch' else trig.channel_or_index
        trigger_obj = self._trigger_object(trig.device_type, trig_ident)
        if trigger_obj is None:
            logger.warning(
                "automation rule %s: trigger device not in registry (%s "
                "not assigned/loaded) — skipped", rule.pk, trig_ident,
            )
            return False

        expected = rule.trigger_state
        rule_id = rule.pk

        def _cb(var_name, value, ts):
            if bool(value) == expected:
                self._execute_automation(rule_id)

        ok = self._notifications.subscribe(
            trigger_obj.notification_var, trigger_obj.notification_plctype, _cb,
        )
        if ok:
            with self._lock:
                self._automation_subs[rule_id] = (trigger_obj.notification_var, _cb)
        return ok

    def _execute_automation(self, rule_id: int):
        from django.apps import apps
        AutomationRule = apps.get_model('find_device', 'AutomationRule')
        ApartmentDevice = apps.get_model('find_device', 'ApartmentDevice')
        rule = AutomationRule.objects.filter(pk=rule_id, enabled=True).select_related('action_device').first()
        if rule is None:
            return

        action = rule.action_device
        try:
            if action.device_type == ApartmentDevice.TYPE_DALI:
                dev = self.dali(action.channel_or_index)
                if dev is not None:
                    dev.set_brightness(int(rule.action_value))
            elif action.device_type == ApartmentDevice.TYPE_RELAY:
                dev = self.relay(action.channel_or_index)
                if dev is not None:
                    dev.set_state(rule.action_value.strip().lower() == 'true')
            elif action.device_type == ApartmentDevice.TYPE_CURTAIN:
                dev = self.curtain(action.channel_or_index)
                cmd = {'stop': CurtainMotor.STOP, 'up': CurtainMotor.UP, 'down': CurtainMotor.DOWN}.get(
                    rule.action_value.strip().lower(),
                )
                if dev is not None and cmd is not None:
                    dev.set_command(cmd)
            elif action.device_type == ApartmentDevice.TYPE_APPLIANCE:
                dev = self.appliance(action.gvl_name)
                if dev is not None:
                    dev.set_state(rule.action_value.strip().lower() == 'true')
            elif action.device_type == ApartmentDevice.TYPE_TOGGLE:
                dev = self.toggle(action.gvl_name)
                if dev is not None:
                    dev.set_state(rule.action_value.strip().lower() == 'true')
            logger.info("automation rule %s (%s) fired", rule_id, rule.name)
        except Exception:
            logger.exception("automation rule %s: action failed", rule_id)

    def reload_automation(self, rule_id: int):
        """Call after creating/enabling/editing a rule so it takes effect
        immediately, without needing a process restart."""
        from django.apps import apps
        AutomationRule = apps.get_model('find_device', 'AutomationRule')

        self.remove_automation(rule_id)
        rule = AutomationRule.objects.filter(pk=rule_id, enabled=True).select_related('trigger_device').first()
        if rule is not None:
            self._subscribe_automation(rule)

    def remove_automation(self, rule_id: int):
        """Call after deleting/disabling a rule to stop reacting to it."""
        with self._lock:
            entry = self._automation_subs.pop(rule_id, None)
        if entry is not None:
            var_name, cb = entry
            self._notifications.unsubscribe(var_name, cb)

    # ── Registration helpers ──────────────────────────────────────────────────

    def add_dali(self, channel: int, name: str, room: str, apartment_device_id: int = 0):
        with self._lock:
            self._dali[channel] = DaliChannel(channel, name, room, self._client,
                                              apartment_device_id=apartment_device_id)

    def fade_dali(self, channel: int, target_percent: int, duration_ms: int) -> bool:
        """
        Start (or replace) a background fade on channel to target_percent
        over duration_ms. Returns immediately — the fade runs on a daemon
        thread against the same live ADS connection, mirroring
        flash_raw_dali's pattern.

        A generation token per channel means a second fade request (e.g.
        the user drags the dim-speed slider again mid-fade) increments the
        token, and the older thread's should_continue() check goes False
        on its next step and exits cleanly — the two never fight over the
        same channel writing conflicting levels.
        """
        dev = self._dali.get(channel)
        if dev is None:
            return False

        with self._lock:
            self._fade_generation[channel] = self._fade_generation.get(channel, 0) + 1
            my_gen = self._fade_generation[channel]

        def _should_continue() -> bool:
            with self._lock:
                return self._fade_generation.get(channel) == my_gen

        def _run():
            try:
                dev.fade_to(target_percent, duration_ms, _should_continue)
            except Exception:
                logger.exception("fade_dali ch%d: fade failed", channel)

        threading.Thread(target=_run, daemon=True).start()
        return True

    def flash_raw_dali(self, channel: int) -> dict:
        """
        Flash any physically valid DALI channel (1-31, skipping 29) even
        when it has no ApartmentDevice row yet — the light-relabel identify
        flow needs to test still-unassigned channels, not just ones already
        registered via add_dali(). Reuses the same live ADS connection.
        """
        self._start()
        probe = DaliChannel(channel, name="", room="", client=self._client)
        original = probe.read_actual_level()
        flash = 20 if original >= 70 else 80
        probe.set_brightness(flash)

        def _restore():
            time.sleep(1.5)
            try:
                probe.set_brightness(original)
            except Exception:
                pass

        threading.Thread(target=_restore, daemon=True).start()
        return {"channel": channel, "original": original, "flash": flash}

    def flash_raw_relay(self, channel: int) -> dict:
        """Pulse any physically valid wall-relay channel (1-16) even when it
        has no ApartmentDevice row yet — mirrors flash_raw_dali."""
        self._start()
        probe = WallRelay(channel, name="", room="", client=self._client)
        original = probe.read_state()
        probe.set_state(True)

        def _restore():
            time.sleep(0.8)
            try:
                probe.set_state(original)
            except Exception:
                pass

        threading.Thread(target=_restore, daemon=True).start()
        return {"channel": channel, "original": original}

    def flash_raw_curtain(self, index: int) -> dict:
        """Drive any physically valid curtain (1-2) UP briefly then stop,
        even when it has no ApartmentDevice row yet — mirrors flash_raw_dali."""
        self._start()
        probe = CurtainMotor(index, name="", room="", client=self._client)
        probe.set_command(CurtainMotor.UP)

        def _stop():
            time.sleep(0.8)
            try:
                probe.set_command(CurtainMotor.STOP)
            except Exception:
                pass

        threading.Thread(target=_stop, daemon=True).start()
        return {"channel": index}

    # Every physically addressable input channel, independent of whether it
    # has an ApartmentDevice row — used by the light-relabel "identify
    # inputs" flow so an installer can press a physical switch/sensor and
    # see exactly which raw channel just changed, before deciding whether
    # to assign it. One batched ADS read for all of them (up to 88
    # channels) rather than 88 individual round trips.
    RAW_SWITCH_INDICES        = range(1, 49)   # gvlDALI.bSwitchOn1-48
    RAW_MOTION_SENSOR_INDICES = range(1, 9)    # gvlDALI.bSensor0-7
    RAW_DOOR_SENSOR_INDICES   = range(1, 17)   # gvlIO.aPyDoorSensor[1-16]
    RAW_WINDOW_SENSOR_INDICES = range(1, 17)   # gvlIO.aPyWindowSensor[1-16]

    def read_raw_inputs(self) -> dict:
        self._start()

        var_of = {
            'switches':       lambda i: f'gvlDALI.bSwitchOn{i}',
            'motion_sensors': lambda i: f'gvlDALI.bSensor{i - 1}',
            'door_sensors':   lambda i: f'gvlIO.aPyDoorSensor[{i}]',
            'window_sensors': lambda i: f'gvlIO.aPyWindowSensor[{i}]',
        }
        indices = {
            'switches':       self.RAW_SWITCH_INDICES,
            'motion_sensors': self.RAW_MOTION_SENSOR_INDICES,
            'door_sensors':   self.RAW_DOOR_SENSOR_INDICES,
            'window_sensors': self.RAW_WINDOW_SENSOR_INDICES,
        }

        # One read_list_by_name call PER GROUP, not one combined call across
        # all 88 channels — door_sensors/window_sensors target gvlIO, which
        # doesn't exist in either apartment's TwinCAT project (see devices.py
        # module docstring), so a single combined sum-read used to fail the
        # moment it hit one nonexistent symbol, nulling every switch and
        # motion sensor in the same call along with it (fixed 2026-08-18).
        #
        # That alone wasn't enough: within the switches group itself, index
        # 3 has a known symbol mismatch (see project memory) AND indices
        # 46-48 were never declared in the GVL at all (it only goes up to
        # 45) — any single bad index still fails that whole group's batch
        # the same way. Found 2026-08-19 once a live connection made it
        # possible to actually see real per-index errors instead of a
        # fully-disconnected 503. Fix: on a group's batch failure, fall back
        # to one read per index so only the genuinely-bad ones go null —
        # batch stays the fast path, this fallback only costs anything when
        # a group actually has a bad symbol in it.
        result = {}
        for group, idx_range in indices.items():
            group_map = {var_of[group](i): pyads.PLCTYPE_BOOL for i in idx_range}
            if self._client.mock:
                raw = {k: False for k in group_map}
            else:
                raw = self._client.read_batch(group_map)
                if not raw:
                    raw = {}
                    for i in idx_range:
                        var = var_of[group](i)
                        try:
                            raw[var] = self._client.read(var, pyads.PLCTYPE_BOOL)
                        except Exception:
                            raw[var] = None
            result[group] = {i: raw.get(var_of[group](i)) for i in idx_range}
        return result

    def add_relay(self, channel: int, name: str, room: str):
        with self._lock:
            self._relays[channel] = WallRelay(channel, name, room, self._client)

    def add_curtain(self, index: int, name: str, room: str):
        with self._lock:
            self._curtains[index] = CurtainMotor(index, name, room, self._client)

    def add_switch(self, index: int, name: str, room: str):
        with self._lock:
            self._switches[index] = SwitchInput(index, name, room, self._client)

    def add_door_sensor(self, index: int, name: str, room: str):
        with self._lock:
            self._door_sensors[index] = MagneticSensor(
                index, 'door', name, room, self._client)

    def add_window_sensor(self, index: int, name: str, room: str):
        with self._lock:
            self._window_sensors[index] = MagneticSensor(
                index, 'window', name, room, self._client)

    def add_motion_sensor(self, index: int, name: str, room: str):
        with self._lock:
            self._motion_sensors[index] = MotionSensor(
                index, name, room, self._client)

    def add_appliance(self, gvl_name: str, display_name: str, room: str):
        with self._lock:
            self._appliances[gvl_name] = ApplianceRelay(
                gvl_name, display_name, room, self._client)

    def add_toggle(self, var_name: str, name: str, room: str, writable: bool = True):
        with self._lock:
            self._toggles[var_name] = NamedRelay(
                var_name, name, room, self._client, writable=writable)

    def add_named_switch(self, var_name: str, name: str, room: str):
        with self._lock:
            self._named_switches[var_name] = NamedSwitchInput(
                var_name, name, room, self._client)

    # ── Accessors ─────────────────────────────────────────────────────────────

    def dali(self, channel: int)       -> Optional[DaliChannel]:      return self._dali.get(channel)
    def relay(self, channel: int)      -> Optional[WallRelay]:        return self._relays.get(channel)
    def curtain(self, index: int)      -> Optional[CurtainMotor]:     return self._curtains.get(index)
    def switch(self, index: int)       -> Optional[SwitchInput]:      return self._switches.get(index)
    def appliance(self, gvl_name: str) -> Optional[ApplianceRelay]:  return self._appliances.get(gvl_name)
    def toggle(self, var_name: str)    -> Optional[NamedRelay]:     return self._toggles.get(var_name)
    def named_switch(self, var_name: str) -> Optional[NamedSwitchInput]: return self._named_switches.get(var_name)
    def door_sensor(self, index: int)  -> Optional[MagneticSensor]:  return self._door_sensors.get(index)
    def window_sensor(self, index: int)-> Optional[MagneticSensor]:  return self._window_sensors.get(index)
    def motion_sensor(self, index: int)-> Optional[MotionSensor]:    return self._motion_sensors.get(index)

    def security(self)            -> Optional[SecurityController]: return self._security
    def all_dali(self)            -> List[DaliChannel]:     return list(self._dali.values())
    def all_relays(self)          -> List[WallRelay]:       return list(self._relays.values())
    def all_curtains(self)        -> List[CurtainMotor]:    return list(self._curtains.values())
    def all_switches(self)        -> List[SwitchInput]:     return list(self._switches.values())
    def all_appliances(self)      -> List[ApplianceRelay]:  return list(self._appliances.values())
    def all_toggles(self)         -> List[NamedRelay]:      return list(self._toggles.values())
    def all_named_switches(self)  -> List[NamedSwitchInput]: return list(self._named_switches.values())
    def all_door_sensors(self)    -> List[MagneticSensor]:  return list(self._door_sensors.values())
    def all_window_sensors(self)  -> List[MagneticSensor]:  return list(self._window_sensors.values())
    def all_motion_sensors(self)  -> List[MotionSensor]:    return list(self._motion_sensors.values())

    def rooms(self) -> List[str]:
        seen, result = set(), []
        for d in (*self._dali.values(), *self._relays.values(), *self._curtains.values()):
            if d.room not in seen:
                seen.add(d.room)
                result.append(d.room)
        return result

    @property
    def mock(self)      -> bool: return self._client.mock
    @property
    def connected(self) -> bool: return self._client.is_connected
    @property
    def modbus_connected(self) -> bool: return self._modbus is not None and self._modbus.is_connected

    # ── ADS/Modbus fallback ───────────────────────────────────────────────────
    # Only covers what POU_Modbus actually bridges on the PLC side: DALI
    # channels 1-16 and relays 1-4 (see GVL.TcGVL). Everything else
    # (switches, sensors, curtains, appliances) has no Modbus path and is
    # untouched by any of this — ADS failures there behave exactly as
    # before. self._modbus is None entirely unless PLC_MODBUS_ENABLED=true.

    def _modbus_ready(self) -> bool:
        return self._modbus is not None and self._modbus.is_connected

    def read_dali_actual_pct(self, channel: int) -> Optional[int]:
        """DALI actual level (0-100%). Falls back to Modbus if ADS fails."""
        dev = self._dali.get(channel)
        if dev is None:
            return None
        try:
            return dev.read_actual_level()
        except Exception as exc:
            if not (self._modbus_ready() and 1 <= channel <= 16):
                raise
            logger.warning("DALI ch%d: ADS read failed (%s) — falling back to Modbus", channel, exc)
            raw = self._modbus.read_dali_level(channel)
            return None if raw is None else byte_to_pct(raw)

    def write_dali_brightness(self, channel: int, percent: int):
        """Set DALI brightness (0-100%). Falls back to Modbus if ADS fails."""
        dev = self._dali.get(channel)
        if dev is None:
            raise ValueError(f"DALI channel {channel} not configured")
        try:
            dev.set_brightness(percent)
        except Exception as exc:
            if not (self._modbus_ready() and 1 <= channel <= 16):
                raise
            logger.warning("DALI ch%d: ADS write failed (%s) — falling back to Modbus", channel, exc)
            if not self._modbus.write_dali_level(channel, pct_to_byte(percent)):
                raise ConnectionError(f"DALI ch{channel}: both ADS and Modbus writes failed") from exc

    def read_relay_actual(self, channel: int) -> Optional[bool]:
        """Relay actual state (channel 1-4). Falls back to Modbus if ADS fails."""
        dev = self._relays.get(channel)
        if dev is None:
            return None
        try:
            return dev.read_state()
        except Exception as exc:
            if not (self._modbus_ready() and 1 <= channel <= 4):
                raise
            logger.warning("Relay ch%d: ADS read failed (%s) — falling back to Modbus", channel, exc)
            return self._modbus.read_relay(channel - 1)

    def write_relay_state(self, channel: int, on: bool):
        """Set relay state (channel 1-4). Falls back to Modbus if ADS fails."""
        dev = self._relays.get(channel)
        if dev is None:
            raise ValueError(f"Relay channel {channel} not configured")
        try:
            dev.set_state(on)
        except Exception as exc:
            if not (self._modbus_ready() and 1 <= channel <= 4):
                raise
            logger.warning("Relay ch%d: ADS write failed (%s) — falling back to Modbus", channel, exc)
            if not self._modbus.write_relay(channel - 1, on):
                raise ConnectionError(f"Relay ch{channel}: both ADS and Modbus writes failed") from exc

    def _fill_dali_gaps_from_modbus(self, levels: dict) -> dict:
        if not self._modbus_ready():
            return levels
        filled = dict(levels)
        for channel in self._dali:
            if filled.get(channel) is not None or not (1 <= channel <= 16):
                continue
            raw = self._modbus.read_dali_level(channel)
            if raw is not None:
                filled[channel] = byte_to_pct(raw)
        return filled

    def _fill_relay_gaps_from_modbus(self, states: dict) -> dict:
        if not self._modbus_ready():
            return states
        filled = dict(states)
        for channel in self._relays:
            if filled.get(channel) is not None or not (1 <= channel <= 4):
                continue
            val = self._modbus.read_relay(channel - 1)
            if val is not None:
                filled[channel] = val
        return filled

    # ── Batched ADS read ──────────────────────────────────────────────────────
    # Folds N per-device ADS round trips into a single read_list_by_name() sum
    # read (pyads.Connection.read_list_by_name / ADSClient.read_batch). Falls
    # back to per-device reads in mock mode, where there is no real ADS round
    # trip to save.

    def _batch_read_group(self, devices: dict) -> dict:
        if not devices:
            return {}

        if self._client.mock:
            result = {}
            for key, dev in devices.items():
                try:
                    result[key] = (
                        dev.read_actual_level() if hasattr(dev, 'read_actual_level')
                        else dev.read_state()
                    )
                except Exception as exc:
                    logger.error("mock read %s[%s]: %s", type(dev).__name__, key, exc)
                    result[key] = None
            return result

        type_map = {dev.batch_var: dev.batch_plctype for dev in devices.values()}
        raw = self._client.read_batch(type_map)
        result = {}
        for key, dev in devices.items():
            if dev.batch_var in raw:
                try:
                    result[key] = dev.decode_batch(raw[dev.batch_var])
                except Exception as exc:
                    logger.error("decode %s: %s", dev.batch_var, exc)
                    result[key] = None
            else:
                result[key] = None
        if not raw:
            logger.error(
                "batch read failed for %d device(s) starting at %s",
                len(devices), next(iter(type_map), '?'),
            )
        return result

    # ── Full state read (hot path — called every 2 s by Flutter poll) ─────────

    def read_full_state(self) -> dict:
        dali_levels  = self._fill_dali_gaps_from_modbus(self._batch_read_group(self._dali))
        relay_states = self._fill_relay_gaps_from_modbus(self._batch_read_group(self._relays))

        # ADSClient._ensure_connected() now fails fast (no blocking
        # reconnect) when disconnected, so this is mostly a fast-path
        # optimization rather than the timeout-avoidance it used to be —
        # still worth skipping N pointless calls in one pass once the PLC is
        # actually down. Only a genuine connection failure should trigger
        # this short-circuit: a per-symbol error (e.g. ADSError 1808 "symbol
        # not found", the pre-existing Switch 3 bug) means the connection is
        # fine and every OTHER variable would still read correctly — treating
        # it the same as a dead connection was blanking every door/window/
        # motion/appliance/toggle read on every single poll, discovered
        # 2026-08-18 while adding NamedRelay/toggle devices. Re-checking
        # is_connected after each exception (rather than latching a boolean
        # on the first one) tells the two cases apart.
        plc_down = (not self._client.mock) and (not self._client.is_connected)

        def _read_group(devices: dict, label: str) -> dict:
            nonlocal plc_down
            out = {}
            for idx, dev in devices.items():
                if plc_down:
                    out[idx] = None
                    continue
                try:
                    out[idx] = dev.read_state()
                except Exception as exc:
                    logger.error("%s %s read: %s", label, idx, exc)
                    out[idx] = None
                    plc_down = (not self._client.mock) and (not self._client.is_connected)
            return out

        curtain_states   = _read_group(self._curtains, "Curtain")
        switch_states     = _read_group(self._switches, "Switch")
        door_states        = _read_group(self._door_sensors, "Door sensor")
        window_states      = _read_group(self._window_sensors, "Window sensor")
        motion_states      = _read_group(self._motion_sensors, "Motion sensor")
        appliance_states   = _read_group(self._appliances, "Appliance")
        toggle_states       = _read_group(self._toggles, "Toggle")
        named_switch_states = _read_group(self._named_switches, "Named switch")

        security_state = {}
        if self._security:
            try:
                security_state = self._security.read_full_state()
            except Exception as exc:
                logger.error("Security read: %s", exc)

        return {
            'mock':        self._client.mock,
            'apartment_id': self.apartment_id,
            'plc_connected':    self._client.is_connected,
            'modbus_connected': self.modbus_connected,
            'dali':        dali_levels,
            'relays':      relay_states,
            'curtains':    curtain_states,
            'switches':    switch_states,
            'door_sensors':   door_states,
            'window_sensors': window_states,
            'motion_sensors': motion_states,
            'appliances':  appliance_states,
            'toggles':     toggle_states,
            'named_switches': named_switch_states,
            'security':    security_state,
        }

    # ── Multi-tenant lookup ────────────────────────────────────────────────────

    @classmethod
    def for_apartment(cls, apt_id: int) -> 'DeviceRegistry':
        """
        Return (or lazily create) the registry for a specific apartment.

        This is the only way to obtain a DeviceRegistry — apartment_id must
        always come from the authenticated user's ApartmentMembership (see
        views.py), never from client-supplied input, or one resident could
        address another apartment's hardware.
        """
        with cls._apt_lock:
            if apt_id not in cls._apt_instances:
                inst = cls(apartment_id=apt_id)
                inst._start()
                cls._apt_instances[apt_id] = inst
            return cls._apt_instances[apt_id]

    @classmethod
    def active_instances(cls) -> List['DeviceRegistry']:
        """All apartment registries that have been used at least once in
        this process — i.e. have an open (or attempted) ADS connection.
        Used by the health monitor instead of eagerly connecting to every
        apartment in the database on a schedule."""
        with cls._apt_lock:
            return list(cls._apt_instances.values())
