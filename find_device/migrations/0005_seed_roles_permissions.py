"""Seed the standard Permission codes and system Role presets."""
from django.db import migrations


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

# name -> permission codes
SYSTEM_ROLES = {
    "Owner": {c for c, _ in PERMISSION_CODES},
    "Administrator": {c for c, _ in PERMISSION_CODES},
    "Building Manager": {c for c, _ in PERMISSION_CODES},
    "Resident": {"view", "control_devices", "create_automations", "view_history", "notification_settings"},
    "Family Member": {"view", "control_devices", "notification_settings"},
    "Guest": {"view", "control_devices"},
    "Temporary Guest": {"view", "control_devices"},
    "Maintenance": {"view", "diagnostics"},
    "Installer": {"view", "diagnostics", "plc_connection_settings", "installer_functions", "firmware_updates"},
    "Security": {"view", "emergency_controls", "view_cameras"},
    "Read-Only User": {"view"},
}


def seed(apps, schema_editor):
    Permission = apps.get_model("find_device", "Permission")
    Role       = apps.get_model("find_device", "Role")

    perm_by_code = {}
    for code, label in PERMISSION_CODES:
        perm, _ = Permission.objects.get_or_create(code=code, defaults={"label": label})
        perm_by_code[code] = perm

    for name, codes in SYSTEM_ROLES.items():
        role, _ = Role.objects.get_or_create(name=name, defaults={"is_system": True})
        role.permissions.set([perm_by_code[c] for c in codes])


def unseed(apps, schema_editor):
    # Irreversible by design — roles may already be referenced by
    # memberships/temporary access by the time anyone would roll back.
    pass


class Migration(migrations.Migration):

    dependencies = [
        ("find_device", "0004_permission_apartmentmembership_extra_permissions_and_more"),
    ]

    operations = [
        migrations.RunPython(seed, unseed),
    ]
