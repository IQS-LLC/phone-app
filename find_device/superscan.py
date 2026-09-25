"""
SuperScan — generic discovery / capability-mapping / safe-testing engine.

Discover -> Describe -> Test safely -> Observe -> Correlate -> Store -> Expose

This is deliberately NOT a pile of hardcoded per-device-type hacks: every
mode walks the exact same list of capabilities DeviceRegistry already
builds from ApartmentDevice rows (see _known_capabilities), so adding a new
device TYPE to the app automatically makes SuperScan understand it too,
with no changes needed here. The one type-specific branch that does exist
(_safe_active_test) exists only because "how do you safely pulse a curtain
vs. a dimmer" is inherently different — everything else (persistence,
diffing, pacing, cancellation, logging) is generic.

Safety
──────
  * Passive/Quick mode sends ZERO commands — enumerate + read only.
  * Full/Deep mode only actuates capabilities that already have a real,
    modeled, writable ApartmentDevice of a known-safe type (dali, relay,
    curtain, appliance, writable toggle) — the exact same set the
    Commissioning Wizard's I/O test already actuates in production
    (commissioning_views.test_io). Nothing undocumented, nothing
    sensor-driven, nothing outside that allowlist is ever written to.
  * Every active test runs to completion (command -> wait -> restore ->
    verify) before the next one starts — no parallel/overlapping commands,
    one pass per capability per run, INTER_TEST_DELAY_S between each.
  * cancel_requested is checked before every step — a running scan reacts
    to STOP within one step's time (worst case ~1.5s, a DALI flash).
  * Deep mode's unknown-symbol pass NEVER writes anything. Raw symbols
    pulled from DiscoveryCache with no matching modeled capability are
    recorded can_safely_test=False, test_status=TEST_NOT_TESTED, and are
    never touched by any active-test code path in this file.
"""
from __future__ import annotations

import logging
import threading
import time

from django.db import IntegrityError, transaction
from django.utils import timezone

from .models import (
    ScanRun, DiscoveredCapability, CapabilityTestLog,
    ApartmentDevice, DiscoveryCache,
)
from .plc.registry import DeviceRegistry
from .plc.devices import CurtainMotor

logger = logging.getLogger("lumina.superscan")

# Pacing — deliberately generous. Multiple past sessions on this project
# proved the CX8190's ADS layer goes unstable under rapid command bursts
# (see registry.py / ads_client.py notes) — SuperScan must not reproduce
# that, so every active test is followed by a pause before the next starts.
INTER_TEST_DELAY_S = 0.3
MAX_ACTIVE_TESTS_PER_RUN = 60  # generous ceiling; this apartment has ~40 devices total

# Real I/O GVLs worth correlating in Deep mode. Every other GVL surfaced by
# DiscoveryCache (Global_Constants, GVL_INTERNAL, TC_EVENTS, MAIN, POU*,
# ParameterList, Global_Version, Global_Variables) is TwinCAT/compiler
# bookkeeping, never a real device — see project memory on the 454-symbol
# 2026-08-19 scan for the full inventory this was filtered from.
DEEP_SCAN_GVLS = frozenset({
    "gvlDALI", "gvlDALI_State", "gvlController", "gvlCurtain", "GVL",
    # Building Common Areas' CX-A6E703 (Runtime 4) uses a different
    # integrator's naming convention for the same kinds of real I/O.
    "GVL_DALI", "GVL_Relay", "GVL_Bilding",
})

# device_type values eligible for an active (write) test — same allowlist
# commissioning_views.test_io already actuates in production.
ACTIVE_TEST_TYPES = frozenset({"dali", "relay", "curtain", "appliance", "toggle"})


class ScanCancelled(Exception):
    pass


class ScanAlreadyRunning(Exception):
    """Raised when the DB's one-running-scan-per-apartment constraint (see
    ScanRun.Meta) rejects a concurrent start — the real, race-proof version
    of the view's .exists() pre-check, which only closes the common case."""
    pass


