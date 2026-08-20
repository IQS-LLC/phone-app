"""
Automations API — "when this input does X, do Y to that output," defined
entirely on the phone, no TwinCAT/ST code involved.

is_staff (IT Team) ONLY — same bar as relabel_views.py: an automation rule
IS the "no more hand-written PLC code" capability, and per
[[project_role_hierarchy_redesign]] that stays invisible to everyone else,
including Building Owner.

Execution lives in find_device/plc/registry.py (DeviceRegistry subscribes
each enabled rule's trigger to an ADS push notification — instant,
event-driven, not polled — via NotificationManager and writes the action
the moment the trigger matches). This module is just the CRUD surface;
rules only take effect once the registry (re)loads them, which every
create/update/delete call here triggers immediately.

  GET    /automations/<apt_id>/rules/            list rules + eligible trigger/action devices
  POST   /automations/<apt_id>/rules/            create a rule
  PATCH  /automations/<apt_id>/rules/<rule_id>/  update a rule
  DELETE /automations/<apt_id>/rules/<rule_id>/  delete a rule
"""
from __future__ import annotations

import logging

from rest_framework.decorators import api_view
from rest_framework.response import Response

from .models import Apartment, ApartmentDevice, AutomationRule
from .permissions import has_relabel_access, log_action
from .plc.registry import DeviceRegistry, NAMED_RELAY_READONLY

logger = logging.getLogger("lumina.automations")


def _ok(**kwargs):
    return Response({"ok": True, **kwargs})


def _err(msg, status=400):
    return Response({"ok": False, "error": msg}, status=status)


def _forbidden_unless_allowed(request, apartment_id):
    if not request.user or not request.user.is_authenticated:
        return _err("Authentication required", status=401)
    if not has_relabel_access(request.user, apartment_id):
        return _err("You don't have permission to manage automations in this apartment", status=403)
    return None


def _is_writable_action(d: ApartmentDevice) -> bool:
    """gvlDALI.bventiliatorRelay (and any future read-only NamedRelay) is
    overwritten every PLC scan by its sensor — see registry.
    NAMED_RELAY_READONLY. Writing to it as an automation action would
    silently no-op, so it must never be offered or accepted as one."""
    if d.device_type == ApartmentDevice.TYPE_TOGGLE:
        return d.gvl_name not in NAMED_RELAY_READONLY
    return True


def _device_summary(d: ApartmentDevice) -> dict:
    return {
        "id": d.pk, "name": d.name, "device_type": d.device_type,
        "channel_or_index": d.channel_or_index,
        "gvl_name": d.gvl_name or None,
        "room_name": d.room.name if d.room_id else None,
    }


def _rule_summary(r: AutomationRule) -> dict:
    return {
        "id": r.pk,
        "name": r.name,
        "enabled": r.enabled,
        "trigger_device": _device_summary(r.trigger_device),
        "trigger_state": r.trigger_state,
        "action_device": _device_summary(r.action_device),
        "action_value": r.action_value,
    }


def _validate_action_value(device_type: str, value: str) -> str | None:
    """Returns an error message, or None if valid."""
    value = (value or "").strip().lower()
    if device_type == ApartmentDevice.TYPE_DALI:
        try:
            pct = int(value)
        except ValueError:
            return "action_value must be an integer 0-100 for a DALI action"
        if not 0 <= pct <= 100:
            return "action_value must be 0-100 for a DALI action"
    elif device_type in (ApartmentDevice.TYPE_RELAY, ApartmentDevice.TYPE_APPLIANCE,
                          ApartmentDevice.TYPE_TOGGLE):
        if value not in ("true", "false"):
            return "action_value must be 'true' or 'false' for this action"
    elif device_type == ApartmentDevice.TYPE_CURTAIN:
        if value not in ("stop", "up", "down"):
            return "action_value must be 'stop', 'up', or 'down' for a curtain action"
    return None


@api_view(["GET", "POST"])
def rule_list(request, apartment_id):
    denied = _forbidden_unless_allowed(request, apartment_id)
    if denied:
        return denied

    apartment = Apartment.objects.filter(pk=apartment_id).first()
    if apartment is None:
        return _err("Apartment not found", status=404)

    if request.method == "POST":
        return _create_rule(request, apartment)

    rules = AutomationRule.objects.filter(apartment=apartment).select_related(
        "trigger_device", "trigger_device__room", "action_device", "action_device__room",
    )
    triggers = ApartmentDevice.objects.filter(
        apartment=apartment, device_type__in=AutomationRule.TRIGGER_TYPES,
    ).select_related("room")
    actions = [
        d for d in ApartmentDevice.objects.filter(
            apartment=apartment, device_type__in=AutomationRule.ACTION_TYPES,
        ).select_related("room")
        if _is_writable_action(d)
    ]

    return _ok(
        rules=[_rule_summary(r) for r in rules],
        triggers=[_device_summary(d) for d in triggers],
        actions=[_device_summary(d) for d in actions],
    )


