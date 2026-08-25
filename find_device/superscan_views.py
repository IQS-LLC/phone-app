"""
SuperScan API — Tech Team only (IsAdminUser), same bar as commissioning_views
and relabel_views. No-code discovery/capability-mapping tool; per project
convention this kind of tooling must be invisible (not just gated) to any
non-IT-Team role on the Flutter side.

  POST /superscan/<apartment_id>/start/                 body: {mode}
  POST /superscan/<apartment_id>/runs/<scan_id>/stop/    STOP SCAN
  GET  /superscan/<apartment_id>/runs/<scan_id>/         poll one run's status/progress
  GET  /superscan/<apartment_id>/runs/                   run history (dashboard summary strip)
  GET  /superscan/<apartment_id>/capabilities/           capability list (dashboard, filterable)
  GET  /superscan/<apartment_id>/capabilities/<cap_id>/  drill-down: capability + its test logs
"""
from __future__ import annotations

import logging

from django.http import JsonResponse
from django.shortcuts import get_object_or_404
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import IsAdminUser

from .models import Apartment, ApartmentDevice, DeviceAddressScheme, Room, ScanRun, DiscoveredCapability
from .permissions import log_action
from .plc.registry import DeviceRegistry
from .superscan import start_scan, ScanAlreadyRunning

logger = logging.getLogger(__name__)


def _ok(**kwargs):
    return JsonResponse({"ok": True, **kwargs})


def _err(msg, status=400):
    return JsonResponse({"ok": False, "error": msg}, status=status)


def _run_dict(run: ScanRun) -> dict:
    return {
        "id": run.pk,
        "mode": run.mode,
        "status": run.status,
        "started_by": run.started_by.username if run.started_by_id else None,
        "started_at": run.started_at.isoformat(),
        "finished_at": run.finished_at.isoformat() if run.finished_at else None,
        "cancel_requested": run.cancel_requested,
        "progress_current": run.progress_current,
        "progress_total": run.progress_total,
        "progress_label": run.progress_label,
        "devices_discovered": run.devices_discovered,
        "capabilities_discovered": run.capabilities_discovered,
        "capabilities_tested": run.capabilities_tested,
        "tests_passed": run.tests_passed,
        "tests_failed": run.tests_failed,
        "unknown_count": run.unknown_count,
        "new_since_last": run.new_since_last,
        "changed_since_last": run.changed_since_last,
        "removed_since_last": run.removed_since_last,
        "error_message": run.error_message,
    }


# ── Start / stop ────────────────────────────────────────────────────────────

@api_view(["POST"])
@permission_classes([IsAdminUser])
def start(request, apartment_id):
    apt = get_object_or_404(Apartment, pk=apartment_id)

    mode = request.data.get("mode", ScanRun.MODE_QUICK)
    if mode not in dict(ScanRun.MODE_CHOICES):
        return _err(f"Invalid mode. Choose one of: {', '.join(dict(ScanRun.MODE_CHOICES))}")

    # Fast-path check for the common case (nice 409 without touching the
    # DB constraint's error path). Not the actual safety guarantee — see
    # ScanRun.Meta.constraints for why an .exists() check alone can't
    # close the race between two concurrent start requests.
    if ScanRun.objects.filter(apartment=apt, status=ScanRun.STATUS_RUNNING).exists():
        return _err("A SuperScan is already running for this apartment.", status=409)

    try:
        run = start_scan(apt, mode, request.user)
    except ScanAlreadyRunning:
        return _err("A SuperScan is already running for this apartment.", status=409)

    log_action(request, "superscan_start", apartment=apt, mode=mode, scan_run_id=run.pk)
    return _ok(run=_run_dict(run))


@api_view(["POST"])
@permission_classes([IsAdminUser])
def stop(request, apartment_id, scan_id):
    run = get_object_or_404(ScanRun, pk=scan_id, apartment_id=apartment_id)
    if run.status != ScanRun.STATUS_RUNNING:
        return _err("This scan is not running.", status=400)
    run.cancel_requested = True
    run.save(update_fields=["cancel_requested"])
    log_action(request, "superscan_stop", apartment_id=apartment_id, scan_run_id=run.pk)
    return _ok(run=_run_dict(run))


