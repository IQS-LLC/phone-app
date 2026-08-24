"""
PLC device abstractions built on top of ADSClient.

Corrected 2026-08-24: this docstring previously quoted a specific variable
table (aPyLevel/aPyWallRelay/aPySwitchState/gvlIO.aPyCurtainCmd) that had
gone stale relative to the actual per-class implementations below and was
never caught because nothing re-derives this comment from the real code.
Each class's own docstring is now the authoritative source for its exact
GVL/variable names — read those directly rather than trusting a summary
here, which is exactly the kind of drift that caused this correction. See
docs/plc-integration.md for the current, real GVL layout and
docs/AUDIT_FINDINGS.md §1 for the full audit that found this.

What's still true and worth knowing before reading the classes below:

- DALI dimmer *brightness* channels (`DaliChannel`) write their GVL
  correctly but are not yet wired into the live PLC control logic — see
  `docs/plc_proposals/README.md` for why (a related change broke
  building-wide switch lighting once live and both were reverted together)
  and the plan to fix it. Wall relays went through the same kind of
  proposal-then-revert cycle but were later re-applied via a different,
  isolated bridge GVL/POU that IS live — see `WallRelay`'s own docstring.
- `ApplianceRelay`, `MagneticSensor`, `MotionSensor` (indices 5-8), and
  `SecurityController` target a `gvlIO` GVL that does not exist in either
  apartment's real TwinCAT project — these only work in `PLC_MOCK` mode
  until matching hardware and PLC logic exist. See
  `docs/plc-integration.md`'s Hardware Support Matrix for the current,
  device-by-device state.
  Curtain motors (index 1-16):
    gvlIO.aPyCurtainCmd[N]     BYTE  0=stop 1=up 2=down   Python→PLC
    gvlIO.aPyCurtainState[N]   BYTE  0/1/2                PLC→Python readback

  Appliances (named):
    gvlIO.bPyFridgeCmd / bPyFridgeState
    gvlIO.bPyCoffeeMachineCmd / bPyCoffeeMachineState
    gvlIO.bPyMicrowaveCmd / bPyMicrowaveState

  Magnetic sensors:
    gvlIO.aPyDoorSensor[N]     BOOL  TRUE=open (index 1-16)
    gvlIO.aPyWindowSensor[N]   BOOL  TRUE=open (index 1-16)

  PIR/motion sensors (index 1-8):
    gvlIO.aPyMotionSensor[N]   BOOL  TRUE=motion detected

  Security:
    gvlIO.bPyKeySwitch         BOOL  PLC→Python  key switch physical state
    gvlIO.bPyAlarmArm          BOOL  Python→PLC  arm command
    gvlIO.bPyLockdown          BOOL  Python→PLC  lockdown command
    gvlIO.bPyAlarmState        BOOL  PLC→Python  armed state
    gvlIO.bPyAlarmTriggered    BOOL  PLC→Python  intrusion latched
    gvlIO.bPyLockdownState     BOOL  PLC→Python  lockdown active

Protocol for setting a DALI channel:
  1. write aPyLevel[N]    = target (0-254)
  2. write aPySetLevel[N] = True   (rising edge → PLC captures level)
  3. sleep ~50 ms
  4. write aPySetLevel[N] = False  (reset for next command)
"""
from __future__ import annotations

import logging
import time
from typing import Any, Dict, Optional

import pyads

logger = logging.getLogger(__name__)

# ── Helpers ───────────────────────────────────────────────────────────────────

def pct_to_byte(pct: int) -> int:
    return int(max(0, min(100, pct)) / 100 * 254)

def byte_to_pct(b: int) -> int:
    return round(max(0, min(254, b)) / 254 * 100)


# ── DaliChannel ───────────────────────────────────────────────────────────────

