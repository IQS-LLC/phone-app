"""
Lugh Tech Team / Building Owner — User & Apartment Management API.

Endpoints (all under /manage/users/, /manage/apartments/) are open to
is_staff (IT Team, every apartment/user) AND to a Building Owner (see
BuildingMembership), scoped to their own building only — see
IsStaffOrBuildingOwner + apartments_in_scope()/users_in_scope() in
permissions.py. This is organizational access (rename rooms/devices,
manage residents) — it deliberately does NOT include apartment_plc
(PLC connection settings), which stays is_staff-only: that's the one
piece of "technical/PLC" territory Building Owner never gets, same as
the light-relabel tool in relabel_views.py.

A plain Resident or Homeowner never reaches any of this — the Flutter UI
hides the whole section for them, and the backend independently enforces
the permission check regardless of what the client sends, per "never
trust the Flutter app."
"""
from __future__ import annotations

import logging

from django.contrib.auth.models import User
from django.contrib.auth.password_validation import validate_password
from django.core.exceptions import ValidationError as DjangoValidationError
from django.shortcuts import get_object_or_404

from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import IsAdminUser
from rest_framework.request import Request
from rest_framework.response import Response
from rest_framework_simplejwt.token_blacklist.models import BlacklistedToken, OutstandingToken

from .models import (
    Apartment, ApartmentDevice, ApartmentMembership, PLCDevice, Permission,
    Role, Room, SessionInfo,
)
from .permissions import IsStaffOrBuildingOwner, apartments_in_scope, log_action, users_in_scope

logger = logging.getLogger("lumina.usermgmt")


def _ok(data: dict, status_code: int = 200) -> Response:
    return Response({"ok": True, **data}, status=status_code)


def _err(message: str, code: str = "ERROR", status_code: int = 400) -> Response:
    return Response({"ok": False, "error": message, "code": code}, status=status_code)


def _user_summary(user: User) -> dict:
    memberships = ApartmentMembership.objects.filter(user=user).select_related("apartment", "custom_role")
    sessions = SessionInfo.objects.filter(user=user, revoked=False)
    return {
        "id": user.id,
        "first_name": user.first_name,
        "last_name": user.last_name,
        "username": user.username,
        "email": user.email,
        "is_active": user.is_active,
        "is_staff": user.is_staff,
        "last_login": user.last_login.isoformat() if user.last_login else None,
        "date_joined": user.date_joined.isoformat(),
        "active_sessions": sessions.count(),
        "apartments": [
            {
                "id": m.apartment_id,
                "name": m.apartment.name,
                "role": m.custom_role.name if m.custom_role_id else m.role,
                "is_default": m.is_default,
            }
            for m in memberships
        ],
    }


# ─────────────────────────────────────────────────────────────────────────────
# List + detail
# ─────────────────────────────────────────────────────────────────────────────

@api_view(["GET"])
@permission_classes([IsStaffOrBuildingOwner])
def user_list(request: Request) -> Response:
    users = users_in_scope(request.user).order_by("username")
    return _ok({"users": [_user_summary(u) for u in users]})


@api_view(["GET"])
@permission_classes([IsStaffOrBuildingOwner])
def apartment_list_all(request: Request) -> Response:
    """
    Every apartment this caller may administer, for the assign-apartment
    picker — distinct from /auth/apartments/, which only returns the
    CALLER's own apartments. Building Owner sees only their building's
    apartments, so they can't assign someone into a building they don't own.
    """
    apartments = apartments_in_scope(request.user).order_by("name")
    return _ok({"apartments": [
        {"id": a.pk, "name": a.name, "building": a.building, "floor": a.floor}
        for a in apartments
    ]})


@api_view(["GET", "DELETE"])
@permission_classes([IsStaffOrBuildingOwner])
def user_detail(request: Request, pk: int) -> Response:
    user = get_object_or_404(users_in_scope(request.user), pk=pk)

    if request.method == "DELETE":
        if user.pk == request.user.pk:
            return _err("You can't delete your own account.", "INVALID_PARAM", 400)
        username = user.username
        log_action(request, "user_deleted", reason=username, target_user_id=pk)
        user.delete()
        return _ok({"message": f"Deleted {username}"})

    return _ok({"user": _user_summary(user)})