# ── Status / history ─────────────────────────────────────────────────────────

@api_view(["GET"])
@permission_classes([IsAdminUser])
def run_status(request, apartment_id, scan_id):
    run = get_object_or_404(ScanRun, pk=scan_id, apartment_id=apartment_id)
    return _ok(run=_run_dict(run))


@api_view(["GET"])
@permission_classes([IsAdminUser])
def run_list(request, apartment_id):
    runs = ScanRun.objects.filter(apartment_id=apartment_id)[:20]
    return _ok(runs=[_run_dict(r) for r in runs])


# ── Capability dashboard ─────────────────────────────────────────────────────

@api_view(["GET"])
@permission_classes([IsAdminUser])
def capability_list(request, apartment_id):
    """
    Query params:
      device_type   filter, e.g. dali / relay / unknown_symbol / ...
      direction     input | output | both
      test_status   not_tested | observed | tested_ok | tested_failed
      known         true | false — is_known_type filter
      present       true | false — still_present filter (default true)
    """
    qs = DiscoveredCapability.objects.filter(apartment_id=apartment_id)

    if dt := request.query_params.get("device_type"):
        qs = qs.filter(device_type=dt)
    if direction := request.query_params.get("direction"):
        qs = qs.filter(direction=direction)
    if ts := request.query_params.get("test_status"):
        qs = qs.filter(test_status=ts)
    if known := request.query_params.get("known"):
        qs = qs.filter(is_known_type=known.lower() == "true")
    present = request.query_params.get("present", "true")
    if present.lower() != "all":
        qs = qs.filter(still_present=present.lower() == "true")

    caps = list(qs)
    summary = {
        "total": len(caps),
        "known": sum(1 for c in caps if c.is_known_type),
        "unknown": sum(1 for c in caps if not c.is_known_type),
        "tested_ok": sum(1 for c in caps if c.test_status == DiscoveredCapability.TEST_PASSED),
        "tested_failed": sum(1 for c in caps if c.test_status == DiscoveredCapability.TEST_FAILED),
        "unavailable": sum(1 for c in caps if c.test_status == DiscoveredCapability.TEST_UNAVAILABLE),
        "observed_only": sum(1 for c in caps if c.test_status == DiscoveredCapability.TEST_OBSERVED),
        "not_tested": sum(1 for c in caps if c.test_status == DiscoveredCapability.TEST_NOT_TESTED),
        "stale": sum(1 for c in caps if c.confidence == "low"),
    }
    return _ok(capabilities=[c.to_dict() for c in caps], summary=summary)


@api_view(["GET"])
@permission_classes([IsAdminUser])
def capability_detail(request, apartment_id, cap_id):
    cap = get_object_or_404(DiscoveredCapability, pk=cap_id, apartment_id=apartment_id)
    logs = cap.test_logs.all()[:50]
    return _ok(capability=cap.to_dict(), test_logs=[l.to_dict() for l in logs])


# ── Promote: DiscoveredCapability -> a real, controllable ApartmentDevice ───

