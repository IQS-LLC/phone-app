"""
Light/Device Relabel API — lets IT Team walk every output channel (DALI,
wall relay, curtain) one at a time, flash it so they can see which physical
fixture it drives, and (re)assign its room + display name — and separately,
watch every raw input channel (switch, motion/door/window sensor) live so
pressing a physical switch or tripping a sensor visibly highlights exactly
which channel it is, before assigning that too.

Exists because commissioning (find_device/commissioning_views.py) only ever
lets you test I/O points that already have an ApartmentDevice row, and its
room/device rename tooling (user_management_views.py) has no "which
physical thing is this" identify step. This covers fixing channels that
were labeled wrong during initial commissioning, and finding channels that
were never assigned a room/name at all.

is_staff (IT Team) ONLY — deliberately not Owner, not Installer, not even
Building Owner. See has_relabel_access in permissions.py and
[[project_role_hierarchy_redesign]] for why: this is the one tool that
would reveal there's no bespoke PLC coding happening, and IT Team keeps
that to itself.

  GET  /relabel/<apt_id>/outputs/<type>/            type: dali|relay|curtain
  POST /relabel/<apt_id>/outputs/<type>/<ch>/flash/
  POST /relabel/<apt_id>/outputs/<type>/<ch>/assign/

  GET  /relabel/<apt_id>/inputs/                    switches + all sensor kinds, live state
  POST /relabel/<apt_id>/inputs/assign/
"""
from __future__ import annotations

import logging

from rest_framework.decorators import api_view
from rest_framework.response import Response

from .models import Apartment, ApartmentDevice, Room
from .permissions import has_relabel_access, log_action
from .plc.devices import CurtainMotor, DaliChannel
from .plc.registry import DeviceRegistry

logger = logging.getLogger("lumina.relabel")


def _ok(**kwargs):
    return Response({"ok": True, **kwargs})


def _err(msg, status=400):
    return Response({"ok": False, "error": msg}, status=status)


def _forbidden_unless_allowed(request, apartment_id):
    if not request.user or not request.user.is_authenticated:
        return _err("Authentication required", status=401)
    if not has_relabel_access(request.user, apartment_id):
        return _err("You don't have permission to relabel devices in this apartment", status=403)
    return None


# ── Output channel specs (DALI / relay / curtain) ─────────────────────────────

_OUTPUT_SPECS = {
    "dali": {
        "device_type": ApartmentDevice.TYPE_DALI,
        "channels": lambda: [
            ch for ch in range(1, DaliChannel.MAX_CHANNEL + 1) if ch != DaliChannel._MISSING_CHANNEL
        ],
        "valid": lambda ch: 1 <= ch <= DaliChannel.MAX_CHANNEL and ch != DaliChannel._MISSING_CHANNEL,
        "flash": lambda registry, ch: registry.flash_raw_dali(ch),
        "add":   lambda registry, ch, name, room, device_id: registry.add_dali(ch, name, room, device_id),
        "flash_message": lambda r: (
            f"Flashed DALI ch{r['channel']} to {r['flash']}% → restoring to {r['original']}% in 1.5 s"
        ),
    },
    "relay": {
        "device_type": ApartmentDevice.TYPE_RELAY,
        "channels": lambda: list(range(1, 17)),
        "valid": lambda ch: 1 <= ch <= 16,
        "flash": lambda registry, ch: registry.flash_raw_relay(ch),
        "add":   lambda registry, ch, name, room, device_id: registry.add_relay(ch, name, room),
        "flash_message": lambda r: f"Pulsed relay ch{r['channel']} ON for 0.8 s",
    },
    "curtain": {
        "device_type": ApartmentDevice.TYPE_CURTAIN,
        "channels": lambda: list(range(1, CurtainMotor.MAX_INDEX + 1)),
        "valid": lambda ch: 1 <= ch <= CurtainMotor.MAX_INDEX,
        "flash": lambda registry, ch: registry.flash_raw_curtain(ch),
        "add":   lambda registry, ch, name, room, device_id: registry.add_curtain(ch, name, room),
        "flash_message": lambda r: f"Drove curtain {r['channel']} UP for 0.8 s then stopped",
    },
}