# ─────────────────────────────────────────────────────────────────────────────
# Enable / disable
# ─────────────────────────────────────────────────────────────────────────────

@api_view(["POST"])
@permission_classes([IsStaffOrBuildingOwner])
def user_disable(request: Request, pk: int) -> Response:
    user = get_object_or_404(users_in_scope(request.user), pk=pk)
    if user.pk == request.user.pk:
        return _err("You can't disable your own account.", "INVALID_PARAM", 400)
    user.is_active = False
    user.save(update_fields=["is_active"])
    _force_logout(user)
    log_action(request, "user_disabled", target_user_id=pk)
    return _ok({"user": _user_summary(user)})


@api_view(["POST"])
@permission_classes([IsStaffOrBuildingOwner])
def user_enable(request: Request, pk: int) -> Response:
    user = get_object_or_404(users_in_scope(request.user), pk=pk)
    user.is_active = True
    user.save(update_fields=["is_active"])
    log_action(request, "user_enabled", target_user_id=pk)
    return _ok({"user": _user_summary(user)})


# ─────────────────────────────────────────────────────────────────────────────
# Password reset
# ─────────────────────────────────────────────────────────────────────────────

@api_view(["POST"])
@permission_classes([IsStaffOrBuildingOwner])
def user_reset_password(request: Request, pk: int) -> Response:
    user = get_object_or_404(users_in_scope(request.user), pk=pk)
    new_password = request.data.get("new_password") or ""
    if not new_password:
        return _err("new_password is required", "INVALID_PARAM", 400)
    try:
        validate_password(new_password, user=user)
    except DjangoValidationError as exc:
        return _err(" ".join(exc.messages), "WEAK_PASSWORD", 400)

    user.set_password(new_password)
    user.save(update_fields=["password"])
    _force_logout(user)  # old sessions shouldn't outlive a forced password reset
    log_action(request, "password_reset", target_user_id=pk)
    return _ok({"message": f"Password reset for {user.username}"})


# ─────────────────────────────────────────────────────────────────────────────
# Force logout
# ─────────────────────────────────────────────────────────────────────────────

def _force_logout(user: User) -> int:
    sessions = SessionInfo.objects.filter(user=user, revoked=False)
    count = 0
    for session in sessions:
        session.revoked = True
        session.save(update_fields=["revoked"])
        outstanding = OutstandingToken.objects.filter(jti=session.jti).first()
        if outstanding is not None:
            BlacklistedToken.objects.get_or_create(token=outstanding)
        count += 1
    return count


@api_view(["POST"])
@permission_classes([IsStaffOrBuildingOwner])
def user_force_logout(request: Request, pk: int) -> Response:
    user = get_object_or_404(users_in_scope(request.user), pk=pk)
    count = _force_logout(user)
    log_action(request, "force_logout", target_user_id=pk, count=count)
    return _ok({"message": f"Revoked {count} session(s) for {user.username}"})


# ─────────────────────────────────────────────────────────────────────────────
# Apartment assignment
# ─────────────────────────────────────────────────────────────────────────────

@api_view(["POST"])
@permission_classes([IsStaffOrBuildingOwner])
def user_assign_apartment(request: Request, pk: int) -> Response:
    """
    Body: apartment_id (required), role ('owner'|'resident'|'installer',
    default 'resident'), custom_role_id (optional, overrides role),
    is_default (optional bool).

    The target user is intentionally NOT restricted to users_in_scope() —
    that would make it impossible to bring a brand-new resident into an
    apartment (they have no membership yet, so they're not "in scope" until
    this call creates one). The apartment itself IS restricted: a Building
    Owner can only assign people into their own building's apartments.
    """
    user = get_object_or_404(User, pk=pk)
    apartment_id = request.data.get("apartment_id")
    if not apartment_id:
        return _err("apartment_id is required", "INVALID_PARAM", 400)
    apartment = get_object_or_404(apartments_in_scope(request.user), pk=apartment_id)

    role = request.data.get("role", ApartmentMembership.ROLE_RESIDENT)
    if role not in dict(ApartmentMembership.ROLE_CHOICES):
        return _err(f"role must be one of {list(dict(ApartmentMembership.ROLE_CHOICES))}", "INVALID_PARAM", 400)

    custom_role = None
    custom_role_id = request.data.get("custom_role_id")
    if custom_role_id:
        custom_role = get_object_or_404(Role, pk=custom_role_id)

    membership, created = ApartmentMembership.objects.update_or_create(
        user=user, apartment=apartment,
        defaults=dict(
            role=role,
            custom_role=custom_role,
            is_default=bool(request.data.get("is_default", False)),
        ),
    )
    log_action(
        request, "apartment_assigned", apartment=apartment, target_user_id=pk,
        role=role, created=created,
    )
    return _ok({"user": _user_summary(user)}, status_code=201 if created else 200)


