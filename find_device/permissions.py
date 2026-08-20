"""
Permission resolution + audit logging shared by views.py and device_views.py.

Every /plc/* and /manage/devices/ request must verify: user, apartment,
membership, and permission — never trust the Flutter app to enforce this;
all authorization decisions live here, server-side.
"""
from __future__ import annotations

from django.utils import timezone
from rest_framework.permissions import BasePermission


def _client_ip(request) -> str | None:
    forwarded = request.META.get("HTTP_X_FORWARDED_FOR")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.META.get("REMOTE_ADDR")


def resolve_membership(user, apartment_id: int):
    """The user's ApartmentMembership for this apartment, or None."""
    from .models import ApartmentMembership
    return ApartmentMembership.objects.filter(
        user=user, apartment_id=apartment_id,
    ).select_related("custom_role").first()


def resolve_permissions(user, apartment_id: int) -> set:
    """
    Effective permission codes for this user on this apartment — the union
    of their permanent ApartmentMembership (if any) and any currently-active
    TemporaryAccess grant (time-window checked here, no cron needed).
    """
    from .models import TemporaryAccess

    codes: set = set()

    membership = resolve_membership(user, apartment_id)
    if membership is not None:
        codes |= membership.permission_codes()

    now = timezone.now()
    for grant in TemporaryAccess.objects.filter(
        user=user, apartment_id=apartment_id, revoked=False,
        starts_at__lte=now, expires_at__gte=now,
    ).select_related("role"):
        codes |= grant.permission_codes()

    return codes


def has_relabel_access(user, apartment_id: int) -> bool:
    """
    IT Team (is_staff) only — deliberately not Owner, not Installer, not
    even Building Owner. Re-identifying/relabeling DALI channels is the one
    piece of "how this actually works" IT Team keeps to itself; everyone
    else (including a Building Owner with otherwise IT-Team-equivalent
    access to user/apartment management) never sees this tool exists.
    """
    return bool(user.is_staff)


def is_building_owner(user, building: str) -> bool:
    """
    Whether this user holds a BuildingMembership for the given
    Apartment.building value — the elevated-but-not-technical tier above
    ApartmentMembership (user/apartment management across every apartment
    in that building, never PLC/device/relabel access).
    """
    if not building:
        return False
    from .models import BuildingMembership
    return BuildingMembership.objects.filter(user=user, building=building).exists()


def owned_buildings(user) -> set:
    """Building names this user holds a BuildingMembership for."""
    from .models import BuildingMembership
    return set(BuildingMembership.objects.filter(user=user).values_list("building", flat=True))


def apartments_in_scope(user):
    """
    Apartments this user may administer (organizational — rooms, devices,
    residents — NOT PLC connection settings, which stays is_staff-only, see
    apartment_plc in user_management_views.py). is_staff -> every
    apartment. Building Owner -> only apartments in their building(s).
    Anyone else -> none.
    """
    from .models import Apartment
    if user.is_staff:
        return Apartment.objects.all()
    buildings = owned_buildings(user)
    if not buildings:
        return Apartment.objects.none()
    return Apartment.objects.filter(building__in=buildings)


def users_in_scope(user):
    """
    Users this user may administer. is_staff -> everyone. Building Owner ->
    only users with a membership in one of their building's apartments.
    Anyone else -> none.
    """
    from django.contrib.auth.models import User
    if user.is_staff:
        return User.objects.all()
    apartment_ids = apartments_in_scope(user).values_list("pk", flat=True)
    return User.objects.filter(apartment_memberships__apartment_id__in=apartment_ids).distinct()


class IsStaffOrBuildingOwner(BasePermission):
    """
    Coarse gate for user_management_views.py endpoints now open to Building
    Owner, not just is_staff: is the caller staff, or do they hold ANY
    BuildingMembership at all? The view itself still must scope its actual
    queryset/target via apartments_in_scope()/users_in_scope() — this class
    only decides whether the door is even worth knocking on, same as
    IsAdminUser did for is_staff alone.
    """

    def has_permission(self, request, view) -> bool:
        user = request.user
        if not user or not user.is_authenticated:
            return False
        if user.is_staff:
            return True
        from .models import BuildingMembership
        return BuildingMembership.objects.filter(user=user).exists()


def log_action(
    request, action: str, *,
    apartment=None, result: str = "success", reason: str = "", user=None, **metadata,
) -> None:
    """
    Record a security/control-relevant action. Never raises — a logging
    failure must not break the request it's logging.

    user: explicit override for actions where the relevant user isn't
    request.user yet (e.g. register/login, where the JWT auth middleware
    saw no token on the way in).
    """
    from .models import AuditLog

    try:
        if user is None:
            req_user = getattr(request, "user", None)
            user = req_user if req_user is not None and getattr(req_user, "is_authenticated", False) else None
        AuditLog.objects.create(
            user=user,
            apartment=apartment,
            action=action,
            result=result,
            reason=reason,
            ip_address=_client_ip(request),
            metadata=metadata,
        )
    except Exception:
        import logging
        logging.getLogger("lumina.audit").exception("log_action failed for %s", action)