@api_view(["GET"])
def list_output_channels(request, apartment_id, device_type):
    denied = _forbidden_unless_allowed(request, apartment_id)
    if denied:
        return denied

    spec = _OUTPUT_SPECS.get(device_type)
    if spec is None:
        return _err(f"Unknown output type '{device_type}'", status=400)

    apartment = Apartment.objects.filter(pk=apartment_id).first()
    if apartment is None:
        return _err("Apartment not found", status=404)

    existing = {
        d.channel_or_index: d
        for d in ApartmentDevice.objects.filter(
            apartment=apartment, device_type=spec["device_type"],
        ).select_related("room")
    }

    channels = []
    for ch in spec["channels"]():
        d = existing.get(ch)
        channels.append({
            "channel": ch,
            "assigned": d is not None,
            "device_id": d.pk if d else None,
            "name": d.name if d else None,
            "room_id": d.room_id if d else None,
            "room_name": d.room.name if (d and d.room) else None,
        })

    rooms = [{"id": r.pk, "name": r.name} for r in apartment.rooms.all()]
    return _ok(channels=channels, rooms=rooms)


@api_view(["POST"])
def flash_output_channel(request, apartment_id, device_type, channel):
    denied = _forbidden_unless_allowed(request, apartment_id)
    if denied:
        return denied

    spec = _OUTPUT_SPECS.get(device_type)
    if spec is None:
        return _err(f"Unknown output type '{device_type}'", status=400)
    if not spec["valid"](channel):
        return _err(f"Invalid {device_type} channel {channel}", status=400)

    try:
        registry = DeviceRegistry.for_apartment(apartment_id)
        result = spec["flash"](registry, channel)
    except ConnectionError as exc:
        return _err(f"PLC communication error: {exc}", status=503)
    except Exception as exc:
        logger.exception("flash_output_channel: unexpected error")
        return _err(f"Internal error: {exc}", status=500)

    return _ok(channel=result["channel"], action=spec["flash_message"](result))


@api_view(["POST"])
def assign_output_channel(request, apartment_id, device_type, channel):
    denied = _forbidden_unless_allowed(request, apartment_id)
    if denied:
        return denied

    spec = _OUTPUT_SPECS.get(device_type)
    if spec is None:
        return _err(f"Unknown output type '{device_type}'", status=400)
    if not spec["valid"](channel):
        return _err(f"Invalid {device_type} channel {channel}", status=400)

    name = (request.data.get("name") or "").strip()
    if not name:
        return _err("name is required", status=400)

    room_id   = request.data.get("room_id")
    room_name = (request.data.get("room_name") or "").strip()
    if not room_id and not room_name:
        return _err("room_id or room_name is required", status=400)

    apartment = Apartment.objects.filter(pk=apartment_id).first()
    if apartment is None:
        return _err("Apartment not found", status=404)

    if room_id:
        room = Room.objects.filter(pk=room_id, apartment=apartment).first()
        if room is None:
            return _err("Room not found in this apartment", status=404)
    else:
        room, _created = Room.objects.get_or_create(apartment=apartment, name=room_name)

    device, _created = ApartmentDevice.objects.get_or_create(
        apartment=apartment,
        device_type=spec["device_type"],
        channel_or_index=channel,
        defaults={"name": name, "room": room},
    )
    if not _created:
        device.name = name
        device.room = room
        device.save(update_fields=["name", "room"])

    try:
        spec["add"](DeviceRegistry.for_apartment(apartment_id), channel, name, room.name, device.pk)
    except Exception:
        logger.exception("assign_output_channel: failed to hot-reload registry (will pick up on next restart)")

    log_action(
        request, "device_relabeled", apartment=apartment,
        reason=f"{device_type} ch{channel} -> {room.name} / {name}",
    )

    return _ok(
        channel=channel, device_id=device.pk, name=device.name,
        room_id=room.pk, room_name=room.name,
    )


# ── Input channels (switch / motion / door / window sensor) ──────────────────

_INPUT_TYPES = {
    "switch":        ApartmentDevice.TYPE_SWITCH,
    "motion_sensor":  ApartmentDevice.TYPE_MOTION_SENSOR,
    "door_sensor":    ApartmentDevice.TYPE_DOOR_SENSOR,
    "window_sensor":  ApartmentDevice.TYPE_WINDOW_SENSOR,
}