@api_view(["DELETE"])
@permission_classes([IsStaffOrBuildingOwner])
def user_remove_apartment(request: Request, pk: int, apartment_id: int) -> Response:
    user = get_object_or_404(User, pk=pk)
    get_object_or_404(apartments_in_scope(request.user), pk=apartment_id)  # 404s if out of scope
    deleted, _ = ApartmentMembership.objects.filter(user=user, apartment_id=apartment_id).delete()
    if not deleted:
        return _err("No such membership", "NOT_FOUND", 404)
    log_action(request, "apartment_unassigned", target_user_id=pk, apartment_id=apartment_id)
    return _ok({"user": _user_summary(user)})


# ─────────────────────────────────────────────────────────────────────────────
# Sessions — view (not just force-revoke) a managed user's logged-in devices
# ─────────────────────────────────────────────────────────────────────────────

@api_view(["GET"])
@permission_classes([IsStaffOrBuildingOwner])
def user_sessions(request: Request, pk: int) -> Response:
    user = get_object_or_404(users_in_scope(request.user), pk=pk)
    sessions = SessionInfo.objects.filter(user=user, revoked=False)
    return _ok({"sessions": [
        {
            "id": s.pk,
            "device_name": s.device_name or "Unknown device",
            "os": s.os,
            "app_version": s.app_version,
            "ip_address": s.ip_address,
            "created_at": s.created_at.isoformat(),
            "last_seen_at": s.last_seen_at.isoformat(),
        }
        for s in sessions
    ]})


# ─────────────────────────────────────────────────────────────────────────────
# Permission editor — list available permission codes, and grant/revoke
# extra (always-additive) permissions on one membership.
# ─────────────────────────────────────────────────────────────────────────────

@api_view(["GET"])
@permission_classes([IsStaffOrBuildingOwner])
def permission_list(request: Request) -> Response:
    perms = Permission.objects.all()
    return _ok({"permissions": [{"code": p.code, "label": p.label} for p in perms]})


@api_view(["GET", "POST"])
@permission_classes([IsStaffOrBuildingOwner])
def user_apartment_permissions(request: Request, pk: int, apartment_id: int) -> Response:
    """
    GET  — effective + extra permission codes for this user's membership on
           this apartment (effective includes whatever their role grants).
    POST — overwrite the membership's extra_permissions set.
           Body: {"permissions": ["diagnostics", "view_cameras", ...]}
    """
    get_object_or_404(apartments_in_scope(request.user), pk=apartment_id)  # 404s if out of scope
    membership = get_object_or_404(
        ApartmentMembership, user_id=pk, apartment_id=apartment_id,
    )

    if request.method == "POST":
        codes = request.data.get("permissions")
        if not isinstance(codes, list):
            return _err("permissions must be a list of codes", "INVALID_PARAM", 400)
        perms = Permission.objects.filter(code__in=codes)
        membership.extra_permissions.set(perms)
        log_action(
            request, "permissions_updated", apartment=membership.apartment,
            target_user_id=pk, permissions=sorted(codes),
        )

    return _ok({
        "role": membership.custom_role.name if membership.custom_role_id else membership.role,
        "effective_permissions": sorted(membership.permission_codes()),
        "extra_permissions": sorted(membership.extra_permissions.values_list("code", flat=True)),
    })


# ─────────────────────────────────────────────────────────────────────────────
# Apartment management — aggregated per-apartment view for the Tech Team
# ─────────────────────────────────────────────────────────────────────────────

