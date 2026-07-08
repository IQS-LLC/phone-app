"""
Lumina Auth API — JWT-based authentication.

Endpoints (all under /auth/)
──────────────────────────────────────────────────
  POST /auth/register/   Create a new user account
  POST /auth/login/      Obtain access + refresh tokens
  POST /auth/refresh/    Rotate refresh token, get new access token
  GET  /auth/me/         Return current user profile
  PATCH /auth/me/        Update user profile
  POST /auth/logout/     Blacklist the refresh token

Token format
  Authorization: Bearer <access_token>
"""
from __future__ import annotations

import logging

from django.contrib.auth.models import User
from django.contrib.auth.password_validation import validate_password
from django.core.exceptions import ValidationError as DjangoValidationError

from rest_framework import serializers, status
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny, IsAdminUser, IsAuthenticated
from rest_framework.request import Request
from rest_framework.response import Response
from rest_framework.views import exception_handler as drf_default_exception_handler

from rest_framework_simplejwt.exceptions import InvalidToken, TokenError
from rest_framework_simplejwt.serializers import TokenObtainPairSerializer
from rest_framework_simplejwt.tokens import RefreshToken
from rest_framework_simplejwt.views import TokenObtainPairView

from .models import ApartmentMembership, SessionInfo, UserProfile
from .permissions import log_action

logger = logging.getLogger("lumina.auth")


# ─────────────────────────────────────────────────────────────────────────────
# Custom DRF exception handler — normalise to Lumina response format
# ─────────────────────────────────────────────────────────────────────────────

def drf_exception_handler(exc, context):
    response = drf_default_exception_handler(exc, context)
    if response is not None:
        detail = response.data.get("detail", str(response.data))
        response.data = {
            "ok":    False,
            "error": str(detail),
            "code":  "AUTH_ERROR",
        }
    return response


# ─────────────────────────────────────────────────────────────────────────────
# Serializers
# ─────────────────────────────────────────────────────────────────────────────

class LuminaTokenObtainSerializer(TokenObtainPairSerializer):
    """Adds user details to the token response."""

    @classmethod
    def get_token(cls, user: User):
        token = super().get_token(user)
        token["username"] = user.username
        token["email"]    = user.email
        return token

    def validate(self, attrs):
        data = super().validate(attrs)
        data["user"] = _user_dict(self.user)
        return data


class LuminaTokenObtainView(TokenObtainPairView):
    serializer_class = LuminaTokenObtainSerializer


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

def _user_dict(user: User) -> dict:
    profile = getattr(user, "profile", None)
    return {
        "id":         user.id,
        "username":   user.username,
        "email":      user.email,
        "first_name": user.first_name,
        "last_name":  user.last_name,
        "is_staff":   user.is_staff,  # Tech Team — gates the in-app admin section
        "theme":      profile.theme if profile else "dark",
        "push_notifications": (
            profile.push_notifications_enabled if profile else True
        ),
    }


def _ok(data: dict, status_code: int = status.HTTP_200_OK) -> Response:
    return Response({"ok": True, **data}, status=status_code)


def _err(message: str, code: str = "ERROR", status_code: int = 400) -> Response:
    return Response({"ok": False, "error": message, "code": code}, status=status_code)


def _client_ip(request) -> str | None:
    forwarded = request.META.get("HTTP_X_FORWARDED_FOR")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.META.get("REMOTE_ADDR")


def _record_session(request, refresh: RefreshToken, user: User) -> None:
    """
    Attach device metadata to the OutstandingToken SimpleJWT already creates
    for this refresh token, so "logged-in devices" has something to show.
    The app sends X-Device-Name / X-Device-OS / X-App-Version headers if it
    has them; falls back to User-Agent. Never raises — losing this metadata
    must not break login.
    """
    try:
        jti = refresh.payload.get("jti", "")
        SessionInfo.objects.update_or_create(
            jti=jti,
            defaults=dict(
                user=user,
                device_name=request.headers.get("X-Device-Name", "")[:100],
                os=request.headers.get("X-Device-OS", "")[:50] or request.headers.get("User-Agent", "")[:50],
                app_version=request.headers.get("X-App-Version", "")[:20],
                ip_address=_client_ip(request),
            ),
        )
    except Exception:
        logger.exception("_record_session failed for user %s", user.username)


# ─────────────────────────────────────────────────────────────────────────────
# Register
# ─────────────────────────────────────────────────────────────────────────────