_INPUT_ADDERS = {
    "switch":        lambda registry, idx, name, room: registry.add_switch(idx, name, room),
    "motion_sensor":  lambda registry, idx, name, room: registry.add_motion_sensor(idx, name, room),
    "door_sensor":    lambda registry, idx, name, room: registry.add_door_sensor(idx, name, room),
    "window_sensor":  lambda registry, idx, name, room: registry.add_window_sensor(idx, name, room),
}


@api_view(["GET"])
def list_inputs(request, apartment_id):
    """
    Every raw switch/sensor channel with its LIVE state, whether or not it
    has an ApartmentDevice row — press a physical switch or trip a sensor
    and watch which entry flips, then assign it.
    """
    denied = _forbidden_unless_allowed(request, apartment_id)
    if denied:
        return denied

    apartment = Apartment.objects.filter(pk=apartment_id).first()
    if apartment is None:
        return _err("Apartment not found", status=404)

    try:
        live = DeviceRegistry.for_apartment(apartment_id).read_raw_inputs()
    except ConnectionError as exc:
        return _err(f"PLC communication error: {exc}", status=503)
    except Exception as exc:
        logger.exception("list_inputs: unexpected error")
        return _err(f"Internal error: {exc}", status=500)

    existing = {
        (d.device_type, d.channel_or_index): d
        for d in ApartmentDevice.objects.filter(
            apartment=apartment, device_type__in=_INPUT_TYPES.values(),
        ).select_related("room")
    }

    # read_raw_inputs groups plural: switches/motion_sensors/door_sensors/window_sensors
    _PLURAL = {
        "switch": "switches", "motion_sensor": "motion_sensors",
        "door_sensor": "door_sensors", "window_sensor": "window_sensors",
    }

    result = {}
    for group, model_type in _INPUT_TYPES.items():
        plural = _PLURAL[group]
        states = live.get(plural, {})
        entries = []
        for idx, state in states.items():
            d = existing.get((model_type, idx))
            entries.append({
                "index": idx,
                "state": state,
                "assigned": d is not None,
                "device_id": d.pk if d else None,
                "name": d.name if d else None,
                "room_id": d.room_id if d else None,
                "room_name": d.room.name if (d and d.room) else None,
            })
        result[plural] = sorted(entries, key=lambda e: e["index"])

    rooms = [{"id": r.pk, "name": r.name} for r in apartment.rooms.all()]
    return _ok(**result, rooms=rooms)


@api_view(["POST"])
def assign_input(request, apartment_id):
    denied = _forbidden_unless_allowed(request, apartment_id)
    if denied:
        return denied

    device_type = request.data.get("device_type")
    if device_type not in _INPUT_TYPES:
        return _err(f"device_type must be one of {list(_INPUT_TYPES)}", status=400)

    try:
        index = int(request.data.get("index"))
    except (TypeError, ValueError):
        return _err("index must be an integer", status=400)

    name = (request.data.get("name") or "").strip()
    if not name:
        return _err("name is required", status=400)

    room_id   = request.data.get("room_id")
    room_name = (request.data.get("room_name") or "").strip()
    if not room_id and not room_name:
        return _err("room_id or room_name is required", status=400)

    apartment = Apartment.objects.filter(pk=apartment_id).first()
    if apartment is None:
        return _err("Apartment not found", status=404)

    if room_id:
        room = Room.objects.filter(pk=room_id, apartment=apartment).first()
        if room is None:
            return _err("Room not found in this apartment", status=404)
    else:
        room, _created = Room.objects.get_or_create(apartment=apartment, name=room_name)

    model_type = _INPUT_TYPES[device_type]
    device, _created = ApartmentDevice.objects.get_or_create(
        apartment=apartment, device_type=model_type, channel_or_index=index,
        defaults={"name": name, "room": room},
    )
    if not _created:
        device.name = name
        device.room = room
        device.save(update_fields=["name", "room"])

    try:
        _INPUT_ADDERS[device_type](DeviceRegistry.for_apartment(apartment_id), index, name, room.name)
    except Exception:
        logger.exception("assign_input: failed to hot-reload registry (will pick up on next restart)")

    log_action(
        request, "device_relabeled", apartment=apartment,
        reason=f"{device_type} #{index} -> {room.name} / {name}",
    )

    return _ok(
        device_type=device_type, index=index, device_id=device.pk, name=device.name,
        room_id=room.pk, room_name=room.name,
    )