def _create_rule(request, apartment):
    name = (request.data.get("name") or "").strip()
    if not name:
        return _err("name is required", status=400)

    trigger_device_id = request.data.get("trigger_device_id")
    action_device_id = request.data.get("action_device_id")
    if not trigger_device_id or not action_device_id:
        return _err("trigger_device_id and action_device_id are required", status=400)

    trigger_device = ApartmentDevice.objects.filter(
        pk=trigger_device_id, apartment=apartment, device_type__in=AutomationRule.TRIGGER_TYPES,
    ).first()
    if trigger_device is None:
        return _err("trigger_device_id must be a switch or sensor in this apartment", status=400)

    action_device = ApartmentDevice.objects.filter(
        pk=action_device_id, apartment=apartment, device_type__in=AutomationRule.ACTION_TYPES,
    ).first()
    if action_device is None:
        return _err("action_device_id must be a light, relay, curtain, or appliance in this apartment", status=400)
    if not _is_writable_action(action_device):
        return _err(
            f"'{action_device.name}' is sensor-driven in the PLC and can't be "
            f"controlled remotely, so it can't be used as an automation action",
            status=400,
        )

    trigger_state_raw = request.data.get("trigger_state")
    trigger_state = str(trigger_state_raw).strip().lower() in ("true", "1")

    action_value = str(request.data.get("action_value") or "")
    value_error = _validate_action_value(action_device.device_type, action_value)
    if value_error:
        return _err(value_error, status=400)

    rule = AutomationRule.objects.create(
        apartment=apartment, name=name, enabled=True,
        trigger_device=trigger_device, trigger_state=trigger_state,
        action_device=action_device, action_value=action_value.strip().lower(),
        created_by=request.user,
    )

    try:
        DeviceRegistry.for_apartment(apartment.pk).reload_automation(rule.pk)
    except Exception:
        logger.exception("rule_list: failed to hot-load automation %s", rule.pk)

    log_action(request, "automation_created", apartment=apartment, reason=name)
    return _ok(rule=_rule_summary(rule))


@api_view(["PATCH", "DELETE"])
def rule_detail(request, apartment_id, rule_id):
    denied = _forbidden_unless_allowed(request, apartment_id)
    if denied:
        return denied

    rule = AutomationRule.objects.filter(pk=rule_id, apartment_id=apartment_id).select_related(
        "trigger_device", "action_device",
    ).first()
    if rule is None:
        return _err("Automation not found", status=404)

    if request.method == "DELETE":
        name = rule.name
        rule.delete()
        try:
            DeviceRegistry.for_apartment(apartment_id).remove_automation(rule_id)
        except Exception:
            logger.exception("rule_detail: failed to unload deleted automation %s", rule_id)
        log_action(request, "automation_deleted", apartment_id=apartment_id, reason=name)
        return _ok(message=f"Deleted '{name}'")

    if "name" in request.data:
        name = str(request.data["name"]).strip()
        if not name:
            return _err("name cannot be empty", status=400)
        rule.name = name
    if "enabled" in request.data:
        rule.enabled = str(request.data["enabled"]).strip().lower() in ("true", "1")
    if "trigger_state" in request.data:
        rule.trigger_state = str(request.data["trigger_state"]).strip().lower() in ("true", "1")
    if "action_value" in request.data:
        action_value = str(request.data["action_value"])
        value_error = _validate_action_value(rule.action_device.device_type, action_value)
        if value_error:
            return _err(value_error, status=400)
        rule.action_value = action_value.strip().lower()
    rule.save()

    try:
        registry = DeviceRegistry.for_apartment(apartment_id)
        if rule.enabled:
            registry.reload_automation(rule.pk)
        else:
            registry.remove_automation(rule.pk)
    except Exception:
        logger.exception("rule_detail: failed to reload automation %s", rule_id)

    log_action(request, "automation_updated", apartment_id=apartment_id, reason=rule.name)
    return _ok(rule=_rule_summary(rule))
