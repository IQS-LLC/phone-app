"""
Lumina PLC REST API — production views.

Endpoints
─────────────────────────────────────────────────────────────
  GET  /plc/                              health + PLC status
  GET  /plc/state/                        full system state  (polled every 2 s)
  GET  /plc/devices/                      device metadata
  GET  /plc/diagnostics/                  detailed diagnostics

  POST /plc/dali/<ch>/brightness/         set single DALI channel
                                            (optional duration_ms=100-5000 fades it)
  POST /plc/dali/all/brightness/          set all DALI channels
  POST /plc/room/<room>/brightness/       set all DALI channels in a room

  POST /plc/relay/<ch>/                   set wall relay (state=on|off)

  POST /plc/curtain/<idx>/               set curtain motor (cmd=stop|up|down)
  POST /plc/curtain/all/                  stop all curtains

  POST /plc/appliance/<gvl_name>/         set appliance relay (state=on|off)

  POST /plc/toggle/<var_name>/            set named relay/light (state=on|off)

  GET  /plc/sensors/                      all sensor states (magnetic + motion)
  POST /plc/security/alarm/               arm/disarm (armed=true|false)
  POST /plc/security/lockdown/            activate/deactivate lockdown

Request format  : application/x-www-form-urlencoded
Response format : JSON  { ok, data/error, ts }

Error codes
  INVALID_PARAM   — bad / missing input parameter
  NOT_FOUND       — device not configured in registry
  PLC_ERROR       — hardware / ADS error
  SERVER_ERROR    — unexpected internal error
"""
from __future__ import annotations

import logging
import time
import urllib.parse

from django.http import JsonResponse
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_GET, require_POST

from .plc.registry import DeviceRegistry
from .plc.devices import CurtainMotor, DaliChannel
from .permissions import log_action

logger = logging.getLogger("lumina.api")

# ── Helpers ───────────────────────────────────────────────────────────────────

def _ts() -> float:
    return round(time.time(), 3)

def _ok(data: dict, status: int = 200) -> JsonResponse:
    return JsonResponse({"ok": True, "data": data, "ts": _ts()}, status=status)

def _err(message: str, code: str = "SERVER_ERROR", status: int = 500) -> JsonResponse:
    return JsonResponse(
        {"ok": False, "error": message, "code": code, "ts": _ts()}, status=status)

def _registry_or_error(request):
    """
    Resolve the DeviceRegistry for the apartment the AUTHENTICATED USER
    belongs to — via a permanent ApartmentMembership, or, failing that, a
    currently-active TemporaryAccess grant (cleaner, electrician, guest).

    apartment_id is NEVER taken from request input — only resolved here
    from the DB against request.user — so one resident can never address
    another apartment's hardware by guessing or sending a different ID.
    Returns (registry, None) on success, or (None, JsonResponse) the
    caller should return as-is on failure.
    """
    from django.apps import apps
    from django.utils import timezone
    ApartmentMembership = apps.get_model('find_device', 'ApartmentMembership')
    TemporaryAccess      = apps.get_model('find_device', 'TemporaryAccess')
    Apartment            = apps.get_model('find_device', 'Apartment')

    user = getattr(request, "user", None)
    if user is not None and getattr(user, "is_authenticated", False):
        membership = (
            ApartmentMembership.objects
            .filter(user=user)
            .order_by('-is_default')
            .first()
        )
        if membership is not None:
            return DeviceRegistry.for_apartment(membership.apartment_id), None

        now = timezone.now()
        grant = (
            TemporaryAccess.objects
            .filter(user=user, revoked=False, starts_at__lte=now, expires_at__gte=now)
            .order_by('-starts_at')
            .first()
        )
        if grant is not None:
            return DeviceRegistry.for_apartment(grant.apartment_id), None

        return None, _err(
            "Your account isn't linked to any apartment yet.",
            "NO_APARTMENT", 403,
        )

    # PLC_REQUIRE_AUTH=False — explicit local-tooling bypass. Fall back to
    # the first apartment in the DB so dev/CI scripts keep working without
    # a token.
    apt = Apartment.objects.order_by('id').first()
    if apt is None:
        return None, _err("No apartment exists in the database yet.", "NOT_FOUND", 404)
    return DeviceRegistry.for_apartment(apt.pk), None