def _apartment_summary(apartment: Apartment) -> dict:
    memberships = ApartmentMembership.objects.filter(apartment=apartment).select_related("user")
    owner = next((m for m in memberships if m.role == ApartmentMembership.ROLE_OWNER), None)
    residents = [
        {"id": m.user_id, "username": m.user.username, "display_name": (
            f"{m.user.first_name} {m.user.last_name}".strip() or m.user.username
        )}
        for m in memberships if m.role != ApartmentMembership.ROLE_OWNER
    ]
    plc = getattr(apartment, "plc_device", None)
    return {
        "id": apartment.pk,
        "name": apartment.name,
        "building": apartment.building,
        "floor": apartment.floor,
        "owner": (
            {"id": owner.user_id, "username": owner.user.username,
             "display_name": f"{owner.user.first_name} {owner.user.last_name}".strip() or owner.user.username}
            if owner else None
        ),
        "residents": residents,
        "room_count": apartment.rooms.count(),
        "device_count": apartment.devices.count(),
        "plc": (
            {
                "name": plc.name,
                "is_active": plc.is_active,
                "last_seen_at": plc.last_seen_at.isoformat() if plc.last_seen_at else None,
            }
            if plc else None
        ),
    }


@api_view(["GET", "POST"])
@permission_classes([IsStaffOrBuildingOwner])
def apartment_management_list(request: Request) -> Response:
    if request.method == "POST":
        return _create_apartment(request)
    apartments = apartments_in_scope(request.user).order_by("name")
    return _ok({"apartments": [_apartment_summary(a) for a in apartments]})


def _create_apartment(request: Request) -> Response:
    name = (request.data.get("name") or "").strip()
    if not name:
        return _err("name is required", "INVALID_PARAM", 400)
    if Apartment.objects.filter(name=name).exists():
        return _err(f"An apartment named '{name}' already exists", "DUPLICATE_NAME", 409)

    building = (request.data.get("building") or "").strip()
    if not request.user.is_staff:
        # Building Owner can only create apartments inside a building they
        # already own — default to it if they only own one and didn't
        # specify, otherwise the given building must be one of theirs.
        from .permissions import owned_buildings
        owned = owned_buildings(request.user)
        if not building and len(owned) == 1:
            building = next(iter(owned))
        if building not in owned:
            return _err(
                "building must be one you own — you can't create an apartment in a building you don't manage",
                "INVALID_PARAM", 400,
            )

    apartment = Apartment.objects.create(
        name=name, building=building, floor=(request.data.get("floor") or "").strip(),
    )
    log_action(request, "apartment_created", apartment=apartment)
    return _ok({"apartment": _apartment_summary(apartment)}, status_code=201)


@api_view(["GET"])
@permission_classes([IsStaffOrBuildingOwner])
def apartment_management_detail(request: Request, pk: int) -> Response:
    apartment = get_object_or_404(apartments_in_scope(request.user), pk=pk)
    summary = _apartment_summary(apartment)
    summary["rooms"] = [
        {"id": r.pk, "name": r.name, "device_count": r.devices.count()}
        for r in apartment.rooms.all()
    ]
    return _ok({"apartment": summary})


# ─────────────────────────────────────────────────────────────────────────────
# PLC assignment — distinct from /manage/devices/, which manages PLCDevice
# rows scoped to their literal `owner` field and never links them to an
# Apartment. Without this, a controller created via "Controllers" has no
# effect on what that apartment's residents actually see.
# ─────────────────────────────────────────────────────────────────────────────

def _validate_ams_net_id(value: str) -> bool:
    parts = value.strip().split(".")
    if len(parts) != 6:
        return False
    try:
        return all(0 <= int(p) <= 255 for p in parts)
    except ValueError:
        return False


def _plc_detail(plc: PLCDevice) -> dict:
    return {
        "name":         plc.name,
        "ip_address":   plc.ip_address,
        "ams_net_id":   plc.ams_net_id,
        "ads_port":     plc.ads_port,
        "is_active":    plc.is_active,
        "last_seen_at": plc.last_seen_at.isoformat() if plc.last_seen_at else None,
    }


