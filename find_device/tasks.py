"""
Celery tasks for Lugh.

Queues:
  plc           — high-frequency PLC state polling (every 2 s)
  alarms        — alarm threshold evaluation (every 5 s)
  notifications — push notification dispatch
  housekeeping  — low-frequency maintenance jobs (expiry sweeps, archival)
"""
from __future__ import annotations

import logging
import time

from celery import shared_task
from django.utils import timezone

logger = logging.getLogger("lumina.tasks")

# Per-alarm cooldown: don't re-notify within this many seconds for the same
# (device_id, var_name) pair while the alarm stays active.
_ALARM_COOLDOWN_S = 300  # 5 minutes
_alarm_last_notified: dict[tuple, float] = {}


# ── PLC polling ───────────────────────────────────────────────────────────────

@shared_task(name="find_device.tasks.poll_plc_state", bind=True,
             max_retries=3, default_retry_delay=5)
def poll_plc_state(self):
    """
    Poll every active apartment's DeviceRegistry and push variable deltas
    into EventBus + DeviceValueCache so SSE clients receive live updates.

    Runs every 2 s via Celery Beat (see settings.CELERY_BEAT_SCHEDULE).
    """
    try:
        import time as _time
        from .models import Apartment
        from .plc.registry import DeviceRegistry
        from .realtime.views import DeviceValueCache
        from .realtime.event_bus import EventBus

        cache  = DeviceValueCache.instance()
        bus    = EventBus.instance()
        ts     = _time.time()
        polled = 0

        apartments = (
            Apartment.objects
            .filter(plc_device__is_active=True)
            .select_related("plc_device")
        )

        for apt in apartments:
            try:
                registry  = DeviceRegistry.for_apartment(apt.pk)
                state     = registry.read_full_state()
                device_id = apt.plc_device.pk

                def _pub(var: str, val):
                    cache.update(device_id, var, val, ts)
                    bus.publish(device_id, var, val, ts)

                for ch, level in (state.get("dali") or {}).items():
                    if level is not None:
                        _pub(f"gvlDALI.nPyChannel_{int(ch):02d}", level)

                for ch, on in (state.get("relays") or {}).items():
                    if on is not None:
                        _pub(f"gvlIO.bPyRelay_{int(ch):02d}", bool(on))

                for ch, pos in (state.get("curtains") or {}).items():
                    if pos is not None:
                        _pub(f"gvlIO.nPyCurtainPos_{int(ch):02d}", pos)

                for ch, open_ in (state.get("door_sensors") or {}).items():
                    if open_ is not None:
                        _pub(f"gvlIO.bPyDoor_{int(ch):02d}", bool(open_))

                for ch, open_ in (state.get("window_sensors") or {}).items():
                    if open_ is not None:
                        _pub(f"gvlIO.bPyWindow_{int(ch):02d}", bool(open_))

                for ch, motion in (state.get("motion_sensors") or {}).items():
                    if motion is not None:
                        _pub(f"gvlIO.bPyMotion_{int(ch):02d}", bool(motion))

                polled += 1
            except Exception as exc:
                logger.warning("poll_plc_state: apartment %d failed — %s", apt.pk, exc)

        logger.debug("poll_plc_state: polled %d apartment(s)", polled)
    except Exception as exc:
        logger.error("poll_plc_state: unexpected error — %s", exc)
        raise self.retry(exc=exc)


# ── Alarm evaluation ──────────────────────────────────────────────────────────

# Thresholds for automatic alarm detection
_ALARM_THRESHOLDS = {
    "gvlSafety.nPyCO2Level":                  ("CO2 Level",        lambda v: v > 1500),
    "gvlSafety.bPyFireAlarm":                  ("Fire Alarm",       lambda v: v is True),
    "gvlSafety.bPySprinklerActive":            ("Sprinkler Active", lambda v: v is True),
    "gvlIO.bPyAlarmTriggered":                 ("Intruder Alarm",   lambda v: v is True),
}