def _require_permission(request, registry, perm_code: str):
    """
    Verify the caller holds perm_code on registry.apartment_id. Never trust
    the Flutter app to enforce this — every authorization decision happens
    here, server-side. Returns None if allowed, or a JsonResponse to return
    as-is if denied. No-ops when PLC_REQUIRE_AUTH=False (local tooling).
    """
    from .permissions import resolve_permissions

    user = getattr(request, "user", None)
    if user is None or not getattr(user, "is_authenticated", False):
        return None

    if perm_code not in resolve_permissions(user, registry.apartment_id):
        log_action(
            request, f"permission_denied:{perm_code}", result="failure",
            path=request.path,
        )
        return _err(
            f"You don't have '{perm_code}' permission for this apartment.",
            "FORBIDDEN", 403,
        )
    return None

def _parse_brightness(post_data):
    raw = post_data.get("brightness")
    if raw is None:
        return None, _err("Missing required parameter: brightness", "INVALID_PARAM", 400)
    try:
        pct = int(raw)
    except (TypeError, ValueError):
        return None, _err(
            f"brightness must be an integer 0-100, got: {raw!r}", "INVALID_PARAM", 400)
    if not 0 <= pct <= 100:
        return None, _err(f"brightness must be 0-100, got: {pct}", "INVALID_PARAM", 400)
    return pct, None

def _parse_duration_ms(post_data):
    """Optional — absent/0 means instant (existing behavior, unchanged).
    Bounds match UserProfile.dim_duration_ms/undim_duration_ms's own
    100-5000 range so a client can't bypass those by calling this endpoint
    directly with an arbitrary value."""
    raw = post_data.get("duration_ms")
    if raw is None or raw == "":
        return 0, None
    try:
        ms = int(raw)
    except (TypeError, ValueError):
        return None, _err(f"duration_ms must be an integer, got: {raw!r}", "INVALID_PARAM", 400)
    if ms == 0:
        return 0, None
    if not 100 <= ms <= 5000:
        return None, _err(f"duration_ms must be 0 or 100-5000, got: {ms}", "INVALID_PARAM", 400)
    return ms, None

def _parse_bool_param(post_data, param: str):
    raw = post_data.get(param, "").lower().strip()
    if not raw:
        return None, _err(f"Missing required parameter: {param}", "INVALID_PARAM", 400)
    if raw not in ("true", "false", "1", "0", "on", "off"):
        return None, _err(
            f"{param} must be true/false/on/off/1/0", "INVALID_PARAM", 400)
    return raw in ("true", "1", "on"), None


# ── Health ────────────────────────────────────────────────────────────────────

def health(request):
    r, _err_resp = _registry_or_error(request)
    try:
        plc_connected, mock = (r.connected, r.mock) if r else (False, True)
    except Exception:
        plc_connected, mock = False, True

    return JsonResponse({
        "status": "ok",
        "plc":    "connected" if plc_connected else "disconnected",
        "mock":   mock,
        "ts":     _ts(),
        "version": "3.0",
    })


# ── Full state ────────────────────────────────────────────────────────────────

@require_GET
def get_state(request):
    r, err = _registry_or_error(request)
    if err:
        return err
    try:
        state = r.read_full_state()
        return JsonResponse({**state, "ts": _ts()})
    except ConnectionError as exc:
        logger.error("get_state: PLC unreachable: %s", exc)
        return _err(f"PLC unreachable: {exc}", "PLC_ERROR", 503)
    except Exception as exc:
        logger.exception("get_state: unexpected error")
        return _err(f"Internal error: {exc}", "SERVER_ERROR", 500)


# ── Device metadata ───────────────────────────────────────────────────────────

@require_GET
def get_devices(request):
    r, err = _registry_or_error(request)
    if err:
        return err
    return JsonResponse({
        "apartment_id":   r.apartment_id,
        "dali":           [d.to_dict() for d in r.all_dali()],
        "relays":         [d.to_dict() for d in r.all_relays()],
        "curtains":       [d.to_dict() for d in r.all_curtains()],
        "switches":       [s.to_dict() for s in r.all_switches()],
        "appliances":     [a.to_dict() for a in r.all_appliances()],
        "toggles":        [t.to_dict() for t in r.all_toggles()],
        "named_switches": [s.to_dict() for s in r.all_named_switches()],
        "door_sensors":   [s.to_dict() for s in r.all_door_sensors()],
        "window_sensors": [s.to_dict() for s in r.all_window_sensors()],
        "motion_sensors": [s.to_dict() for s in r.all_motion_sensors()],
        "security_available": r.security() is not None,
        "rooms":          r.rooms(),
        "ts":             _ts(),
    })