@api_view(["POST"])
@permission_classes([IsAdminUser])
def register(request: Request) -> Response:
    """
    Create a new account. Staff-only (admin/installer/IT team) — residents
    are provisioned accounts by the building's IT team, never self-service.
    Use Django admin for the common case; this endpoint exists for
    programmatic provisioning by staff tooling.

    Body: username, password, email (optional), first_name (optional)
    Returns: access + refresh tokens + user dict
    """
    username   = (request.data.get("username") or "").strip()
    password   = request.data.get("password") or ""
    email      = (request.data.get("email") or "").strip()
    first_name = (request.data.get("first_name") or "").strip()

    if not username:
        return _err("username is required", "INVALID_PARAM")
    if not password:
        return _err("password is required", "INVALID_PARAM")
    if len(username) < 3:
        return _err("username must be at least 3 characters", "INVALID_PARAM")
    if User.objects.filter(username=username).exists():
        return _err("Username already taken", "USERNAME_TAKEN", 409)
    if email and User.objects.filter(email=email).exists():
        return _err("Email already registered", "EMAIL_TAKEN", 409)

    # Validate password strength
    try:
        validate_password(password)
    except DjangoValidationError as exc:
        return _err(" ".join(exc.messages), "WEAK_PASSWORD")

    user = User.objects.create_user(
        username=username,
        password=password,
        email=email,
        first_name=first_name,
    )

    refresh = RefreshToken.for_user(user)
    _record_session(request, refresh, user)
    logger.info("New user registered: %s", username)
    log_action(request, "register", user=user)

    return _ok(
        {
            "access":  str(refresh.access_token),
            "refresh": str(refresh),
            "user":    _user_dict(user),
        },
        status_code=status.HTTP_201_CREATED,
    )


# ─────────────────────────────────────────────────────────────────────────────
# Login  (delegates to simplejwt but adds user dict)
# ─────────────────────────────────────────────────────────────────────────────

@api_view(["POST"])
@permission_classes([AllowAny])
def login(request: Request) -> Response:
    """
    Authenticate with username + password.
    Returns access token (30 min) + refresh token (7 days, rotated).
    """
    attempted_username = (request.data.get("username") or "").strip()
    serializer = LuminaTokenObtainSerializer(
        data=request.data, context={"request": request}
    )
    try:
        serializer.is_valid(raise_exception=True)
    except TokenError as exc:
        return _err(str(exc), "TOKEN_ERROR", 401)
    except serializers.ValidationError:
        logger.warning("Login failed: %s", attempted_username)
        log_action(
            request, "login", result="failure",
            reason="invalid credentials", attempted_username=attempted_username,
        )
        return _err(
            "Invalid credentials. Check username and password.",
            "INVALID_CREDENTIALS",
            401,
        )

    data = serializer.validated_data
    user = User.objects.get(username=data["user"]["username"])
    _record_session(request, RefreshToken(data["refresh"]), user)
    logger.info("Login: %s", data["user"]["username"])
    log_action(request, "login", user=user)
    return _ok(data)


# ─────────────────────────────────────────────────────────────────────────────
# Refresh
# ─────────────────────────────────────────────────────────────────────────────

@api_view(["POST"])
@permission_classes([AllowAny])
def refresh_token(request: Request) -> Response:
    """
    Exchange a refresh token for a new access + refresh pair.
    The old refresh token is blacklisted (rotation enabled).
    """
    token_str = request.data.get("refresh") or ""
    if not token_str:
        return _err("refresh token is required", "INVALID_PARAM")

    try:
        token = RefreshToken(token_str)
        access = str(token.access_token)
        user = User.objects.get(id=token.payload["user_id"])
        # rotate — blacklists old, generates new refresh
        token.blacklist()
        new_refresh = RefreshToken.for_user(user)
        _record_session(request, new_refresh, user)
    except (TokenError, InvalidToken) as exc:
        return _err(str(exc), "TOKEN_INVALID", 401)
    except Exception as exc:
        logger.exception("refresh_token error")
        return _err(str(exc), "SERVER_ERROR", 500)

    return _ok({"access": access, "refresh": str(new_refresh)})


# ─────────────────────────────────────────────────────────────────────────────
# Me
# ─────────────────────────────────────────────────────────────────────────────

@api_view(["GET", "PATCH"])
@permission_classes([IsAuthenticated])
def me(request: Request) -> Response:
    """
    GET  — return the authenticated user's profile.
    PATCH — update theme or push_notifications.
    """
    user = request.user

    if request.method == "GET":
        return _ok({"user": _user_dict(user)})

    # PATCH — update mutable profile fields
    profile, _ = UserProfile.objects.get_or_create(user=user)
    updated = []

    if "theme" in request.data:
        theme = request.data["theme"]
        if theme not in ("dark", "light"):
            return _err("theme must be 'dark' or 'light'", "INVALID_PARAM")
        profile.theme = theme
        updated.append("theme")

    if "push_notifications" in request.data:
        profile.push_notifications_enabled = bool(request.data["push_notifications"])
        updated.append("push_notifications")

    if "first_name" in request.data:
        user.first_name = str(request.data["first_name"])[:50]
        user.save(update_fields=["first_name"])
        updated.append("first_name")

    if "last_name" in request.data:
        user.last_name = str(request.data["last_name"])[:50]
        user.save(update_fields=["last_name"])
        updated.append("last_name")

    profile.save()
    return _ok({"user": _user_dict(user), "updated": updated})


