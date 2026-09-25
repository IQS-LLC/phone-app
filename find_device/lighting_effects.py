"""
Server-side lighting effects that drive real ADS writes directly — no PLC
program changes, no new TwinCAT logic. Currently just the "Christmas mode"
chase requested for Building Common Areas.

Runs as a background daemon thread per apartment (same shape as
superscan.py's scan-in-a-thread pattern), not a Celery task — it needs to
start/stop on a plain synchronous view call and step continuously while
active, which fits a stoppable thread better than a queued job.

Apartment.christmas_mode_active in the DB is the source of truth for
whether the show *should* be running; the thread is just the current
executor. That's what lets it survive a server restart (see
resume_active_chases, called every minute by embedded_scheduler) and be
stopped from any process (the loop re-checks the flag periodically).

Honest hardware constraint: this building's CX currently exposes its lights
as plain BOOL outputs (GVL_Relay.bRelay0-3, and GVL_DALI.bLamp, which the
PLC program maps to all DALI ballasts in group 0 together) — not
individually addressable, dimmable ballasts. So this is an on/off chase, not
a per-ballast brightness show. Per-ballast dimming needs individual DALI
short-address control; see docs/plc-integration.md.
"""
from __future__ import annotations

import logging
import threading
from typing import Dict

logger = logging.getLogger("find_device.lighting_effects")

# apartment_id -> threading.Event (set() to signal "stop")
_active: Dict[int, threading.Event] = {}
_lock = threading.Lock()

_STEP_S = 0.6
# How often (in steps) the loop re-reads the DB flag, so a stop issued from
# another process — or a flag cleared any other way — ends the show.
_FLAG_CHECK_EVERY = 10


def is_running(apartment_id: int) -> bool:
    with _lock:
        return apartment_id in _active


def has_devices(apartment_id: int) -> bool:
    from find_device.plc.registry import DeviceRegistry
    try:
        return bool(DeviceRegistry.for_apartment(apartment_id).all_templated())
    except Exception:
        return False


def start_christmas_chase(apartment_id: int) -> bool:
    """Idempotent — a second call while already running is a no-op.
    Callers must set Apartment.christmas_mode_active=True *before* calling,
    or the loop's first flag check will see the old False and exit."""
    with _lock:
        if apartment_id in _active:
            return False
        stop_event = threading.Event()
        _active[apartment_id] = stop_event

    threading.Thread(
        target=_run_chase, args=(apartment_id, stop_event),
        name=f"christmas-chase-apt{apartment_id}", daemon=True,
    ).start()
    logger.info("Christmas chase started for apartment %s", apartment_id)
    return True


def stop_christmas_chase(apartment_id: int) -> bool:
    """Signals the running thread; it turns everything off itself on the way
    out (doing it from here would race a write already in flight and could
    leave one light on). If nothing is running in this process — stale flag
    after a restart — turn everything off directly."""
    with _lock:
        stop_event = _active.pop(apartment_id, None)
    if stop_event is None:
        _all_off(apartment_id)
        return False
    stop_event.set()
    logger.info("Christmas chase stop requested for apartment %s", apartment_id)
    return True


def resume_active_chases():
    """Restart any show the DB says should be running but isn't — e.g. after
    the server process was restarted mid-show."""
    from django.apps import apps
    from django.db import close_old_connections
    close_old_connections()
    Apartment = apps.get_model("find_device", "Apartment")
    for apt_id in Apartment.objects.filter(christmas_mode_active=True).values_list("pk", flat=True):
        if not is_running(apt_id) and has_devices(apt_id):
            logger.info("Christmas chase resuming for apartment %s", apt_id)
            start_christmas_chase(apt_id)


def _all_off(apartment_id: int):
    from find_device.plc.registry import DeviceRegistry
    try:
        for dev in DeviceRegistry.for_apartment(apartment_id).all_templated():
            try:
                dev.write(False)
            except Exception:
                pass
    except Exception as exc:
        logger.error("Christmas chase: failed to restore off state: %s", exc)


def _flag_still_set(apartment_id: int) -> bool:
    from django.apps import apps
    from django.db import close_old_connections
    close_old_connections()
    Apartment = apps.get_model("find_device", "Apartment")
    return Apartment.objects.filter(pk=apartment_id, christmas_mode_active=True).exists()


def _run_chase(apartment_id: int, stop_event: threading.Event):
    from django.apps import apps
    from find_device.plc.registry import DeviceRegistry

    try:
        devices = DeviceRegistry.for_apartment(apartment_id).all_templated()
        if not devices:
            logger.warning("Christmas chase: apartment %s has no scheme-driven devices to chase", apartment_id)
            Apartment = apps.get_model("find_device", "Apartment")
            Apartment.objects.filter(pk=apartment_id).update(christmas_mode_active=False)
            return

        # A gentle back-and-forth "theater chase" — one light on at a time —
        # reads as a deliberate synchronized pattern rather than flicker, and
        # never asks two outputs to switch in the same instant.
        n = len(devices)
        order = list(range(n)) + list(range(n - 2, 0, -1)) if n > 1 else [0]
        step = 0

        while not stop_event.is_set():
            if step and step % _FLAG_CHECK_EVERY == 0 and not _flag_still_set(apartment_id):
                break
            lit = order[step % len(order)]
            for i, dev in enumerate(devices):
                try:
                    dev.write(i == lit)
                except Exception as exc:
                    logger.error("Christmas chase: write failed for device %s: %s",
                                 getattr(dev, "apartment_device_id", "?"), exc)
            step += 1
            stop_event.wait(_STEP_S)
    except Exception:
        logger.exception("Christmas chase crashed for apartment %s", apartment_id)
    finally:
        _all_off(apartment_id)
        with _lock:
            # Only remove our own entry — a stop-then-start may already have
            # registered a newer thread for this apartment.
            if _active.get(apartment_id) is stop_event:
                _active.pop(apartment_id, None)
        logger.info("Christmas chase ended for apartment %s", apartment_id)