# ── Diagnostics ───────────────────────────────────────────────────────────────

@require_GET
def get_diagnostics(request):
    r, err = _registry_or_error(request)
    if err:
        return err
    try:
        state = r.read_full_state()

        from django.apps import apps
        PLCDevice = apps.get_model('find_device', 'PLCDevice')
        plc_device = PLCDevice.objects.filter(apartment_id=r.apartment_id).first()

        return _ok({
            "plc_connected":     r.connected,
            "modbus_connected":  r.modbus_connected,
            "down_since":        plc_device.down_since.isoformat() if plc_device and plc_device.down_since else None,
            "last_seen_at":      plc_device.last_seen_at.isoformat() if plc_device and plc_device.last_seen_at else None,
            "mock":            r.mock,
            "apartment_id":    r.apartment_id,
            "dali_channels":   len(r.all_dali()),
            "relay_channels":  len(r.all_relays()),
            "curtain_motors":  len(r.all_curtains()),
            "switch_inputs":   len(r.all_switches()),
            "appliances":      len(r.all_appliances()),
            "toggles":         len(r.all_toggles()),
            "named_switches":  len(r.all_named_switches()),
            "door_sensors":    len(r.all_door_sensors()),
            "window_sensors":  len(r.all_window_sensors()),
            "motion_sensors":  len(r.all_motion_sensors()),
            "rooms":           r.rooms(),
            "dali": [
                {"channel": dev.channel, "name": dev.name, "room": dev.room,
                 "brightness": state["dali"].get(dev.channel),
                 "ok": state["dali"].get(dev.channel) is not None}
                for dev in r.all_dali()
            ],
            "relays": [
                {"channel": dev.channel, "name": dev.name, "room": dev.room,
                 "on": state["relays"].get(dev.channel),
                 "ok": state["relays"].get(dev.channel) is not None}
                for dev in r.all_relays()
            ],
            "curtains": [
                {"index": dev.index, "name": dev.name, "room": dev.room,
                 "state": state["curtains"].get(dev.index),
                 "ok": state["curtains"].get(dev.index) is not None}
                for dev in r.all_curtains()
            ],
            "security": state.get("security", {}),
        })
    except Exception as exc:
        logger.exception("get_diagnostics: unexpected error")
        return _err(str(exc), "SERVER_ERROR", 500)


# ─────────────────────────────────────────────────────────────────────────────
# Write commands (DALI/relay/curtain/appliance/toggle/security below)
#
# Concurrent-write semantics — documented, not accidental:
#
# Two requests can arrive for the same device at nearly the same instant
# (two residents, a manual toggle racing an automation, SuperScan testing
# while polling continues). What makes the outcome deterministic rather
# than a timing accident:
#
#   1. WEB_CONCURRENCY=1 (Dockerfile, docker-compose.prod.yml) — exactly one
#      Gunicorn worker process handles every request, one at a time. Two
#      requests never execute their view functions truly in parallel; the
#      second one's view function only starts once the first has returned.
#   2. ADSClient.write_*() takes self._lock (an RLock) around the actual PLC
#      write, so even if that guarantee ever changed, the hardware write
#      itself is still serialized per-connection.
#
# The result: "requested state" (what a client asked for) always resolves
# to whatever request's write reaches the PLC LAST, in arrival order — not
# a race with an unpredictable winner. "Confirmed state" is whatever the
# next GET /plc/state/ reads back from the hardware itself, independent of
# which client asked for what; no client's local guess is ever treated as
# authoritative. Verified live 2026-08-20: two parallel opposite commands
# to the same relay (ON/OFF, ~100ms apart) both returned 200, and the
# channel settled to the later-arriving request's value with no corruption,
# no duplicate command, and no stuck state.
#
# This determinism depends on staying at one worker / one replica — see the
# WEB_CONCURRENCY=1 setting in Dockerfile and docker-compose.prod.yml, and
# CLAUDE.md's "Critical Architecture Constraints", before ever changing it.
# ─────────────────────────────────────────────────────────────────────────────