def start_scan(apartment, mode: str, user) -> ScanRun:
    """
    Create the ScanRun row and launch the engine on a background daemon
    thread. Returns immediately with the (status=running) row — callers
    poll GET .../status/<id>/ for progress, or flip cancel_requested for
    STOP SCAN.
    """
    try:
        with transaction.atomic():
            run = ScanRun.objects.create(apartment=apartment, mode=mode, started_by=user)
    except IntegrityError as exc:
        raise ScanAlreadyRunning() from exc
    threading.Thread(target=_run_in_background, args=(run.pk,), daemon=True).start()
    return run


def _run_in_background(scan_run_id: int):
    run = ScanRun.objects.filter(pk=scan_run_id).first()
    if run is None:
        return
    try:
        SuperScanEngine(run).execute()
    except Exception:
        logger.exception("superscan run %s: unhandled engine error", scan_run_id)
        ScanRun.objects.filter(pk=scan_run_id).update(
            status=ScanRun.STATUS_FAILED,
            error_message="Internal error — see server logs.",
            finished_at=timezone.now(),
        )


def _apartment_device_lookup(apartment):
    by_channel, by_gvl = {}, {}
    for d in ApartmentDevice.objects.filter(apartment=apartment):
        if d.gvl_name:
            by_gvl[(d.device_type, d.gvl_name)] = d
        if d.channel_or_index is not None:
            by_channel[(d.device_type, d.channel_or_index)] = d
    return by_channel, by_gvl


def _guess_direction(name: str, type_name: str) -> str:
    n = name.lower()
    if any(tok in n for tok in ("cmd", "setlevel", "set_", "arm", "lockdown")) and "set" in n:
        return "output"
    if any(tok in n for tok in ("cmd", "arm", "lockdown")):
        return "output"
    if any(tok in n for tok in ("state", "actual", "sensor", "switch", "status", "triggered")):
        return "input"
    return "both"


