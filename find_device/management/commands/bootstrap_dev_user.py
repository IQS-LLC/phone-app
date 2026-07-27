"""
Idempotent local-dev bootstrap: creates (or updates) a test user account,
links them to an Apartment via ApartmentMembership, and points that
apartment's PLCDevice at this dev machine — so the Flutter login screen has
something real to sign in with and a populated apartment to control.

Usage:
    python manage.py bootstrap_dev_user --ip 10.0.2.2
    python manage.py bootstrap_dev_user --ip 192.168.0.158 --username devtest
    python manage.py bootstrap_dev_user --ip 10.0.2.2 --apartment-name "Apartment 8"
"""
from __future__ import annotations

from django.contrib.auth.models import User
from django.core.management.base import BaseCommand

from find_device.models import Apartment, ApartmentMembership, PLCDevice


class Command(BaseCommand):
    help = "Create/update a dev user + apartment membership + PLCDevice for local Flutter testing."

    def add_arguments(self, parser):
        parser.add_argument(
            "--ip", required=True,
            help="ip_address to set on this apartment's PLCDevice. Under "
                 "PLC_MOCK=True this is never actually dialed by pyADS, so "
                 "any value works for local testing.",
        )
        parser.add_argument("--username", default="devtest")
        parser.add_argument("--password", default="DevTest12345")
        parser.add_argument("--device-name", default="Local Dev")
        parser.add_argument(
            "--apartment-name", default="Apartment 16",
            help="Which Apartment row to attach this user/device to. "
                 "Defaults to the seeded 'Apartment 16' (16 DALI channels, "
                 "4 relays, 10 switches) so the dashboard isn't empty.",
        )
        parser.add_argument("--netid", default="5.168.214.72.1.1", help="AMS Net ID for the PLCDevice.")

    def handle(self, *args, **opts):
        username  = opts["username"]
        password  = opts["password"]
        ip        = opts["ip"]
        apt_name  = opts["apartment_name"]

        user, created = User.objects.get_or_create(username=username)
        user.set_password(password)
        user.save()
        self.stdout.write(self.style.SUCCESS(
            f"{'Created' if created else 'Updated'} user '{username}'"
        ))

        apartment, apt_created = Apartment.objects.get_or_create(name=apt_name)
        self.stdout.write(self.style.SUCCESS(
            f"{'Created' if apt_created else 'Using existing'} apartment '{apartment.name}' (id={apartment.pk})"
        ))

        membership, mem_created = ApartmentMembership.objects.update_or_create(
            user=user, apartment=apartment,
            defaults=dict(role=ApartmentMembership.ROLE_OWNER, is_default=True),
        )
        self.stdout.write(self.style.SUCCESS(
            f"{'Created' if mem_created else 'Updated'} membership "
            f"({username} -> {apartment.name}, role={membership.role})"
        ))

        # PLCDevice has a legacy unique_together("owner", "name") from the
        # single-user era, plus a 1:1 to Apartment now — look up by either
        # key so re-running this command against a different --apartment-name
        # for the same user doesn't hit a stale unique-constraint collision.
        device = (
            PLCDevice.objects.filter(apartment=apartment).first()
            or PLCDevice.objects.filter(owner=user, name=opts["device_name"]).first()
        )
        if device is None:
            device = PLCDevice(owner=user, name=opts["device_name"])
        dev_created = device.pk is None
        device.apartment  = apartment
        device.ip_address = ip
        device.ams_net_id = opts["netid"]
        device.is_active  = True
        device.is_default = True
        device.save()
        self.stdout.write(self.style.SUCCESS(
            f"{'Created' if dev_created else 'Updated'} PLCDevice "
            f"'{device.name}' (ip={ip}) for apartment '{apartment.name}'"
        ))

        self.stdout.write("")
        self.stdout.write(self.style.NOTICE("Sign in to the app with:"))
        self.stdout.write(f"  Server address: http://{ip}:8000")
        self.stdout.write(f"  Username:       {username}")
        self.stdout.write(f"  Password:       {password}")