# ── DALI — single channel ─────────────────────────────────────────────────────

@csrf_exempt
@require_POST
def set_dali_brightness(request, channel: int):
    if not 1 <= channel <= DaliChannel.MAX_CHANNEL:
        return _err(
            f"DALI channel must be 1-{DaliChannel.MAX_CHANNEL}, got {channel}",
            "INVALID_PARAM", 400)

    pct, err = _parse_brightness(request.POST)
    if err:
        return err

    duration_ms, err = _parse_duration_ms(request.POST)
    if err:
        return err

    r, err = _registry_or_error(request)
    if err:
        return err
    err = _require_permission(request, r, "control_devices")
    if err:
        return err
    dev = r.dali(channel)
    if dev is None:
        return _err(f"DALI channel {channel} not configured", "NOT_FOUND", 404)

    try:
        if duration_ms:
            r.fade_dali(channel, pct, duration_ms)
            logger.info("DALI ch%d → %d%% over %dms", channel, pct, duration_ms)
            log_action(request, "dali_brightness", channel=channel, brightness=pct, duration_ms=duration_ms)
        else:
            r.write_dali_brightness(channel, pct)
            logger.info("DALI ch%d → %d%%", channel, pct)
            log_action(request, "dali_brightness", channel=channel, brightness=pct)
        return _ok({"channel": channel, "brightness": pct, "duration_ms": duration_ms})
    except ConnectionError as exc:
        return _err(str(exc), "PLC_ERROR", 503)
    except Exception as exc:
        logger.exception("set_dali_brightness ch%d", channel)
        return _err(str(exc), "SERVER_ERROR", 500)


# ── DALI — all channels ───────────────────────────────────────────────────────

@csrf_exempt
@require_POST
def set_dali_brightness_all(request):
    pct, err = _parse_brightness(request.POST)
    if err:
        return err

    r, err = _registry_or_error(request)
    if err:
        return err
    err = _require_permission(request, r, "control_devices")
    if err:
        return err
    errors = []
    for dev in r.all_dali():
        try:
            dev.set_brightness(pct)
        except Exception as exc:
            errors.append({"channel": dev.channel, "error": str(exc)})
            logger.error("set_all_brightness ch%d: %s", dev.channel, exc)

    if errors:
        return JsonResponse({
            "ok": False, "data": {"brightness": pct, "errors": errors},
            "error": f"{len(errors)} channel(s) failed",
            "code": "PARTIAL_FAILURE", "ts": _ts(),
        }, status=207)

    logger.info("set_all_brightness → %d%%", pct)
    log_action(request, "dali_brightness_all", brightness=pct)
    return _ok({"brightness": pct, "channels": len(r.all_dali())})


# ── DALI — room brightness ────────────────────────────────────────────────────

@csrf_exempt
@require_POST
def set_room_brightness(request, room_name: str):
    room = urllib.parse.unquote(room_name).strip()
    if not room:
        return _err("Room name cannot be empty", "INVALID_PARAM", 400)

    pct, err = _parse_brightness(request.POST)
    if err:
        return err

    r, err = _registry_or_error(request)
    if err:
        return err
    err = _require_permission(request, r, "control_devices")
    if err:
        return err
    devices = [d for d in r.all_dali() if d.room.lower() == room.lower()]

    if not devices:
        return _err(
            f"Room '{room}' not found. Available: {r.rooms()}",
            "NOT_FOUND", 404)

    errors = []
    for dev in devices:
        try:
            dev.set_brightness(pct)
        except Exception as exc:
            errors.append({"channel": dev.channel, "error": str(exc)})
            logger.error("set_room_brightness %s ch%d: %s", room, dev.channel, exc)

    if errors:
        return JsonResponse({
            "ok": False,
            "data": {"room": room, "brightness": pct, "errors": errors},
            "error": f"{len(errors)} channel(s) in '{room}' failed",
            "code": "PARTIAL_FAILURE", "ts": _ts(),
        }, status=207)

    logger.info("set_room_brightness '%s' → %d%%", room, pct)
    log_action(request, "dali_brightness_room", room=room, brightness=pct)
    return _ok({"room": room, "brightness": pct, "channels": len(devices)})


# ── Wall relay ────────────────────────────────────────────────────────────────

