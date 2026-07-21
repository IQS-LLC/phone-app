"""
Commissioning API — used exclusively by the Tech Team Commissioning Wizard.

All endpoints require is_staff. These are never called during normal resident
operations. They give the installer a live window into every I/O point so they
can verify physical wiring before handing the apartment to a resident.

  GET  /commissioning/<apt_id>/checklist/   — per-step completion status
  POST /commissioning/<apt_id>/test-io/     — pulse a single I/O point
  GET  /commissioning/<apt_id>/summary/     — final handover summary
"""
from __future__ import annotations

import logging
import threading
import time

from django.http import JsonResponse
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import IsAdminUser

from .models import (
    Apartment, ApartmentMembership, ApartmentDevice, PLCDevice,
    MapLayout, Room,
)
from .plc.registry import DeviceRegistry
from .plc.devices import CurtainMotor

logger = logging.getLogger("lumina.commissioning")


def _ok(**kwargs):
    return JsonResponse({"ok": True, **kwargs})


def _err(msg, status=400):
    return JsonResponse({"ok": False, "error": msg}, status=status)


# ── Checklist ─────────────────────────────────────────────────────────────────

@api_view(["GET"])
@permission_classes([IsAdminUser])
def checklist(request, apartment_id):
    """
    Return the completion status for each wizard step.

    Used by the Flutter wizard to pre-populate which steps are already done
    so a returning installer can resume without redoing completed work.
    """
    try:
        apt = Apartment.objects.get(pk=apartment_id)
    except Apartment.DoesNotExist:
        return _err("Apartment not found", status=404)

    # PLC registration
    try:
        plc = apt.plc_device
        plc_registered = True
    except PLCDevice.DoesNotExist:
        plc = None
        plc_registered = False

    # PLC live connectivity — try to resolve the registry without crashing
    plc_connected = False
    if plc_registered:
        try:
            registry = DeviceRegistry.for_apartment(apartment_id)
            plc_connected = registry.connected
        except Exception:
            pass

    rooms = Room.objects.filter(apartment=apt)
    devices = ApartmentDevice.objects.filter(apartment=apt)

    # Map editor state
    floor_plan = False
    map_published = False
    object_count = 0
    try:
        ml = MapLayout.objects.get(apartment=apt)
        floor_plan = bool(ml.background_url)
        map_published = ml.is_published
        object_count = ml.canvas_objects.count()
    except MapLayout.DoesNotExist:
        pass

    # Resident accounts
    resident_count = ApartmentMembership.objects.filter(
        apartment=apt, role="resident"
    ).count()

    return _ok(
        steps={
            "plc_registered":     {"done": plc_registered,          "label": "PLC registered"},
            "plc_connected":      {"done": plc_connected,           "label": "PLC connectivity verified"},
            "rooms_created":      {"done": rooms.count() > 0,       "label": "Rooms created"},
            "devices_configured": {"done": devices.count() > 0,     "label": "I/O devices configured"},
            "floor_plan":         {"done": floor_plan,              "label": "Floor plan uploaded"},
            "map_objects":        {"done": object_count > 0,        "label": "Devices placed on map"},
            "map_published":      {"done": map_published,           "label": "Map published"},
            "residents_created":  {"done": resident_count > 0,      "label": "Resident accounts created"},
        },
        counts={
            "rooms":     rooms.count(),
            "devices":   devices.count(),
            "residents": resident_count,
            "map_objects": object_count,
        },
        apartment={"id": apt.pk, "name": apt.name, "building": apt.building, "floor": apt.floor},
    )


# ── I/O Point Test ────────────────────────────────────────────────────────────