class DaliChannel:
    """
    Single Tridonic DALI dimmer channel, one per fbDALI102DimmerNSwitch
    instance in POU.TcPOU (real instance numbers: 1-28, 30, 31 — 29 was
    never declared, skip it).

    gvlController.aDaliLevel/aDaliSetLevel/aDaliActual[N] — deployed to a
    new, isolated gvlController.TcGVL + POU_Controller.TcPOU (see
    docs/plc_proposals/dali_dimmer_control.md), built, and downloaded.
    Deliberately does NOT wire bOn: an earlier attempt wired bOn into 28
    previously-unconnected FB inputs and that fought with the existing
    switch/motion-sensor logic, breaking switch-driven lighting
    building-wide. This time on/off is expressed purely through level
    (0 = off, >0 = on) via the same bSetLevel/nLevel pins already used for
    dimming — bOn/bOff are untouched on every instance, including 30/31
    where they're wired to a motion sensor.
    """

    MAX_CHANNEL = 31
    _MISSING_CHANNEL = 29  # never declared in POU.TcPOU
    _DEFAULT_ON_PERCENT = 100  # turn_on() with no remembered level goes here

    def __init__(self, channel: int, name: str, room: str, client,
                 apartment_device_id: int = 0):
        if not 1 <= channel <= self.MAX_CHANNEL or channel == self._MISSING_CHANNEL:
            raise ValueError(f"DALI channel must be 1-{self.MAX_CHANNEL} (excluding {self._MISSING_CHANNEL}), got {channel}")
        self.channel              = channel
        self.name                 = name
        self.room                 = room
        self.apartment_device_id  = apartment_device_id
        self._client              = client
        self._mock_level          = 0

    @property
    def _var_level(self)     -> str: return f'gvlController.aDaliLevel[{self.channel}]'
    @property
    def _var_set_level(self) -> str: return f'gvlController.aDaliSetLevel[{self.channel}]'
    @property
    def _var_actual(self)    -> str: return f'gvlController.aDaliActual[{self.channel}]'

    # Public alias + decoder so DeviceRegistry can fold this var into a
    # single ADS sum-read (read_list_by_name) across every DALI channel
    # instead of one round trip per channel.
    @property
    def batch_var(self) -> str: return self._var_actual
    batch_plctype = pyads.PLCTYPE_BYTE

    @staticmethod
    def decode_batch(raw: Any) -> int:
        return byte_to_pct(int(raw))

    def set_brightness(self, percent: int):
        level = pct_to_byte(percent)
        if self._client.mock:
            self._mock_level = level
            return
        self._client.write(self._var_level,     level, pyads.PLCTYPE_BYTE)
        self._client.write(self._var_set_level, True,  pyads.PLCTYPE_BOOL)
        time.sleep(0.05)
        self._client.write(self._var_set_level, False, pyads.PLCTYPE_BOOL)

    def fade_to(self, target_percent: int, duration_ms: int, should_continue):
        """
        Step from the current actual level to target_percent over
        duration_ms, checking should_continue() before every step so a
        newer fade request (e.g. the user drags the slider again) can
        cancel this one instead of the two fighting over the channel.

        Step count is capped, not scaled linearly with duration — this
        runs against a PLC (Windows CE, 2026-08 sessions on this project
        spent hours proving its ADS layer is fragile under load) so a
        slow 4s fade must spread the SAME handful of writes further apart,
        not send more of them. Each set_brightness() call already costs
        ~50ms+ from its own commit-pulse protocol, so duration_ms is a
        target, not a hard guarantee — real timing has protocol overhead
        on top, most noticeable at the fast end.
        """
        start = self.read_actual_level()
        if start == target_percent:
            return
        steps = max(2, min(16, duration_ms // 100))
        interval = duration_ms / steps / 1000.0
        for i in range(1, steps + 1):
            if not should_continue():
                return
            level = round(start + (target_percent - start) * (i / steps))
            self.set_brightness(level)
            if i < steps:
                time.sleep(interval)

    def turn_on(self):
        """Level-based on: no bOn pin is wired, so "on" is just a nonzero level."""
        self.set_brightness(self._DEFAULT_ON_PERCENT)

    def turn_off(self):
        """Level-based off: level 0, same bSetLevel/nLevel pins as dimming."""
        self.set_brightness(0)

    def read_actual_level(self) -> int:
        if self._client.mock:
            return byte_to_pct(self._mock_level)
        return byte_to_pct(int(self._client.read(self._var_actual, pyads.PLCTYPE_BYTE)))

    def to_dict(self) -> Dict[str, Any]:
        return {'channel': self.channel, 'name': self.name, 'room': self.room,
                'apartment_device_id': self.apartment_device_id,
                'device_type': 'dali_light'}


# ── WallRelay ─────────────────────────────────────────────────────────────────

class WallRelay:
    """
    Relay-driven wall light (channel 1-16; only 4 physical relays exist
    per apartment — bRelay0-3 / KL2809 — so 1-4 are in use).

    Read side: gvlDALI.bRelay{channel-1} — confirmed live on the real PLC
    (WallLight_POU.TcPOU writes it every scan from internal light state).

    Write side: gvlController.bRelayCmd{channel-1} / bRelaySet{channel-1} —
    deployed in the isolated gvlController.TcGVL + POU_Controller.TcPOU.
    A rising edge on bRelaySetN sets gvlDALI_State.bLightStateN (the same
    internal state WallLight_POU already mirrors into bRelayN every scan)
    for channels 1/3/4 (relays 0/2/3) — same effect as a physical switch
    press, doesn't touch WallLight_POU itself. Channel 2 / relay 1 (Guest
    Bathroom) is handled specially in POU_Controller since its physical
    output is driven by a motion sensor, not by the shared light state.
    """

    def __init__(self, channel: int, name: str, room: str, client):
        if not 1 <= channel <= 16:
            raise ValueError(f"WallRelay channel must be 1-16, got {channel}")
        self.channel = channel
        self.name    = name
        self.room    = room
        self._client = client
        self._mock_state = False

    @property
    def _var_state(self)    -> str: return f'gvlDALI.bRelay{self.channel - 1}'
    @property
    def _var_cmd(self)      -> str: return f'gvlController.bRelayCmd{self.channel - 1}'
    @property
    def _var_cmd_set(self)  -> str: return f'gvlController.bRelaySet{self.channel - 1}'

    # Public alias + decoder — see DaliChannel.batch_var.
    @property
    def batch_var(self) -> str: return self._var_state
    batch_plctype = pyads.PLCTYPE_BOOL

    @staticmethod
    def decode_batch(raw: Any) -> bool:
        return bool(raw)

    def set_state(self, on: bool):
        if self._client.mock:
            self._mock_state = on
            return
        self._client.write(self._var_cmd, on, pyads.PLCTYPE_BOOL)
        self._client.write(self._var_cmd_set, True,  pyads.PLCTYPE_BOOL)
        time.sleep(0.05)
        self._client.write(self._var_cmd_set, False, pyads.PLCTYPE_BOOL)

    def read_state(self) -> bool:
        if self._client.mock:
            return self._mock_state
        return bool(self._client.read(self._var_state, pyads.PLCTYPE_BOOL))

    def to_dict(self) -> Dict[str, Any]:
        return {'channel': self.channel, 'name': self.name, 'room': self.room,
                'device_type': 'wall_relay'}


# ── NamedRelay ────────────────────────────────────────────────────────────────

class NamedRelay:
    """
    Plain named BOOL relay/light living directly under gvlDALI — the 8
    fixtures added straight to POU_Controller.TcPOU without ever getting a
    gvlController bridge variable (big-area light, laundry/bathroom/master
    bathroom/guest bathroom ventilators, balcony light, mirror light, both
    Var Lights). Each is a single global BOOL, already linked to a real
    KL2809 output channel, toggled in the PLC only by a local push-button
    rising edge — there is no separate Cmd/commit pair like WallRelay or
    DaliChannel use.

    Because nothing in POU_Controller re-writes these every scan (unlike
    the laundry ventilator, see writable=False below), an ADS write here
    just sticks until the next physical button press flips it — so a
    direct write is a safe, correct remote toggle with no PLC change
    needed.

    writable=False is for gvlDALI.bventiliatorRelay specifically: POU_
    Controller sets `gvlDALI.bventiliatorRelay := gvlDALI.bSensor1;`
    unconditionally every 10ms scan, so any ADS write would be clobbered
    within one cycle. Modeled as read-only status until the PLC gets a
    manual-override branch (same pattern already sitting unused in
    POU_Controller for the old Guest Bathroom relay).
    """

    def __init__(self, var_name: str, name: str, room: str, client, writable: bool = True):
        self.var_name = var_name
        self.name     = name
        self.room     = room
        self.writable = writable
        self._client  = client
        self._mock_state = False

    @property
    def _var(self) -> str: return f'gvlDALI.{self.var_name}'

    # Public alias + decoder — see DaliChannel.batch_var.
    @property
    def batch_var(self) -> str: return self._var
    batch_plctype = pyads.PLCTYPE_BOOL

    @staticmethod
    def decode_batch(raw: Any) -> bool:
        return bool(raw)

    def set_state(self, on: bool):
        if not self.writable:
            raise ValueError(
                f"{self.var_name} is sensor-driven in the PLC (overwritten every "
                f"scan) — not remotely controllable until the PLC adds a manual "
                f"override branch.")
        if self._client.mock:
            self._mock_state = on
            return
        self._client.write(self._var, on, pyads.PLCTYPE_BOOL)

    def read_state(self) -> bool:
        if self._client.mock:
            return self._mock_state
        return bool(self._client.read(self._var, pyads.PLCTYPE_BOOL))

    def to_dict(self) -> Dict[str, Any]:
        return {'var_name': self.var_name, 'name': self.name, 'room': self.room,
                'writable': self.writable, 'device_type': 'toggle'}


# ── SwitchInput ───────────────────────────────────────────────────────────────

class SwitchInput:
    """
    Physical wall switch input (index 1-33 wired for real — gvlDALI.bSwitchOn1
    through bSwitchOn33, confirmed live on the real PLC; index up to 48
    accepted for future hardware). Index 30-33 are also read directly by
    WallLight_POU as the 4 relay-light toggle buttons — this class just
    reads the same raw input, it doesn't change what the PLC does with it.
    """

    def __init__(self, index: int, name: str, room: str, client):
        if not 1 <= index <= 48:
            raise ValueError(f"Switch index must be 1-48, got {index}")
        self.index   = index
        self.name    = name
        self.room    = room
        self._client = client
        self._mock_state = False

    @property
    def _var(self) -> str: return f'gvlDALI.bSwitchOn{self.index}'

    # Public alias for AutomationRule/NotificationManager subscription —
    # see DaliChannel.batch_var for the same pattern.
    @property
    def notification_var(self) -> str: return self._var
    notification_plctype = pyads.PLCTYPE_BOOL

    def read_state(self) -> bool:
        if self._client.mock:
            return self._mock_state
        return bool(self._client.read(self._var, pyads.PLCTYPE_BOOL))

    def to_dict(self) -> Dict[str, Any]:
        return {'index': self.index, 'name': self.name, 'room': self.room,
                'device_type': 'switch_input'}


# ── NamedSwitchInput ──────────────────────────────────────────────────────────

class NamedSwitchInput:
    """
    Read-only input counterpart to NamedRelay — a physical push-button wired
    directly into POU_Controller under its own unique name (e.g.
    "bVentilatorGuestButton", "bBalconLight") rather than a numbered slot in
    the bSwitchOn1..48 array SwitchInput expects. These are the buttons that
    drive the 8 writable NamedRelay fixtures (ventilators, balcony/var
    lights) found in the 2026-08-18 TwinCAT scan.

    Exists purely so these buttons can show up as Automation triggers and
    be identified/renamed — there is no write side, same as SwitchInput.
    """

    def __init__(self, var_name: str, name: str, room: str, client):
        self.var_name = var_name
        self.name     = name
        self.room     = room
        self._client  = client
        self._mock_state = False

    @property
    def _var(self) -> str: return f'gvlDALI.{self.var_name}'

    @property
    def notification_var(self) -> str: return self._var
    notification_plctype = pyads.PLCTYPE_BOOL

    def read_state(self) -> bool:
        if self._client.mock:
            return self._mock_state
        return bool(self._client.read(self._var, pyads.PLCTYPE_BOOL))

    def to_dict(self) -> Dict[str, Any]:
        return {'var_name': self.var_name, 'name': self.name, 'room': self.room,
                'device_type': 'named_switch'}


# ── CurtainMotor ──────────────────────────────────────────────────────────────

class CurtainMotor:
    """
    Curtain motor (index 1-2 — only 2 physical curtains exist: Curtain 1/2,
    driven by KL2809 relay outputs via gvlCurtain/POU_Curtain in the
    Apartmant16 TwinCAT project). Momentary/held-while-true on the PLC
    side (POU_Curtain: output stays on only while the button input is
    true, off as soon as it's released) — this class's stop/up/down
    command API is translated into that button-press model so the
    existing app/API contract (0=stop, 1=up, 2=down) doesn't change.

    Earlier revision of this class targeted gvlIO.aPyCurtainCmd/State,
    which was never implemented on the real PLC (confirmed: no gvlIO GVL
    exists in this project) — every read/write against it failed with
    ADSError: symbol not found. This retargets it at the GVL that
    actually exists.

    Commands : 0 = stop,  1 = up (open),  2 = down (close)
    State    : reflects the PLC's momentary Open/Close output, not a
    persisted position — this mirrors a held button, not a motor that
    runs to an end-stop on its own. Releasing (stop) reads back as 0 as
    soon as the PLC clears both outputs next scan.
    """

    STOP = 0
    UP   = 1
    DOWN = 2

    MAX_INDEX = 2  # gvlCurtain only wires Curtain 1 and Curtain 2

    def __init__(self, index: int, name: str, room: str, client):
        if not 1 <= index <= self.MAX_INDEX:
            raise ValueError(f"CurtainMotor index must be 1-{self.MAX_INDEX}, got {index}")
        self.index   = index
        self.name    = name
        self.room    = room
        self._client = client
        self._mock_state = 0   # 0/1/2

    @property
    def _var_open_btn(self)  -> str: return f'gvlCurtain.bCurtain{self.index}OpenBtn'
    @property
    def _var_close_btn(self) -> str: return f'gvlCurtain.bCurtain{self.index}CloseBtn'
    @property
    def _var_open(self)      -> str: return f'gvlCurtain.bCurtain{self.index}Open'
    @property
    def _var_close(self)     -> str: return f'gvlCurtain.bCurtain{self.index}Close'

    def set_command(self, cmd: int):
        """Send stop (0), up/open (1), or down/close (2)."""
        if cmd not in (self.STOP, self.UP, self.DOWN):
            raise ValueError(f"Curtain cmd must be 0/1/2, got {cmd}")
        if self._client.mock:
            self._mock_state = cmd
            return
        self._client.write(self._var_open_btn,  cmd == self.UP,   pyads.PLCTYPE_BOOL)
        self._client.write(self._var_close_btn, cmd == self.DOWN, pyads.PLCTYPE_BOOL)

    def read_state(self) -> int:
        if self._client.mock:
            return self._mock_state
        if bool(self._client.read(self._var_open, pyads.PLCTYPE_BOOL)):
            return self.UP
        if bool(self._client.read(self._var_close, pyads.PLCTYPE_BOOL)):
            return self.DOWN
        return self.STOP

    def to_dict(self) -> Dict[str, Any]:
        return {'index': self.index, 'name': self.name, 'room': self.room,
                'device_type': 'curtain_motor'}


# ── ApplianceRelay ────────────────────────────────────────────────────────────

# Canonical appliance names understood by both PLC GVL and this class
APPLIANCE_NAMES = ('Fridge', 'CoffeeMachine', 'Microwave')

class ApplianceRelay:
    """
    Smart appliance controlled by a relay (fridge, coffee machine, microwave).

    gvl_name must be one of: 'Fridge', 'CoffeeMachine', 'Microwave'
    Maps to gvlIO.bPy{gvl_name}Cmd / bPy{gvl_name}State
    """

    def __init__(self, gvl_name: str, display_name: str, room: str, client):
        if gvl_name not in APPLIANCE_NAMES:
            raise ValueError(f"gvl_name must be one of {APPLIANCE_NAMES}, got {gvl_name!r}")
        self.gvl_name     = gvl_name
        self.name         = display_name
        self.room         = room
        self._client      = client
        self._mock_state  = False

    @property
    def _var_cmd(self)   -> str: return f'gvlIO.bPy{self.gvl_name}Cmd'
    @property
    def _var_state(self) -> str: return f'gvlIO.bPy{self.gvl_name}State'

    def set_state(self, on: bool):
        if self._client.mock:
            self._mock_state = on
            return
        self._client.write(self._var_cmd, on, pyads.PLCTYPE_BOOL)

    def read_state(self) -> bool:
        if self._client.mock:
            return self._mock_state
        return bool(self._client.read(self._var_state, pyads.PLCTYPE_BOOL))

    def to_dict(self) -> Dict[str, Any]:
        return {'gvl_name': self.gvl_name, 'name': self.name, 'room': self.room,
                'device_type': 'appliance'}


# ── MagneticSensor ────────────────────────────────────────────────────────────

class MagneticSensor:
    """
    Door or window magnetic contact sensor (index 1-16).

    sensor_type: 'door' or 'window'
    Maps to gvlIO.aPyDoorSensor[N] or gvlIO.aPyWindowSensor[N]
    TRUE = open (contact broken).
    """

    def __init__(self, index: int, sensor_type: str, name: str, room: str, client):
        if not 1 <= index <= 16:
            raise ValueError(f"MagneticSensor index must be 1-16, got {index}")
        if sensor_type not in ('door', 'window'):
            raise ValueError(f"sensor_type must be 'door' or 'window', got {sensor_type!r}")
        self.index       = index
        self.sensor_type = sensor_type
        self.name        = name
        self.room        = room
        self._client     = client
        self._mock_state = False

    @property
    def _var(self) -> str:
        prefix = 'Door' if self.sensor_type == 'door' else 'Window'
        return f'gvlIO.aPy{prefix}Sensor[{self.index}]'

    @property
    def notification_var(self) -> str: return self._var
    notification_plctype = pyads.PLCTYPE_BOOL

    def read_state(self) -> bool:
        """Returns True if the door/window is open."""
        if self._client.mock:
            return self._mock_state
        return bool(self._client.read(self._var, pyads.PLCTYPE_BOOL))

    def to_dict(self) -> Dict[str, Any]:
        return {'index': self.index, 'sensor_type': self.sensor_type,
                'name': self.name, 'room': self.room,
                'device_type': 'magnetic_sensor'}


# ── MotionSensor ──────────────────────────────────────────────────────────────

class MotionSensor:
    """
    PIR / presence sensor (index 1-8; only 1-4 have real backing hardware
    today — gvlDALI.bSensor0-3, confirmed live on the real PLC and read
    directly by WallLight_POU / POU_GUEST_Bathroom for auto-on lighting.
    Indices 5-8 accepted for future hardware but have no real variable yet.
    """

    def __init__(self, index: int, name: str, room: str, client):
        if not 1 <= index <= 8:
            raise ValueError(f"MotionSensor index must be 1-8, got {index}")
        self.index   = index
        self.name    = name
        self.room    = room
        self._client = client
        self._mock_state = False

    @property
    def _var(self) -> str: return f'gvlDALI.bSensor{self.index - 1}'

    @property
    def notification_var(self) -> str: return self._var
    notification_plctype = pyads.PLCTYPE_BOOL

    def read_state(self) -> bool:
        if self._client.mock:
            return self._mock_state
        return bool(self._client.read(self._var, pyads.PLCTYPE_BOOL))

    def to_dict(self) -> Dict[str, Any]:
        return {'index': self.index, 'name': self.name, 'room': self.room,
                'device_type': 'motion_sensor'}


# ── SecurityController ────────────────────────────────────────────────────────

class SecurityController:
    """
    Alarm and lockdown controller (one per apartment).

    Writes:  bPyAlarmArm, bPyLockdown
    Reads:   bPyAlarmState, bPyAlarmTriggered, bPyLockdownState, bPyKeySwitch
    """

    def __init__(self, client):
        self._client = client
        self._mock = {'armed': False, 'triggered': False, 'lockdown': False, 'key': False}

    # ── Commands ──────────────────────────────────────────────────────────────

    def set_alarm_armed(self, armed: bool):
        if self._client.mock:
            self._mock['armed'] = armed
            return
        self._client.write('gvlIO.bPyAlarmArm', armed, pyads.PLCTYPE_BOOL)

    def set_lockdown(self, active: bool):
        if self._client.mock:
            self._mock['lockdown'] = active
            return
        self._client.write('gvlIO.bPyLockdown', active, pyads.PLCTYPE_BOOL)

    # ── State reads ───────────────────────────────────────────────────────────

    def read_alarm_state(self) -> bool:
        if self._client.mock:
            return self._mock['armed']
        return bool(self._client.read('gvlIO.bPyAlarmState', pyads.PLCTYPE_BOOL))

    def read_alarm_triggered(self) -> bool:
        if self._client.mock:
            return self._mock['triggered']
        return bool(self._client.read('gvlIO.bPyAlarmTriggered', pyads.PLCTYPE_BOOL))

    def read_lockdown_state(self) -> bool:
        if self._client.mock:
            return self._mock['lockdown']
        return bool(self._client.read('gvlIO.bPyLockdownState', pyads.PLCTYPE_BOOL))

    def read_key_switch(self) -> bool:
        if self._client.mock:
            return self._mock['key']
        return bool(self._client.read('gvlIO.bPyKeySwitch', pyads.PLCTYPE_BOOL))

    def read_full_state(self) -> dict:
        return {
            'armed':     self.read_alarm_state(),
            'triggered': self.read_alarm_triggered(),
            'lockdown':  self.read_lockdown_state(),
            'key_switch': self.read_key_switch(),
        }

    def to_dict(self) -> Dict[str, Any]:
        return {'device_type': 'security_controller'}


# ── TemplatedDevice ──────────────────────────────────────────────────────────

# Maps DeviceAddressScheme.plc_type (a plain string, kept in the DB rather
# than a pyads object so schemes stay serializable/DB-safe) to the actual
# pyads.PLCTYPE_* constant ADSClient.read()/write() need. Deliberately the
# same string vocabulary find_device/discovery/classifier.py already uses
# for _BOOL_TYPES/_INT_TYPES/_REAL_TYPES/_STR_TYPES, so a scheme built from
# a SuperScan-discovered symbol's type_name needs no translation.
_PLC_TYPE_MAP = {
    'BOOL':    pyads.PLCTYPE_BOOL,
    'BYTE':    pyads.PLCTYPE_BYTE,
    'INT':     pyads.PLCTYPE_INT,
    'UINT':    pyads.PLCTYPE_UINT,
    'DINT':    pyads.PLCTYPE_DINT,
    'UDINT':   pyads.PLCTYPE_UDINT,
    'SINT':    pyads.PLCTYPE_SINT,
    'USINT':   pyads.PLCTYPE_USINT,
    'WORD':    pyads.PLCTYPE_WORD,
    'DWORD':   pyads.PLCTYPE_DWORD,
    'REAL':    pyads.PLCTYPE_REAL,
    'LREAL':   pyads.PLCTYPE_LREAL,
    'STRING':  pyads.PLCTYPE_STRING,
    'WSTRING': pyads.PLCTYPE_WSTRING,
}


class TemplatedDevice:
    """
    A device whose GVL addressing comes from a DeviceAddressScheme database
    row instead of being hardcoded in a Python class — the "new GVL layout
    without writing new Python" escape hatch. See
    find_device.models.DeviceAddressScheme's docstring for the full design
    rationale, and docs/plc-integration.md for when to reach for this vs.
    writing a real class the way every other device type in this file does.

    Deliberately narrower than the hardcoded classes above: it supports the
    common read/write(-then-commit-pulse) shape that DaliChannel/WallRelay/
    CurtainMotor all already share, not every possible protocol nuance
    (e.g. CurtainMotor's momentary-button semantics still need a real
    class). A scheme whose device genuinely needs bespoke logic should
    become a real class, following the pattern of any class above it in
    this file — this exists for the common case, not every case.

    A malformed template (e.g. referencing a placeholder the scheme's
    format_var doesn't provide) raises immediately from __init__, so a bad
    DeviceAddressScheme row fails loud at DeviceRegistry._start() time —
    surfaced as a startup warning for that one device, exactly like any
    other per-device construction failure already is — rather than
    resolving to a wrong variable name that silently reads/writes nothing
    useful.
    """

    def __init__(self, apartment_device_id: int, channel_or_index: Optional[int],
                 gvl_name: str, name: str, room: str, client, scheme):
        self.apartment_device_id = apartment_device_id
        self.name                = name
        self.room                = room
        self._client             = client
        self._scheme              = scheme
        self._mock_value         = False if scheme.plc_type == 'BOOL' else 0

        fmt = lambda t: scheme.format_var(t, channel_or_index=channel_or_index, gvl_name=gvl_name)
        self._var_read   = fmt(scheme.read_var_template)  if scheme.read_var_template  else None
        self._var_write  = fmt(scheme.write_var_template) if scheme.write_var_template else None
        self._var_commit = fmt(scheme.commit_var_template) if scheme.commit_var_template else None
        self._plctype = _PLC_TYPE_MAP.get(scheme.plc_type, pyads.PLCTYPE_BOOL)

    def read(self) -> Any:
        if self._var_read is None:
            raise ValueError(f"DeviceAddressScheme '{self._scheme.name}' has no read_var_template")
        if self._client.mock:
            return self._mock_value
        return self._client.read(self._var_read, self._plctype)

    def write(self, value: Any):
        """
        Writes value, then pulses the commit variable true->false if the
        scheme has one — the same write-then-commit-pulse shape
        DaliChannel.set_brightness()/WallRelay already use, generalized.
        A scheme with no commit_var_template just writes once, for GVLs
        that apply a write immediately with no separate commit pin.
        """
        if self._var_write is None:
            raise ValueError(f"DeviceAddressScheme '{self._scheme.name}' has no write_var_template")
        if self._client.mock:
            self._mock_value = value
            return
        self._client.write(self._var_write, value, self._plctype)
        if self._var_commit is not None:
            self._client.write(self._var_commit, True, pyads.PLCTYPE_BOOL)
            time.sleep(0.05)
            self._client.write(self._var_commit, False, pyads.PLCTYPE_BOOL)

    def to_dict(self) -> Dict[str, Any]:
        return {
            'apartment_device_id': self.apartment_device_id,
            'name': self.name, 'room': self.room,
            'device_type': 'templated',
            'address_scheme': self._scheme.name,
        }