@csrf_exempt
@require_POST
def set_relay(request, channel: int):
    if not 1 <= channel <= 16:
        return _err(f"Relay channel must be 1-16, got {channel}", "INVALID_PARAM", 400)

    on, err = _parse_bool_param(request.POST, "state")
    if err:
        return err

    r, err = _registry_or_error(request)
    if err:
        return err
    err = _require_permission(request, r, "control_devices")
    if err:
        return err
    dev = r.relay(channel)
    if dev is None:
        return _err(f"Relay channel {channel} not configured", "NOT_FOUND", 404)

    try:
        r.write_relay_state(channel, on)
        logger.info("Relay ch%d → %s", channel, "ON" if on else "OFF")
        log_action(request, "relay", channel=channel, on=on)
        return _ok({"channel": channel, "on": on})
    except ConnectionError as exc:
        return _err(str(exc), "PLC_ERROR", 503)
    except Exception as exc:
        logger.exception("set_relay ch%d", channel)
        return _err(str(exc), "SERVER_ERROR", 500)


# ── Curtain motor ─────────────────────────────────────────────────────────────

_CURTAIN_CMD_MAP = {
    "stop": CurtainMotor.STOP,
    "0":    CurtainMotor.STOP,
    "up":   CurtainMotor.UP,
    "1":    CurtainMotor.UP,
    "down": CurtainMotor.DOWN,
    "2":    CurtainMotor.DOWN,
}

@csrf_exempt
@require_POST
def set_curtain(request, index: int):
    if not 1 <= index <= CurtainMotor.MAX_INDEX:
        return _err(f"Curtain index must be 1-{CurtainMotor.MAX_INDEX}, got {index}", "INVALID_PARAM", 400)

    raw = request.POST.get("cmd", "").lower().strip()
    if raw not in _CURTAIN_CMD_MAP:
        return _err(
            "cmd must be 'stop'/'up'/'down' (or 0/1/2)", "INVALID_PARAM", 400)
    cmd = _CURTAIN_CMD_MAP[raw]

    r, err = _registry_or_error(request)
    if err:
        return err
    err = _require_permission(request, r, "control_devices")
    if err:
        return err
    dev = r.curtain(index)
    if dev is None:
        return _err(f"Curtain {index} not configured", "NOT_FOUND", 404)

    try:
        dev.set_command(cmd)
        logger.info("Curtain %d → %s (%d)", index, raw, cmd)
        log_action(request, "curtain", index=index, cmd=cmd)
        return _ok({"index": index, "cmd": cmd})
    except ConnectionError as exc:
        return _err(str(exc), "PLC_ERROR", 503)
    except Exception as exc:
        logger.exception("set_curtain %d", index)
        return _err(str(exc), "SERVER_ERROR", 500)


@csrf_exempt
@require_POST
def set_curtain_all(request):
    raw = request.POST.get("cmd", "stop").lower().strip()
    if raw not in _CURTAIN_CMD_MAP:
        return _err("cmd must be 'stop'/'up'/'down'", "INVALID_PARAM", 400)
    cmd = _CURTAIN_CMD_MAP[raw]

    r, err = _registry_or_error(request)
    if err:
        return err
    err = _require_permission(request, r, "control_devices")
    if err:
        return err
    errors = []
    for dev in r.all_curtains():
        try:
            dev.set_command(cmd)
        except Exception as exc:
            errors.append({"index": dev.index, "error": str(exc)})

    if errors:
        return JsonResponse({
            "ok": False, "data": {"cmd": cmd, "errors": errors},
            "error": f"{len(errors)} curtain(s) failed",
            "code": "PARTIAL_FAILURE", "ts": _ts(),
        }, status=207)

    logger.info("set_curtain_all → %s (%d)", raw, cmd)
    log_action(request, "curtain_all", cmd=cmd)
    return _ok({"cmd": cmd, "count": len(r.all_curtains())})


# ── Appliance ─────────────────────────────────────────────────────────────────

