"""
In-process stand-in for Celery Beat, for a single-process deployment with no
Celery worker/Redis (e.g. the native `manage.py runserver` stopgap used
while the production stack is being rebuilt).

Opt-in only via LUGH_EMBEDDED_SCHEDULER=1 — never enable it alongside a
real Celery Beat, or the same jobs run twice. Covers just the building
controls that would otherwise silently never fire without Beat:
  - sunset/sunrise manual override (tasks.apply_sunset_sunrise_overrides_once)
  - resuming a Christmas show the DB says should be running
"""
from __future__ import annotations

import logging
import threading

logger = logging.getLogger("find_device.embedded_scheduler")

_TICK_S = 60
_started = False
_lock = threading.Lock()


def start():
    global _started
    with _lock:
        if _started:
            return
        _started = True
    threading.Thread(target=_loop, name="lugh-embedded-scheduler", daemon=True).start()
    logger.info("Embedded scheduler started (every %ss)", _TICK_S)


def _loop():
    from . import lighting_effects
    from .tasks import apply_sunset_sunrise_overrides_once

    stop = threading.Event()
    while True:
        for job in (apply_sunset_sunrise_overrides_once, lighting_effects.resume_active_chases):
            try:
                job()
            except Exception:
                logger.exception("Embedded scheduler job %s failed", job.__name__)
        stop.wait(_TICK_S)