@api_view(["POST"])
@permission_classes([IsAdminUser])
def test_io(request, apartment_id):
    """
    Send a brief test pulse to a single I/O point for physical verification.

    Body: { "device_id": <ApartmentDevice pk> }

    DALI      — flash to 80% (or 20% if already bright) for 1.5 s, then restore.
    Relay     — pulse ON for 0.8 s, then restore original state.
    Curtain   — drive UP for 0.8 s, then STOP.
    Appliance — pulse ON for 0.8 s, then restore original state.
    Sensors   — read current value only (no actuation).

    The restore operations run in daemon threads so the HTTP response is
    returned immediately. The commissioning wizard polls SSE for live feedback.
    """
    device_id = request.data.get("device_id")
    if not device_id:
        return _err("Missing required field: device_id")
    try:
        device_id = int(device_id)
    except (TypeError, ValueError):
        return _err("device_id must be an integer")

    try:
        apt_device = ApartmentDevice.objects.get(pk=device_id, apartment_id=apartment_id)
    except ApartmentDevice.DoesNotExist:
        return _err("Device not found in this apartment", status=404)

    try:
        registry = DeviceRegistry.for_apartment(apartment_id)
    except Exception as exc:
        return _err(f"Cannot connect to PLC: {exc}", status=503)

    dtype = apt_device.device_type
    ch    = apt_device.channel_or_index
    gvl   = apt_device.gvl_name

    try:
        if dtype == "dali":
            dev = registry.dali(ch)
            if dev is None:
                return _err(f"DALI channel {ch} not found in registry", status=404)
            state    = registry.read_full_state()
            original = int(state.get("dali", {}).get(ch) or 0)
            flash    = 20 if original >= 70 else 80
            dev.set_brightness(flash)

            def _restore_dali():
                time.sleep(1.5)
                try:
                    dev.set_brightness(original)
                except Exception:
                    pass

            threading.Thread(target=_restore_dali, daemon=True).start()
            return _ok(
                device_name=apt_device.name,
                device_type=dtype,
                channel=ch,
                action=f"Flashed DALI ch{ch} to {flash}% → restoring to {original}% in 1.5 s",
            )

        elif dtype == "relay":
            dev = registry.relay(ch)
            if dev is None:
                return _err(f"Relay channel {ch} not found in registry", status=404)
            state    = registry.read_full_state()
            original = bool(state.get("relays", {}).get(ch) or False)
            dev.set_state(True)

            def _restore_relay():
                time.sleep(0.8)
                try:
                    dev.set_state(original)
                except Exception:
                    pass

            threading.Thread(target=_restore_relay, daemon=True).start()
            return _ok(
                device_name=apt_device.name,
                device_type=dtype,
                channel=ch,
                action=f"Pulsed relay ch{ch} ON for 0.8 s",
            )

        elif dtype == "curtain":
            dev = registry.curtain(ch)
            if dev is None:
                return _err(f"Curtain {ch} not found in registry", status=404)
            dev.set_command(CurtainMotor.UP)

            def _stop_curtain():
                time.sleep(0.8)
                try:
                    dev.set_command(CurtainMotor.STOP)
                except Exception:
                    pass

            threading.Thread(target=_stop_curtain, daemon=True).start()
            return _ok(
                device_name=apt_device.name,
                device_type=dtype,
                channel=ch,
                action=f"Drove curtain {ch} UP for 0.8 s then stopped",
            )

        elif dtype == "appliance":
            dev = registry.appliance(gvl)
            if dev is None:
                return _err(f"Appliance '{gvl}' not found in registry", status=404)
            state    = registry.read_full_state()
            original = bool(state.get("appliances", {}).get(gvl) or False)
            dev.set_state(True)

            def _restore_appliance():
                time.sleep(0.8)
                try:
                    dev.set_state(original)
                except Exception:
                    pass

            threading.Thread(target=_restore_appliance, daemon=True).start()
            return _ok(
                device_name=apt_device.name,
                device_type=dtype,
                gvl_name=gvl,
                action=f"Pulsed appliance '{apt_device.name}' ON for 0.8 s",
            )

        elif dtype in ("door_sensor", "window_sensor", "motion_sensor"):
            state = registry.read_full_state()
            sensor_key = {
                "door_sensor":   "door_sensors",
                "window_sensor": "window_sensors",
                "motion_sensor": "motion_sensors",
            }[dtype]
            value = state.get(sensor_key, {}).get(ch)
            human = ("OPEN / ACTIVE" if value else "CLOSED / INACTIVE") if value is not None else "unknown"
            return _ok(
                device_name=apt_device.name,
                device_type=dtype,
                channel=ch,
                action=f"Sensor read: {human} (sensors are read-only, no actuation)",
                sensor_value=value,
            )

        elif dtype == "switch":
            state = registry.read_full_state()
            value = state.get("switches", {}).get(ch)
            return _ok(
                device_name=apt_device.name,
                device_type=dtype,
                channel=ch,
                action=f"Switch input {ch}: {'pressed' if value else 'released'} (read-only)",
                sensor_value=value,
            )

        else:
            return _err(f"No test defined for device type '{dtype}'")

    except ConnectionError as exc:
        logger.warning("commissioning test_io: PLC error: %s", exc)
        return _err(f"PLC communication error: {exc}", status=503)
    except Exception as exc:
        logger.exception("commissioning test_io: unexpected error")
        return _err(f"Internal error: {exc}", status=500)


# ── Handover Summary ──────────────────────────────────────────────────────────

@api_view(["GET"])
@permission_classes([IsAdminUser])
def summary(request, apartment_id):
    """
    Complete handover summary for the final wizard step.

    Returns everything configured for this apartment so the installer can
    print or photograph it for the commissioning record.
    """
    try:
        apt = Apartment.objects.get(pk=apartment_id)
    except Apartment.DoesNotExist:
        return _err("Apartment not found", status=404)

    rooms = list(
        Room.objects.filter(apartment=apt)
        .values("id", "name", "sort_order")
        .order_by("sort_order")
    )

    devices = list(
        ApartmentDevice.objects.filter(apartment=apt)
        .values("id", "name", "device_type", "channel_or_index", "gvl_name", "room_id")
        .order_by("sort_order")
    )

    residents = []
    for m in (
        ApartmentMembership.objects
        .filter(apartment=apt, role="resident")
        .select_related("user")
        .order_by("created_at")
    ):
        residents.append({
            "username":   m.user.username,
            "email":      m.user.email,
            "created_at": m.created_at.isoformat(),
        })

    map_info = None
    try:
        ml = MapLayout.objects.get(apartment=apt)
        map_info = {
            "is_published":   ml.is_published,
            "published_at":   ml.published_at.isoformat() if ml.published_at else None,
            "object_count":   ml.canvas_objects.count(),
            "has_background": bool(ml.background_url),
            "layers":         ml.layers.count(),
        }
    except MapLayout.DoesNotExist:
        pass

    plc_info = None
    try:
        plc = apt.plc_device
        plc_info = {
            "name":       plc.name,
            "ip_address": plc.ip_address,
            "ams_net_id": plc.ams_net_id,
            "ads_port":   plc.ads_port,
            "is_active":  plc.is_active,
        }
    except PLCDevice.DoesNotExist:
        pass

    device_counts = {}
    for d in devices:
        device_counts[d["device_type"]] = device_counts.get(d["device_type"], 0) + 1

    return _ok(
        apartment={
            "id":       apt.pk,
            "name":     apt.name,
            "building": apt.building,
            "floor":    apt.floor,
        },
        plc=plc_info,
        rooms=rooms,
        devices=devices,
        device_counts=device_counts,
        residents=residents,
        map=map_info,
    )