# ─────────────────────────────────────────────────────────────────────────────
# Logout
# ─────────────────────────────────────────────────────────────────────────────

@api_view(["POST"])
@permission_classes([IsAuthenticated])
def logout(request: Request) -> Response:
    """
    Blacklist the refresh token so it can no longer be used.
    The client should also discard its stored tokens.
    """
    token_str = request.data.get("refresh") or ""
    if not token_str:
        return _err("refresh token is required", "INVALID_PARAM")

    try:
        token = RefreshToken(token_str)
        SessionInfo.objects.filter(jti=token.payload.get("jti", "")).update(revoked=True)
        token.blacklist()
    except (TokenError, InvalidToken):
        pass  # already invalid/expired — treat as logged out

    logger.info("Logout: %s", request.user.username)
    log_action(request, "logout")
    return _ok({"message": "Logged out successfully"})


# ─────────────────────────────────────────────────────────────────────────────
# Sessions — logged-in devices
# ─────────────────────────────────────────────────────────────────────────────

@api_view(["GET"])
@permission_classes([IsAuthenticated])
def session_list(request: Request) -> Response:
    """List this user's logged-in devices (active, non-revoked sessions)."""
    sessions = SessionInfo.objects.filter(user=request.user, revoked=False)
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


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def session_revoke(request: Request, pk: int) -> Response:
    """
    Log out one specific device. Blacklists its underlying OutstandingToken
    so the refresh token can't be used again, not just a local flag flip.
    """
    from django.shortcuts import get_object_or_404
    from rest_framework_simplejwt.token_blacklist.models import BlacklistedToken, OutstandingToken

    session = get_object_or_404(SessionInfo, pk=pk, user=request.user)
    session.revoked = True
    session.save(update_fields=["revoked"])

    outstanding = OutstandingToken.objects.filter(jti=session.jti).first()
    if outstanding is not None:
        BlacklistedToken.objects.get_or_create(token=outstanding)

    log_action(request, "session_revoke", session_id=pk, device_name=session.device_name)
    return _ok({"message": "Session revoked"})


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def session_revoke_all(request: Request) -> Response:
    """Log out every device except the one making this request, if identifiable."""
    from rest_framework_simplejwt.token_blacklist.models import BlacklistedToken, OutstandingToken

    sessions = SessionInfo.objects.filter(user=request.user, revoked=False)
    count = 0
    for session in sessions:
        session.revoked = True
        session.save(update_fields=["revoked"])
        outstanding = OutstandingToken.objects.filter(jti=session.jti).first()
        if outstanding is not None:
            BlacklistedToken.objects.get_or_create(token=outstanding)
        count += 1

    log_action(request, "session_revoke_all", count=count)
    return _ok({"message": f"Revoked {count} session(s)"})


# ─────────────────────────────────────────────────────────────────────────────
# Apartment selection
# ─────────────────────────────────────────────────────────────────────────────

@api_view(["GET"])
@permission_classes([IsAuthenticated])
def apartment_list(request: Request) -> Response:
    """
    Every apartment this user can access — via permanent membership or an
    active temporary grant — with their role/permissions on each, so the
    app can show an apartment selector (or skip straight in if there's
    only one) without ever needing a PLC IP or AMS Net ID.
    """
    from django.utils import timezone
    from .models import TemporaryAccess

    apartments = []
    for m in ApartmentMembership.objects.filter(user=request.user).select_related("apartment"):
        apartments.append({
            "id": m.apartment_id,
            "name": m.apartment.name,
            "building": m.apartment.building,
            "floor": m.apartment.floor,
            "role": m.custom_role.name if m.custom_role_id else m.role,
            "permissions": sorted(m.permission_codes()),
            "is_default": m.is_default,
            "access_type": "membership",
        })

    now = timezone.now()
    for g in TemporaryAccess.objects.filter(
        user=request.user, revoked=False, starts_at__lte=now, expires_at__gte=now,
    ).select_related("apartment", "role"):
        apartments.append({
            "id": g.apartment_id,
            "name": g.apartment.name,
            "building": g.apartment.building,
            "floor": g.apartment.floor,
            "role": g.role.name,
            "permissions": sorted(g.permission_codes()),
            "is_default": False,
            "access_type": "temporary",
            "expires_at": g.expires_at.isoformat(),
        })

    return _ok({"apartments": apartments})


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def apartment_select(request: Request, pk: int) -> Response:
    """Switch which apartment this user's app opens to by default."""
    membership = ApartmentMembership.objects.filter(user=request.user, apartment_id=pk).first()
    if membership is None:
        return _err(
            "You don't have a membership on that apartment (temporary "
            "grants can't be set as default).", "NOT_FOUND", 404,
        )
    membership.is_default = True
    membership.save()  # model.save() demotes any other default
    log_action(request, "apartment_select", apartment=membership.apartment)
    return _ok({"apartment_id": pk})
