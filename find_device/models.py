"""
Lumina PLC — Database models.

Apartment          : One physical apartment / unit. The tenant-isolation
                      boundary — a user can only ever act through their
                      ApartmentMembership rows, never via a client-supplied
                      apartment ID.
ApartmentMembership : Links a User to an Apartment with a role. Replaces the
                      old "PLCDevice.owner = single user" assumption — an
                      apartment can now have multiple residents, and a user
                      (e.g. an installer) can belong to multiple apartments.
PLCDevice          : Connection details (IP/AMS Net ID/port) for the one
                      Beckhoff CX that serves an Apartment. Lives only on
                      the server — never sent to the Flutter app.
Room               : A room within an apartment (Living Room, Kitchen, ...).
ApartmentDevice    : One physical I/O point (DALI channel, wall relay,
                      switch, ...) belonging to an apartment/room. Replaces
                      the hardcoded APARTMENT_CONFIGS dict in registry.py —
                      adding apartment #501 is now a DB row, not a redeploy.
UserProfile        : Per-user preferences (theme, notifications).
DiscoveryCache     : Cached symbol table from a PLCDevice scan.
"""
from django.db import models
from django.contrib.auth.models import User
from django.db.models.signals import post_save
from django.dispatch import receiver


class Apartment(models.Model):
    """
    One physical apartment / unit — the tenant-isolation boundary.

    Every /plc/* request resolves to exactly one Apartment via the
    authenticated user's ApartmentMembership. Never accept an apartment ID
    from request input for this resolution — that would let a user request
    another apartment's ID and control hardware they don't live in.
    """

    name       = models.CharField(max_length=100)
    building   = models.CharField(max_length=100, blank=True)
    floor      = models.CharField(max_length=20, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["name"]

    def __str__(self) -> str:
        return self.name


class ApartmentMembership(models.Model):
    """
    Grants a User access to an Apartment. One user may belong to several
    apartments (e.g. an installer, or someone who owns two units); one
    apartment may have several residents (a household).
    """

    ROLE_OWNER     = "owner"
    ROLE_RESIDENT  = "resident"
    ROLE_INSTALLER = "installer"
    ROLE_CHOICES = [
        (ROLE_OWNER, "Owner"),
        (ROLE_RESIDENT, "Resident"),
        (ROLE_INSTALLER, "Installer"),
    ]

    # Default permission set implied by each basic role, used when no
    # custom_role is set. Defined here (not in the DB) so the common case
    # costs zero extra queries. See Role/Permission below for fully custom,
    # per-building configurable roles.
    DEFAULT_ROLE_PERMISSIONS = {
        ROLE_OWNER: {
            "view", "control_devices", "create_automations", "edit_automations",
            "view_history", "change_settings", "manage_users",
            "plc_connection_settings", "notification_settings", "emergency_controls",
        },
        ROLE_RESIDENT: {
            "view", "control_devices", "create_automations", "view_history",
            "notification_settings",
        },
        ROLE_INSTALLER: {
            "view", "diagnostics", "plc_connection_settings",
            "installer_functions", "firmware_updates",
        },
    }

    user       = models.ForeignKey(
        User, on_delete=models.CASCADE, related_name="apartment_memberships",
    )
    apartment  = models.ForeignKey(
        Apartment, on_delete=models.CASCADE, related_name="memberships",
    )
    role       = models.CharField(max_length=12, choices=ROLE_CHOICES, default=ROLE_RESIDENT)
    # Optional: a fully custom, per-building-configurable role (see Role
    # below) that REPLACES the basic role's default permission set rather
    # than adding to it. Lets a building admin define e.g. a "Security"
    # role with exactly {emergency_controls, view_cameras} and nothing else.
    custom_role = models.ForeignKey(
        "Role", on_delete=models.SET_NULL, null=True, blank=True,
        related_name="memberships",
    )
    # Always-additive on top of role/custom_role — e.g. grant a Resident
    # one extra permission without redefining their whole role.
    extra_permissions = models.ManyToManyField(
        "Permission", blank=True, related_name="granted_to_memberships",
    )
    is_default = models.BooleanField(
        default=False,
        help_text="Which apartment this user's app opens to when they have more than one",
    )
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = [("user", "apartment")]
        ordering = ["-is_default", "apartment__name"]

    def permission_codes(self) -> set:
        """Effective permission codes for this membership."""
        if self.custom_role_id:
            codes = set(self.custom_role.permissions.values_list("code", flat=True))
        else:
            codes = set(self.DEFAULT_ROLE_PERMISSIONS.get(self.role, set()))
        codes |= set(self.extra_permissions.values_list("code", flat=True))
        return codes

    def __str__(self) -> str:
        return f"{self.user.username} -> {self.apartment.name} ({self.role})"

    def save(self, *args, **kwargs):
        if self.is_default:
            ApartmentMembership.objects.filter(
                user=self.user, is_default=True,
            ).exclude(pk=self.pk).update(is_default=False)
        super().save(*args, **kwargs)


class PLCDevice(models.Model):
    """
    Connection details for the one Beckhoff CX / TwinCAT 3 runtime serving
    an Apartment. Server-side only — pyADS uses this; the Flutter app never
    sees an IP address or AMS Net ID.

    The AMS Net ID is the 6-octet identifier TwinCAT uses for routing,
    e.g. "192.168.0.158.1.1".  The IP address is the TCP/IP address of
    the host that runs TwinCAT.  Port 851 is the default TC3 runtime port.
    """

    apartment   = models.OneToOneField(
        Apartment, on_delete=models.CASCADE, related_name="plc_device",
        null=True, blank=True,
    )
    # Kept for backward compatibility / installer audit trail (who registered
    # this connection) — no longer used to decide whether a resident can
    # reach it. That's ApartmentMembership's job.
    owner       = models.ForeignKey(
        User, on_delete=models.CASCADE, related_name="plc_devices",
    )
    name        = models.CharField(max_length=100)
    description = models.CharField(max_length=255, blank=True)
    ip_address  = models.GenericIPAddressField(protocol="both")
    ams_net_id  = models.CharField(
        max_length=23,
        help_text="TwinCAT AMS Net ID, e.g. 192.168.0.158.1.1",
    )
    ads_port    = models.PositiveIntegerField(
        default=851,
        help_text="TwinCAT 3 runtime port (default 851)",
    )
    is_active   = models.BooleanField(default=True)
    is_default  = models.BooleanField(
        default=False,
        help_text="Legacy: whether this was the registering user's primary device",
    )
    created_at  = models.DateTimeField(auto_now_add=True)
    updated_at  = models.DateTimeField(auto_now=True)
    last_seen_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering        = ["-updated_at"]
        unique_together = [("owner", "name")]
        verbose_name    = "PLC Device"
        verbose_name_plural = "PLC Devices"

    def __str__(self) -> str:
        return f"{self.name} ({self.ams_net_id})"

    def save(self, *args, **kwargs):
        # Ensure only one default per user.
        if self.is_default:
            PLCDevice.objects.filter(
                owner=self.owner, is_default=True,
            ).exclude(pk=self.pk).update(is_default=False)
        super().save(*args, **kwargs)


class Room(models.Model):
    """A room within an apartment (Living Room, Kitchen, ...)."""

    apartment  = models.ForeignKey(Apartment, on_delete=models.CASCADE, related_name="rooms")
    name       = models.CharField(max_length=100)
    sort_order = models.PositiveIntegerField(default=0)

    class Meta:
        ordering = ["sort_order", "name"]
        unique_together = [("apartment", "name")]

    def __str__(self) -> str:
        return f"{self.apartment.name} / {self.name}"


class ApartmentDevice(models.Model):
    """
    One physical I/O point belonging to an apartment — a DALI channel, wall
    relay, BTicino switch input, curtain motor, appliance relay, or sensor.

    Replaces the hardcoded APARTMENT_CONFIGS dict that used to live in
    registry.py: DeviceRegistry now builds its in-memory device objects by
    querying ApartmentDevice rows for the apartment being served, so adding
    a new apartment (or a new light in an existing one) is a database row,
    not a code change + redeploy.

    channel_or_index meaning depends on device_type:
      dali / relay     -> DALI/relay channel number
      switch           -> BTicino switch index
      curtain          -> curtain motor index
      door_sensor / window_sensor / motion_sensor -> sensor index
      appliance        -> unused (gvl_name carries the identity instead)
    """

    TYPE_DALI          = "dali"
    TYPE_RELAY         = "relay"
    TYPE_SWITCH        = "switch"
    TYPE_CURTAIN       = "curtain"
    TYPE_APPLIANCE     = "appliance"
    TYPE_DOOR_SENSOR   = "door_sensor"
    TYPE_WINDOW_SENSOR = "window_sensor"
    TYPE_MOTION_SENSOR = "motion_sensor"
    TYPE_CHOICES = [
        (TYPE_DALI, "DALI dimmer"),
        (TYPE_RELAY, "Wall relay"),
        (TYPE_SWITCH, "Switch input"),
        (TYPE_CURTAIN, "Curtain motor"),
        (TYPE_APPLIANCE, "Appliance relay"),
        (TYPE_DOOR_SENSOR, "Door sensor"),
        (TYPE_WINDOW_SENSOR, "Window sensor"),
        (TYPE_MOTION_SENSOR, "Motion sensor"),
    ]

    apartment        = models.ForeignKey(Apartment, on_delete=models.CASCADE, related_name="devices")
    room             = models.ForeignKey(Room, on_delete=models.SET_NULL, null=True, blank=True, related_name="devices")
    device_type      = models.CharField(max_length=20, choices=TYPE_CHOICES)
    channel_or_index = models.PositiveIntegerField(null=True, blank=True)
    gvl_name         = models.CharField(max_length=50, blank=True)
    name             = models.CharField(max_length=100)
    sort_order       = models.PositiveIntegerField(default=0)

    class Meta:
        ordering = ["device_type", "sort_order", "channel_or_index"]
        indexes = [
            models.Index(fields=["apartment", "device_type"]),
        ]

    def __str__(self) -> str:
        ident = self.gvl_name or self.channel_or_index
        return f"{self.apartment.name} / {self.device_type}[{ident}] {self.name}"


class UserProfile(models.Model):
    """Per-user preferences — auto-created on User creation via signal."""

    THEME_DARK  = "dark"
    THEME_LIGHT = "light"
    THEME_CHOICES = [(THEME_DARK, "Dark"), (THEME_LIGHT, "Light")]

    user    = models.OneToOneField(
        User, on_delete=models.CASCADE, related_name="profile",
    )
    theme   = models.CharField(
        max_length=10, choices=THEME_CHOICES, default=THEME_DARK,
    )
    push_notifications_enabled = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = "User Profile"

    def __str__(self) -> str:
        return f"Profile({self.user.username})"


@receiver(post_save, sender=User)
def _create_user_profile(sender, instance, created, **kwargs):
    if created:
        UserProfile.objects.get_or_create(user=instance)


class DiscoveryCache(models.Model):
    """
    Cached TwinCAT symbol discovery result for a PLCDevice.

    symbols_json is a list of symbol descriptor dicts, each containing:
      {name, full_name, type_name, comment, gvl, widget_type, unit, min, max}
    """

    device      = models.OneToOneField(
        PLCDevice, on_delete=models.CASCADE, related_name="discovery_cache",
    )
    symbols_json = models.JSONField(default=list)
    scanned_at  = models.DateTimeField(auto_now=True)
    scan_duration_ms = models.PositiveIntegerField(default=0)
    symbol_count = models.PositiveIntegerField(default=0)

    class Meta:
        verbose_name = "Discovery Cache"

    def __str__(self) -> str:
        return f"DiscoveryCache({self.device.name}, {self.symbol_count} symbols)"


# ─────────────────────────────────────────────────────────────────────────────
# Configurable permissions / custom roles
# ─────────────────────────────────────────────────────────────────────────────

PERMISSION_CODES = [
    ("view",                     "View"),
    ("control_devices",          "Control Devices"),
    ("create_automations",       "Create Automations"),
    ("edit_automations",         "Edit Automations"),
    ("view_cameras",             "View Cameras"),
    ("view_history",             "View History"),
    ("change_settings",          "Change Settings"),
    ("manage_users",             "Manage Users"),
    ("installer_functions",      "Installer Functions"),
    ("diagnostics",              "Diagnostics"),
    ("firmware_updates",         "Firmware Updates"),
    ("plc_connection_settings",  "PLC Connection Settings"),
    ("emergency_controls",       "Emergency Controls"),
    ("notification_settings",    "Notification Settings"),
]


class Permission(models.Model):
    """One independently-assignable capability. Seeded from PERMISSION_CODES."""

    code  = models.SlugField(max_length=50, unique=True)
    label = models.CharField(max_length=100)

    class Meta:
        ordering = ["code"]

    def __str__(self) -> str:
        return self.label


class Role(models.Model):
    """
    A fully custom, per-building-configurable role (e.g. "Security",
    "Building Manager", "Cleaning Service"). Distinct from
    ApartmentMembership.role's 3 basic built-in roles — this is for buildings
    that need finer-grained, named permission sets. is_system roles
    (seeded ones matching common titles) can't be deleted via the API.
    """

    name        = models.CharField(max_length=50, unique=True)
    is_system   = models.BooleanField(default=False)
    permissions = models.ManyToManyField(Permission, blank=True, related_name="roles")
    created_at  = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["name"]

    def __str__(self) -> str:
        return self.name


class TemporaryAccess(models.Model):
    """
    Time-windowed, scoped access — cleaning service, electrician, guest,
    babysitter. Expires automatically (a time-window check at query time,
    no cron required) and can be scoped to specific rooms/devices.
    """

    apartment       = models.ForeignKey(Apartment, on_delete=models.CASCADE, related_name="temporary_grants")
    user            = models.ForeignKey(User, on_delete=models.CASCADE, related_name="temporary_access")
    role            = models.ForeignKey(Role, on_delete=models.PROTECT, related_name="temporary_grants")
    starts_at       = models.DateTimeField()
    expires_at      = models.DateTimeField()
    allowed_rooms   = models.ManyToManyField(Room, blank=True, related_name="temporary_grants")
    allowed_devices = models.ManyToManyField(ApartmentDevice, blank=True, related_name="temporary_grants")
    created_by      = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, related_name="granted_temporary_access")
    revoked         = models.BooleanField(default=False)
    revoked_at      = models.DateTimeField(null=True, blank=True)
    created_at      = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-starts_at"]
        indexes = [models.Index(fields=["apartment", "user", "expires_at"])]

    def __str__(self) -> str:
        return f"{self.user.username} -> {self.apartment.name} ({self.starts_at:%Y-%m-%d} to {self.expires_at:%Y-%m-%d})"

    def is_active(self) -> bool:
        from django.utils import timezone
        now = timezone.now()
        return not self.revoked and self.starts_at <= now <= self.expires_at

    def permission_codes(self) -> set:
        return set(self.role.permissions.values_list("code", flat=True))


