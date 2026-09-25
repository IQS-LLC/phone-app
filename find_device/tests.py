"""
Regression tests for the multi-tenant PLC backend.

Covers the two properties that must never regress:
  1. /plc/* requires a valid JWT (PLC_REQUIRE_AUTH).
  2. A user is only ever routed to their OWN apartment's DeviceRegistry —
     never another apartment's, regardless of what they ask for.
"""
from datetime import timedelta
from unittest.mock import MagicMock, patch

from django.contrib.auth.models import User
from django.test import TestCase
from django.utils import timezone

from find_device.models import (
    Apartment, ApartmentDevice, ApartmentMembership, AutomationRule,
    BuildingMembership, DeviceAddressScheme, DiscoveredCapability,
    PLCDevice, Role, Room, TemporaryAccess,
)
from find_device.plc.devices import CurtainMotor
from find_device.plc.registry import DeviceRegistry
from find_device.tasks import check_plc_heartbeat


class AuthGateTests(TestCase):
    """/plc/* must reject requests with no/invalid JWT."""

    def setUp(self):
        self.user = User.objects.create_user(username="alice", password="pw12345")
        self.apartment = Apartment.objects.get(name="Apartment 16")
        ApartmentMembership.objects.create(
            user=self.user, apartment=self.apartment,
            role=ApartmentMembership.ROLE_OWNER, is_default=True,
        )

    def _login(self):
        resp = self.client.post("/auth/login/", {"username": "alice", "password": "pw12345"})
        return resp.json()["access"]

    def test_state_requires_auth(self):
        resp = self.client.get("/plc/state/")
        self.assertEqual(resp.status_code, 401)

    def test_state_with_valid_token_succeeds(self):
        token = self._login()
        resp = self.client.get("/plc/state/", HTTP_AUTHORIZATION=f"Bearer {token}")
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.json()["apartment_id"], self.apartment.pk)

    def test_garbage_token_rejected(self):
        resp = self.client.get("/plc/state/", HTTP_AUTHORIZATION="Bearer not-a-real-token")
        self.assertEqual(resp.status_code, 401)

    def test_health_check_stays_open_without_auth(self):
        # The bare /plc/ health endpoint must stay reachable for monitoring
        # tools that don't carry a user token.
        resp = self.client.get("/plc/")
        self.assertEqual(resp.status_code, 200)


class TenantIsolationTests(TestCase):
    """Two users on two different apartments must never see each other's hardware."""

    def setUp(self):
        self.apt16 = Apartment.objects.get(name="Apartment 16")
        self.apt8  = Apartment.objects.get(name="Apartment 8")

        self.alice = User.objects.create_user(username="alice", password="pw12345")
        self.bob   = User.objects.create_user(username="bob", password="pw12345")

        ApartmentMembership.objects.create(
            user=self.alice, apartment=self.apt16,
            role=ApartmentMembership.ROLE_OWNER, is_default=True,
        )
        ApartmentMembership.objects.create(
            user=self.bob, apartment=self.apt8,
            role=ApartmentMembership.ROLE_OWNER, is_default=True,
        )

    def _token_for(self, username):
        resp = self.client.post("/auth/login/", {"username": username, "password": "pw12345"})
        return resp.json()["access"]

    def test_each_user_routes_to_their_own_apartment(self):
        alice_token = self._token_for("alice")
        bob_token   = self._token_for("bob")

        alice_state = self.client.get(
            "/plc/state/", HTTP_AUTHORIZATION=f"Bearer {alice_token}").json()
        bob_state = self.client.get(
            "/plc/state/", HTTP_AUTHORIZATION=f"Bearer {bob_token}").json()

        self.assertEqual(alice_state["apartment_id"], self.apt16.pk)
        self.assertEqual(bob_state["apartment_id"], self.apt8.pk)
        self.assertNotEqual(alice_state["apartment_id"], bob_state["apartment_id"])

    def test_user_with_no_membership_gets_clean_403_not_a_crash(self):
        User.objects.create_user(username="carol", password="pw12345")
        token = self._token_for("carol")
        resp = self.client.get("/plc/state/", HTTP_AUTHORIZATION=f"Bearer {token}")
        self.assertEqual(resp.status_code, 403)
        self.assertEqual(resp.json()["code"], "NO_APARTMENT")

    def test_writing_a_dali_channel_only_affects_the_callers_apartment(self):
        alice_token = self._token_for("alice")
        self.client.post(
            "/plc/dali/1/brightness/", {"brightness": "77"},
            HTTP_AUTHORIZATION=f"Bearer {alice_token}",
        )
        alice_state = self.client.get(
            "/plc/state/", HTTP_AUTHORIZATION=f"Bearer {alice_token}").json()
        self.assertEqual(alice_state["dali"]["1"], 77)

        bob_token = self._token_for("bob")
        bob_state = self.client.get(
            "/plc/state/", HTTP_AUTHORIZATION=f"Bearer {bob_token}").json()
        # Bob's apartment 8 channel 1 must be untouched by Alice's write.
        self.assertEqual(bob_state["dali"]["1"], 0)


class DeviceRegistryDbDrivenTests(TestCase):
    """DeviceRegistry must build its device set from ApartmentDevice rows."""

    def test_apartment_16_loads_expected_device_counts(self):
        apt = Apartment.objects.get(name="Apartment 16")
        registry = DeviceRegistry.for_apartment(apt.pk)
        self.assertEqual(len(registry.all_dali()), 16)
        self.assertEqual(len(registry.all_relays()), 4)
        self.assertEqual(len(registry.all_switches()), 10)

    def test_unknown_apartment_id_yields_empty_registry_not_a_crash(self):
        registry = DeviceRegistry.for_apartment(999_999)
        self.assertEqual(len(registry.all_dali()), 0)
        self.assertEqual(len(registry.all_relays()), 0)

    def test_security_is_none_when_not_configured(self):
        apt = Apartment.objects.get(name="Apartment 16")
        registry = DeviceRegistry.for_apartment(apt.pk)
        self.assertIsNone(registry.security())


class DeviceAddressSchemeTests(TestCase):
    """
    DeviceAddressScheme / TemplatedDevice — the data-driven GVL addressing
    layer added 2026-08-24 (see docs/plc-integration.md and
    docs/AUDIT_FINDINGS.md §1 for why: adding a new GVL layout used to mean
    writing a new Python class in devices.py).

    Uses a brand-new Apartment rather than "Apartment 16"/"Apartment 8" —
    DeviceRegistry caches one instance per apartment_id for the life of the
    process (DeviceRegistry._apt_instances), and other test classes in this
    file already call DeviceRegistry.for_apartment() for those two
    apartments, which would leave a stale, already-_started registry that
    silently ignores any ApartmentDevice row created after it started. A
    fresh apartment guarantees a fresh, never-started registry.
    """

    def setUp(self):
        # DeviceRegistry._apt_instances is a process-level cache keyed by
        # apartment_id, not reset by TestCase's per-test transaction
        # rollback — and sqlite (the local/test DB) reuses primary keys
        # once a transaction that inserted them rolls back, so two test
        # methods creating "a fresh Apartment" can end up with the SAME
        # apartment_id and collide on an already-_started registry from a
        # prior test. Clearing the cache is the same thing production code
        # never needs to do (a real process's apartment_ids don't get
        # reused this way) — this is a test-isolation fix, not evidence of
        # a production bug.
        DeviceRegistry._apt_instances.clear()
        self.apartment = Apartment.objects.create(name="Templated Test Apartment")
        self.scheme = DeviceAddressScheme.objects.create(
            name="test_scheme_v1",
            gvl="gvlTest",
            read_var_template="{gvl}.aLevel[{index}]",
            write_var_template="{gvl}.aLevel[{index}]",
            commit_var_template="{gvl}.bSet[{index}]",
            index_offset=0,
            plc_type="BYTE",
            protocol=DeviceAddressScheme.PROTOCOL_ADS,
            widget_type="dali_slider",
        )

    def test_device_with_scheme_round_trips_through_templated_device_in_mock_mode(self):
        device = ApartmentDevice.objects.create(
            apartment=self.apartment, device_type=ApartmentDevice.TYPE_DALI,
            channel_or_index=5, name="Test Light", address_scheme=self.scheme,
        )
        registry = DeviceRegistry.for_apartment(self.apartment.pk)
        templated = registry.templated(device.pk)
        self.assertIsNotNone(templated)

        templated.write(88)
        self.assertEqual(templated.read(), 88)

    def test_device_with_scheme_is_not_also_built_as_the_hardcoded_class(self):
        device = ApartmentDevice.objects.create(
            apartment=self.apartment, device_type=ApartmentDevice.TYPE_DALI,
            channel_or_index=5, name="Test Light", address_scheme=self.scheme,
        )
        registry = DeviceRegistry.for_apartment(self.apartment.pk)
        # A scheme takes priority over device_type entirely (see
        # registry.DeviceRegistry._start()) — this row must NOT also end up
        # in the hardcoded DALI dict, or a caller using the old dali()
        # accessor would find a device whose addressing doesn't match what
        # DaliChannel assumes.
        self.assertIsNone(registry.dali(5))
        self.assertIsNotNone(registry.templated(device.pk))

    def test_device_without_scheme_still_uses_the_hardcoded_class(self):
        ApartmentDevice.objects.create(
            apartment=self.apartment, device_type=ApartmentDevice.TYPE_DALI,
            channel_or_index=5, name="Plain Light",
        )
        registry = DeviceRegistry.for_apartment(self.apartment.pk)
        self.assertIsNotNone(registry.dali(5))
        self.assertEqual(len(registry.all_templated()), 0)

    def test_malformed_template_fails_loud_not_silently_wrong(self):
        bad_scheme = DeviceAddressScheme.objects.create(
            name="bad_scheme_v1", gvl="gvlTest",
            read_var_template="{gvl}.aLevel[{not_a_real_placeholder}]",
            plc_type="BYTE",
        )
        ApartmentDevice.objects.create(
            apartment=self.apartment, device_type=ApartmentDevice.TYPE_DALI,
            channel_or_index=1, name="Broken Light", address_scheme=bad_scheme,
        )
        with self.assertRaises(KeyError):
            DeviceRegistry.for_apartment(self.apartment.pk)