@api_view(["GET", "POST", "DELETE"])
@permission_classes([IsAdminUser])
def apartment_plc(request: Request, pk: int) -> Response:
    apartment = get_object_or_404(Apartment, pk=pk)
    existing = getattr(apartment, "plc_device", None)

    if request.method == "DELETE":
        if existing is None:
            return _err("No PLC assigned to this apartment", "NOT_FOUND", 404)
        existing.delete()
        log_action(request, "plc_unassigned", apartment=apartment)
        return _ok({"message": f"PLC unassigned from {apartment.name}"})

    if request.method == "POST":
        name = (request.data.get("name") or f"{apartment.name} PLC").strip()
        ip   = (request.data.get("ip_address") or "").strip()
        ams  = (request.data.get("ams_net_id") or "").strip()
        ads_port = request.data.get("ads_port", 851)

        if not ip:
            return _err("ip_address is required", "INVALID_PARAM", 400)
        if not _validate_ams_net_id(ams):
            return _err(
                "ams_net_id must be 6 dot-separated octets, e.g. 192.168.0.158.1.1",
                "INVALID_PARAM", 400,
            )
        try:
            ads_port = int(ads_port)
            if not 1 <= ads_port <= 65535:
                raise ValueError
        except (TypeError, ValueError):
            return _err("ads_port must be 1-65535", "INVALID_PARAM", 400)

        plc, created = PLCDevice.objects.update_or_create(
            apartment=apartment,
            defaults=dict(
                owner=request.user, name=name, ip_address=ip,
                ams_net_id=ams, ads_port=ads_port, is_active=True, is_default=True,
            ),
        )
        log_action(request, "plc_assigned", apartment=apartment, created=created)
        return _ok({"plc": _plc_detail(plc)}, status_code=201 if created else 200)

    # GET
    if existing is None:
        return _ok({"plc": None})
    return _ok({"plc": _plc_detail(existing)})


# ─────────────────────────────────────────────────────────────────────────────
# Rooms — rename/reorder (Tech Team layout control)
# ─────────────────────────────────────────────────────────────────────────────

@api_view(["GET", "POST"])
@permission_classes([IsStaffOrBuildingOwner])
def apartment_rooms(request: Request, pk: int) -> Response:
    apartment = get_object_or_404(apartments_in_scope(request.user), pk=pk)

    if request.method == "POST":
        name = (request.data.get("name") or "").strip()
        if not name:
            return _err("name is required", "INVALID_PARAM", 400)
        if Room.objects.filter(apartment=apartment, name=name).exists():
            return _err(f"Room '{name}' already exists in {apartment.name}", "DUPLICATE_NAME", 409)
        next_order = Room.objects.filter(apartment=apartment).count()
        room = Room.objects.create(apartment=apartment, name=name, sort_order=next_order)
        log_action(request, "room_created", apartment=apartment, room_id=room.pk)
        return _ok({"room": {
            "id": room.pk, "name": room.name, "sort_order": room.sort_order, "device_count": 0,
        }}, status_code=201)

    rooms = apartment.rooms.all()
    return _ok({"rooms": [
        {"id": r.pk, "name": r.name, "sort_order": r.sort_order, "device_count": r.devices.count()}
        for r in rooms
    ]})


@api_view(["PATCH", "DELETE"])
@permission_classes([IsStaffOrBuildingOwner])
def apartment_room_detail(request: Request, pk: int, room_id: int) -> Response:
    get_object_or_404(apartments_in_scope(request.user), pk=pk)  # 404s if out of scope
    room = get_object_or_404(Room, pk=room_id, apartment_id=pk)

    if request.method == "DELETE":
        name = room.name
        room.delete()  # devices in it fall back to room=None (SET_NULL)
        log_action(request, "room_deleted", apartment_id=pk, reason=name)
        return _ok({"message": f"Deleted room '{name}'"})

    if "name" in request.data:
        name = str(request.data["name"]).strip()
        if not name:
            return _err("name cannot be empty", "INVALID_PARAM", 400)
        if Room.objects.filter(apartment_id=pk, name=name).exclude(pk=room.pk).exists():
            return _err(f"Room '{name}' already exists", "DUPLICATE_NAME", 409)
        room.name = name
    if "sort_order" in request.data:
        try:
            room.sort_order = int(request.data["sort_order"])
        except (TypeError, ValueError):
            return _err("sort_order must be an integer", "INVALID_PARAM", 400)
    room.save()
    log_action(request, "room_updated", apartment_id=pk, room_id=room.pk)
    return _ok({"room": {
        "id": room.pk, "name": room.name, "sort_order": room.sort_order,
        "device_count": room.devices.count(),
    }})


