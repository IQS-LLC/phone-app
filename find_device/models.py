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

    # ── Building-wide admin controls (2026-09-25) ───────────────────────────
    # Additive, defaults preserve current behavior for every existing row —
    # only meaningful for a building-wide Apartment (e.g. "Building Common
    # Areas"), harmless no-ops for a normal tenant apartment. These drive
    # find_device.tasks.apply_sunset_sunrise_overrides and
    # find_device.lighting_effects's Christmas chase directly over ADS —
    # deliberately independent of whatever a PLC's own on-board automation
    # (e.g. this building's MAIN.fbHttpClientOpenWeatherMap) does, since we
    # have no visibility into or control over that program's own logic and
    # won't push unverified TwinCAT changes to real hardware. If the PLC's
    # own automatic behavior is already working, enabling an override here
    # will fight it — auto_sunset_sunrise defaults True (app does nothing)
    # specifically so this never engages until an admin deliberately turns
    # auto off and sets override times.
    auto_sunset_sunrise  = models.BooleanField(default=True)
    sunset_override_time  = models.TimeField(null=True, blank=True)
    sunrise_override_time = models.TimeField(null=True, blank=True)

    # Client poll interval floor, seconds. AppState's own hardcoded 1s
    # default (see runtime_config/app_state.dart) is already tuned to the
    # CX8190's ADS stability limits — this field lets an admin raise it
    # (never lower below the app's own safety floor) if a particular
    # building's PLC needs a gentler poll rate.
    poll_interval_s = models.PositiveIntegerField(default=1)

    # Whether find_device.lighting_effects's Christmas chase is currently
    # running for this apartment — DB-backed (not just an in-process flag)
    # so status survives a worker restart and is visible cross-process.
    christmas_mode_active = models.BooleanField(default=False)

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
    # Owner (the homeowner — whether they live there or rent it out) is
    # deliberately NOT a technical/admin role: same device-control surface
    # as Resident, plus only the ability to manage their own household
    # (invite/remove their own family members or renters). No PLC/settings/
    # configuration access of any kind — that's exclusively IT Team
    # (is_staff) and, above the apartment level, a Building Owner. See
    # has_relabel_access in permissions.py, which is is_staff-only for
    # exactly this reason.
    DEFAULT_ROLE_PERMISSIONS = {
        ROLE_OWNER: {
            "view", "control_devices", "create_automations", "edit_automations",
            "view_history", "manage_users", "notification_settings", "emergency_controls",
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


class BuildingMembership(models.Model):
    """
    Grants a User elevated access across every Apartment sharing the same
    Apartment.building value — a tier above ApartmentMembership, for someone
    who owns/manages the whole building rather than one unit.

    Deliberately separate from ApartmentMembership rather than "just another
    role" on it: this permission surface spans MANY apartments (user
    management, apartment management across the building), which
    ApartmentMembership has no way to express since it's scoped to exactly
    one apartment.

    Building Owner gets IT-Team-equivalent access to user/apartment
    management, but NOT PLC/device commissioning or the light-relabel tool
    — that stays exclusively is_staff, on purpose (see has_relabel_access
    in permissions.py). Matches Apartment.building by plain string equality;
    there's no separate Building model since nothing today needs building
    metadata beyond a shared name to group apartments by.
    """

    ROLE_OWNER = "owner"
    ROLE_CHOICES = [
        (ROLE_OWNER, "Building Owner"),
    ]

    user       = models.ForeignKey(
        User, on_delete=models.CASCADE, related_name="building_memberships",
    )
    building   = models.CharField(max_length=200)
    role       = models.CharField(max_length=12, choices=ROLE_CHOICES, default=ROLE_OWNER)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = [("user", "building")]

    def __str__(self) -> str:
        return f"{self.user.username} -> {self.building} ({self.role})"


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
    down_since   = models.DateTimeField(
        null=True, blank=True,
        help_text="Set when check_plc_heartbeat first observes this device "
                   "unreachable (ADS and Modbus both down); cleared on "
                   "recovery. Persisted (not in-memory) so a Celery worker "
                   "restart mid-outage doesn't lose track of it or re-fire "
                   "the outage-start alert.",
    )

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
      appliance / toggle / named_switch -> unused (gvl_name carries the
      identity instead)

    toggle is a plain named BOOL relay/light living directly under gvlDALI
    (e.g. "bBalconLightRaley", "bMirrorLight") — distinct from appliance,
    which targets gvlIO.bPy{name}Cmd/State (no real hardware exists there
    yet). gvl_name for a toggle device is the exact variable name after
    "gvlDALI." — see devices.NamedRelay.

    named_switch is the read-only input-side counterpart: a physical
    push-button wired straight into POU_Controller with its own unique
    name (e.g. "bVentilatorGuestButton") rather than a numbered slot in
    the bSwitchOn1..48 array SwitchInput expects — see devices.
    NamedSwitchInput. Exists so these buttons can be used as Automation
    triggers even though they don't fit the indexed switch model.
    """

    TYPE_DALI          = "dali"
    TYPE_RELAY         = "relay"
    TYPE_SWITCH        = "switch"
    TYPE_CURTAIN       = "curtain"
    TYPE_APPLIANCE     = "appliance"
    TYPE_DOOR_SENSOR   = "door_sensor"
    TYPE_WINDOW_SENSOR = "window_sensor"
    TYPE_MOTION_SENSOR = "motion_sensor"
    TYPE_TOGGLE        = "toggle"
    TYPE_NAMED_SWITCH  = "named_switch"
    # For a DeviceAddressScheme-driven device (see address_scheme below)
    # whose shape doesn't map cleanly onto any type above — e.g. a
    # SuperScan-discovered symbol promoted via superscan_views.promote_capability
    # with no existing class it resembles. Purely descriptive: the registry
    # dispatches on address_scheme_id being set, not on this value, for any
    # row that has a scheme — see registry.DeviceRegistry._start().
    TYPE_CUSTOM        = "custom"
    TYPE_CHOICES = [
        (TYPE_DALI, "DALI dimmer"),
        (TYPE_RELAY, "Wall relay"),
        (TYPE_SWITCH, "Switch input"),
        (TYPE_CURTAIN, "Curtain motor"),
        (TYPE_APPLIANCE, "Appliance relay"),
        (TYPE_DOOR_SENSOR, "Door sensor"),
        (TYPE_WINDOW_SENSOR, "Window sensor"),
        (TYPE_MOTION_SENSOR, "Motion sensor"),
        (TYPE_TOGGLE, "Named relay/light"),
        (TYPE_NAMED_SWITCH, "Named switch input"),
        (TYPE_CUSTOM, "Custom (scheme-driven)"),
    ]

    apartment        = models.ForeignKey(Apartment, on_delete=models.CASCADE, related_name="devices")
    room             = models.ForeignKey(Room, on_delete=models.SET_NULL, null=True, blank=True, related_name="devices")
    device_type      = models.CharField(max_length=20, choices=TYPE_CHOICES)
    channel_or_index = models.PositiveIntegerField(null=True, blank=True)
    gvl_name         = models.CharField(max_length=50, blank=True)
    name             = models.CharField(max_length=100)
    sort_order       = models.PositiveIntegerField(default=0)

    # Added 2026-08-24, nullable, defaults to null on every existing row —
    # see DeviceAddressScheme's docstring. When set, DeviceRegistry builds
    # this device as a devices.TemplatedDevice using the scheme's GVL
    # templates instead of dispatching on device_type to one of the
    # hardcoded classes below. When null (every device created before this
    # field existed, and every device created the normal way since), this
    # column has no effect whatsoever — DeviceRegistry's existing dispatch
    # is completely unchanged.
    address_scheme = models.ForeignKey(
        "DeviceAddressScheme", on_delete=models.PROTECT, null=True, blank=True,
        related_name="devices",
        help_text="Optional. Leave blank to use the built-in Python class "
                   "for this device_type (the normal, tested path). Set "
                   "this only for a device whose GVL layout doesn't match "
                   "any existing hardcoded class — see docs/plc-integration.md.",
    )

    class Meta:
        ordering = ["device_type", "sort_order", "channel_or_index"]
        indexes = [
            models.Index(fields=["apartment", "device_type"]),
        ]

    def __str__(self) -> str:
        ident = self.gvl_name or self.channel_or_index
        return f"{self.apartment.name} / {self.device_type}[{ident}] {self.name}"


class DeviceAddressScheme(models.Model):
    """
    A reusable, named GVL addressing pattern — added 2026-08-24 so a new PLC
    generation or a different integrator's naming convention can be
    expressed as a database row instead of a new Python class in
    find_device/plc/devices.py. See docs/plc-integration.md for the full
    design rationale and docs/AUDIT_FINDINGS.md §1 for why this exists (the
    control path had hardcoded a GVL prefix + addressing formula per device
    class, so every new GVL layout meant writing new Python).

    Deliberately additive: ApartmentDevice.address_scheme is nullable and
    defaults to null on every existing row. A device with no scheme keeps
    using devices.py's existing hardcoded classes exactly as before this
    model existed — nothing about current apartments changes by this model
    merely existing. See devices.TemplatedDevice for the class that
    interprets a scheme, and registry.DeviceRegistry._start() for the one
    new branch that constructs it instead of a hardcoded class.

    Template placeholders (plain str.format(), never eval — deliberately
    not a general expression language, to keep a bad template fail loud
    with a KeyError/IndexError rather than execute arbitrary code):
      {gvl}      -> this row's own `gvl` field
      {index}    -> the owning ApartmentDevice.channel_or_index + index_offset
      {gvl_name} -> the owning ApartmentDevice.gvl_name, verbatim

    index_offset exists because real addressing isn't always a direct
    channel-number substitution — e.g. WallRelay's actual, current formula
    is `gvlDALI.bRelay{channel-1}` (zero-based array, one-based channel
    number in the UI/DB). Rather than allow arbitrary arithmetic in a
    template string, the one offset real schemes have needed so far is a
    first-class field.
    """

    PROTOCOL_ADS    = "ads"
    PROTOCOL_MODBUS = "modbus"
    PROTOCOL_BOTH   = "both"
    PROTOCOL_CHOICES = [
        (PROTOCOL_ADS, "ADS only"),
        (PROTOCOL_MODBUS, "Modbus only"),
        (PROTOCOL_BOTH, "ADS with Modbus fallback"),
    ]

    # Matches the raw ADS type vocabulary find_device/discovery/classifier.py
    # already uses (_BOOL_TYPES/_INT_TYPES/_REAL_TYPES/_STR_TYPES) — reused
    # rather than inventing a second type vocabulary for the same concept.
    PLC_TYPE_CHOICES = [
        ("BOOL", "BOOL"),
        ("BYTE", "BYTE"), ("INT", "INT"), ("UINT", "UINT"),
        ("DINT", "DINT"), ("UDINT", "UDINT"),
        ("SINT", "SINT"), ("USINT", "USINT"),
        ("WORD", "WORD"), ("DWORD", "DWORD"),
        ("REAL", "REAL"), ("LREAL", "LREAL"),
        ("STRING", "STRING"), ("WSTRING", "WSTRING"),
    ]

    name        = models.CharField(
        max_length=100, unique=True,
        help_text="Short, versioned identifier, e.g. 'apt16_dali_v1'. A "
                   "different PLC generation or naming convention is a new "
                   "row with a new name, never an edit to an existing one "
                   "that's already in use — devices already pointing at a "
                   "scheme must not have its meaning change under them.",
    )
    description = models.CharField(max_length=255, blank=True)

    gvl                 = models.CharField(max_length=50, help_text="e.g. gvlController")
    read_var_template   = models.CharField(max_length=150, blank=True)
    write_var_template  = models.CharField(max_length=150, blank=True)
    commit_var_template = models.CharField(
        max_length=150, blank=True,
        help_text="Optional rising-edge 'commit' variable for the "
                   "write-then-pulse pattern DaliChannel/WallRelay already "
                   "use (see devices.py) — leave blank if this scheme's "
                   "write_var_template alone is sufficient.",
    )
    index_offset = models.IntegerField(
        default=0,
        help_text="Added to the owning device's channel_or_index before "
                   "it's substituted into a template as {index}.",
    )

    plc_type = models.CharField(max_length=10, choices=PLC_TYPE_CHOICES, default="BOOL")
    protocol = models.CharField(max_length=10, choices=PROTOCOL_CHOICES, default=PROTOCOL_ADS)

    # Reuses find_device/discovery/classifier.py's WIDGET_* vocabulary as
    # plain strings (not a FK/import — classifier.py has no models and
    # shouldn't need to) so a scheme-driven device renders with the same
    # widget catalogue a SuperScan-discovered one does.
    widget_type = models.CharField(
        max_length=20, blank=True,
        help_text="One of find_device.discovery.classifier's WIDGET_* "
                   "values, e.g. 'dali_slider', 'toggle'. Blank is fine — "
                   "the UI falls back to device_type-based rendering.",
    )

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = "Device Address Scheme"
        verbose_name_plural = "Device Address Schemes"

    def __str__(self) -> str:
        return f"{self.name} ({self.gvl}, {self.protocol})"

    def format_var(self, template: str, *, channel_or_index, gvl_name: str) -> str:
        """
        Render one of this scheme's templates against an owning device's
        identity. Raises KeyError/IndexError on a malformed template rather
        than silently producing a wrong variable name — see
        devices.TemplatedDevice for how that surfaces as a real, loud
        connection error instead of a mysteriously-nonresponsive device.
        """
        index = None
        if channel_or_index is not None:
            index = channel_or_index + self.index_offset
        return template.format(gvl=self.gvl, index=index, gvl_name=gvl_name)


class AutomationRule(models.Model):
    """
    "When this input does X, do Y to that output" — configured entirely
    through the phone, no TwinCAT/ST code involved. Executed by
    DeviceRegistry subscribing to trigger_device's raw ADS variable via
    NotificationManager (find_device/plc/ads_notifications.py — instant,
    event-driven push, not polling) and writing action_device the moment
    trigger_device's value matches trigger_state.

    Deliberately ADDITIVE, never a replacement: whatever's already
    hardwired inside the PLC's own program for a given switch/sensor keeps
    running completely unchanged. A rule here is a second, independent
    reaction to the same physical event — it does not, and cannot, disable
    or rewire the PLC's existing logic. Actually reassigning what a
    hardwired switch does requires editing the TwinCAT program itself, a
    separate and far riskier change (see docs / project memory on this).

    is_staff (IT Team) only, same bar as the light-relabel tool — an
    automation rule IS the "no more hand-written PLC code" capability the
    building owner isn't meant to know exists as a raw technical tool.
    """

    TRIGGER_TYPES = (
        ApartmentDevice.TYPE_SWITCH, ApartmentDevice.TYPE_MOTION_SENSOR,
        ApartmentDevice.TYPE_DOOR_SENSOR, ApartmentDevice.TYPE_WINDOW_SENSOR,
        ApartmentDevice.TYPE_NAMED_SWITCH,
    )
    ACTION_TYPES = (
        ApartmentDevice.TYPE_DALI, ApartmentDevice.TYPE_RELAY,
        ApartmentDevice.TYPE_CURTAIN, ApartmentDevice.TYPE_APPLIANCE,
        ApartmentDevice.TYPE_TOGGLE,
    )

    apartment      = models.ForeignKey(Apartment, on_delete=models.CASCADE, related_name="automation_rules")
    name           = models.CharField(max_length=100)
    enabled        = models.BooleanField(default=True)
    trigger_device = models.ForeignKey(
        ApartmentDevice, on_delete=models.CASCADE, related_name="automation_triggers",
    )
    # Fires when trigger_device's boolean state BECOMES this value — covers
    # both "on press/activate" (True) and "on release/clear" (False).
    trigger_state  = models.BooleanField()
    action_device  = models.ForeignKey(
        ApartmentDevice, on_delete=models.CASCADE, related_name="automation_actions",
    )
    # Interpreted per action_device.device_type: dali -> "0"-"100" (percent),
    # relay/appliance/toggle -> "true"/"false", curtain -> "stop"/"up"/"down".
    action_value   = models.CharField(max_length=20)
    created_by     = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, blank=True)
    created_at     = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]

    def __str__(self) -> str:
        return f"{self.apartment.name}: {self.name}"


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
    show_ventilators_home = models.BooleanField(default=True)
    # DALI fade duration in ms. Applies only to continuously-dimmable DALI
    # channels — relays/curtains are binary and stay instant regardless of
    # these. Global per-user for now; per-light override is a real future
    # option, not built until there's an actual need for it.
    dim_duration_ms   = models.PositiveIntegerField(default=800)
    undim_duration_ms = models.PositiveIntegerField(default=500)
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


# ─────────────────────────────────────────────────────────────────────────────
# Digital Twin Map Editor
# ─────────────────────────────────────────────────────────────────────────────

class MapLayout(models.Model):
    """
    Canvas configuration for one apartment's Digital Twin floor plan.
    Tech Team edits this; residents read the published state.
    One layout per apartment — create on first editor open.
    """

    apartment      = models.OneToOneField(
        Apartment, on_delete=models.CASCADE, related_name="map_layout",
    )
    canvas_width   = models.FloatField(default=2000)
    canvas_height  = models.FloatField(default=1500)

    # Background image (architectural drawing imported as locked tracing layer)
    background_url    = models.CharField(max_length=500, blank=True)
    background_x      = models.FloatField(default=0)
    background_y      = models.FloatField(default=0)
    background_width  = models.FloatField(default=2000)
    background_height = models.FloatField(default=1500)
    background_rotation = models.FloatField(default=0)
    background_opacity  = models.FloatField(default=0.25)
    background_locked   = models.BooleanField(default=True)
    background_visible  = models.BooleanField(default=True)

    is_published  = models.BooleanField(default=False)
    published_at  = models.DateTimeField(null=True, blank=True)
    created_by    = models.ForeignKey(
        User, on_delete=models.SET_NULL, null=True, blank=True,
        related_name="created_map_layouts",
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = "Map Layout"

    def __str__(self) -> str:
        return f"MapLayout({self.apartment.name})"


class MapLayer(models.Model):
    """Named layer for organising canvas objects (walls, lighting, sensors, …)."""

    LAYER_BACKGROUND  = "background"
    LAYER_WALLS       = "walls"
    LAYER_FURNITURE   = "furniture"
    LAYER_ELECTRICAL  = "electrical"
    LAYER_LIGHTING    = "lighting"
    LAYER_SENSORS     = "sensors"
    LAYER_SECURITY    = "security"
    LAYER_HVAC        = "hvac"
    LAYER_ENERGY      = "energy"
    LAYER_NETWORKING  = "networking"
    LAYER_LABELS      = "labels"
    LAYER_ANNOTATIONS = "annotations"
    LAYER_CHOICES = [
        (LAYER_BACKGROUND,  "Background"),
        (LAYER_WALLS,       "Walls"),
        (LAYER_FURNITURE,   "Furniture"),
        (LAYER_ELECTRICAL,  "Electrical"),
        (LAYER_LIGHTING,    "Lighting"),
        (LAYER_SENSORS,     "Sensors"),
        (LAYER_SECURITY,    "Security"),
        (LAYER_HVAC,        "HVAC"),
        (LAYER_ENERGY,      "Energy"),
        (LAYER_NETWORKING,  "Networking"),
        (LAYER_LABELS,      "Labels"),
        (LAYER_ANNOTATIONS, "Annotations"),
    ]

    DEFAULT_LAYERS = [
        ("Rooms",       LAYER_WALLS,       0),
        ("Furniture",   LAYER_FURNITURE,   1),
        ("Electrical",  LAYER_ELECTRICAL,  2),
        ("Lighting",    LAYER_LIGHTING,    3),
        ("Sensors",     LAYER_SENSORS,     4),
        ("HVAC",        LAYER_HVAC,        5),
        ("Security",    LAYER_SECURITY,    6),
        ("Labels",      LAYER_LABELS,      7),
        ("Annotations", LAYER_ANNOTATIONS, 8),
    ]

    layout     = models.ForeignKey(MapLayout, on_delete=models.CASCADE, related_name="layers")
    name       = models.CharField(max_length=100)
    layer_type = models.CharField(max_length=20, choices=LAYER_CHOICES, default=LAYER_LABELS)
    visible    = models.BooleanField(default=True)
    locked     = models.BooleanField(default=False)
    sort_order = models.PositiveIntegerField(default=0)

    class Meta:
        ordering = ["sort_order", "id"]

    def __str__(self) -> str:
        return f"{self.layout.apartment.name} / {self.name}"


class CanvasObject(models.Model):
    """
    One interactive element on the canvas: a room, a device icon, a label, etc.
    Linked to ApartmentDevice for live PLC control in resident mode.
    """

    TYPE_ROOM    = "room"
    TYPE_DEVICE  = "device"
    TYPE_LABEL   = "label"
    TYPE_WALL    = "wall"
    TYPE_OBJECT_CHOICES = [
        (TYPE_ROOM,   "Room"),
        (TYPE_DEVICE, "Device"),
        (TYPE_LABEL,  "Label"),
        (TYPE_WALL,   "Wall"),
    ]

    # Device sub-types (one per physical device category)
    DEV_CEILING_LIGHT    = "ceiling_light"
    DEV_PENDANT_LIGHT    = "pendant_light"
    DEV_LED_STRIP        = "led_strip"
    DEV_RELAY_LIGHT      = "relay_light"
    DEV_CURTAIN          = "curtain"
    DEV_BLIND            = "blind"
    DEV_WINDOW           = "window"
    DEV_DOOR             = "door"
    DEV_DOOR_SENSOR      = "door_sensor"
    DEV_WINDOW_SENSOR    = "window_sensor"
    DEV_PRESENCE_SENSOR  = "presence_sensor"
    DEV_SMOKE_DETECTOR   = "smoke_detector"
    DEV_HEAT_DETECTOR    = "heat_detector"
    DEV_LEAK_SENSOR      = "leak_sensor"
    DEV_HVAC             = "hvac"
    DEV_THERMOSTAT       = "thermostat"
    DEV_TEMP_SENSOR      = "temperature_sensor"
    DEV_HUMIDITY_SENSOR  = "humidity_sensor"
    DEV_POWER_OUTLET     = "power_outlet"
    DEV_USB_OUTLET       = "usb_outlet"
    DEV_TV_OUTLET        = "tv_outlet"
    DEV_RJ45_OUTLET      = "rj45_outlet"
    DEV_GARAGE_DOOR      = "garage_door"
    DEV_GATE             = "gate"
    DEV_CAMERA           = "camera"
    DEV_DOORBIRD         = "doorbird"
    DEV_INTERCOM         = "intercom"
    DEV_SPEAKER          = "speaker"
    DEV_MICROPHONE       = "microphone"
    DEV_ALARM            = "alarm"
    DEV_WEATHER_STATION  = "weather_station"
    DEV_SOLAR            = "solar"
    DEV_BATTERY          = "battery"
    DEV_EV_CHARGER       = "ev_charger"
    DEV_GARDEN           = "garden"
    DEV_POOL             = "pool"
    DEV_CUSTOM           = "custom"
    DEVICE_TYPE_CHOICES = [
        (DEV_CEILING_LIGHT,   "Ceiling Light"),
        (DEV_PENDANT_LIGHT,   "Pendant Light"),
        (DEV_LED_STRIP,       "LED Strip"),
        (DEV_RELAY_LIGHT,     "Relay Light"),
        (DEV_CURTAIN,         "Curtain"),
        (DEV_BLIND,           "Blind"),
        (DEV_WINDOW,          "Window"),
        (DEV_DOOR,            "Door"),
        (DEV_DOOR_SENSOR,     "Door Sensor"),
        (DEV_WINDOW_SENSOR,   "Window Sensor"),
        (DEV_PRESENCE_SENSOR, "Presence Sensor"),
        (DEV_SMOKE_DETECTOR,  "Smoke Detector"),
        (DEV_HEAT_DETECTOR,   "Heat Detector"),
        (DEV_LEAK_SENSOR,     "Leak Sensor"),
        (DEV_HVAC,            "HVAC"),
        (DEV_THERMOSTAT,      "Thermostat"),
        (DEV_TEMP_SENSOR,     "Temperature Sensor"),
        (DEV_HUMIDITY_SENSOR, "Humidity Sensor"),
        (DEV_POWER_OUTLET,    "Power Outlet"),
        (DEV_USB_OUTLET,      "USB Outlet"),
        (DEV_TV_OUTLET,       "TV Outlet"),
        (DEV_RJ45_OUTLET,     "RJ45 Outlet"),
        (DEV_GARAGE_DOOR,     "Garage Door"),
        (DEV_GATE,            "Gate"),
        (DEV_CAMERA,          "Camera"),
        (DEV_DOORBIRD,        "DoorBird"),
        (DEV_INTERCOM,        "Intercom"),
        (DEV_SPEAKER,         "Speaker"),
        (DEV_MICROPHONE,      "Microphone"),
        (DEV_ALARM,           "Alarm"),
        (DEV_WEATHER_STATION, "Weather Station"),
        (DEV_SOLAR,           "Solar"),
        (DEV_BATTERY,         "Battery"),
        (DEV_EV_CHARGER,      "EV Charger"),
        (DEV_GARDEN,          "Garden"),
        (DEV_POOL,            "Pool"),
        (DEV_CUSTOM,          "Custom"),
    ]

    layout      = models.ForeignKey(MapLayout, on_delete=models.CASCADE, related_name="canvas_objects")
    layer       = models.ForeignKey(
        MapLayer, on_delete=models.SET_NULL, null=True, blank=True, related_name="canvas_objects",
    )
    object_type = models.CharField(max_length=10, choices=TYPE_OBJECT_CHOICES, default=TYPE_DEVICE)
    device_type = models.CharField(max_length=30, choices=DEVICE_TYPE_CHOICES, blank=True)
    name        = models.CharField(max_length=200)

    # Canvas position + transform (in canvas units, not pixels)
    x        = models.FloatField(default=100)
    y        = models.FloatField(default=100)
    width    = models.FloatField(default=48)
    height   = models.FloatField(default=48)
    rotation = models.FloatField(default=0)

    # PLC linking — either a free-form ADS symbol path or a FK to ApartmentDevice
    plc_variable    = models.CharField(max_length=255, blank=True)
    apartment_device = models.ForeignKey(
        ApartmentDevice, on_delete=models.SET_NULL, null=True, blank=True,
        related_name="canvas_objects",
    )
    room = models.ForeignKey(
        Room, on_delete=models.SET_NULL, null=True, blank=True,
        related_name="canvas_objects",
    )

    # Visual customisation
    color    = models.CharField(max_length=20, blank=True, help_text="Hex e.g. #FF5A3E")
    label_visible = models.BooleanField(default=True)

    # Grouping (objects with the same group_id can be moved/operated together)
    group_id = models.CharField(max_length=50, blank=True)

    # Flexible extra metadata (scene membership, HVAC zone, etc.)
    properties = models.JSONField(default=dict, blank=True)

    sort_order = models.PositiveIntegerField(default=0)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["sort_order", "id"]

    def __str__(self) -> str:
        return f"{self.layout.apartment.name} / {self.name} ({self.object_type})"

    def to_dict(self) -> dict:
        return {
            "id":               self.pk,
            "layer_id":         self.layer_id,
            "object_type":      self.object_type,
            "device_type":      self.device_type,
            "name":             self.name,
            "x":                self.x,
            "y":                self.y,
            "width":            self.width,
            "height":           self.height,
            "rotation":         self.rotation,
            "plc_variable":     self.plc_variable,
            "apartment_device_id": self.apartment_device_id,
            "room_id":          self.room_id,
            "room_name":        self.room.name if self.room else None,
            "color":            self.color,
            "label_visible":    self.label_visible,
            "group_id":         self.group_id,
            "properties":       self.properties,
            "sort_order":       self.sort_order,
        }


class MapVersion(models.Model):
    """Immutable snapshot of a MapLayout's objects at a point in time."""

    layout         = models.ForeignKey(MapLayout, on_delete=models.CASCADE, related_name="versions")
    version_number = models.PositiveIntegerField()
    snapshot       = models.JSONField(help_text="Full serialized list of CanvasObject dicts")
    created_by     = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, blank=True)
    created_at     = models.DateTimeField(auto_now_add=True)
    description    = models.CharField(max_length=255, blank=True)
    is_published   = models.BooleanField(default=False)

    class Meta:
        ordering        = ["-version_number"]
        unique_together = [("layout", "version_number")]

    def __str__(self) -> str:
        tag = " [published]" if self.is_published else ""
        return f"{self.layout.apartment.name} v{self.version_number}{tag}"


# ─────────────────────────────────────────────────────────────────────────────
# SuperScan — discovery / capability-mapping knowledge layer
#
# ScanRun               : one execution of the scan (mode, progress, summary).
# DiscoveredCapability   : persistent, updated-in-place row per capability —
#                          IS the "Device" + "Capability" the spec asked for
#                          merged into one, since in this system a capability
#                          already maps 1:1 onto a channel/gvl_name and
#                          duplicating that as two tables would just be two
#                          copies of the same identity. Cross-references
#                          ApartmentDevice when the capability is already a
#                          modeled, in-use device; is_known_type=False marks
#                          genuinely unrecognized symbols pulled from
#                          DiscoveryCache that don't correspond to anything
#                          the app's device classes understand yet.
# CapabilityTestLog      : one row per individual probe — the actual
#                          INPUT → COMMAND → RESPONSE → STATE-CHANGE
#                          correlation record the spec asked for by name.
# ─────────────────────────────────────────────────────────────────────────────

class ScanRun(models.Model):
    MODE_PASSIVE = "passive"  # zero commands sent — enumerate + snapshot only
    MODE_QUICK   = "quick"    # same as passive, alias kept for the UI's own naming
    MODE_FULL    = "full"     # + safe active tests on already-modeled devices
    MODE_DEEP    = "deep"     # + cross-reference DiscoveryCache for unknowns
    MODE_CHOICES = [
        (MODE_PASSIVE, "Passive — observe only, zero commands sent"),
        (MODE_QUICK,   "Quick — passive discovery of existing entities/state"),
        (MODE_FULL,    "Full — quick scan + safe capability tests"),
        (MODE_DEEP,    "Deep SuperScan — full scan + unknown-symbol correlation"),
    ]

    STATUS_RUNNING   = "running"
    STATUS_COMPLETED = "completed"
    STATUS_STOPPED   = "stopped"
    STATUS_FAILED    = "failed"
    STATUS_CHOICES = [
        (STATUS_RUNNING,   "Running"),
        (STATUS_COMPLETED, "Completed"),
        (STATUS_STOPPED,   "Stopped by user"),
        (STATUS_FAILED,    "Failed"),
    ]

    apartment    = models.ForeignKey(Apartment, on_delete=models.CASCADE, related_name="scan_runs")
    mode         = models.CharField(max_length=10, choices=MODE_CHOICES)
    status       = models.CharField(max_length=10, choices=STATUS_CHOICES, default=STATUS_RUNNING)
    started_by   = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, blank=True)
    started_at   = models.DateTimeField(auto_now_add=True)
    finished_at  = models.DateTimeField(null=True, blank=True)

    # Checked between every step by the running background thread — the
    # STOP SCAN control the spec requires at all times during an active scan.
    cancel_requested = models.BooleanField(default=False)

    progress_current = models.PositiveIntegerField(default=0)
    progress_total    = models.PositiveIntegerField(default=0)
    progress_label    = models.CharField(max_length=200, blank=True)

    devices_discovered      = models.PositiveIntegerField(default=0)
    capabilities_discovered = models.PositiveIntegerField(default=0)
    capabilities_tested     = models.PositiveIntegerField(default=0)
    tests_passed            = models.PositiveIntegerField(default=0)
    tests_failed            = models.PositiveIntegerField(default=0)
    unknown_count            = models.PositiveIntegerField(default=0)
    new_since_last           = models.PositiveIntegerField(default=0)
    changed_since_last       = models.PositiveIntegerField(default=0)
    removed_since_last       = models.PositiveIntegerField(default=0)

    error_message = models.TextField(blank=True)

    class Meta:
        ordering = ["-started_at"]
        constraints = [
            # DB-level guarantee, not just the view's pre-check .exists() —
            # a partial unique index is the only thing that actually closes
            # the race between two concurrent "start scan" requests (an
            # .exists() check has nothing to lock against when the matching
            # set is empty, so two requests can both see "no running scan"
            # and both proceed). Postgres allows only one row per apartment
            # with status='running' at a time; a second INSERT racing past
            # the view's pre-check fails with IntegrityError instead of
            # silently starting a second concurrent scan against the PLC.
            models.UniqueConstraint(
                fields=["apartment"],
                condition=models.Q(status="running"),
                name="one_running_scan_per_apartment",
            ),
        ]

    def __str__(self) -> str:
        return f"ScanRun({self.apartment.name}, {self.mode}, {self.status})"