@shared_task(name="find_device.tasks.check_alarms", bind=True, max_retries=2)
def check_alarms(self):
    """
    Evaluate alarm thresholds against the last-known PLC state and dispatch
    push notifications for any that have become active since the last check.
    A per-alarm cooldown (_ALARM_COOLDOWN_S) prevents notification storms when
    an alarm condition remains active across multiple evaluation cycles.

    Runs every 5 s via Celery Beat.
    """
    try:
        from .models import PLCDevice
        from .realtime.views import DeviceValueCache

        cache = DeviceValueCache.instance()
        now   = time.monotonic()
        # Guard: apartment FK is nullable — skip devices with no linked apartment
        devices = PLCDevice.objects.filter(is_active=True).select_related("apartment")

        for device in devices:
            if device.apartment is None:
                continue

            snapshot = cache.get_all(device.pk)
            for var_name, (label, predicate) in _ALARM_THRESHOLDS.items():
                entry = snapshot.get(var_name)
                if entry is None:
                    continue
                if predicate(entry.get("value")):
                    cooldown_key = (device.pk, var_name)
                    last_sent = _alarm_last_notified.get(cooldown_key, 0)
                    if now - last_sent < _ALARM_COOLDOWN_S:
                        continue  # within cooldown window — skip

                    _alarm_last_notified[cooldown_key] = now
                    logger.warning(
                        "ALARM: device=%d  %s=%s  (%s)",
                        device.pk, var_name, entry.get("value"), label,
                    )
                    send_notification.delay(
                        apartment_id=device.apartment_id,
                        title=f"Alert: {label}",
                        body=f"{label} detected in {device.apartment.name}",
                        priority="high",
                    )
    except Exception as exc:
        logger.error("check_alarms: unexpected error — %s", exc)
        raise self.retry(exc=exc)


# ── Notification dispatch ─────────────────────────────────────────────────────

@shared_task(name="find_device.tasks.send_notification", bind=True, max_retries=3,
             default_retry_delay=10)
def send_notification(self, apartment_id: int, title: str, body: str,
                      priority: str = "normal"):
    """
    Dispatch a push notification to all active users of an apartment.

    In a production deployment this would call FCM / APNs.  Currently logs
    the notification; wire up the push provider credentials via env vars
    FIREBASE_SERVER_KEY / APNS_KEY_ID when ready.
    """
    try:
        from .models import ApartmentMembership
        members = ApartmentMembership.objects.filter(
            apartment_id=apartment_id,
        ).select_related("user", "user__profile")

        logger.info(
            "NOTIFICATION [%s] apt=%d  '%s': %s  (%d members)",
            priority.upper(), apartment_id, title, body, members.count(),
        )
        # TODO: integrate FCM/APNs here when push tokens are stored in UserProfile
    except Exception as exc:
        logger.error("send_notification: error — %s", exc)
        raise self.retry(exc=exc)


# ── Housekeeping ──────────────────────────────────────────────────────────────

@shared_task(name="find_device.tasks.expire_temporary_access")
def expire_temporary_access():
    """
    Sweep TemporaryAccess grants that have passed their expires_at timestamp
    and mark them as revoked.  Runs every minute via Beat.
    """
    try:
        from .models import TemporaryAccess
        now = timezone.now()
        expired = TemporaryAccess.objects.filter(
            expires_at__lte=now,
            revoked=False,
        )
        count = expired.count()
        if count:
            expired.update(revoked=True)
            logger.info("expire_temporary_access: revoked %d grant(s)", count)
    except Exception as exc:
        logger.error("expire_temporary_access: error — %s", exc)


@shared_task(name="find_device.tasks.archive_audit_log")
def archive_audit_log():
    """
    Archive AuditLog entries older than 90 days to keep the primary table fast.
    Runs daily at 02:00 UTC via Beat.
    """
    try:
        from django.utils import timezone as tz
        from datetime import timedelta

        cutoff = tz.now() - timedelta(days=90)

        from .models import AuditLog
        deleted, _ = AuditLog.objects.filter(created_at__lt=cutoff).delete()
        if deleted:
            logger.info("archive_audit_log: purged %d entries older than 90d", deleted)
    except Exception as exc:
        logger.error("archive_audit_log: error — %s", exc)
