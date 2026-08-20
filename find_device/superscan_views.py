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

from django.http import JsonResponse
from django.shortcuts import get_object_or_404
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import IsAdminUser

from .models import Apartment, ScanRun, DiscoveredCapability
from .permissions import log_action
from .superscan import start_scan, ScanAlreadyRunning


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