class DiscoveredCapability(models.Model):
    DIRECTION_INPUT  = "input"
    DIRECTION_OUTPUT = "output"
    DIRECTION_BOTH   = "both"
    DIRECTION_CHOICES = [
        (DIRECTION_INPUT,  "Input (sensor/switch — read-only)"),
        (DIRECTION_OUTPUT, "Output (controllable)"),
        (DIRECTION_BOTH,   "Both (read + write)"),
    ]

    TEST_NOT_TESTED  = "not_tested"
    TEST_OBSERVED    = "observed"       # DISCOVERED — NOT ACTIVELY TESTED
    TEST_PASSED      = "tested_ok"
    TEST_FAILED      = "tested_failed"
    # Distinct from TEST_FAILED: the active test never actually reached the
    # device — the PLC itself was unreachable at the moment of the attempt.
    # Without this, a mid-scan PLC drop (see project history: this has
    # happened live, more than once) marks every untested-so-far writable
    # device "tested — failed", which reads to a technician as "this light
    # is broken" when the truth is "we never got to ask it."
    TEST_UNAVAILABLE = "unavailable"
    TEST_CHOICES = [
        (TEST_NOT_TESTED, "Not tested"),
        (TEST_OBSERVED,   "Discovered — not actively tested"),
        (TEST_PASSED,     "Tested — passed"),
        (TEST_FAILED,     "Tested — failed"),
        (TEST_UNAVAILABLE, "Unavailable — PLC disconnected during test"),
    ]

    apartment        = models.ForeignKey(Apartment, on_delete=models.CASCADE, related_name="discovered_capabilities")
    apartment_device = models.ForeignKey(
        ApartmentDevice, on_delete=models.SET_NULL, null=True, blank=True,
        related_name="discovered_capabilities",
        help_text="Set when this capability corresponds to an already-modeled ApartmentDevice row.",
    )

    device_type   = models.CharField(max_length=30)   # dali / relay / switch / curtain / toggle / named_switch / motion_sensor / unknown_symbol / ...
    identifier    = models.CharField(max_length=100)  # channel number, gvl_name, or raw symbol name — the stable key
    name          = models.CharField(max_length=150, blank=True)
    room          = models.CharField(max_length=100, blank=True)
    direction     = models.CharField(max_length=10, choices=DIRECTION_CHOICES, default=DIRECTION_OUTPUT)

    is_known_type = models.BooleanField(default=True)   # False = raw symbol with no matching device class
    raw_var_name  = models.CharField(max_length=200, blank=True)
    data_type     = models.CharField(max_length=40, blank=True)   # bool / percent / int / string / ...
    valid_range   = models.CharField(max_length=100, blank=True)  # human-readable, e.g. "0-100" or "true/false"

    test_status   = models.CharField(max_length=15, choices=TEST_CHOICES, default=TEST_NOT_TESTED)
    confidence    = models.CharField(max_length=10, default="high")  # high / medium / low
    physical_effect_confirmed = models.BooleanField(default=False)
    can_safely_test = models.BooleanField(default=True)

    last_value     = models.CharField(max_length=100, blank=True)
    last_tested_at = models.DateTimeField(null=True, blank=True)
    first_seen_at  = models.DateTimeField(auto_now_add=True)
    last_seen_scan = models.ForeignKey(ScanRun, on_delete=models.SET_NULL, null=True, blank=True, related_name="+")
    still_present  = models.BooleanField(default=True)  # False once a scan no longer finds it

    notes = models.TextField(blank=True)

    class Meta:
        unique_together = [("apartment", "device_type", "identifier")]
        ordering = ["device_type", "identifier"]

    def __str__(self) -> str:
        return f"{self.apartment.name}/{self.device_type}[{self.identifier}] {self.name}"

    def to_dict(self) -> dict:
        return {
            "id":            self.pk,
            "apartment_device_id": self.apartment_device_id,
            "device_type":   self.device_type,
            "identifier":    self.identifier,
            "name":          self.name,
            "room":          self.room,
            "direction":     self.direction,
            "is_known_type": self.is_known_type,
            "raw_var_name":  self.raw_var_name,
            "data_type":     self.data_type,
            "valid_range":   self.valid_range,
            "test_status":   self.test_status,
            "confidence":    self.confidence,
            "physical_effect_confirmed": self.physical_effect_confirmed,
            "can_safely_test": self.can_safely_test,
            "last_value":    self.last_value,
            "last_tested_at": self.last_tested_at.isoformat() if self.last_tested_at else None,
            "first_seen_at": self.first_seen_at.isoformat(),
            "still_present": self.still_present,
            "notes":         self.notes,
        }


