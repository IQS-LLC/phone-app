"""
Idempotent demo environment seed — one user per role, spread across both
real apartments, so every major feature (roles, permissions, temporary
access, apartment switching) can be exercised immediately.

Usage:
    python manage.py seed_demo
    python manage.py seed_demo --ip 10.0.2.2   # also point Apartment 16's
                                                 # PLCDevice at this host,
                                                 # same as bootstrap_dev_user
"""
from __future__ import annotations

import os
from datetime import timedelta

from django.contrib.auth.models import User
from django.core.management.base import BaseCommand
from django.utils import timezone

from find_device.models import (
    Apartment, ApartmentMembership, ApartmentDevice, PLCDevice, Room,
    Role, TemporaryAccess,
)

DEMO_PASSWORD = "Demo12345!"

# (username, apartment_name, role_kind, custom_role_name_or_None, description)
DEMO_USERS = [
    ("admin_diana",   "Apartment 16", ApartmentMembership.ROLE_OWNER, "Building Manager", "Building Administrator — full access to every apartment"),
    ("owner_oliver",  "Apartment 16", ApartmentMembership.ROLE_OWNER, None,                "Apartment Owner — full control of Apartment 16"),
    ("family_fiona",  "Apartment 16", ApartmentMembership.ROLE_RESIDENT, "Family Member",  "Family Member — view + control devices, no settings"),
    ("guest_gary",    "Apartment 16", ApartmentMembership.ROLE_RESIDENT, "Guest",          "Guest — view + control devices only"),
    ("tech_tina",     "Apartment 8",  ApartmentMembership.ROLE_INSTALLER, "Maintenance",   "Maintenance Technician — diagnostics only"),
    ("installer_ivan", "Apartment 8", ApartmentMembership.ROLE_INSTALLER, "Installer",     "Installer — PLC connection settings + diagnostics"),
    ("owner_olivia8", "Apartment 8",  ApartmentMembership.ROLE_OWNER, None,                "Apartment Owner — full control of Apartment 8"),
]

# Building Administrator gets membership on EVERY apartment, not just one.
ADMIN_USERNAME = "admin_diana"