class PromoteCapabilityTests(TestCase):
    """
    POST /superscan/<apt>/capabilities/<cap>/promote/ — the bridge from a
    SuperScan-discovered symbol to a real, controllable ApartmentDevice
    (see superscan_views.promote_capability's docstring and
    docs/AUDIT_FINDINGS.md §1 for why this exists).
    """

    def setUp(self):
        DeviceRegistry._apt_instances.clear()
        self.apartment = Apartment.objects.create(name="Promote Test Apartment")
        self.staff = User.objects.create_user(username="promote_staff", password="pw12345", is_staff=True)
        self.resident = User.objects.create_user(username="promote_resident", password="pw12345")
        ApartmentMembership.objects.create(
            user=self.resident, apartment=self.apartment,
            role=ApartmentMembership.ROLE_RESIDENT, is_default=True,
        )
        self.cap = DiscoveredCapability.objects.create(
            apartment=self.apartment, device_type="unknown_symbol",
            identifier="gvlTest.bSomeSwitch", raw_var_name="gvlTest.bSomeSwitch",
            data_type="BOOL", is_known_type=False,
        )

    def _token(self, username):
        return self.client.post(
            "/auth/login/", {"username": username, "password": "pw12345"},
        ).json()["access"]

    def test_staff_can_promote_a_discovered_capability(self):
        token = self._token("promote_staff")
        resp = self.client.post(
            f"/superscan/{self.apartment.pk}/capabilities/{self.cap.pk}/promote/",
            content_type="application/json",
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200, resp.content)
        body = resp.json()
        self.assertTrue(body["ok"])
        device_id = body["device_id"]

        device = ApartmentDevice.objects.get(pk=device_id)
        self.assertEqual(device.apartment_id, self.apartment.pk)
        self.assertIsNotNone(device.address_scheme_id)
        self.assertEqual(device.address_scheme.gvl, "gvlTest")
        self.assertEqual(device.address_scheme.read_var_template, "gvlTest.bSomeSwitch")

        self.cap.refresh_from_db()
        self.assertEqual(self.cap.apartment_device_id, device_id)

        # The promoted device must actually be controllable through the
        # normal registry path, not just exist as a DB row.
        registry = DeviceRegistry.for_apartment(self.apartment.pk)
        templated = registry.templated(device_id)
        self.assertIsNotNone(templated)
        templated.write(True)
        self.assertEqual(templated.read(), True)

    def test_resident_cannot_promote(self):
        token = self._token("promote_resident")
        resp = self.client.post(
            f"/superscan/{self.apartment.pk}/capabilities/{self.cap.pk}/promote/",
            content_type="application/json",
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 403)

    def test_cannot_promote_the_same_capability_twice(self):
        token = self._token("promote_staff")
        first = self.client.post(
            f"/superscan/{self.apartment.pk}/capabilities/{self.cap.pk}/promote/",
            content_type="application/json",
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(first.status_code, 200, first.content)

        second = self.client.post(
            f"/superscan/{self.apartment.pk}/capabilities/{self.cap.pk}/promote/",
            content_type="application/json",
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(second.status_code, 409)


class SecurityEndpointTests(TestCase):
    """Security endpoints must 404 cleanly, never 500, when unconfigured."""

    def setUp(self):
        self.user = User.objects.create_user(username="alice", password="pw12345")
        ApartmentMembership.objects.create(
            user=self.user, apartment=Apartment.objects.get(name="Apartment 16"),
            role=ApartmentMembership.ROLE_OWNER, is_default=True,
        )

    def test_set_alarm_without_security_hardware_404s(self):
        token = self.client.post(
            "/auth/login/", {"username": "alice", "password": "pw12345"},
        ).json()["access"]
        resp = self.client.post(
            "/plc/security/alarm/", {"armed": "true"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 404)
        self.assertEqual(resp.json()["code"], "NOT_FOUND")


class DeviceManagementPermissionTests(TestCase):
    """
    PLC connection settings (IP/AMS Net ID) are an owner/installer concern.
    A plain resident must not be able to see or edit them via /manage/devices/.
    """

    def setUp(self):
        self.apartment = Apartment.objects.get(name="Apartment 16")
        self.owner    = User.objects.create_user(username="owner", password="pw12345")
        self.resident = User.objects.create_user(username="resident", password="pw12345")

        ApartmentMembership.objects.create(
            user=self.owner, apartment=self.apartment,
            role=ApartmentMembership.ROLE_OWNER, is_default=True,
        )
        ApartmentMembership.objects.create(
            user=self.resident, apartment=self.apartment,
            role=ApartmentMembership.ROLE_RESIDENT, is_default=True,
        )
        self.device = PLCDevice.objects.create(
            apartment=self.apartment, owner=self.owner, name="Real PLC",
            ip_address="192.168.0.161", ams_net_id="192.168.0.161.1.1",
        )

    def _token_for(self, username):
        resp = self.client.post("/auth/login/", {"username": username, "password": "pw12345"})
        return resp.json()["access"]

    def test_owner_can_see_the_apartment_plc_device(self):
        token = self._token_for("owner")
        resp = self.client.get("/manage/devices/", HTTP_AUTHORIZATION=f"Bearer {token}")
        names = [d["name"] for d in resp.json()["devices"]]
        self.assertIn("Real PLC", names)

    def test_resident_cannot_see_the_apartment_plc_device(self):
        token = self._token_for("resident")
        resp = self.client.get("/manage/devices/", HTTP_AUTHORIZATION=f"Bearer {token}")
        names = [d["name"] for d in resp.json()["devices"]]
        self.assertNotIn("Real PLC", names)

    def test_resident_cannot_edit_the_apartment_plc_device(self):
        token = self._token_for("resident")
        resp = self.client.patch(
            f"/manage/devices/{self.device.pk}/",
            {"ip_address": "10.10.10.10"},
            content_type="application/json",
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 404)


class PermissionEnforcementTests(TestCase):
    """
    A membership's role determines what it can DO, not just whether it can
    see the apartment at all. A read-only-ish role must be blocked from
    writes by the server, regardless of what the app sends.
    """

    def setUp(self):
        self.apartment = Apartment.objects.get(name="Apartment 16")
        self.guest_role = Role.objects.get(name="Read-Only User")  # {"view"} only

    def _token_for(self, username):
        resp = self.client.post("/auth/login/", {"username": username, "password": "pw12345"})
        return resp.json()["access"]

    def test_owner_can_write(self):
        owner = User.objects.create_user(username="owner1", password="pw12345")
        ApartmentMembership.objects.create(
            user=owner, apartment=self.apartment,
            role=ApartmentMembership.ROLE_OWNER, is_default=True,
        )
        token = self._token_for("owner1")
        resp = self.client.post(
            "/plc/dali/1/brightness/", {"brightness": "50"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)

    def test_read_only_custom_role_cannot_write(self):
        viewer = User.objects.create_user(username="viewer1", password="pw12345")
        ApartmentMembership.objects.create(
            user=viewer, apartment=self.apartment, custom_role=self.guest_role,
            is_default=True,
        )
        token = self._token_for("viewer1")

        # Read access still works...
        resp = self.client.get("/plc/state/", HTTP_AUTHORIZATION=f"Bearer {token}")
        self.assertEqual(resp.status_code, 200)

        # ...but writes are blocked server-side, regardless of what's sent.
        resp = self.client.post(
            "/plc/dali/1/brightness/", {"brightness": "50"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 403)
        self.assertEqual(resp.json()["code"], "FORBIDDEN")

    def test_extra_permissions_grant_additive_access(self):
        viewer = User.objects.create_user(username="viewer2", password="pw12345")
        membership = ApartmentMembership.objects.create(
            user=viewer, apartment=self.apartment, custom_role=self.guest_role,
            is_default=True,
        )
        from find_device.models import Permission
        membership.extra_permissions.add(Permission.objects.get(code="control_devices"))

        token = self._token_for("viewer2")
        resp = self.client.post(
            "/plc/dali/1/brightness/", {"brightness": "50"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)

    def test_expired_temporary_access_does_not_grant_anything(self):
        guest = User.objects.create_user(username="cleaner", password="pw12345")
        # No ApartmentMembership at all — only an expired TemporaryAccess grant.
        now = timezone.now()
        TemporaryAccess.objects.create(
            apartment=self.apartment, user=guest, role=self.guest_role,
            starts_at=now - timedelta(days=2), expires_at=now - timedelta(days=1),
        )
        token = self._token_for("cleaner")
        resp = self.client.get("/plc/state/", HTTP_AUTHORIZATION=f"Bearer {token}")
        # No permanent membership and no active grant -> no apartment access.
        self.assertEqual(resp.status_code, 403)

    def test_active_temporary_access_grants_apartment_access_with_no_membership(self):
        full_access_role = Role.objects.get(name="Guest")  # {"view", "control_devices"}
        cleaner = User.objects.create_user(username="cleaner2", password="pw12345")
        owner = User.objects.create_user(username="owner2", password="pw12345")
        ApartmentMembership.objects.create(
            user=owner, apartment=self.apartment,
            role=ApartmentMembership.ROLE_OWNER, is_default=True,
        )
        # cleaner2 has NO ApartmentMembership at all — only a time-boxed grant.
        now = timezone.now()
        TemporaryAccess.objects.create(
            apartment=self.apartment, user=cleaner, role=full_access_role,
            starts_at=now - timedelta(hours=1), expires_at=now + timedelta(hours=1),
            created_by=owner,
        )
        token = self._token_for("cleaner2")

        # Routes to the apartment via the grant, and the Guest role's
        # control_devices permission carries through.
        resp = self.client.get("/plc/state/", HTTP_AUTHORIZATION=f"Bearer {token}")
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.json()["apartment_id"], self.apartment.pk)

        resp = self.client.post(
            "/plc/dali/1/brightness/", {"brightness": "33"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)

    def test_revoked_temporary_access_grants_nothing(self):
        full_access_role = Role.objects.get(name="Guest")
        cleaner = User.objects.create_user(username="cleaner3", password="pw12345")
        now = timezone.now()
        TemporaryAccess.objects.create(
            apartment=self.apartment, user=cleaner, role=full_access_role,
            starts_at=now - timedelta(hours=1), expires_at=now + timedelta(hours=1),
            revoked=True,
        )
        token = self._token_for("cleaner3")
        resp = self.client.get("/plc/state/", HTTP_AUTHORIZATION=f"Bearer {token}")
        self.assertEqual(resp.status_code, 403)


class SessionManagementTests(TestCase):
    """Logged-in devices: list, revoke one, revoke all."""

    def setUp(self):
        User.objects.create_user(username="alice", password="pw12345")

    def _login(self, device_name="iPhone 15"):
        resp = self.client.post(
            "/auth/login/", {"username": "alice", "password": "pw12345"},
            HTTP_X_DEVICE_NAME=device_name,
        )
        return resp.json()

    def test_login_creates_a_session(self):
        data = self._login()
        resp = self.client.get(
            "/auth/sessions/", HTTP_AUTHORIZATION=f"Bearer {data['access']}")
        sessions = resp.json()["sessions"]
        self.assertEqual(len(sessions), 1)
        self.assertEqual(sessions[0]["device_name"], "iPhone 15")

    def test_two_devices_show_as_two_sessions(self):
        d1 = self._login(device_name="iPhone 15")
        d2 = self._login(device_name="iPad Pro")
        resp = self.client.get(
            "/auth/sessions/", HTTP_AUTHORIZATION=f"Bearer {d2['access']}")
        names = {s["device_name"] for s in resp.json()["sessions"]}
        self.assertEqual(names, {"iPhone 15", "iPad Pro"})
        self.assertTrue(d1 and d2)

    def test_revoking_a_session_logs_out_that_device(self):
        d1 = self._login(device_name="iPhone 15")
        sessions = self.client.get(
            "/auth/sessions/", HTTP_AUTHORIZATION=f"Bearer {d1['access']}").json()["sessions"]
        session_id = sessions[0]["id"]

        resp = self.client.post(
            f"/auth/sessions/{session_id}/revoke/",
            HTTP_AUTHORIZATION=f"Bearer {d1['access']}",
        )
        self.assertEqual(resp.status_code, 200)

        # The revoked device's refresh token must no longer work.
        refresh_resp = self.client.post("/auth/refresh/", {"refresh": d1["refresh"]})
        self.assertEqual(refresh_resp.status_code, 401)

    def test_logout_revokes_its_own_session(self):
        data = self._login()
        self.client.post(
            "/auth/logout/", {"refresh": data["refresh"]},
            HTTP_AUTHORIZATION=f"Bearer {data['access']}",
        )
        resp = self.client.get(
            "/auth/sessions/", HTTP_AUTHORIZATION=f"Bearer {data['access']}")
        self.assertEqual(resp.json()["sessions"], [])


class ApartmentSelectorTests(TestCase):
    """GET /auth/apartments/ + POST .../select/ for the apartment switcher."""

    def setUp(self):
        self.apt16 = Apartment.objects.get(name="Apartment 16")
        self.apt8  = Apartment.objects.get(name="Apartment 8")
        self.user  = User.objects.create_user(username="alice", password="pw12345")
        ApartmentMembership.objects.create(
            user=self.user, apartment=self.apt16,
            role=ApartmentMembership.ROLE_OWNER, is_default=True,
        )
        ApartmentMembership.objects.create(
            user=self.user, apartment=self.apt8,
            role=ApartmentMembership.ROLE_RESIDENT, is_default=False,
        )

    def _token(self):
        return self.client.post(
            "/auth/login/", {"username": "alice", "password": "pw12345"},
        ).json()["access"]

    def test_lists_both_apartments_with_roles(self):
        token = self._token()
        resp = self.client.get("/auth/apartments/", HTTP_AUTHORIZATION=f"Bearer {token}")
        apartments = {a["name"]: a for a in resp.json()["apartments"]}
        self.assertEqual(set(apartments), {"Apartment 16", "Apartment 8"})
        self.assertEqual(apartments["Apartment 16"]["role"], "owner")
        self.assertTrue(apartments["Apartment 16"]["is_default"])
        self.assertIn("control_devices", apartments["Apartment 8"]["permissions"])

    def test_switching_default_apartment_changes_plc_routing(self):
        token = self._token()
        # Initially routed to Apartment 16 (the default).
        state = self.client.get(
            "/plc/state/", HTTP_AUTHORIZATION=f"Bearer {token}").json()
        self.assertEqual(state["apartment_id"], self.apt16.pk)

        resp = self.client.post(
            f"/auth/apartments/{self.apt8.pk}/select/",
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)

        state = self.client.get(
            "/plc/state/", HTTP_AUTHORIZATION=f"Bearer {token}").json()
        self.assertEqual(state["apartment_id"], self.apt8.pk)


class NetworkDiscoveryTests(TestCase):
    """Network-wide PLC discovery is an installer-only operation."""

    def setUp(self):
        self.apartment = Apartment.objects.get(name="Apartment 16")
        self.installer_role = Role.objects.get(name="Installer")

    def _token_for(self, username):
        resp = self.client.post("/auth/login/", {"username": username, "password": "pw12345"})
        return resp.json()["access"]

    def test_non_installer_cannot_scan(self):
        resident = User.objects.create_user(username="resident9", password="pw12345")
        ApartmentMembership.objects.create(
            user=resident, apartment=self.apartment,
            role=ApartmentMembership.ROLE_RESIDENT, is_default=True,
        )
        token = self._token_for("resident9")
        resp = self.client.post(
            "/manage/discovery/network-scan/", HTTP_AUTHORIZATION=f"Bearer {token}")
        self.assertEqual(resp.status_code, 403)

    def test_installer_can_scan_and_gets_mock_results_under_plc_mock(self):
        tech = User.objects.create_user(username="tech9", password="pw12345")
        ApartmentMembership.objects.create(
            user=tech, apartment=self.apartment, custom_role=self.installer_role,
            is_default=True,
        )
        token = self._token_for("tech9")
        resp = self.client.post(
            "/manage/discovery/network-scan/", HTTP_AUTHORIZATION=f"Bearer {token}")
        self.assertEqual(resp.status_code, 200)
        self.assertTrue(resp.json()["mock"])
        self.assertGreater(len(resp.json()["results"]), 0)


class RegistrationLockdownTests(TestCase):
    """
    Accounts are provisioned by the building's IT team, never self-service.
    /auth/register/ must reject anonymous and ordinary-user callers, and
    only succeed for staff.
    """

    def test_anonymous_cannot_self_register(self):
        resp = self.client.post(
            "/auth/register/",
            {"username": "newperson", "password": "SomeStrongPass123!"},
        )
        self.assertIn(resp.status_code, (401, 403))
        self.assertFalse(User.objects.filter(username="newperson").exists())

    def test_ordinary_logged_in_user_cannot_register_others(self):
        User.objects.create_user(username="alice", password="pw12345")
        token = self.client.post(
            "/auth/login/", {"username": "alice", "password": "pw12345"},
        ).json()["access"]
        resp = self.client.post(
            "/auth/register/",
            {"username": "newperson2", "password": "SomeStrongPass123!"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 403)

    def test_staff_can_provision_an_account(self):
        User.objects.create_user(username="itstaff", password="pw12345", is_staff=True)
        token = self.client.post(
            "/auth/login/", {"username": "itstaff", "password": "pw12345"},
        ).json()["access"]
        resp = self.client.post(
            "/auth/register/",
            {"username": "newperson3", "password": "SomeStrongPass123!"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 201)
        self.assertTrue(User.objects.filter(username="newperson3").exists())


class UserManagementTests(TestCase):
    """Tech Team user-management API — staff-only, residents locked out."""

    def setUp(self):
        self.staff = User.objects.create_user(username="techlead", password="pw12345", is_staff=True)
        self.resident = User.objects.create_user(username="resident1", password="pw12345")
        self.apartment = Apartment.objects.get(name="Apartment 16")
        ApartmentMembership.objects.create(
            user=self.resident, apartment=self.apartment,
            role=ApartmentMembership.ROLE_RESIDENT, is_default=True,
        )

    def _token(self, username, password="pw12345"):
        return self.client.post(
            "/auth/login/", {"username": username, "password": password},
        ).json()["access"]

    def test_resident_cannot_list_users(self):
        token = self._token("resident1")
        resp = self.client.get("/manage/users/", HTTP_AUTHORIZATION=f"Bearer {token}")
        self.assertEqual(resp.status_code, 403)

    def test_staff_can_list_users_with_apartment_summary(self):
        token = self._token("techlead")
        resp = self.client.get("/manage/users/", HTTP_AUTHORIZATION=f"Bearer {token}")
        self.assertEqual(resp.status_code, 200)
        by_username = {u["username"]: u for u in resp.json()["users"]}
        self.assertIn("resident1", by_username)
        self.assertEqual(by_username["resident1"]["apartments"][0]["name"], "Apartment 16")

    def test_resident_cannot_list_all_apartments(self):
        token = self._token("resident1")
        resp = self.client.get("/manage/users/apartments/", HTTP_AUTHORIZATION=f"Bearer {token}")
        self.assertEqual(resp.status_code, 403)

    def test_staff_can_list_all_apartments(self):
        token = self._token("techlead")
        resp = self.client.get("/manage/users/apartments/", HTTP_AUTHORIZATION=f"Bearer {token}")
        self.assertEqual(resp.status_code, 200)
        names = {a["name"] for a in resp.json()["apartments"]}
        self.assertIn("Apartment 16", names)
        self.assertIn("Apartment 8", names)

    def test_staff_can_disable_and_reenable_a_user(self):
        token = self._token("techlead")
        resp = self.client.post(
            f"/manage/users/{self.resident.pk}/disable/",
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)
        self.resident.refresh_from_db()
        self.assertFalse(self.resident.is_active)

        # A disabled account can no longer log in.
        login_resp = self.client.post(
            "/auth/login/", {"username": "resident1", "password": "pw12345"})
        self.assertEqual(login_resp.status_code, 401)

        resp = self.client.post(
            f"/manage/users/{self.resident.pk}/enable/",
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)
        self.resident.refresh_from_db()
        self.assertTrue(self.resident.is_active)

    def test_staff_cannot_disable_their_own_account(self):
        token = self._token("techlead")
        resp = self.client.post(
            f"/manage/users/{self.staff.pk}/disable/",
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 400)

    def test_staff_can_reset_a_users_password(self):
        token = self._token("techlead")
        resp = self.client.post(
            f"/manage/users/{self.resident.pk}/reset-password/",
            {"new_password": "BrandNewPass456!"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)

        # Old password no longer works, new one does.
        old_login = self.client.post(
            "/auth/login/", {"username": "resident1", "password": "pw12345"})
        self.assertEqual(old_login.status_code, 401)
        new_login = self.client.post(
            "/auth/login/", {"username": "resident1", "password": "BrandNewPass456!"})
        self.assertEqual(new_login.status_code, 200)

    def test_staff_can_force_logout_a_user(self):
        # resident1 logs in on two "devices".
        d1 = self.client.post(
            "/auth/login/", {"username": "resident1", "password": "pw12345"}).json()
        self.client.post(
            "/auth/login/", {"username": "resident1", "password": "pw12345"})

        token = self._token("techlead")
        resp = self.client.post(
            f"/manage/users/{self.resident.pk}/force-logout/",
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)

        # The old refresh token from before the force-logout no longer works.
        refresh_resp = self.client.post("/auth/refresh/", {"refresh": d1["refresh"]})
        self.assertEqual(refresh_resp.status_code, 401)

    def test_staff_can_assign_a_second_apartment(self):
        apt8 = Apartment.objects.get(name="Apartment 8")
        token = self._token("techlead")
        resp = self.client.post(
            f"/manage/users/{self.resident.pk}/assign-apartment/",
            {"apartment_id": apt8.pk, "role": "owner"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 201)
        apartments = {a["name"]: a for a in resp.json()["user"]["apartments"]}
        self.assertEqual(set(apartments), {"Apartment 16", "Apartment 8"})
        self.assertEqual(apartments["Apartment 8"]["role"], "owner")

    def test_staff_can_delete_a_user(self):
        token = self._token("techlead")
        resp = self.client.delete(
            f"/manage/users/{self.resident.pk}/",
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)
        self.assertFalse(User.objects.filter(username="resident1").exists())

    def test_staff_cannot_delete_their_own_account(self):
        token = self._token("techlead")
        resp = self.client.delete(
            f"/manage/users/{self.staff.pk}/",
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 400)
        self.assertTrue(User.objects.filter(username="techlead").exists())

    def test_staff_can_view_a_users_sessions(self):
        self.client.post("/auth/login/", {"username": "resident1", "password": "pw12345"})
        token = self._token("techlead")
        resp = self.client.get(
            f"/manage/users/{self.resident.pk}/sessions/",
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.json()["sessions"]), 1)

    def test_resident_cannot_view_another_users_sessions(self):
        token = self._token("resident1")
        resp = self.client.get(
            f"/manage/users/{self.staff.pk}/sessions/",
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 403)

    def test_permission_list_is_staff_only(self):
        resp = self.client.get(
            "/manage/permissions/", HTTP_AUTHORIZATION=f"Bearer {self._token('resident1')}",
        )
        self.assertEqual(resp.status_code, 403)

        resp = self.client.get(
            "/manage/permissions/", HTTP_AUTHORIZATION=f"Bearer {self._token('techlead')}",
        )
        self.assertEqual(resp.status_code, 200)
        codes = {p["code"] for p in resp.json()["permissions"]}
        self.assertIn("diagnostics", codes)
        self.assertIn("view_cameras", codes)

    def test_staff_can_grant_and_view_extra_permissions(self):
        token = self._token("techlead")
        resp = self.client.post(
            f"/manage/users/{self.resident.pk}/apartments/{self.apartment.pk}/permissions/",
            {"permissions": ["diagnostics", "view_cameras"]},
            content_type="application/json",
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)
        body = resp.json()
        self.assertEqual(body["extra_permissions"], ["diagnostics", "view_cameras"])
        self.assertIn("diagnostics", body["effective_permissions"])
        # resident's normal role permissions (e.g. "view") are still present —
        # extra_permissions is additive, not a replacement.
        self.assertIn("view", body["effective_permissions"])

        get_resp = self.client.get(
            f"/manage/users/{self.resident.pk}/apartments/{self.apartment.pk}/permissions/",
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(get_resp.status_code, 200)
        self.assertEqual(get_resp.json()["extra_permissions"], ["diagnostics", "view_cameras"])

    def test_resident_cannot_grant_permissions(self):
        token = self._token("resident1")
        resp = self.client.post(
            f"/manage/users/{self.resident.pk}/apartments/{self.apartment.pk}/permissions/",
            {"permissions": ["diagnostics"]},
            content_type="application/json",
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 403)


class ApartmentManagementTests(TestCase):
    """Tech Team apartment-overview API — staff-only, aggregated per-apartment view."""

    def setUp(self):
        self.staff = User.objects.create_user(username="techlead2", password="pw12345", is_staff=True)
        self.owner = User.objects.create_user(username="owner1", password="pw12345")
        self.resident = User.objects.create_user(username="resident2", password="pw12345")
        self.apartment = Apartment.objects.get(name="Apartment 16")
        ApartmentMembership.objects.create(
            user=self.owner, apartment=self.apartment,
            role=ApartmentMembership.ROLE_OWNER, is_default=True,
        )
        ApartmentMembership.objects.create(
            user=self.resident, apartment=self.apartment,
            role=ApartmentMembership.ROLE_RESIDENT, is_default=True,
        )

    def _token(self, username, password="pw12345"):
        return self.client.post(
            "/auth/login/", {"username": username, "password": password},
        ).json()["access"]

    def test_resident_cannot_list_apartment_management_overview(self):
        token = self._token("resident2")
        resp = self.client.get("/manage/apartments/", HTTP_AUTHORIZATION=f"Bearer {token}")
        self.assertEqual(resp.status_code, 403)

    def test_staff_sees_owner_residents_and_device_counts(self):
        token = self._token("techlead2")
        resp = self.client.get("/manage/apartments/", HTTP_AUTHORIZATION=f"Bearer {token}")
        self.assertEqual(resp.status_code, 200)
        by_name = {a["name"]: a for a in resp.json()["apartments"]}
        apt16 = by_name["Apartment 16"]
        self.assertEqual(apt16["owner"]["username"], "owner1")
        self.assertEqual([r["username"] for r in apt16["residents"]], ["resident2"])
        self.assertGreater(apt16["device_count"], 0)
        self.assertGreater(apt16["room_count"], 0)

    def test_staff_can_view_apartment_detail_with_room_breakdown(self):
        token = self._token("techlead2")
        resp = self.client.get(
            f"/manage/apartments/{self.apartment.pk}/", HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)
        apartment = resp.json()["apartment"]
        self.assertEqual(apartment["name"], "Apartment 16")
        self.assertGreater(len(apartment["rooms"]), 0)
        self.assertIn("device_count", apartment["rooms"][0])

    def test_staff_can_create_a_new_apartment(self):
        token = self._token("techlead2")
        resp = self.client.post(
            "/manage/apartments/", {"name": "Apartment 22", "building": "B", "floor": "2"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 201)
        self.assertTrue(Apartment.objects.filter(name="Apartment 22").exists())

    def test_staff_cannot_create_duplicate_apartment_name(self):
        token = self._token("techlead2")
        resp = self.client.post(
            "/manage/apartments/", {"name": "Apartment 16"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 409)

    def test_resident_cannot_create_apartment(self):
        token = self._token("resident2")
        resp = self.client.post(
            "/manage/apartments/", {"name": "Apartment 99"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 403)
        self.assertFalse(Apartment.objects.filter(name="Apartment 99").exists())


class ApartmentPlcAssignmentTests(TestCase):
    """
    PLC assignment endpoint — distinct from /manage/devices/, which never
    links a created device to an Apartment. This is the only path that
    actually makes a controller serve an apartment's dashboard.
    """

    def setUp(self):
        self.staff = User.objects.create_user(username="techlead3", password="pw12345", is_staff=True)
        self.resident = User.objects.create_user(username="resident3", password="pw12345")
        self.apartment = Apartment.objects.get(name="Apartment 8")
        ApartmentMembership.objects.create(
            user=self.resident, apartment=self.apartment,
            role=ApartmentMembership.ROLE_RESIDENT, is_default=True,
        )

    def _token(self, username, password="pw12345"):
        return self.client.post(
            "/auth/login/", {"username": username, "password": password},
        ).json()["access"]

    def test_resident_cannot_assign_plc(self):
        token = self._token("resident3")
        resp = self.client.post(
            f"/manage/apartments/{self.apartment.pk}/plc/",
            {"ip_address": "192.168.0.50", "ams_net_id": "192.168.0.50.1.1"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 403)

    def test_staff_can_assign_and_view_plc(self):
        token = self._token("techlead3")
        resp = self.client.post(
            f"/manage/apartments/{self.apartment.pk}/plc/",
            {"ip_address": "192.168.0.50", "ams_net_id": "192.168.0.50.1.1", "ads_port": 851},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(resp.json()["plc"]["ip_address"], "192.168.0.50")

        # It's really linked to the apartment now, not floating unowned.
        self.apartment.refresh_from_db()
        self.assertIsNotNone(self.apartment.plc_device)
        self.assertEqual(self.apartment.plc_device.ip_address, "192.168.0.50")

        get_resp = self.client.get(
            f"/manage/apartments/{self.apartment.pk}/plc/", HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(get_resp.status_code, 200)
        self.assertEqual(get_resp.json()["plc"]["ams_net_id"], "192.168.0.50.1.1")

    def test_invalid_ams_net_id_rejected(self):
        token = self._token("techlead3")
        resp = self.client.post(
            f"/manage/apartments/{self.apartment.pk}/plc/",
            {"ip_address": "192.168.0.50", "ams_net_id": "not-an-ams-id"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 400)

    def test_staff_can_reassign_then_unassign_plc(self):
        token = self._token("techlead3")
        self.client.post(
            f"/manage/apartments/{self.apartment.pk}/plc/",
            {"ip_address": "192.168.0.50", "ams_net_id": "192.168.0.50.1.1"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        # Re-POST updates the existing PLCDevice rather than erroring.
        resp = self.client.post(
            f"/manage/apartments/{self.apartment.pk}/plc/",
            {"ip_address": "192.168.0.99", "ams_net_id": "192.168.0.99.1.1"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.json()["plc"]["ip_address"], "192.168.0.99")

        del_resp = self.client.delete(
            f"/manage/apartments/{self.apartment.pk}/plc/", HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(del_resp.status_code, 200)
        self.apartment.refresh_from_db()
        self.assertIsNone(getattr(self.apartment, "plc_device", None))


class RoomAndDeviceLayoutTests(TestCase):
    """Tech Team room/device rename + reorder — staff-only layout control."""

    def setUp(self):
        self.staff = User.objects.create_user(username="techlead4", password="pw12345", is_staff=True)
        self.resident = User.objects.create_user(username="resident4", password="pw12345")
        self.apartment = Apartment.objects.get(name="Apartment 16")
        ApartmentMembership.objects.create(
            user=self.resident, apartment=self.apartment,
            role=ApartmentMembership.ROLE_RESIDENT, is_default=True,
        )

    def _token(self, username, password="pw12345"):
        return self.client.post(
            "/auth/login/", {"username": username, "password": password},
        ).json()["access"]

    def test_resident_cannot_create_room(self):
        token = self._token("resident4")
        resp = self.client.post(
            f"/manage/apartments/{self.apartment.pk}/rooms/", {"name": "Office"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 403)

    def test_staff_can_create_rename_and_delete_a_room(self):
        token = self._token("techlead4")
        create_resp = self.client.post(
            f"/manage/apartments/{self.apartment.pk}/rooms/", {"name": "Office"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(create_resp.status_code, 201)
        room_id = create_resp.json()["room"]["id"]

        rename_resp = self.client.patch(
            f"/manage/apartments/{self.apartment.pk}/rooms/{room_id}/",
            {"name": "Home Office"}, content_type="application/json",
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(rename_resp.status_code, 200)
        self.assertEqual(rename_resp.json()["room"]["name"], "Home Office")

        del_resp = self.client.delete(
            f"/manage/apartments/{self.apartment.pk}/rooms/{room_id}/",
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(del_resp.status_code, 200)
        self.assertFalse(Room.objects.filter(pk=room_id).exists())

    def test_staff_can_reorder_rooms(self):
        token = self._token("techlead4")
        rooms = list(Room.objects.filter(apartment=self.apartment).order_by("sort_order"))
        self.assertGreaterEqual(len(rooms), 2)
        reversed_order = [r.pk for r in reversed(rooms)]

        resp = self.client.post(
            f"/manage/apartments/{self.apartment.pk}/rooms/reorder/",
            {"order": reversed_order}, content_type="application/json",
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)
        rooms[-1].refresh_from_db()
        self.assertEqual(rooms[-1].sort_order, 0)

    def test_staff_can_rename_and_move_a_device_between_rooms(self):
        token = self._token("techlead4")
        device = ApartmentDevice.objects.filter(apartment=self.apartment, device_type="dali").first()
        self.assertIsNotNone(device)
        other_room = Room.objects.filter(apartment=self.apartment).exclude(pk=device.room_id).first()
        self.assertIsNotNone(other_room)

        resp = self.client.patch(
            f"/manage/apartments/{self.apartment.pk}/devices/{device.pk}/",
            {"name": "Reading Lamp", "room_id": other_room.pk},
            content_type="application/json",
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)
        body = resp.json()["device"]
        self.assertEqual(body["name"], "Reading Lamp")
        self.assertEqual(body["room_id"], other_room.pk)

    def test_resident_cannot_rename_device(self):
        token = self._token("resident4")
        device = ApartmentDevice.objects.filter(apartment=self.apartment).first()
        resp = self.client.patch(
            f"/manage/apartments/{self.apartment.pk}/devices/{device.pk}/",
            {"name": "Hacked"}, content_type="application/json",
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 403)


# =============================================================================
# Map API
# =============================================================================

class MapApiTests(TestCase):
    """
    End-to-end coverage of the Digital Twin Map Editor REST API.

    Permission matrix:
      GET  /map/<id>/                        — authenticated member (resident or staff)
      POST /map/<id>/                        — staff only
      PUT  /map/<id>/                        — staff only
      POST /map/<id>/publish/                — staff only
      GET  /map/<id>/versions/               — staff only
      POST /map/<id>/versions/<v>/restore/   — staff only
      GET  /map/apartments/                  — staff only
      GET  /map/<id>/devices/                — staff only
    """

    def setUp(self):
        self.apt16 = Apartment.objects.get(name="Apartment 16")
        self.apt8  = Apartment.objects.get(name="Apartment 8")

        self.staff    = User.objects.create_user(username="mapstaff",    password="pw12345", is_staff=True)
        self.resident = User.objects.create_user(username="mapresident", password="pw12345")
        self.stranger = User.objects.create_user(username="mapstranger", password="pw12345")

        ApartmentMembership.objects.create(
            user=self.resident, apartment=self.apt16,
            role=ApartmentMembership.ROLE_OWNER, is_default=True,
        )

    def _token(self, username):
        resp = self.client.post("/auth/login/", {"username": username, "password": "pw12345"})
        return resp.json()["access"]

    def _auth(self, username):
        return {"HTTP_AUTHORIZATION": f"Bearer {self._token(username)}"}

    def _create_layout(self):
        resp = self.client.post(
            f"/map/{self.apt16.pk}/",
            data=b"{}",
            content_type="application/json",
            **self._auth("mapstaff"),
        )
        return resp.json()["layout"]

    # ── Authentication boundary ───────────────────────────────────────────────

    def test_unauthenticated_cannot_get_layout(self):
        resp = self.client.get(f"/map/{self.apt16.pk}/")
        self.assertEqual(resp.status_code, 401)

    def test_stranger_cannot_get_layout(self):
        resp = self.client.get(f"/map/{self.apt16.pk}/", **self._auth("mapstranger"))
        self.assertEqual(resp.status_code, 403)

    # ── No layout yet ─────────────────────────────────────────────────────────

    def test_get_layout_returns_null_when_none_exists(self):
        resp = self.client.get(f"/map/{self.apt16.pk}/", **self._auth("mapresident"))
        self.assertEqual(resp.status_code, 200)
        body = resp.json()
        self.assertTrue(body["ok"])
        self.assertIsNone(body["layout"])

    # ── Staff creates a layout ────────────────────────────────────────────────

    def test_staff_creates_layout_with_default_layers(self):
        layout = self._create_layout()
        self.assertIsNotNone(layout)
        self.assertEqual(layout["apartment_id"], self.apt16.pk)
        self.assertGreater(len(layout["layers"]), 0)
        self.assertFalse(layout["is_published"])

    def test_resident_cannot_create_layout(self):
        resp = self.client.post(
            f"/map/{self.apt16.pk}/",
            data=b"{}",
            content_type="application/json",
            **self._auth("mapresident"),
        )
        self.assertEqual(resp.status_code, 403)

    # ── Staff saves objects ───────────────────────────────────────────────────

    def test_staff_saves_canvas_objects(self):
        import json as _json
        self._create_layout()
        payload = {
            "objects": [
                {"object_type": "room",   "device_type": "",              "name": "Living Room",
                 "x": 100, "y": 100, "width": 400, "height": 300},
                {"object_type": "device", "device_type": "ceiling_light", "name": "Main Light",
                 "x": 200, "y": 200, "width": 48,  "height": 48,
                 "plc_variable": "GVL.nBrightness_1"},
            ],
        }
        resp = self.client.put(
            f"/map/{self.apt16.pk}/",
            data=_json.dumps(payload).encode(),
            content_type="application/json",
            **self._auth("mapstaff"),
        )
        self.assertEqual(resp.status_code, 200)
        objects = resp.json()["layout"]["objects"]
        self.assertEqual(len(objects), 2)
        self.assertEqual({o["object_type"] for o in objects}, {"room", "device"})

    def test_saved_objects_include_room_name(self):
        import json as _json
        room = Room.objects.filter(apartment=self.apt16).first()
        if room is None:
            self.skipTest("Apartment 16 has no rooms in fixture")
        self._create_layout()
        payload = {"objects": [
            {"object_type": "room", "name": room.name, "room_id": room.pk,
             "x": 0, "y": 0, "width": 200, "height": 150},
        ]}
        resp = self.client.put(
            f"/map/{self.apt16.pk}/",
            data=_json.dumps(payload).encode(),
            content_type="application/json",
            **self._auth("mapstaff"),
        )
        self.assertEqual(resp.status_code, 200)
        obj = resp.json()["layout"]["objects"][0]
        self.assertEqual(obj["room_name"], room.name)

    # ── Resident reads the layout ─────────────────────────────────────────────

    def test_resident_can_read_existing_layout(self):
        self._create_layout()
        resp = self.client.get(f"/map/{self.apt16.pk}/", **self._auth("mapresident"))
        self.assertEqual(resp.status_code, 200)
        self.assertIsNotNone(resp.json()["layout"])

    # ── Cross-apartment isolation ─────────────────────────────────────────────

    def test_resident_cannot_read_other_apartments_layout(self):
        self.client.post(
            f"/map/{self.apt8.pk}/",
            data=b"{}",
            content_type="application/json",
            **self._auth("mapstaff"),
        )
        resp = self.client.get(f"/map/{self.apt8.pk}/", **self._auth("mapresident"))
        self.assertEqual(resp.status_code, 403)

    # ── Publish ───────────────────────────────────────────────────────────────

    def test_staff_publishes_layout(self):
        import json as _json
        self._create_layout()
        resp = self.client.post(
            f"/map/{self.apt16.pk}/publish/",
            data=_json.dumps({"description": "First release"}).encode(),
            content_type="application/json",
            **self._auth("mapstaff"),
        )
        self.assertEqual(resp.status_code, 200)
        version = resp.json()["version"]
        self.assertEqual(version["version_number"], 1)
        self.assertTrue(version["is_published"])

    def test_publish_increments_version_number(self):
        self._create_layout()
        for _ in range(3):
            self.client.post(
                f"/map/{self.apt16.pk}/publish/",
                data=b"{}",
                content_type="application/json",
                **self._auth("mapstaff"),
            )
        resp = self.client.get(f"/map/{self.apt16.pk}/versions/", **self._auth("mapstaff"))
        numbers = [v["version_number"] for v in resp.json()["versions"]]
        self.assertIn(3, numbers)

    def test_only_one_published_version_at_a_time(self):
        self._create_layout()
        for _ in range(2):
            self.client.post(
                f"/map/{self.apt16.pk}/publish/",
                data=b"{}",
                content_type="application/json",
                **self._auth("mapstaff"),
            )
        resp = self.client.get(f"/map/{self.apt16.pk}/versions/", **self._auth("mapstaff"))
        published_count = sum(1 for v in resp.json()["versions"] if v["is_published"])
        self.assertEqual(published_count, 1)

    def test_resident_cannot_publish(self):
        self._create_layout()
        resp = self.client.post(
            f"/map/{self.apt16.pk}/publish/",
            data=b"{}",
            content_type="application/json",
            **self._auth("mapresident"),
        )
        self.assertEqual(resp.status_code, 403)

    def test_publish_on_nonexistent_layout_returns_404(self):
        resp = self.client.post(
            f"/map/{self.apt8.pk}/publish/",
            data=b"{}",
            content_type="application/json",
            **self._auth("mapstaff"),
        )
        self.assertEqual(resp.status_code, 404)

    # ── Version list ──────────────────────────────────────────────────────────

    def test_version_list_empty_when_never_published(self):
        self._create_layout()
        resp = self.client.get(f"/map/{self.apt16.pk}/versions/", **self._auth("mapstaff"))
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.json()["versions"], [])

    def test_resident_cannot_list_versions(self):
        self._create_layout()
        resp = self.client.get(f"/map/{self.apt16.pk}/versions/", **self._auth("mapresident"))
        self.assertEqual(resp.status_code, 403)

    # ── Version restore ───────────────────────────────────────────────────────

    def test_version_restore_replaces_objects(self):
        import json as _json
        self.client.post(
            f"/map/{self.apt16.pk}/",
            data=_json.dumps({"objects": [
                {"object_type": "room", "name": "Original", "x": 0, "y": 0},
            ]}).encode(),
            content_type="application/json",
            **self._auth("mapstaff"),
        )
        publish_resp = self.client.post(
            f"/map/{self.apt16.pk}/publish/",
            data=b"{}",
            content_type="application/json",
            **self._auth("mapstaff"),
        )
        v1_id = publish_resp.json()["version"]["id"]

        self.client.put(
            f"/map/{self.apt16.pk}/",
            data=_json.dumps({"objects": [
                {"object_type": "room", "name": "New1", "x": 0, "y": 0},
                {"object_type": "room", "name": "New2", "x": 0, "y": 0},
            ]}).encode(),
            content_type="application/json",
            **self._auth("mapstaff"),
        )

        restore_resp = self.client.post(
            f"/map/{self.apt16.pk}/versions/{v1_id}/restore/",
            data=b"{}",
            content_type="application/json",
            **self._auth("mapstaff"),
        )
        self.assertEqual(restore_resp.status_code, 200)
        objects = restore_resp.json()["layout"]["objects"]
        self.assertEqual(len(objects), 1)
        self.assertEqual(objects[0]["name"], "Original")

    def test_restore_nonexistent_version_returns_404(self):
        self._create_layout()
        resp = self.client.post(
            f"/map/{self.apt16.pk}/versions/99999/restore/",
            data=b"{}",
            content_type="application/json",
            **self._auth("mapstaff"),
        )
        self.assertEqual(resp.status_code, 404)

    # ── Apartment list (editor picker) ────────────────────────────────────────

    def test_apartment_list_staff_only(self):
        resp = self.client.get("/map/apartments/", **self._auth("mapstaff"))
        self.assertEqual(resp.status_code, 200)
        names = {a["name"] for a in resp.json()["apartments"]}
        self.assertIn("Apartment 16", names)

    def test_apartment_list_shows_layout_status(self):
        self._create_layout()
        resp = self.client.get("/map/apartments/", **self._auth("mapstaff"))
        entry = next(a for a in resp.json()["apartments"] if a["name"] == "Apartment 16")
        self.assertTrue(entry["has_layout"])
        self.assertFalse(entry["is_published"])

    def test_apartment_list_shows_published_after_publish(self):
        self._create_layout()
        self.client.post(
            f"/map/{self.apt16.pk}/publish/",
            data=b"{}",
            content_type="application/json",
            **self._auth("mapstaff"),
        )
        resp = self.client.get("/map/apartments/", **self._auth("mapstaff"))
        entry = next(a for a in resp.json()["apartments"] if a["name"] == "Apartment 16")
        self.assertTrue(entry["is_published"])

    def test_resident_cannot_list_apartments(self):
        resp = self.client.get("/map/apartments/", **self._auth("mapresident"))
        self.assertEqual(resp.status_code, 403)

    # ── Device picker ─────────────────────────────────────────────────────────

    def test_device_picker_returns_devices_and_rooms(self):
        resp = self.client.get(f"/map/{self.apt16.pk}/devices/", **self._auth("mapstaff"))
        self.assertEqual(resp.status_code, 200)
        body = resp.json()
        self.assertIn("devices", body)
        self.assertIn("rooms", body)

    def test_resident_cannot_access_device_picker(self):
        resp = self.client.get(f"/map/{self.apt16.pk}/devices/", **self._auth("mapresident"))
        self.assertEqual(resp.status_code, 403)


# ─────────────────────────────────────────────────────────────────────────────
# Curtain command translation (added alongside the gvlCurtain PLC bridge)
# ─────────────────────────────────────────────────────────────────────────────

class _FakeAdsClient:
    """Records writes and serves canned reads — not an ADSClient, just
    enough surface (mock/read/write) for a single device class under test."""

    def __init__(self):
        self.mock = False
        self.writes = {}
        self.reads  = {}

    def write(self, var, value, plctype):
        self.writes[var] = value

    def read(self, var, plctype):
        return self.reads.get(var, False)


class CurtainMotorTranslationTests(TestCase):
    """
    CurtainMotor previously targeted gvlIO.aPyCurtainCmd/State, which never
    existed on the real PLC — every call failed with ADSError: symbol not
    found. These pin the fix: the app-facing stop/up/down (0/1/2) contract
    must translate correctly onto gvlCurtain's OpenBtn/CloseBtn/Open/Close.
    """

    def setUp(self):
        self.client_stub = _FakeAdsClient()
        self.curtain = CurtainMotor(1, "Living Room Curtain", "Living Room", self.client_stub)

    def test_max_index_is_2_not_16(self):
        # Only 2 physical curtains exist (gvlCurtain wires Curtain 1/2 only).
        with self.assertRaises(ValueError):
            CurtainMotor(3, "Nonexistent", "Nowhere", self.client_stub)

    def test_up_command_opens_and_clears_close(self):
        self.curtain.set_command(CurtainMotor.UP)
        self.assertTrue(self.client_stub.writes["gvlCurtain.bCurtain1OpenBtn"])
        self.assertFalse(self.client_stub.writes["gvlCurtain.bCurtain1CloseBtn"])

    def test_down_command_closes_and_clears_open(self):
        self.curtain.set_command(CurtainMotor.DOWN)
        self.assertFalse(self.client_stub.writes["gvlCurtain.bCurtain1OpenBtn"])
        self.assertTrue(self.client_stub.writes["gvlCurtain.bCurtain1CloseBtn"])

    def test_stop_command_clears_both(self):
        self.curtain.set_command(CurtainMotor.STOP)
        self.assertFalse(self.client_stub.writes["gvlCurtain.bCurtain1OpenBtn"])
        self.assertFalse(self.client_stub.writes["gvlCurtain.bCurtain1CloseBtn"])

    def test_read_state_reflects_open_output(self):
        self.client_stub.reads["gvlCurtain.bCurtain1Open"] = True
        self.assertEqual(self.curtain.read_state(), CurtainMotor.UP)

    def test_read_state_reflects_close_output(self):
        self.client_stub.reads["gvlCurtain.bCurtain1Close"] = True
        self.assertEqual(self.curtain.read_state(), CurtainMotor.DOWN)

    def test_read_state_stopped_when_neither_output_set(self):
        self.assertEqual(self.curtain.read_state(), CurtainMotor.STOP)


# ─────────────────────────────────────────────────────────────────────────────
# ADS/Modbus fallback (registry.py) — only DALI 1-16 / relay 1-4 are bridged
# ─────────────────────────────────────────────────────────────────────────────

class RegistryModbusFallbackTests(TestCase):
    """
    Modbus exists specifically to survive the class of ADS failure this
    project keeps hitting (route resets, Secure ADS). These pin that the
    fallback actually engages on an ADS failure, stays out of the way when
    ADS is healthy, and never silently swallows a failure when Modbus
    isn't available either.
    """

    def setUp(self):
        apt = Apartment.objects.get(name="Apartment 16")
        self.registry = DeviceRegistry.for_apartment(apt.pk)

    def test_no_fallback_when_ads_succeeds(self):
        dali = self.registry.dali(1)
        with patch.object(dali, "read_actual_level", return_value=42) as ads_read:
            result = self.registry.read_dali_actual_pct(1)
        self.assertEqual(result, 42)
        ads_read.assert_called_once()

    def test_dali_read_falls_back_to_modbus_when_ads_fails(self):
        dali = self.registry.dali(1)
        fake_modbus = MagicMock()
        fake_modbus.is_connected = True
        fake_modbus.read_dali_level.return_value = 127  # raw byte, ~50%
        self.registry._modbus = fake_modbus
        with patch.object(dali, "read_actual_level", side_effect=ConnectionError("ADS down")):
            result = self.registry.read_dali_actual_pct(1)
        fake_modbus.read_dali_level.assert_called_once_with(1)
        self.assertIsNotNone(result)

    def test_dali_read_reraises_when_modbus_also_unavailable(self):
        dali = self.registry.dali(1)
        self.registry._modbus = None  # PLC_MODBUS_ENABLED=false — the default
        with patch.object(dali, "read_actual_level", side_effect=ConnectionError("ADS down")):
            with self.assertRaises(ConnectionError):
                self.registry.read_dali_actual_pct(1)

    def test_relay_write_falls_back_to_modbus_when_ads_fails(self):
        relay = self.registry.relay(1)
        fake_modbus = MagicMock()
        fake_modbus.is_connected = True
        fake_modbus.write_relay.return_value = True
        self.registry._modbus = fake_modbus
        with patch.object(relay, "set_state", side_effect=ConnectionError("ADS down")):
            self.registry.write_relay_state(1, True)  # must not raise
        fake_modbus.write_relay.assert_called_once_with(0, True)  # channel 1 -> relay index 0

    def test_fallback_never_attempted_for_unconfigured_channel(self):
        # No relay 5 exists on this registry (only 4 physical relays are
        # seeded) — read_relay_actual must return None via the normal
        # "device not configured" path without ever touching Modbus, even
        # though Modbus itself is reachable here.
        fake_modbus = MagicMock()
        fake_modbus.is_connected = True
        self.registry._modbus = fake_modbus
        self.assertIsNone(self.registry.read_relay_actual(5))
        fake_modbus.read_relay.assert_not_called()


# ─────────────────────────────────────────────────────────────────────────────
# PLC outage heartbeat (tasks.check_plc_heartbeat)
# ─────────────────────────────────────────────────────────────────────────────

class PlcHeartbeatTests(TestCase):
    """
    check_plc_heartbeat must persist outage state on PLCDevice (survives a
    worker restart) and alert exactly once per transition — not on every
    tick of an ongoing outage, and not for blips shorter than the
    reconnect loop's own backoff ceiling.
    """

    def setUp(self):
        self.apt = Apartment.objects.get(name="Apartment 16")
        owner = User.objects.create_user(username="heartbeat_owner", password="pw12345")
        self.device = PLCDevice.objects.create(
            apartment=self.apt, owner=owner, name="Heartbeat Test PLC",
            ip_address="192.168.0.161", ams_net_id="192.168.0.161.1.1",
        )

    def _run_with_status(self, up: bool):
        fake_registry = MagicMock()
        fake_registry.connected = up
        fake_registry.modbus_connected = False
        with patch(
            "find_device.plc.registry.DeviceRegistry.for_apartment",
            return_value=fake_registry,
        ), patch("find_device.tasks.send_notification") as notify:
            check_plc_heartbeat()
        return notify

    def test_first_down_tick_records_down_since_without_alerting(self):
        notify = self._run_with_status(up=False)
        self.device.refresh_from_db()
        self.assertIsNotNone(self.device.down_since)
        notify.delay.assert_not_called()

    def test_short_blip_does_not_alert_on_recovery(self):
        self.device.down_since = timezone.now() - timedelta(seconds=10)
        self.device.save(update_fields=["down_since"])
        notify = self._run_with_status(up=True)
        self.device.refresh_from_db()
        self.assertIsNone(self.device.down_since)
        notify.delay.assert_not_called()

    def test_outage_past_threshold_alerts_exactly_once(self):
        self.device.down_since = timezone.now() - timedelta(seconds=125)
        self.device.save(update_fields=["down_since"])
        notify = self._run_with_status(up=False)
        notify.delay.assert_called_once()
        _, kwargs = notify.delay.call_args
        self.assertEqual(kwargs["priority"], "high")

    def test_recovery_after_real_outage_alerts_once_with_duration(self):
        self.device.down_since = timezone.now() - timedelta(minutes=5)
        self.device.save(update_fields=["down_since"])
        notify = self._run_with_status(up=True)
        self.device.refresh_from_db()
        self.assertIsNone(self.device.down_since)
        notify.delay.assert_called_once()

    def test_ongoing_outage_does_not_re_alert_every_tick(self):
        # Already well past the threshold on a previous tick.
        self.device.down_since = timezone.now() - timedelta(seconds=300)
        self.device.save(update_fields=["down_since"])
        notify = self._run_with_status(up=False)
        notify.delay.assert_not_called()


# =============================================================================
# Light Relabel API
# =============================================================================

class RelabelPermissionTests(TestCase):
    """
    IT Team (is_staff) only — deliberately not Owner (homeowner), not
    Installer, not even a Building Owner. Re-identifying/relabeling DALI
    channels is IT Team's own tooling, kept invisible to everyone else,
    including roles that otherwise hold broad access elsewhere.
    """

    def setUp(self):
        self.apartment = Apartment.objects.get(name="Apartment 16")
        self.staff = User.objects.create_user(username="relabel_staff", password="pw12345", is_staff=True)
        self.owner = User.objects.create_user(username="relabel_owner", password="pw12345")
        self.installer = User.objects.create_user(username="relabel_installer", password="pw12345")
        self.resident = User.objects.create_user(username="relabel_resident", password="pw12345")
        self.building_owner = User.objects.create_user(username="relabel_bldg_owner", password="pw12345")
        ApartmentMembership.objects.create(
            user=self.owner, apartment=self.apartment,
            role=ApartmentMembership.ROLE_OWNER, is_default=True,
        )
        ApartmentMembership.objects.create(
            user=self.installer, apartment=self.apartment,
            role=ApartmentMembership.ROLE_INSTALLER, is_default=True,
        )
        ApartmentMembership.objects.create(
            user=self.resident, apartment=self.apartment,
            role=ApartmentMembership.ROLE_RESIDENT, is_default=True,
        )
        BuildingMembership.objects.create(user=self.building_owner, building=self.apartment.building)

    def _token(self, username):
        return self.client.post(
            "/auth/login/", {"username": username, "password": "pw12345"},
        ).json()["access"]

    def test_resident_forbidden(self):
        token = self._token("relabel_resident")
        resp = self.client.get(
            f"/relabel/{self.apartment.pk}/outputs/dali/", HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 403)

    def test_staff_allowed(self):
        token = self._token("relabel_staff")
        resp = self.client.get(
            f"/relabel/{self.apartment.pk}/outputs/dali/", HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)

    def test_owner_forbidden(self):
        """Homeowner is deliberately resident-equivalent for anything technical."""
        token = self._token("relabel_owner")
        resp = self.client.get(
            f"/relabel/{self.apartment.pk}/outputs/dali/", HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 403)

    def test_installer_forbidden(self):
        token = self._token("relabel_installer")
        resp = self.client.get(
            f"/relabel/{self.apartment.pk}/outputs/dali/", HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 403)

    def test_building_owner_forbidden(self):
        """
        Building Owner has IT-Team-equivalent user/apartment management but
        never this — the one tool that would reveal there's no bespoke PLC
        coding happening stays exclusively IT Team's.
        """
        token = self._token("relabel_bldg_owner")
        resp = self.client.get(
            f"/relabel/{self.apartment.pk}/outputs/dali/", HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 403)

    def test_unauthenticated_rejected(self):
        resp = self.client.get(f"/relabel/{self.apartment.pk}/outputs/dali/")
        self.assertEqual(resp.status_code, 401)

    def test_inputs_also_staff_only(self):
        token = self._token("relabel_owner")
        resp = self.client.get(
            f"/relabel/{self.apartment.pk}/inputs/", HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 403)


class RelabelOutputChannelListTests(TestCase):
    """GET /relabel/<apt>/outputs/<type>/ shape for each output type."""

    def setUp(self):
        self.apartment = Apartment.objects.get(name="Apartment 16")
        self.staff = User.objects.create_user(username="relabel_list_staff", password="pw12345", is_staff=True)

    def _token(self):
        return self.client.post(
            "/auth/login/", {"username": "relabel_list_staff", "password": "pw12345"},
        ).json()["access"]

    def test_dali_returns_30_channels_and_existing_rooms(self):
        token = self._token()
        resp = self.client.get(
            f"/relabel/{self.apartment.pk}/outputs/dali/", HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)
        body = resp.json()
        self.assertEqual(len(body["channels"]), 30)  # 1-31 excluding 29
        self.assertNotIn(29, [c["channel"] for c in body["channels"]])
        self.assertGreater(len(body["rooms"]), 0)

        already_assigned = [c for c in body["channels"] if c["assigned"]]
        self.assertGreater(len(already_assigned), 0)
        sample = already_assigned[0]
        self.assertIsNotNone(sample["name"])
        self.assertIsNotNone(sample["room_name"])

    def test_relay_returns_16_channels(self):
        token = self._token()
        resp = self.client.get(
            f"/relabel/{self.apartment.pk}/outputs/relay/", HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.json()["channels"]), 16)

    def test_curtain_returns_2_channels(self):
        token = self._token()
        resp = self.client.get(
            f"/relabel/{self.apartment.pk}/outputs/curtain/", HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.json()["channels"]), 2)

    def test_unknown_output_type_rejected(self):
        token = self._token()
        resp = self.client.get(
            f"/relabel/{self.apartment.pk}/outputs/hvac/", HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 400)


class RelabelOutputFlashAndAssignTests(TestCase):
    """
    Flash-test and assign use a dedicated apartment (not "Apartment 16") so
    the hot-reloaded in-memory registry entries this creates don't leak into
    Apartment 16's shared, process-lifetime DeviceRegistry instance and
    corrupt its device-count assertions elsewhere (DeviceRegistryDbDrivenTests).
    """

    def setUp(self):
        self.apartment = Apartment.objects.create(name="Relabel Test Apartment")
        self.staff = User.objects.create_user(username="relabel_fa_staff", password="pw12345", is_staff=True)

    def _token(self):
        return self.client.post(
            "/auth/login/", {"username": "relabel_fa_staff", "password": "pw12345"},
        ).json()["access"]

    def test_flash_unassigned_dali_channel_succeeds(self):
        token = self._token()
        resp = self.client.post(
            f"/relabel/{self.apartment.pk}/outputs/dali/20/flash/",
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)
        self.assertTrue(resp.json()["ok"])
        self.assertEqual(resp.json()["channel"], 20)

    def test_flash_invalid_dali_channel_rejected(self):
        token = self._token()
        resp = self.client.post(
            f"/relabel/{self.apartment.pk}/outputs/dali/29/flash/",
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 400)

    def test_flash_unassigned_relay_channel_succeeds(self):
        token = self._token()
        resp = self.client.post(
            f"/relabel/{self.apartment.pk}/outputs/relay/3/flash/",
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.json()["channel"], 3)

    def test_flash_invalid_relay_channel_rejected(self):
        token = self._token()
        resp = self.client.post(
            f"/relabel/{self.apartment.pk}/outputs/relay/17/flash/",
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 400)

    def test_flash_unassigned_curtain_succeeds(self):
        token = self._token()
        resp = self.client.post(
            f"/relabel/{self.apartment.pk}/outputs/curtain/1/flash/",
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.json()["channel"], 1)

    def test_flash_invalid_curtain_rejected(self):
        token = self._token()
        resp = self.client.post(
            f"/relabel/{self.apartment.pk}/outputs/curtain/3/flash/",
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 400)

    def test_assign_creates_new_room_and_device(self):
        token = self._token()
        resp = self.client.post(
            f"/relabel/{self.apartment.pk}/outputs/dali/21/assign/",
            {"name": "Laundry Ceiling Light", "room_name": "Laundry Room"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)
        body = resp.json()
        self.assertEqual(body["room_name"], "Laundry Room")

        device = ApartmentDevice.objects.get(
            apartment=self.apartment, device_type=ApartmentDevice.TYPE_DALI, channel_or_index=21,
        )
        self.assertEqual(device.name, "Laundry Ceiling Light")
        self.assertEqual(device.room.name, "Laundry Room")

    def test_assign_relay_creates_relay_typed_device(self):
        token = self._token()
        resp = self.client.post(
            f"/relabel/{self.apartment.pk}/outputs/relay/2/assign/",
            {"name": "Porch Wall Light", "room_name": "Porch"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)
        device = ApartmentDevice.objects.get(
            apartment=self.apartment, device_type=ApartmentDevice.TYPE_RELAY, channel_or_index=2,
        )
        self.assertEqual(device.name, "Porch Wall Light")

    def test_assign_curtain_creates_curtain_typed_device(self):
        token = self._token()
        resp = self.client.post(
            f"/relabel/{self.apartment.pk}/outputs/curtain/2/assign/",
            {"name": "Bedroom Curtain", "room_name": "Bedroom Main"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)
        device = ApartmentDevice.objects.get(
            apartment=self.apartment, device_type=ApartmentDevice.TYPE_CURTAIN, channel_or_index=2,
        )
        self.assertEqual(device.name, "Bedroom Curtain")

    def test_assign_relabels_existing_channel_in_place(self):
        token = self._token()
        room_a = Room.objects.create(apartment=self.apartment, name="Bedroom Light 1 (wrong)")
        ApartmentDevice.objects.create(
            apartment=self.apartment, device_type=ApartmentDevice.TYPE_DALI,
            channel_or_index=22, name="Bedroom Light 1", room=room_a,
        )

        resp = self.client.post(
            f"/relabel/{self.apartment.pk}/outputs/dali/22/assign/",
            {"name": "Guest Bathroom Light", "room_name": "Guest Bathroom"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)

        # Same device row updated in place — no duplicate created for ch22.
        matches = ApartmentDevice.objects.filter(
            apartment=self.apartment, device_type=ApartmentDevice.TYPE_DALI, channel_or_index=22,
        )
        self.assertEqual(matches.count(), 1)
        device = matches.first()
        self.assertEqual(device.name, "Guest Bathroom Light")
        self.assertEqual(device.room.name, "Guest Bathroom")

    def test_assign_reuses_existing_room_by_id_supports_numbered_duplicates(self):
        token = self._token()
        bathroom_1 = Room.objects.create(apartment=self.apartment, name="Bathroom 1")
        Room.objects.create(apartment=self.apartment, name="Bathroom 2")

        resp = self.client.post(
            f"/relabel/{self.apartment.pk}/outputs/dali/23/assign/",
            {"name": "Bathroom 1 Ceiling Light", "room_id": bathroom_1.pk},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(
            Room.objects.filter(apartment=self.apartment, name__startswith="Bathroom").count(), 2,
        )
        device = ApartmentDevice.objects.get(apartment=self.apartment, channel_or_index=23)
        self.assertEqual(device.room_id, bathroom_1.pk)

    def test_assign_missing_name_rejected(self):
        token = self._token()
        resp = self.client.post(
            f"/relabel/{self.apartment.pk}/outputs/dali/24/assign/",
            {"room_name": "Office"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 400)

    def test_resident_cannot_assign(self):
        resident = User.objects.create_user(username="relabel_fa_resident", password="pw12345")
        ApartmentMembership.objects.create(
            user=resident, apartment=self.apartment,
            role=ApartmentMembership.ROLE_RESIDENT, is_default=True,
        )
        token = self.client.post(
            "/auth/login/", {"username": "relabel_fa_resident", "password": "pw12345"},
        ).json()["access"]
        resp = self.client.post(
            f"/relabel/{self.apartment.pk}/outputs/dali/25/assign/",
            {"name": "Hacked", "room_name": "Nowhere"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 403)


class RelabelInputTests(TestCase):
    """
    GET /relabel/<apt>/inputs/ (live state for every switch/sensor channel,
    assigned or not) and POST .../inputs/assign/ — same dedicated-apartment
    isolation rationale as RelabelOutputFlashAndAssignTests.
    """

    def setUp(self):
        self.apartment = Apartment.objects.create(name="Relabel Input Test Apartment")
        self.staff = User.objects.create_user(username="relabel_in_staff", password="pw12345", is_staff=True)

    def _token(self):
        return self.client.post(
            "/auth/login/", {"username": "relabel_in_staff", "password": "pw12345"},
        ).json()["access"]

    def test_lists_all_input_groups_with_live_state(self):
        token = self._token()
        resp = self.client.get(
            f"/relabel/{self.apartment.pk}/inputs/", HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)
        body = resp.json()
        self.assertEqual(len(body["switches"]), 48)
        self.assertEqual(len(body["motion_sensors"]), 8)
        self.assertEqual(len(body["door_sensors"]), 16)
        self.assertEqual(len(body["window_sensors"]), 16)
        # PLC_MOCK=true in tests → read_batch is skipped, every raw state is False.
        self.assertFalse(any(s["state"] for s in body["switches"]))
        self.assertIn("rooms", body)

    def test_assign_switch_creates_device(self):
        token = self._token()
        resp = self.client.post(
            f"/relabel/{self.apartment.pk}/inputs/assign/",
            {"device_type": "switch", "index": 34, "name": "Laundry Motion Switch", "room_name": "Laundry Room"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)
        device = ApartmentDevice.objects.get(
            apartment=self.apartment, device_type=ApartmentDevice.TYPE_SWITCH, channel_or_index=34,
        )
        self.assertEqual(device.name, "Laundry Motion Switch")
        self.assertEqual(device.room.name, "Laundry Room")

    def test_assign_motion_sensor_creates_device(self):
        token = self._token()
        resp = self.client.post(
            f"/relabel/{self.apartment.pk}/inputs/assign/",
            {"device_type": "motion_sensor", "index": 5, "name": "Hallway PIR", "room_name": "Hallway"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)
        device = ApartmentDevice.objects.get(
            apartment=self.apartment, device_type=ApartmentDevice.TYPE_MOTION_SENSOR, channel_or_index=5,
        )
        self.assertEqual(device.name, "Hallway PIR")

    def test_assign_unknown_device_type_rejected(self):
        token = self._token()
        resp = self.client.post(
            f"/relabel/{self.apartment.pk}/inputs/assign/",
            {"device_type": "thermostat", "index": 1, "name": "X", "room_name": "Y"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 400)

    def test_resident_cannot_list_inputs(self):
        resident = User.objects.create_user(username="relabel_in_resident", password="pw12345")
        ApartmentMembership.objects.create(
            user=resident, apartment=self.apartment,
            role=ApartmentMembership.ROLE_RESIDENT, is_default=True,
        )
        token = self.client.post(
            "/auth/login/", {"username": "relabel_in_resident", "password": "pw12345"},
        ).json()["access"]
        resp = self.client.get(
            f"/relabel/{self.apartment.pk}/inputs/", HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 403)


# =============================================================================
# Building Owner scoping — user_management_views.py opened up beyond is_staff
# =============================================================================

class BuildingOwnerScopingTests(TestCase):
    """
    Building Owner gets IT-Team-equivalent user/apartment management, but
    strictly scoped to their own building — never another building's data,
    and never apartment_plc (PLC connection settings stays is_staff-only).
    """

    def setUp(self):
        self.building_a_apt = Apartment.objects.create(name="BOA Apt 1", building="Building A")
        self.building_b_apt = Apartment.objects.create(name="BOB Apt 1", building="Building B")

        self.bo_a = User.objects.create_user(username="bo_a", password="pw12345")
        BuildingMembership.objects.create(user=self.bo_a, building="Building A")

        self.resident_a = User.objects.create_user(username="bo_resident_a", password="pw12345")
        ApartmentMembership.objects.create(
            user=self.resident_a, apartment=self.building_a_apt,
            role=ApartmentMembership.ROLE_RESIDENT, is_default=True,
        )
        self.resident_b = User.objects.create_user(username="bo_resident_b", password="pw12345")
        ApartmentMembership.objects.create(
            user=self.resident_b, apartment=self.building_b_apt,
            role=ApartmentMembership.ROLE_RESIDENT, is_default=True,
        )

    def _token(self, username):
        return self.client.post(
            "/auth/login/", {"username": username, "password": "pw12345"},
        ).json()["access"]

    def test_building_owner_sees_only_their_buildings_apartments(self):
        token = self._token("bo_a")
        resp = self.client.get("/manage/apartments/", HTTP_AUTHORIZATION=f"Bearer {token}")
        self.assertEqual(resp.status_code, 200)
        names = [a["name"] for a in resp.json()["apartments"]]
        self.assertIn("BOA Apt 1", names)
        self.assertNotIn("BOB Apt 1", names)

    def test_building_owner_cannot_view_other_buildings_apartment_detail(self):
        token = self._token("bo_a")
        resp = self.client.get(
            f"/manage/apartments/{self.building_b_apt.pk}/", HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 404)

    def test_building_owner_sees_only_their_buildings_users(self):
        token = self._token("bo_a")
        resp = self.client.get("/manage/users/", HTTP_AUTHORIZATION=f"Bearer {token}")
        self.assertEqual(resp.status_code, 200)
        usernames = [u["username"] for u in resp.json()["users"]]
        self.assertIn("bo_resident_a", usernames)
        self.assertNotIn("bo_resident_b", usernames)

    def test_building_owner_cannot_view_other_buildings_user_detail(self):
        token = self._token("bo_a")
        resp = self.client.get(
            f"/manage/users/{self.resident_b.pk}/", HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 404)

    def test_building_owner_cannot_assign_user_into_other_building(self):
        token = self._token("bo_a")
        resp = self.client.post(
            f"/manage/users/{self.resident_b.pk}/assign-apartment/",
            {"apartment_id": self.building_b_apt.pk, "role": "resident"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 404)

    def test_building_owner_can_rename_room_in_their_building(self):
        token = self._token("bo_a")
        create_resp = self.client.post(
            f"/manage/apartments/{self.building_a_apt.pk}/rooms/", {"name": "Office"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(create_resp.status_code, 201)

    def test_building_owner_cannot_touch_rooms_in_other_building(self):
        token = self._token("bo_a")
        resp = self.client.post(
            f"/manage/apartments/{self.building_b_apt.pk}/rooms/", {"name": "Office"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 404)

    def test_building_owner_cannot_reach_plc_settings(self):
        """apartment_plc stays is_staff-only — PLC connection config is the
        one thing Building Owner never gets, same bar as the relabel tool."""
        token = self._token("bo_a")
        resp = self.client.get(
            f"/manage/apartments/{self.building_a_apt.pk}/plc/", HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 403)

    def test_building_owner_new_apartment_forced_into_their_building(self):
        token = self._token("bo_a")
        resp = self.client.post(
            "/manage/apartments/", {"name": "BOA Apt 2"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(resp.json()["apartment"]["building"], "Building A")

    def test_building_owner_cannot_create_apartment_in_other_building(self):
        token = self._token("bo_a")
        resp = self.client.post(
            "/manage/apartments/", {"name": "Sneaky Apt", "building": "Building B"},
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 400)

    def test_plain_resident_still_forbidden_from_user_management(self):
        token = self._token("bo_resident_a")
        resp = self.client.get("/manage/users/", HTTP_AUTHORIZATION=f"Bearer {token}")
        self.assertEqual(resp.status_code, 403)

    def test_staff_still_sees_every_building(self):
        staff = User.objects.create_user(username="bo_staff", password="pw12345", is_staff=True)
        token = self._token("bo_staff")
        resp = self.client.get("/manage/apartments/", HTTP_AUTHORIZATION=f"Bearer {token}")
        names = [a["name"] for a in resp.json()["apartments"]]
        self.assertIn("BOA Apt 1", names)
        self.assertIn("BOB Apt 1", names)


# =============================================================================
# Automations — "no more hand-written PLC code" from the phone
# =============================================================================

class AutomationApiTests(TestCase):
    """
    CRUD + validation for AutomationRule. is_staff only — same bar as
    relabel. Uses a dedicated apartment (not "Apartment 16") for the same
    shared-registry-isolation reason as RelabelOutputFlashAndAssignTests.
    """

    def setUp(self):
        self.apartment = Apartment.objects.create(name="Automation Test Apartment")
        self.staff = User.objects.create_user(username="auto_staff", password="pw12345", is_staff=True)
        self.owner = User.objects.create_user(username="auto_owner", password="pw12345")
        ApartmentMembership.objects.create(
            user=self.owner, apartment=self.apartment,
            role=ApartmentMembership.ROLE_OWNER, is_default=True,
        )
        self.switch = ApartmentDevice.objects.create(
            apartment=self.apartment, device_type=ApartmentDevice.TYPE_SWITCH,
            channel_or_index=1, name="Test Switch",
        )
        self.light = ApartmentDevice.objects.create(
            apartment=self.apartment, device_type=ApartmentDevice.TYPE_DALI,
            channel_or_index=1, name="Test Light",
        )
        self.relay = ApartmentDevice.objects.create(
            apartment=self.apartment, device_type=ApartmentDevice.TYPE_RELAY,
            channel_or_index=1, name="Test Relay",
        )

    def _token(self, username):
        return self.client.post(
            "/auth/login/", {"username": username, "password": "pw12345"},
        ).json()["access"]

    def test_owner_forbidden(self):
        token = self._token("auto_owner")
        resp = self.client.get(
            f"/automations/{self.apartment.pk}/rules/", HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 403)

    def test_staff_can_list_rules_and_eligible_devices(self):
        token = self._token("auto_staff")
        resp = self.client.get(
            f"/automations/{self.apartment.pk}/rules/", HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)
        body = resp.json()
        self.assertEqual(body["rules"], [])
        trigger_ids = [d["id"] for d in body["triggers"]]
        action_ids = [d["id"] for d in body["actions"]]
        self.assertIn(self.switch.pk, trigger_ids)
        self.assertIn(self.light.pk, action_ids)
        self.assertNotIn(self.light.pk, trigger_ids)   # a light isn't a valid trigger
        self.assertNotIn(self.switch.pk, action_ids)   # a switch isn't a valid action

    def test_staff_can_create_dali_rule(self):
        token = self._token("auto_staff")
        resp = self.client.post(
            f"/automations/{self.apartment.pk}/rules/",
            {
                "name": "Switch turns on light",
                "trigger_device_id": self.switch.pk, "trigger_state": "true",
                "action_device_id": self.light.pk, "action_value": "80",
            },
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 200)
        rule = resp.json()["rule"]
        self.assertTrue(rule["enabled"])
        self.assertEqual(rule["action_value"], "80")
        self.assertTrue(AutomationRule.objects.filter(pk=rule["id"]).exists())

    def test_invalid_dali_action_value_rejected(self):
        token = self._token("auto_staff")
        resp = self.client.post(
            f"/automations/{self.apartment.pk}/rules/",
            {
                "name": "Bad rule",
                "trigger_device_id": self.switch.pk, "trigger_state": "true",
                "action_device_id": self.light.pk, "action_value": "150",
            },
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 400)

    def test_invalid_relay_action_value_rejected(self):
        token = self._token("auto_staff")
        resp = self.client.post(
            f"/automations/{self.apartment.pk}/rules/",
            {
                "name": "Bad relay rule",
                "trigger_device_id": self.switch.pk, "trigger_state": "true",
                "action_device_id": self.relay.pk, "action_value": "on",
            },
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 400)

    def test_light_cannot_be_used_as_trigger(self):
        token = self._token("auto_staff")
        resp = self.client.post(
            f"/automations/{self.apartment.pk}/rules/",
            {
                "name": "Bad trigger",
                "trigger_device_id": self.light.pk, "trigger_state": "true",
                "action_device_id": self.relay.pk, "action_value": "true",
            },
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(resp.status_code, 400)

    def test_update_and_delete_rule(self):
        token = self._token("auto_staff")
        rule = AutomationRule.objects.create(
            apartment=self.apartment, name="Original", enabled=True,
            trigger_device=self.switch, trigger_state=True,
            action_device=self.relay, action_value="true",
        )

        patch_resp = self.client.patch(
            f"/automations/{self.apartment.pk}/rules/{rule.pk}/",
            {"enabled": "false"}, content_type="application/json",
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(patch_resp.status_code, 200)
        rule.refresh_from_db()
        self.assertFalse(rule.enabled)

        del_resp = self.client.delete(
            f"/automations/{self.apartment.pk}/rules/{rule.pk}/",
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )
        self.assertEqual(del_resp.status_code, 200)
        self.assertFalse(AutomationRule.objects.filter(pk=rule.pk).exists())


class AutomationExecutionTests(TestCase):
    """
    Exercises DeviceRegistry._execute_automation() directly — under
    PLC_MOCK, NotificationManager.subscribe() always returns False (no real
    ADS connection to push notifications over), so this validates the
    action-execution logic itself rather than the notification wiring,
    the same way flash_raw_dali's tests validate the write path without a
    live PLC.
    """

    def setUp(self):
        self.apartment = Apartment.objects.create(name="Automation Exec Test Apartment")
        self.switch = ApartmentDevice.objects.create(
            apartment=self.apartment, device_type=ApartmentDevice.TYPE_SWITCH,
            channel_or_index=10, name="Exec Switch",
        )
        self.light = ApartmentDevice.objects.create(
            apartment=self.apartment, device_type=ApartmentDevice.TYPE_DALI,
            channel_or_index=10, name="Exec Light",
        )
        self.relay = ApartmentDevice.objects.create(
            apartment=self.apartment, device_type=ApartmentDevice.TYPE_RELAY,
            channel_or_index=10, name="Exec Relay",
        )

    def test_dali_action_sets_brightness(self):
        rule = AutomationRule.objects.create(
            apartment=self.apartment, name="Dim rule", enabled=True,
            trigger_device=self.switch, trigger_state=True,
            action_device=self.light, action_value="55",
        )
        registry = DeviceRegistry.for_apartment(self.apartment.pk)
        registry._start()
        registry.add_dali(channel=10, name="Exec Light", room="", apartment_device_id=self.light.pk)
        registry._execute_automation(rule.pk)
        self.assertEqual(registry.dali(10).read_actual_level(), 55)

    def test_relay_action_sets_state(self):
        rule = AutomationRule.objects.create(
            apartment=self.apartment, name="Relay on rule", enabled=True,
            trigger_device=self.switch, trigger_state=True,
            action_device=self.relay, action_value="true",
        )
        registry = DeviceRegistry.for_apartment(self.apartment.pk)
        registry._start()
        registry.add_relay(channel=10, name="Exec Relay", room="")
        registry._execute_automation(rule.pk)
        self.assertTrue(registry.relay(10).read_state())

    def test_disabled_rule_does_not_execute(self):
        rule = AutomationRule.objects.create(
            apartment=self.apartment, name="Disabled rule", enabled=False,
            trigger_device=self.switch, trigger_state=True,
            action_device=self.relay, action_value="true",
        )
        registry = DeviceRegistry.for_apartment(self.apartment.pk)
        registry._start()
        registry.add_relay(channel=10, name="Exec Relay", room="")
        registry._execute_automation(rule.pk)
        self.assertFalse(registry.relay(10).read_state())

    def test_reload_and_remove_automation_do_not_crash_under_mock(self):
        rule = AutomationRule.objects.create(
            apartment=self.apartment, name="Reload rule", enabled=True,
            trigger_device=self.switch, trigger_state=True,
            action_device=self.relay, action_value="true",
        )
        registry = DeviceRegistry.for_apartment(self.apartment.pk)
        registry._start()
        registry.add_switch(index=10, name="Exec Switch", room="")
        registry.add_relay(channel=10, name="Exec Relay", room="")
        registry.reload_automation(rule.pk)   # subscribe() returns False under mock — should not raise
        registry.remove_automation(rule.pk)   # no-op since nothing was actually subscribed — should not raise


class BuildingControlsTests(TestCase):
    """
    Building-wide admin controls (2026-09-25): scheme-driven ("custom")
    devices surfacing in /plc/state/ + /plc/devices/, the building-settings
    endpoint (sunset/sunrise override, poll cooldown), Christmas mode, and
    the sunset/sunrise override job itself. Fresh apartment per test, same
    DeviceRegistry-cache reasoning as DeviceAddressSchemeTests.
    """

    def setUp(self):
        DeviceRegistry._apt_instances.clear()
        self.apartment = Apartment.objects.create(name="Test Common Areas", building="Main Building")
        self.scheme = DeviceAddressScheme.objects.create(
            name="test_building_relay_v1", gvl="GVL_Relay",
            read_var_template="{gvl}.bRelay{index}", write_var_template="{gvl}.bRelay{index}",
            plc_type="BOOL", protocol=DeviceAddressScheme.PROTOCOL_ADS,
        )
        self.staff = User.objects.create_user(username="bc_staff", password="pw12345", is_staff=True)
        self.member = User.objects.create_user(username="bc_member", password="pw12345")
        for user in (self.staff, self.member):
            ApartmentMembership.objects.create(
                user=user, apartment=self.apartment,
                role=ApartmentMembership.ROLE_OWNER, is_default=True,
            )

    def _token(self, username):
        return self.client.post("/auth/login/", {"username": username, "password": "pw12345"}).json()["access"]

    def _add_light(self, index):
        return ApartmentDevice.objects.create(
            apartment=self.apartment, device_type=ApartmentDevice.TYPE_CUSTOM,
            channel_or_index=index, name=f"Relay {index}", address_scheme=self.scheme,
        )

    def _url(self, suffix):
        return f"/manage/apartments/{self.apartment.pk}/{suffix}/"

    # ── custom devices in the live API ─────────────────────────────────────

    def test_custom_devices_appear_in_state_and_device_list(self):
        light = self._add_light(0)
        auth = {"HTTP_AUTHORIZATION": f"Bearer {self._token('bc_member')}"}
        state = self.client.get("/plc/state/", **auth).json()
        self.assertIn(str(light.pk), state["custom"])
        self.assertEqual(state["poll_interval_s"], 1)
        devices = self.client.get("/plc/devices/", **auth).json()
        self.assertEqual([d["apartment_device_id"] for d in devices["custom"]], [light.pk])

    def test_custom_device_write_endpoint_round_trips(self):
        light = self._add_light(0)
        auth = {"HTTP_AUTHORIZATION": f"Bearer {self._token('bc_member')}"}
        resp = self.client.post(f"/plc/custom/{light.pk}/", {"state": "true"}, **auth)
        self.assertEqual(resp.status_code, 200)
        state = self.client.get("/plc/state/", **auth).json()
        self.assertIs(state["custom"][str(light.pk)], True)

    # ── building settings ──────────────────────────────────────────────────

    def test_building_settings_is_staff_only(self):
        resp = self.client.get(self._url("building-settings"),
                               HTTP_AUTHORIZATION=f"Bearer {self._token('bc_member')}")
        self.assertEqual(resp.status_code, 403)

    def test_building_settings_patch_persists_and_reaches_state(self):
        auth = {"HTTP_AUTHORIZATION": f"Bearer {self._token('bc_staff')}"}
        resp = self.client.patch(
            self._url("building-settings"),
            {"auto_sunset_sunrise": False, "sunset_override_time": "18:30",
             "sunrise_override_time": "06:30", "poll_interval_s": 5},
            content_type="application/json", **auth,
        )
        self.assertEqual(resp.status_code, 200)
        s = resp.json()["settings"]
        self.assertEqual((s["auto_sunset_sunrise"], s["sunset_override_time"],
                          s["sunrise_override_time"], s["poll_interval_s"]),
                         (False, "18:30", "06:30", 5))
        self.assertEqual(self.client.get("/plc/state/", **auth).json()["poll_interval_s"], 5)

    def test_building_settings_rejects_bad_input(self):
        auth = {"HTTP_AUTHORIZATION": f"Bearer {self._token('bc_staff')}"}
        for body in ({"sunset_override_time": "25:99"}, {"poll_interval_s": 0}, {"poll_interval_s": 61}):
            resp = self.client.patch(self._url("building-settings"), body,
                                     content_type="application/json", **auth)
            self.assertEqual(resp.status_code, 400, body)
        self.apartment.refresh_from_db()
        self.assertEqual(self.apartment.poll_interval_s, 1)

    # ── Christmas mode ─────────────────────────────────────────────────────

    def test_christmas_mode_refuses_when_there_are_no_lights(self):
        resp = self.client.post(self._url("christmas-mode"), {"active": True},
                                content_type="application/json",
                                HTTP_AUTHORIZATION=f"Bearer {self._token('bc_staff')}")
        self.assertEqual(resp.status_code, 409)
        self.apartment.refresh_from_db()
        self.assertFalse(self.apartment.christmas_mode_active)

    def test_christmas_mode_start_then_stop(self):
        import time
        from find_device import lighting_effects
        self._add_light(0)
        self._add_light(1)
        auth = {"HTTP_AUTHORIZATION": f"Bearer {self._token('bc_staff')}"}
        try:
            resp = self.client.post(self._url("christmas-mode"), {"active": True},
                                    content_type="application/json", **auth)
            self.assertEqual(resp.status_code, 200)
            self.apartment.refresh_from_db()
            self.assertTrue(self.apartment.christmas_mode_active)
            self.assertTrue(lighting_effects.is_running(self.apartment.pk))

            resp = self.client.post(self._url("christmas-mode"), {"active": False},
                                    content_type="application/json", **auth)
            self.assertEqual(resp.status_code, 200)
            self.apartment.refresh_from_db()
            self.assertFalse(self.apartment.christmas_mode_active)
            deadline = time.time() + 3
            while lighting_effects.is_running(self.apartment.pk) and time.time() < deadline:
                time.sleep(0.05)
            self.assertFalse(lighting_effects.is_running(self.apartment.pk))
        finally:
            lighting_effects.stop_christmas_chase(self.apartment.pk)

    # ── sunset / sunrise override job ──────────────────────────────────────

    def test_lights_should_be_on_handles_overnight_wrap(self):
        from datetime import time as t
        from find_device.tasks import lights_should_be_on
        sunset, sunrise = t(18, 30), t(6, 30)
        self.assertTrue(lights_should_be_on(t(20, 0), sunset, sunrise))
        self.assertTrue(lights_should_be_on(t(2, 0), sunset, sunrise))
        self.assertFalse(lights_should_be_on(t(12, 0), sunset, sunrise))
        self.assertFalse(lights_should_be_on(t(6, 30), sunset, sunrise))
        self.assertTrue(lights_should_be_on(t(18, 30), sunset, sunrise))

    def _override(self, **extra):
        from datetime import time as t
        Apartment.objects.filter(pk=self.apartment.pk).update(
            auto_sunset_sunrise=False, sunset_override_time=t(18, 30),
            sunrise_override_time=t(6, 30), **extra,
        )

    def test_override_job_switches_lights_for_the_current_window(self):
        from datetime import time as t
        from find_device.tasks import apply_sunset_sunrise_overrides_once
        light = self._add_light(0)
        self._override()
        dev = DeviceRegistry.for_apartment(self.apartment.pk).templated(light.pk)
        apply_sunset_sunrise_overrides_once(now=t(20, 0))
        self.assertIs(dev.read(), True)
        apply_sunset_sunrise_overrides_once(now=t(12, 0))
        self.assertIs(dev.read(), False)

    def test_override_job_leaves_automatic_and_christmas_apartments_alone(self):
        from datetime import time as t
        from find_device.tasks import apply_sunset_sunrise_overrides_once
        light = self._add_light(0)
        dev = DeviceRegistry.for_apartment(self.apartment.pk).templated(light.pk)
        apply_sunset_sunrise_overrides_once(now=t(20, 0))       # auto on (default)
        self.assertIs(dev.read(), False)
        self._override(christmas_mode_active=True)
        apply_sunset_sunrise_overrides_once(now=t(20, 0))       # the show owns the lights
        self.assertIs(dev.read(), False)