# The 2026-08-24 bridge closing the gap docs/AUDIT_FINDINGS.md §1 describes:
# SuperScan discovers and classifies symbols dynamically, but that knowledge
# never used to reach DeviceRegistry — an installer had to already know the
# right ApartmentDevice/gvl_name mapping by hand. This endpoint creates that
# ApartmentDevice (+ a DeviceAddressScheme, unless an existing one is
# reused) directly from what SuperScan already discovered.
#
# Deliberately the simple case only: treats raw_var_name as one fixed
# scalar symbol (no {index}/{gvl_name} templating, no commit-pulse
# variable) — correct for a plain read/write point, not for an indexed
# array or a write-then-pulse-commit GVL. A capability needing either of
# those still needs a hand-built DeviceAddressScheme (Django admin) or a
# real devices.py class, same as before this endpoint existed.
@api_view(["POST"])
@permission_classes([IsAdminUser])
def promote_capability(request, apartment_id, cap_id):
    """
    Body (all optional except when noted):
      room_id      int  — Room to assign; omitted/null leaves it unassigned
      name         str  — display name; defaults to the capability's own name/identifier
      device_type  str  — one of ApartmentDevice.TYPE_CHOICES; defaults to "custom"
      scheme_name  str  — reuse an existing DeviceAddressScheme by name instead of
                           creating a new one (e.g. a second symbol on the same GVL/type)
    """
    apt = get_object_or_404(Apartment, pk=apartment_id)
    cap = get_object_or_404(DiscoveredCapability, pk=cap_id, apartment_id=apartment_id)

    if cap.apartment_device_id:
        return _err("This capability is already linked to an ApartmentDevice.", status=409)
    if not cap.raw_var_name:
        return _err("This capability has no raw_var_name to build an address scheme from — "
                     "promotion only works for a real scanned symbol.", status=400)

    room = None
    if room_id := request.data.get("room_id"):
        room = get_object_or_404(Room, pk=room_id, apartment=apt)

    name = request.data.get("name") or cap.name or cap.identifier
    device_type = request.data.get("device_type") or ApartmentDevice.TYPE_CUSTOM
    if device_type not in dict(ApartmentDevice.TYPE_CHOICES):
        return _err(f"Invalid device_type. Choose one of: {', '.join(dict(ApartmentDevice.TYPE_CHOICES))}")

    scheme_name = request.data.get("scheme_name")
    if scheme_name:
        scheme = get_object_or_404(DeviceAddressScheme, name=scheme_name)
    else:
        gvl = cap.raw_var_name.split(".", 1)[0] if "." in cap.raw_var_name else cap.raw_var_name
        plc_type = (cap.data_type or "BOOL").upper()
        if plc_type not in dict(DeviceAddressScheme.PLC_TYPE_CHOICES):
            return _err(
                f"Discovered data_type '{cap.data_type}' doesn't match a known PLC "
                f"type ({', '.join(dict(DeviceAddressScheme.PLC_TYPE_CHOICES))}) — "
                "promote with an explicit scheme_name pointing at a manually-created "
                "DeviceAddressScheme instead.", status=400,
            )
        scheme, _ = DeviceAddressScheme.objects.get_or_create(
            name=f"promoted_{cap.raw_var_name}",
            defaults=dict(
                description=f"Auto-created by promoting capability #{cap.pk} "
                            f"({cap.raw_var_name}) on {apt.name}.",
                gvl=gvl,
                read_var_template=cap.raw_var_name,
                write_var_template=cap.raw_var_name,
                plc_type=plc_type,
                protocol=DeviceAddressScheme.PROTOCOL_ADS,
            ),
        )

    device = ApartmentDevice.objects.create(
        apartment=apt, room=room, device_type=device_type,
        name=name, address_scheme=scheme,
    )
    cap.apartment_device = device
    cap.save(update_fields=["apartment_device"])

    # Unlike relabel_views.py's assign_output_channel/assign_input, a
    # promoted capability can be any device_type (including a
    # DeviceAddressScheme-backed TemplatedDevice) — no single hot-add call
    # covers every case, so re-sync the whole registry from the DB instead.
    # Never let this block the response: the device row is already
    # committed, and the next poll would pick it up anyway if this raced
    # with a concurrent restart.
    try:
        DeviceRegistry.for_apartment(apartment_id).refresh_devices()
    except Exception:
        logger.exception("promote_capability: failed to hot-reload registry (will pick up on next restart)")

    log_action(request, "promote_capability", apartment=apt,
               capability_id=cap.pk, raw_var_name=cap.raw_var_name, device_id=device.pk)

    return _ok(device_id=device.pk, address_scheme=scheme.name, capability=cap.to_dict())
