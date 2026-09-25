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
import os
import time
import urllib.request

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


# ── PLC heartbeat / outage alerting ────────────────────────────────────────────

# Every real outage traced this project has been physical (power/network),
# not a protocol bug — this doesn't fix the CX going dark, it makes it
# visible immediately instead of "found out by opening the app later".
#
# Don't alert on ordinary reconnect blips: ADSClient's own backoff loop
# tops out at 60 s, so anything shorter than this is normal self-healing,
# not an outage worth waking someone up for.
_OUTAGE_ALERT_THRESHOLD_S = 120

def _send_outage_webhook(message: str):
    """
    Optional zero-setup notification channel — e.g. ntfy.sh (POST to
    https://ntfy.sh/<your-topic>, no account needed, free Android/iOS app)
    or a Slack/Discord incoming webhook. Unset by default (no-op) until
    PLC_OUTAGE_WEBHOOK_URL is configured; this exists alongside
    send_notification (below) which is the in-app channel but currently
    logs only — FCM/APNs isn't wired up yet.
    """
    url = os.getenv("PLC_OUTAGE_WEBHOOK_URL")
    if not url:
        return
    try:
        req = urllib.request.Request(
            url, data=message.encode("utf-8"), method="POST",
            headers={"Content-Type": "text/plain; charset=utf-8"},
        )
        urllib.request.urlopen(req, timeout=5)
    except Exception as exc:
        logger.warning("check_plc_heartbeat: webhook delivery failed: %s", exc)


@shared_task(name="find_device.tasks.check_plc_heartbeat", bind=True, max_retries=2)
def check_plc_heartbeat(self):
    """
    Track every apartment's PLC reachability (ADS or, if enabled, Modbus)
    and alert exactly once on outage-start and once on recovery.

    Deliberately does NOT filter on PLCDevice.is_active — that flag only
    gates the background SSE convenience poll (poll_plc_state above), it
    doesn't mean "don't bother checking this one's actually reachable".
    Apartment 16's PLCDevice currently has is_active=False, which would
    silently make this a no-op for the one real apartment if it used the
    same filter poll_plc_state does.

    down_since lives on PLCDevice (not an in-memory dict) so a Celery
    worker restart mid-outage doesn't lose track of it or re-fire the
    outage-start alert on the next tick. Runs every minute via Celery Beat.
    """
    try:
        from .models import Apartment, PLCDevice
        from .plc.registry import DeviceRegistry

        now = timezone.now()
        apartments = (
            Apartment.objects
            .filter(plc_device__isnull=False)
            .select_related("plc_device")
        )

        for apt in apartments:
            device: PLCDevice = apt.plc_device
            try:
                registry = DeviceRegistry.for_apartment(apt.pk)
                up = registry.connected or registry.modbus_connected
            except Exception as exc:
                logger.warning("check_plc_heartbeat: apartment %d check failed — %s", apt.pk, exc)
                continue

            if up:
                if device.down_since is not None:
                    outage_s = (now - device.down_since).total_seconds()
                    device.down_since = None
                    device.last_seen_at = now
                    device.save(update_fields=["down_since", "last_seen_at"])
                    if outage_s >= _OUTAGE_ALERT_THRESHOLD_S:
                        msg = f"{apt.name}: PLC back online after {int(outage_s // 60)}m{int(outage_s % 60)}s"
                        logger.warning("check_plc_heartbeat: %s", msg)
                        send_notification.delay(apt.pk, "PLC reconnected", msg, priority="normal")
                        _send_outage_webhook(msg)
                else:
                    device.last_seen_at = now
                    device.save(update_fields=["last_seen_at"])
                continue

            # Unreachable this tick.
            if device.down_since is None:
                device.down_since = now
                device.save(update_fields=["down_since"])
                continue

            outage_s = (now - device.down_since).total_seconds()
            # Fire exactly once, the first tick after crossing the
            # threshold — not again on every subsequent minute of the
            # same ongoing outage.
            if _OUTAGE_ALERT_THRESHOLD_S <= outage_s < _OUTAGE_ALERT_THRESHOLD_S + 60:
                msg = f"{apt.name}: PLC unreachable for over {_OUTAGE_ALERT_THRESHOLD_S // 60} minute(s)"
                logger.error("check_plc_heartbeat: %s", msg)
                send_notification.delay(apt.pk, "PLC offline", msg, priority="high")
                _send_outage_webhook(msg)
    except Exception as exc:
        logger.error("check_plc_heartbeat: unexpected error — %s", exc)
        raise self.retry(exc=exc)