class SuperScanEngine:
    """
    One run of SuperScan against one apartment. The ScanRun row IS the
    progress/status/cancel channel — nothing else needs to reach back into
    this object once execute() starts on its background thread.
    """

    def __init__(self, run: ScanRun):
        self.run = run
        self.apartment = run.apartment
        self.mode = run.mode

    # ── control ──────────────────────────────────────────────────────────────

    def _check_cancel(self):
        self.run.refresh_from_db(fields=["cancel_requested"])
        if self.run.cancel_requested:
            raise ScanCancelled()

    def _progress(self, current: int, total: int, label: str):
        self.run.progress_current = current
        self.run.progress_total = max(total, 1)
        self.run.progress_label = label
        self.run.save(update_fields=["progress_current", "progress_total", "progress_label"])

    # ── entry point ──────────────────────────────────────────────────────────

    def execute(self):
        try:
            self._run_scan()
        except ScanCancelled:
            self.run.status = ScanRun.STATUS_STOPPED
            self.run.finished_at = timezone.now()
            self.run.save()
            logger.info("superscan run %s: stopped by user", self.run.pk)
            return
        except Exception as exc:
            logger.exception("superscan run %s failed", self.run.pk)
            self.run.status = ScanRun.STATUS_FAILED
            self.run.error_message = str(exc)
            self.run.finished_at = timezone.now()
            self.run.save()
            return

        self.run.status = ScanRun.STATUS_COMPLETED
        self.run.finished_at = timezone.now()
        self.run.save()
        logger.info(
            "superscan run %s (%s) completed: %d capabilities, %d tested "
            "(%d pass/%d fail), %d unknown, %d new, %d changed, %d removed",
            self.run.pk, self.mode, self.run.capabilities_discovered,
            self.run.capabilities_tested, self.run.tests_passed, self.run.tests_failed,
            self.run.unknown_count, self.run.new_since_last,
            self.run.changed_since_last, self.run.removed_since_last,
        )

    # ── enumeration ──────────────────────────────────────────────────────────

    def _known_capabilities(self, registry: DeviceRegistry):
        """(device_type, identifier, direction, data_type, valid_range, obj)
        for every capability currently modeled in this apartment's
        registry — the single generic list every mode reads from."""
        items = []
        for d in registry.all_dali():
            items.append(("dali", str(d.channel), "output", "percent", "0-100", d))
        for d in registry.all_relays():
            items.append(("relay", str(d.channel), "output", "bool", "true/false", d))
        for d in registry.all_curtains():
            items.append(("curtain", str(d.index), "output", "int", "0=stop,1=up,2=down", d))
        for d in registry.all_appliances():
            items.append(("appliance", d.gvl_name, "output", "bool", "true/false", d))
        for d in registry.all_toggles():
            direction = "output" if d.writable else "input"
            items.append(("toggle", d.var_name, direction, "bool", "true/false", d))
        for d in registry.all_switches():
            items.append(("switch", str(d.index), "input", "bool", "true/false", d))
        for d in registry.all_named_switches():
            items.append(("named_switch", d.var_name, "input", "bool", "true/false", d))
        for d in registry.all_door_sensors():
            items.append(("door_sensor", str(d.index), "input", "bool", "true=open", d))
        for d in registry.all_window_sensors():
            items.append(("window_sensor", str(d.index), "input", "bool", "true=open", d))
        for d in registry.all_motion_sensors():
            items.append(("motion_sensor", str(d.index), "input", "bool", "true=motion", d))
        for d in registry.all_templated():
            items.append(("custom", str(d.apartment_device_id), "output", "bool", "true/false", d))
        sec = registry.security()
        if sec is not None:
            items.append(("security", "controller", "both", "bool", "n/a", sec))
        return items

    @staticmethod
    def _read_value(obj):
        try:
            if hasattr(obj, "read_actual_level"):
                return obj.read_actual_level()
            if hasattr(obj, "read_full_state"):
                return obj.read_full_state()
            return obj.read_state()
        except Exception as exc:
            logger.warning("superscan read failed on %r: %s", obj, exc)
            return None

    @staticmethod
    def _raw_var_names(obj) -> set:
        """Every internal ADS variable name this device object touches —
        used to tell Deep mode's raw-symbol pass which real PLC variables
        already belong to a modeled capability, so it only ever reports
        genuinely unmapped symbols as unknown."""
        names = set()
        for attr in (
            "_var", "_var_level", "_var_set_level", "_var_actual",
            "_var_state", "_var_cmd", "_var_cmd_set",
            "_var_open_btn", "_var_close_btn", "_var_open", "_var_close",
            "_var_read", "_var_write", "_var_commit",
            "batch_var", "notification_var",
        ):
            val = getattr(obj, attr, None)
            if isinstance(val, str):
                names.add(val)
        return names

    def _upsert_capability(
        self, device_type, identifier, direction, data_type, valid_range,
        name, room, apartment_device, value,
    ) -> DiscoveredCapability:
        read_ok = value is not None
        defaults = dict(
            apartment_device=apartment_device,
            name=name or identifier,
            room=room or "",
            direction=direction,
            is_known_type=True,
            raw_var_name="",
            data_type=data_type,
            valid_range=valid_range,
            can_safely_test=(direction == "output" and device_type in ACTIVE_TEST_TYPES),
            last_seen_scan=self.run,
            still_present=True,
        )
        if read_ok:
            defaults["last_value"] = str(value)
            defaults["confidence"] = "high"
        else:
            # A transient read failure must NEVER destroy the last confirmed
            # value — that's exactly the "temporary outage makes a healthy
            # device look broken" failure mode this project hit live. Omit
            # last_value from defaults entirely: update_or_create leaves an
            # existing row's value untouched, and a brand-new row falls back
            # to the field's own "" default — either way nothing is
            # overwritten with a false reading. still_present stays True
            # (the row is still touched this scan, from the DB-backed
            # ApartmentDevice list, independent of whether the live read
            # worked) so it's never wrongly marked "removed" below either.
            # confidence drops to "low" so the dashboard can visibly flag a
            # stale reading instead of presenting it as freshly confirmed.
            defaults["confidence"] = "low"

        cap, _created = DiscoveredCapability.objects.update_or_create(
            apartment=self.apartment, device_type=device_type, identifier=identifier,
            defaults=defaults,
        )
        if cap.test_status == DiscoveredCapability.TEST_NOT_TESTED:
            cap.test_status = DiscoveredCapability.TEST_OBSERVED
            cap.save(update_fields=["test_status"])
        return cap

    # ── main pass ────────────────────────────────────────────────────────────

    def _run_scan(self):
        prior_values = {
            (dt, ident): val
            for dt, ident, val in (
                DiscoveredCapability.objects
                .filter(apartment=self.apartment, still_present=True)
                .values_list("device_type", "identifier", "last_value")
            )
        }

        try:
            registry = DeviceRegistry.for_apartment(self.apartment.pk)
        except Exception as exc:
            raise RuntimeError(f"Cannot reach PLC: {exc}") from exc

        by_channel, by_gvl = _apartment_device_lookup(self.apartment)
        known = self._known_capabilities(registry)

        active_mode = self.mode in (ScanRun.MODE_FULL, ScanRun.MODE_DEEP)
        writable = [item for item in known if item[2] == "output" and item[0] in ACTIVE_TEST_TYPES]
        writable = writable[:MAX_ACTIVE_TESTS_PER_RUN]
        total_steps = len(known) + (len(writable) if active_mode else 0)

        step = 0
        new_count = 0
        changed_count = 0
        known_var_names: set = set()

        for device_type, identifier, direction, data_type, valid_range, obj in known:
            self._check_cancel()
            step += 1
            self._progress(step, total_steps, f"Reading {device_type} {identifier}")

            known_var_names |= self._raw_var_names(obj)
            value = self._read_value(obj)
            name = getattr(obj, "name", "") or identifier
            room = getattr(obj, "room", "") or ""
            apt_device = (
                by_gvl.get((device_type, identifier))
                or (by_channel.get((device_type, int(identifier))) if identifier.isdigit() else None)
            )

            key = (device_type, identifier)
            was_new = key not in prior_values
            cap = self._upsert_capability(
                device_type, identifier, direction, data_type, valid_range,
                name, room, apt_device, value,
            )
            if was_new:
                new_count += 1
            elif prior_values.get(key, "") != cap.last_value:
                changed_count += 1

        self.run.devices_discovered = len(known)
        self.run.capabilities_discovered = len(known)
        self.run.new_since_last = new_count
        self.run.changed_since_last = changed_count

        tested = passed = failed = 0
        if active_mode:
            for device_type, identifier, direction, data_type, valid_range, obj in writable:
                self._check_cancel()
                step += 1
                self._progress(step, total_steps, f"Testing {device_type} {identifier}")

                cap = DiscoveredCapability.objects.get(
                    apartment=self.apartment, device_type=device_type, identifier=identifier,
                )

                # Check connectivity BEFORE attempting — if the PLC is
                # already known down, don't burn a round trip finding that
                # out per-device (that's the "retry storm" pattern the
                # audit flagged) and, more importantly, don't record it as
                # TEST_FAILED: that reads to a technician as "this device is
                # broken" when the truth is "we never got to ask it."
                if not registry.connected:
                    cap.test_status = DiscoveredCapability.TEST_UNAVAILABLE
                    cap.save(update_fields=["test_status"])
                    CapabilityTestLog.objects.create(
                        capability=cap, scan_run=self.run,
                        command_sent="", params={}, state_before="", state_after="",
                        response="skipped — PLC unavailable", success=False,
                        latency_ms=None, error="PLC disconnected before this test could run",
                    )
                    tested += 1
                    failed += 1
                    continue

                success, log_kwargs = self._safe_active_test(device_type, obj)
                tested += 1
                if success:
                    passed += 1
                    cap.test_status = DiscoveredCapability.TEST_PASSED
                    cap.physical_effect_confirmed = True
                elif not registry.connected:
                    # The test itself is what revealed the PLC dropped —
                    # same "not the device's fault" distinction as above,
                    # discovered mid-attempt instead of before it.
                    failed += 1
                    cap.test_status = DiscoveredCapability.TEST_UNAVAILABLE
                else:
                    failed += 1
                    cap.test_status = DiscoveredCapability.TEST_FAILED
                cap.last_tested_at = timezone.now()
                cap.save(update_fields=["test_status", "physical_effect_confirmed", "last_tested_at"])
                CapabilityTestLog.objects.create(capability=cap, scan_run=self.run, **log_kwargs)

                time.sleep(INTER_TEST_DELAY_S)

        self.run.capabilities_tested = tested
        self.run.tests_passed = passed
        self.run.tests_failed = failed

        unknown_count = 0
        if self.mode == ScanRun.MODE_DEEP:
            unknown_count = self._deep_unknown_pass(known_var_names)
        self.run.unknown_count = unknown_count

        # Anything still marked present from a prior run but not touched by
        # THIS run (last_seen_scan != this run) is no longer discoverable —
        # a device/capability that disappeared since the last scan.
        removed_qs = (
            DiscoveredCapability.objects
            .filter(apartment=self.apartment, still_present=True)
            .exclude(last_seen_scan=self.run)
        )
        self.run.removed_since_last = removed_qs.count()
        removed_qs.update(still_present=False)

        self.run.save()

    # ── active (write) testing ──────────────────────────────────────────────

    def _safe_active_test(self, device_type: str, obj) -> tuple:
        """
        Run the exact command -> wait -> restore -> verify protocol already
        proven safe in commissioning_views.test_io, but synchronously (so
        state_after/latency can be logged) and only against the allowlisted
        writable device types. Returns (success, CapabilityTestLog kwargs).
        """
        start = time.monotonic()
        command_sent, params = "", {}
        try:
            if device_type == "dali":
                original = obj.read_actual_level()
                flash = 20 if original >= 70 else 80
                command_sent, params = "set_brightness", {"target_percent": flash}
                obj.set_brightness(flash)
                time.sleep(1.5)
                obj.set_brightness(original)
                # 0.1s proved too short live: a DALI restore write reads back
                # 100ms later as still the flashed value, not yet the
                # restored one (channel 2, verified 2026-08-20 — the light
                # WAS correctly back at its original level moments later, the
                # test just read too early and logged a false failure).
                time.sleep(0.3)
                after = obj.read_actual_level()
                success = after == original
                before_s, after_s = str(original), str(after)

            elif device_type == "relay":
                original = obj.read_state()
                command_sent, params = "set_state", {"value": True}
                obj.set_state(True)
                time.sleep(0.8)
                mid = obj.read_state()
                obj.set_state(original)
                time.sleep(0.3)
                after = obj.read_state()
                success = (mid is True) and (after == original)
                before_s, after_s = str(original), str(after)

            elif device_type == "curtain":
                original = obj.read_state()
                command_sent, params = "set_command", {"cmd": "up"}
                obj.set_command(CurtainMotor.UP)
                time.sleep(0.8)
                obj.set_command(CurtainMotor.STOP)
                time.sleep(0.3)
                after = obj.read_state()
                success = after == CurtainMotor.STOP
                before_s, after_s = str(original), str(after)

            elif device_type == "appliance":
                original = obj.read_state()
                command_sent, params = "set_state", {"value": True}
                obj.set_state(True)
                time.sleep(0.8)
                mid = obj.read_state()
                obj.set_state(original)
                time.sleep(0.3)
                after = obj.read_state()
                success = (mid is True) and (after == original)
                before_s, after_s = str(original), str(after)

            elif device_type == "toggle":
                original = obj.read_state()
                command_sent, params = "set_state", {"value": not original}
                obj.set_state(not original)
                time.sleep(0.5)
                mid = obj.read_state()
                obj.set_state(original)
                time.sleep(0.3)
                after = obj.read_state()
                success = (mid == (not original)) and (after == original)
                before_s, after_s = str(original), str(after)

            else:
                return False, dict(
                    command_sent="", params={}, state_before="", state_after="",
                    response="no safe active test defined for this device type",
                    success=False, latency_ms=None, error="unsupported device_type",
                )

            latency_ms = (time.monotonic() - start) * 1000
            return success, dict(
                command_sent=command_sent, params=params,
                state_before=before_s, state_after=after_s,
                response="restored to original state" if success else "state did not restore as expected",
                success=success, latency_ms=latency_ms, error="",
            )
        except Exception as exc:
            latency_ms = (time.monotonic() - start) * 1000
            logger.warning("superscan active test %s failed: %s", device_type, exc)
            return False, dict(
                command_sent=command_sent, params=params,
                state_before="", state_after="", response="",
                success=False, latency_ms=latency_ms, error=str(exc),
            )

    # ── deep mode: unmapped raw symbols ─────────────────────────────────────

    def _refresh_discovery_cache(self, plc_device):
        """
        Re-enumerate the PLC's live symbol table so Deep mode sees devices
        wired in since the last scan (new ballasts, new relays) — previously
        it only read whatever DiscoveryCache a separate /discovery/ scan had
        left behind, and silently found nothing on a controller that had
        never been scanned that way. Falls back to the existing cache if
        the PLC can't be reached right now.
        """
        from .discovery.scanner import SymbolScanner
        from .discovery.classifier import classify_batch
        try:
            raw_symbols, duration_ms = SymbolScanner(
                ip=plc_device.ip_address, ams_net_id=plc_device.ams_net_id,
                ads_port=plc_device.ads_port,
                mock=DeviceRegistry.for_apartment(self.apartment.pk).mock,
            ).scan()
            symbols_json = [s.to_dict() for s in classify_batch(raw_symbols)]
            cache, _ = DiscoveryCache.objects.update_or_create(
                device=plc_device,
                defaults={
                    "symbols_json": symbols_json,
                    "scan_duration_ms": duration_ms,
                    "symbol_count": len(symbols_json),
                },
            )
            return cache
        except Exception as exc:
            logger.warning("SuperScan deep: live symbol refresh failed (%s) — using cached symbols", exc)
            try:
                return plc_device.discovery_cache
            except DiscoveryCache.DoesNotExist:
                return None

    def _deep_unknown_pass(self, known_var_names: set) -> int:
        try:
            plc_device = self.apartment.plc_device
        except Exception:
            return 0
        cache = self._refresh_discovery_cache(plc_device)
        if cache is None:
            return 0

        unknown_count = 0
        for sym in cache.symbols_json:
            self._check_cancel()
            gvl = sym.get("gvl", "")
            if gvl not in DEEP_SCAN_GVLS:
                continue
            full_name = sym.get("full_name", "")
            if not full_name or full_name in known_var_names:
                continue
            # full_name itself is a dotted GVL.var path — always short. What
            # isn't guaranteed short is the PLC's own inline comment, used
            # verbatim as the label (_assign_label in classifier.py) — some
            # TwinCAT library symbols carry multi-sentence doc comments
            # (discovered live: GVL.mb_Output_Coils' TF6250 comment is 993
            # chars). Truncate defensively rather than let one verbose
            # comment crash the whole Deep pass.
            identifier = full_name[:100]
            raw_name = full_name[:200]
            label = (sym.get("label") or sym.get("name") or full_name)[:150]

            direction = _guess_direction(sym.get("name", ""), sym.get("type_name", ""))
            DiscoveredCapability.objects.update_or_create(
                apartment=self.apartment, device_type="unknown_symbol", identifier=identifier,
                defaults=dict(
                    apartment_device=None,
                    name=label,
                    room="",
                    direction=direction,
                    is_known_type=False,
                    raw_var_name=raw_name,
                    data_type=sym.get("type_name", "")[:40],
                    valid_range="",
                    confidence="low",
                    can_safely_test=False,
                    last_value="",
                    last_seen_scan=self.run,
                    still_present=True,
                    notes=(
                        f"Raw symbol from the discovery symbol cache (scanned "
                        f"{cache.scanned_at:%Y-%m-%d %H:%M} UTC) with no matching "
                        f"modeled device — never actively tested."
                    ),
                ),
            )
            unknown_count += 1
        return unknown_count