class CapabilityTestLog(models.Model):
    """
    One row per individual probe. This is the literal
    INPUT -> COMMAND/SIGNAL -> DEVICE -> RESPONSE -> STATE CHANGE
    correlation record.
    """
    capability = models.ForeignKey(DiscoveredCapability, on_delete=models.CASCADE, related_name="test_logs")
    scan_run   = models.ForeignKey(ScanRun, on_delete=models.SET_NULL, null=True, blank=True, related_name="test_logs")
    timestamp  = models.DateTimeField(auto_now_add=True)

    command_sent = models.CharField(max_length=100, blank=True)
    params       = models.JSONField(default=dict, blank=True)
    state_before = models.CharField(max_length=100, blank=True)
    state_after  = models.CharField(max_length=100, blank=True)
    response     = models.CharField(max_length=200, blank=True)
    success      = models.BooleanField(default=False)
    latency_ms   = models.FloatField(null=True, blank=True)
    error        = models.TextField(blank=True)

    class Meta:
        ordering = ["-timestamp"]

    def to_dict(self) -> dict:
        return {
            "id":           self.pk,
            "timestamp":    self.timestamp.isoformat(),
            "command_sent": self.command_sent,
            "params":       self.params,
            "state_before": self.state_before,
            "state_after":  self.state_after,
            "response":     self.response,
            "success":      self.success,
            "latency_ms":   self.latency_ms,
            "error":        self.error,
        }