# ── Sunset/sunrise manual override ──────────────────────────────────────────

@shared_task(name="find_device.tasks.apply_sunset_sunrise_overrides", bind=True, max_retries=2)
def apply_sunset_sunrise_overrides(self):
    """
    For every Apartment with auto_sunset_sunrise=False and both override
    times set, directly ADS-write the on/off state its scheme-driven
    ("custom") devices should be in right now.

    Deliberately writes every tick (every 5 min via Celery Beat) rather than
    tracking "already applied today" — a repeated write of the same boolean
    is harmless and this way a worker restart or a missed tick can never
    leave lights stuck in the wrong state until the next crossing.

    This is intentionally independent of any automatic behavior a PLC's own
    on-board program might already implement (e.g. Building Common Areas'
    MAIN.fbHttpClientOpenWeatherMap) — see Apartment.auto_sunset_sunrise's
    docstring. Only apartments where an admin has explicitly turned auto
    off are touched; every apartment defaults to auto=True, i.e. untouched.
    """
    try:
        apply_sunset_sunrise_overrides_once()
    except Exception as exc:
        logger.error("apply_sunset_sunrise_overrides: unexpected error — %s", exc)
        raise self.retry(exc=exc)


def lights_should_be_on(now, sunset, sunrise) -> bool:
    """Lights ON from sunset until sunrise — handles the normal overnight
    wrap (sunset 18:30 > sunrise 06:30) and the same-day case alike."""
    if sunset <= sunrise:
        return sunset <= now < sunrise
    return now >= sunset or now < sunrise


def apply_sunset_sunrise_overrides_once(now=None):
    """
    The actual work, as a plain function so it runs identically from Celery
    Beat (production stack) or find_device.embedded_scheduler (a single
    process with no Celery/Redis, e.g. a native dev/stopgap server).
    `now` (a datetime.time) is injectable for tests.
    """
    from zoneinfo import ZoneInfo
    from datetime import datetime
    from django.conf import settings
    from .models import Apartment
    from .plc.registry import DeviceRegistry

    # Override times are the building's wall-clock times — never compare
    # them against UTC (TIME_ZONE's default), or 18:30 fires at 22:30 in
    # Yerevan.
    if now is None:
        now = datetime.now(ZoneInfo(settings.BUILDING_TIME_ZONE)).time()

    apartments = Apartment.objects.filter(
        auto_sunset_sunrise=False,
        sunset_override_time__isnull=False,
        sunrise_override_time__isnull=False,
        # An admin-started Christmas show owns the lights while it runs;
        # without this the two would fight every tick.
        christmas_mode_active=False,
    )

    for apt in apartments:
        want_on = lights_should_be_on(now, apt.sunset_override_time, apt.sunrise_override_time)
        try:
            registry = DeviceRegistry.for_apartment(apt.pk)
            for dev in registry.all_templated():
                dev.write(want_on)
        except Exception as exc:
            logger.error("apply_sunset_sunrise_overrides: apartment %d failed — %s", apt.pk, exc)


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


@shared_task(name="find_device.tasks.backup_database", bind=True, max_retries=2, default_retry_delay=300)
def backup_database(self):
    """
    pg_dump the database (see backup_db management command) and prune
    backups older than BACKUP_RETENTION_DAYS. Runs daily at 03:00 UTC via
    Beat — after archive_audit_log (02:00) so the two don't compete for
    the same table locks.

    A no-op (with a clear log line, not a silent skip) on the SQLite dev
    fallback — only meaningful against the Postgres-backed dev/prod
    stacks.
    """
    try:
        from django.core.management import call_command
        call_command("backup_db")
    except Exception as exc:
        logger.error("backup_database: error — %s", exc)
        raise self.retry(exc=exc)