@csrf_exempt
@require_POST
def set_appliance(request, gvl_name: str):
    on, err = _parse_bool_param(request.POST, "state")
    if err:
        return err

    r, err = _registry_or_error(request)
    if err:
        return err
    err = _require_permission(request, r, "control_devices")
    if err:
        return err
    dev = r.appliance(gvl_name)
    if dev is None:
        return _err(
            f"Appliance '{gvl_name}' not configured. "
            f"Available: {list(r._appliances.keys())}",
            "NOT_FOUND", 404)

    try:
        dev.set_state(on)
        logger.info("Appliance %s → %s", gvl_name, "ON" if on else "OFF")
        log_action(request, "appliance", gvl_name=gvl_name, on=on)
        return _ok({"gvl_name": gvl_name, "on": on})
    except ConnectionError as exc:
        return _err(str(exc), "PLC_ERROR", 503)
    except Exception as exc:
        logger.exception("set_appliance %s", gvl_name)
        return _err(str(exc), "SERVER_ERROR", 500)


# ── Named relay/light (toggle) ────────────────────────────────────────────────

@csrf_exempt
@require_POST
def set_toggle(request, var_name: str):
    on, err = _parse_bool_param(request.POST, "state")
    if err:
        return err

    r, err = _registry_or_error(request)
    if err:
        return err
    err = _require_permission(request, r, "control_devices")
    if err:
        return err
    dev = r.toggle(var_name)
    if dev is None:
        return _err(
            f"Device '{var_name}' not configured. "
            f"Available: {list(r._toggles.keys())}",
            "NOT_FOUND", 404)

    try:
        dev.set_state(on)
        logger.info("Toggle %s → %s", var_name, "ON" if on else "OFF")
        log_action(request, "toggle", var_name=var_name, on=on)
        return _ok({"var_name": var_name, "on": on})
    except ValueError as exc:
        return _err(str(exc), "NOT_WRITABLE", 409)
    except ConnectionError as exc:
        return _err(str(exc), "PLC_ERROR", 503)
    except Exception as exc:
        logger.exception("set_toggle %s", var_name)
        return _err(str(exc), "SERVER_ERROR", 500)


# ── Sensors ───────────────────────────────────────────────────────────────────

@require_GET
def get_sensors(request):
    """Returns live states of all magnetic and motion sensors."""
    r, err = _registry_or_error(request)
    if err:
        return err
    try:
        return _ok({
            "door_sensors":   {idx: dev.read_state() for idx, dev in r._door_sensors.items()},
            "window_sensors": {idx: dev.read_state() for idx, dev in r._window_sensors.items()},
            "motion_sensors": {idx: dev.read_state() for idx, dev in r._motion_sensors.items()},
        })
    except Exception as exc:
        logger.exception("get_sensors: unexpected error")
        return _err(str(exc), "SERVER_ERROR", 500)


# ── Security — alarm ──────────────────────────────────────────────────────────

@csrf_exempt
@require_POST
def set_alarm(request):
    armed, err = _parse_bool_param(request.POST, "armed")
    if err:
        return err

    r, err = _registry_or_error(request)
    if err:
        return err
    err = _require_permission(request, r, "emergency_controls")
    if err:
        return err
    sec = r.security()
    if sec is None:
        return _err("No security hardware configured for this apartment", "NOT_FOUND", 404)

    try:
        sec.set_alarm_armed(armed)
        logger.info("Alarm → %s", "ARMED" if armed else "DISARMED")
        log_action(request, "alarm", armed=armed)
        return _ok({"armed": armed})
    except ConnectionError as exc:
        return _err(str(exc), "PLC_ERROR", 503)
    except Exception as exc:
        logger.exception("set_alarm")
        return _err(str(exc), "SERVER_ERROR", 500)


# ── Security — lockdown ───────────────────────────────────────────────────────

@csrf_exempt
@require_POST
def set_lockdown(request):
    active, err = _parse_bool_param(request.POST, "active")
    if err:
        return err

    r, err = _registry_or_error(request)
    if err:
        return err
    err = _require_permission(request, r, "emergency_controls")
    if err:
        return err
    sec = r.security()
    if sec is None:
        return _err("No security hardware configured for this apartment", "NOT_FOUND", 404)

    try:
        sec.set_lockdown(active)
        logger.info("Lockdown → %s", "ACTIVE" if active else "INACTIVE")
        log_action(request, "lockdown", active=active)
        return _ok({"lockdown": active})
    except ConnectionError as exc:
        return _err(str(exc), "PLC_ERROR", 503)
    except Exception as exc:
        logger.exception("set_lockdown")
        return _err(str(exc), "SERVER_ERROR", 500)
