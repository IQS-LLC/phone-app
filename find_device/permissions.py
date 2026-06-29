"""
Permission resolution + audit logging shared by views.py and device_views.py.

Every /plc/* and /manage/devices/ request must verify: user, apartment,
membership, and permission — never trust the Flutter app to enforce this;
all authorization decisions live here, server-side.
"""
from __future__ import annotations

from django.utils import timezone


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