# ─────────────────────────────────────────────────────────────────────────────
# Sessions / devices
# ─────────────────────────────────────────────────────────────────────────────

class SessionInfo(models.Model):
    """
    Device metadata for one issued refresh token. Correlates 1:1 with
    SimpleJWT's own OutstandingToken (from rest_framework_simplejwt.
    token_blacklist, already installed) via jti — we don't duplicate token
    storage, just attach "what device is this" on top of it. Revoking a
    session blacklists the underlying OutstandingToken.
    """

    jti          = models.CharField(max_length=255, unique=True)
    user         = models.ForeignKey(User, on_delete=models.CASCADE, related_name="sessions")
    device_name  = models.CharField(max_length=100, blank=True)
    os           = models.CharField(max_length=50, blank=True)
    app_version  = models.CharField(max_length=20, blank=True)
    ip_address   = models.GenericIPAddressField(null=True, blank=True)
    created_at   = models.DateTimeField(auto_now_add=True)
    last_seen_at = models.DateTimeField(auto_now=True)
    revoked      = models.BooleanField(default=False)

    class Meta:
        ordering = ["-last_seen_at"]

    def __str__(self) -> str:
        return f"{self.user.username} @ {self.device_name or 'unknown device'}"


# ─────────────────────────────────────────────────────────────────────────────
# Audit log
# ─────────────────────────────────────────────────────────────────────────────

class AuditLog(models.Model):
    """Every security/control-relevant action, for installer/owner review."""

    RESULT_SUCCESS = "success"
    RESULT_FAILURE = "failure"
    RESULT_CHOICES = [(RESULT_SUCCESS, "Success"), (RESULT_FAILURE, "Failure")]

    user       = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, blank=True, related_name="audit_logs")
    apartment  = models.ForeignKey(Apartment, on_delete=models.SET_NULL, null=True, blank=True, related_name="audit_logs")
    action     = models.CharField(max_length=50)
    result     = models.CharField(max_length=10, choices=RESULT_CHOICES, default=RESULT_SUCCESS)
    reason     = models.CharField(max_length=255, blank=True)
    ip_address = models.GenericIPAddressField(null=True, blank=True)
    metadata   = models.JSONField(default=dict, blank=True)
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)

    class Meta:
        ordering = ["-created_at"]
        indexes = [models.Index(fields=["apartment", "action", "created_at"])]

    def __str__(self) -> str:
        who = self.user.username if self.user else "anonymous"
        return f"[{self.created_at:%Y-%m-%d %H:%M}] {who} {self.action} ({self.result})"