@api_view(["POST"])
@permission_classes([IsStaffOrBuildingOwner])
def apartment_rooms_reorder(request: Request, pk: int) -> Response:
    """Body: {"order": [room_id, room_id, ...]} — sets sort_order = index."""
    get_object_or_404(apartments_in_scope(request.user), pk=pk)  # 404s if out of scope
    order = request.data.get("order")
    if not isinstance(order, list):
        return _err("order must be a list of room ids", "INVALID_PARAM", 400)
    rooms = {r.pk: r for r in Room.objects.filter(apartment_id=pk, pk__in=order)}
    for index, room_id in enumerate(order):
        room = rooms.get(room_id)
        if room is not None:
            room.sort_order = index
            room.save(update_fields=["sort_order"])
    log_action(request, "rooms_reordered", apartment_id=pk)
    return _ok({"message": "Rooms reordered"})


# ─────────────────────────────────────────────────────────────────────────────
# Devices — rename/reassign room/reorder (Tech Team layout control)
# ─────────────────────────────────────────────────────────────────────────────

def _device_summary(d: ApartmentDevice) -> dict:
    return {
        "id":               d.pk,
        "name":             d.name,
        "device_type":      d.device_type,
        "room_id":          d.room_id,
        "room_name":        d.room.name if d.room_id else None,
        "sort_order":       d.sort_order,
        "channel_or_index": d.channel_or_index,
    }


@api_view(["GET"])
@permission_classes([IsStaffOrBuildingOwner])
def apartment_devices(request: Request, pk: int) -> Response:
    get_object_or_404(apartments_in_scope(request.user), pk=pk)  # 404s if out of scope
    devices = ApartmentDevice.objects.filter(apartment_id=pk).select_related("room")
    return _ok({"devices": [_device_summary(d) for d in devices]})


@api_view(["PATCH"])
@permission_classes([IsStaffOrBuildingOwner])
def apartment_device_detail(request: Request, pk: int, device_id: int) -> Response:
    get_object_or_404(apartments_in_scope(request.user), pk=pk)  # 404s if out of scope
    device = get_object_or_404(ApartmentDevice, pk=device_id, apartment_id=pk)

    if "name" in request.data:
        name = str(request.data["name"]).strip()
        if not name:
            return _err("name cannot be empty", "INVALID_PARAM", 400)
        device.name = name
    if "room_id" in request.data:
        room_id = request.data["room_id"]
        device.room = None if room_id is None else get_object_or_404(Room, pk=room_id, apartment_id=pk)
    if "sort_order" in request.data:
        try:
            device.sort_order = int(request.data["sort_order"])
        except (TypeError, ValueError):
            return _err("sort_order must be an integer", "INVALID_PARAM", 400)
    device.save()
    log_action(request, "device_updated", apartment_id=pk, device_id=device.pk)
    return _ok({"device": _device_summary(device)})


@api_view(["POST"])
@permission_classes([IsStaffOrBuildingOwner])
def apartment_devices_reorder(request: Request, pk: int) -> Response:
    """Body: {"order": [device_id, ...]} — sets sort_order = index."""
    get_object_or_404(apartments_in_scope(request.user), pk=pk)  # 404s if out of scope
    order = request.data.get("order")
    if not isinstance(order, list):
        return _err("order must be a list of device ids", "INVALID_PARAM", 400)
    devices = {d.pk: d for d in ApartmentDevice.objects.filter(apartment_id=pk, pk__in=order)}
    for index, device_id in enumerate(order):
        device = devices.get(device_id)
        if device is not None:
            device.sort_order = index
            device.save(update_fields=["sort_order"])
    log_action(request, "devices_reordered", apartment_id=pk)
    return _ok({"message": "Devices reordered"})