class Command(BaseCommand):
    help = "Seed a demo environment: one user per role across both apartments."

    def add_arguments(self, parser):
        # SEED_APT16_IP / SEED_APT16_NETID let a site-specific .env pin these
        # without editing the automated startup command — otherwise every
        # container recreation (which re-runs this command) silently resets
        # Apartment 16's PLCDevice back to the mock-safe emulator alias.
        parser.add_argument(
            "--ip", default=os.getenv("SEED_APT16_IP", "10.0.2.2"),
            help="ip_address for Apartment 16's PLCDevice (mock-safe).",
        )
        parser.add_argument(
            "--netid", default=os.getenv("SEED_APT16_NETID", "5.168.214.72.1.1"),
            help="AMS Net ID for Apartment 16's PLCDevice.",
        )
        parser.add_argument("--noinput", action="store_true", help="No-op; accepted for compatibility with automated startup commands.")

    def handle(self, *args, **opts):
        apartments = {a.name: a for a in Apartment.objects.filter(name__in=["Apartment 16", "Apartment 8"])}
        if len(apartments) < 2:
            self.stderr.write(self.style.ERROR(
                "Apartment 16 / Apartment 8 not found — run migrations first."
            ))
            return

        roles = {r.name: r for r in Role.objects.all()}

        for username, apt_name, basic_role, custom_role_name, description in DEMO_USERS:
            user, created = User.objects.get_or_create(username=username)
            user.set_password(DEMO_PASSWORD)
            user.first_name = description.split("—")[0].strip()
            user.save()

            apartment = apartments[apt_name]
            membership, _ = ApartmentMembership.objects.update_or_create(
                user=user, apartment=apartment,
                defaults=dict(
                    role=basic_role,
                    custom_role=roles.get(custom_role_name) if custom_role_name else None,
                    is_default=True,
                ),
            )
            self.stdout.write(self.style.SUCCESS(
                f"{'Created' if created else 'Updated'} {username} -> {apt_name} "
                f"({custom_role_name or basic_role})"
            ))

        # Building Administrator doubles as the demo Tech Team account —
        # is_staff is what gates the in-app User/Apartment Management
        # console, independent of any ApartmentMembership role.
        admin = User.objects.get(username=ADMIN_USERNAME)
        admin.is_staff = True
        admin.save(update_fields=["is_staff"])
        for apartment in apartments.values():
            ApartmentMembership.objects.update_or_create(
                user=admin, apartment=apartment,
                defaults=dict(
                    role=ApartmentMembership.ROLE_OWNER,
                    custom_role=roles.get("Building Manager"),
                    is_default=(apartment.name == "Apartment 16"),
                ),
            )
        self.stdout.write(self.style.SUCCESS(f"{ADMIN_USERNAME} -> membership on every apartment"))

        # PLCDevice for Apartment 16 so it's immediately controllable.
        device, _ = PLCDevice.objects.update_or_create(
            apartment=apartments["Apartment 16"],
            defaults=dict(
                owner=admin, name="Demo PLC",
                ip_address=opts["ip"], ams_net_id=opts["netid"],
                is_active=True, is_default=True,
            ),
        )

        # Curtain motors for Apartment 16 (channels 1–3)
        apt16 = apartments["Apartment 16"]
        curtain_layout = [
            (1, "Living Room Curtain",  "Living Room"),
            (2, "Bedroom 1 Curtain",    "Bedroom 1"),
            (3, "Bedroom 2 Curtain",    "Bedroom 2"),
        ]
        for idx, dev_name, room_name in curtain_layout:
            room = Room.objects.filter(apartment=apt16, name=room_name).first()
            ApartmentDevice.objects.update_or_create(
                apartment=apt16,
                device_type=ApartmentDevice.TYPE_CURTAIN,
                channel_or_index=idx,
                defaults=dict(
                    room=room, name=dev_name, sort_order=idx,
                ),
            )
        self.stdout.write(self.style.SUCCESS("Seeded 3 curtain devices for Apartment 16"))

        # A scheduled, time-windowed example: cleaner with a 4-hour window
        # today, scoped to the Guest role's permission set.
        guest_role = roles.get("Guest")
        if guest_role is not None:
            cleaner, _ = User.objects.get_or_create(username="cleaner_carlos")
            cleaner.set_password(DEMO_PASSWORD)
            cleaner.first_name = "Cleaning Service"
            cleaner.save()
            now = timezone.now()
            TemporaryAccess.objects.update_or_create(
                user=cleaner, apartment=apartments["Apartment 16"],
                defaults=dict(
                    role=guest_role,
                    starts_at=now - timedelta(hours=1),
                    expires_at=now + timedelta(hours=3),
                    created_by=admin,
                ),
            )
            self.stdout.write(self.style.SUCCESS(
                "cleaner_carlos -> Apartment 16 (Guest role, 4h window, started 1h ago)"
            ))

        self._print_credentials()

    def _print_credentials(self):
        self.stdout.write("")
        self.stdout.write(self.style.NOTICE("=" * 72))
        self.stdout.write(self.style.NOTICE("DEMO CREDENTIALS  (password for all: %s)" % DEMO_PASSWORD))
        self.stdout.write(self.style.NOTICE("=" * 72))
        rows = [
            ("admin_diana",     "Building Admin + Tech Team", "Every apartment + User/Apartment Management"),
            ("owner_oliver",    "Apartment Owner",         "Apartment 16, full access"),
            ("family_fiona",    "Family Member",           "Apartment 16, view + control"),
            ("guest_gary",      "Guest",                   "Apartment 16, view + control"),
            ("cleaner_carlos",  "Temporary Guest",         "Apartment 16, 4h window only"),
            ("tech_tina",       "Maintenance",              "Apartment 8, diagnostics only"),
            ("installer_ivan",  "Installer",                "Apartment 8, PLC + diagnostics"),
            ("owner_olivia8",   "Apartment Owner",          "Apartment 8, full access"),
        ]
        for username, role, scope in rows:
            self.stdout.write(f"  {username:<16} {role:<24} {scope}")
        self.stdout.write(self.style.NOTICE("=" * 72))
        self.stdout.write("Server address to use in the app's login screen: http://10.0.2.2:8000")
        self.stdout.write("(or your PC's LAN IP for a real device on the same WiFi)")
