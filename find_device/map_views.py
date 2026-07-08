"""
Digital Twin Map Editor — REST API.

Permission model
────────────────
GET  /map/<apt_id>/            Authenticated apartment member (resident can read published layout)
PUT  /map/<apt_id>/            Staff only (Tech Team editor save)
POST /map/<apt_id>/            Staff only (create initial layout)
POST /map/<apt_id>/background/ Staff only (upload background image URL)
GET  /map/<apt_id>/versions/   Staff only
POST /map/<apt_id>/publish/    Staff only
POST /map/<apt_id>/versions/<v>/restore/ Staff only
GET  /map/apartments/          Staff only  (list all apartments for editor picker)
"""

import json
import os

from django.http import JsonResponse
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_http_methods
from django.utils import timezone

from rest_framework.permissions import IsAuthenticated, IsAdminUser
from rest_framework.decorators import api_view, permission_classes

from .models import (
    Apartment, ApartmentMembership, ApartmentDevice, Room,
    MapLayout, MapLayer, CanvasObject, MapVersion,
)


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

def _ok(**kwargs):
    return JsonResponse({"ok": True, **kwargs})

def _err(msg, status=400):
    return JsonResponse({"ok": False, "error": msg}, status=status)

def _is_member(user, apartment):
    """True if user belongs to the apartment (any role) or is staff."""
    if user.is_staff:
        return True
    return ApartmentMembership.objects.filter(user=user, apartment=apartment).exists()


def _layout_dict(layout):
    layers = list(layout.layers.values(
        "id", "name", "layer_type", "visible", "locked", "sort_order",
    ))
    objects = [obj.to_dict() for obj in layout.objects.select_related("layer", "room", "apartment_device")]
    return {
        "id":                 layout.pk,
        "apartment_id":       layout.apartment_id,
        "apartment_name":     layout.apartment.name,
        "canvas_width":       layout.canvas_width,
        "canvas_height":      layout.canvas_height,
        "background_url":     layout.background_url,
        "background_x":       layout.background_x,
        "background_y":       layout.background_y,
        "background_width":   layout.background_width,
        "background_height":  layout.background_height,
        "background_rotation":layout.background_rotation,
        "background_opacity": layout.background_opacity,
        "background_locked":  layout.background_locked,
        "background_visible": layout.background_visible,
        "is_published":       layout.is_published,
        "published_at":       layout.published_at.isoformat() if layout.published_at else None,
        "updated_at":         layout.updated_at.isoformat(),
        "layers":             layers,
        "objects":            objects,
    }


def _create_default_layers(layout):
    """Seed the standard layer set on first layout creation."""
    for name, layer_type, sort_order in MapLayer.DEFAULT_LAYERS:
        MapLayer.objects.create(
            layout=layout, name=name, layer_type=layer_type, sort_order=sort_order,
        )


# ─────────────────────────────────────────────────────────────────────────────
# Apartment picker (Tech Team)
# ─────────────────────────────────────────────────────────────────────────────

@api_view(["GET"])
@permission_classes([IsAdminUser])
def apartment_list(request):
    """List all apartments with their map layout status for the editor picker."""
    apts = Apartment.objects.prefetch_related("map_layout").order_by("name")
    result = []
    for a in apts:
        try:
            ml = a.map_layout
            has_layout   = True
            is_published = ml.is_published
            object_count = ml.objects.count()
        except MapLayout.DoesNotExist:
            has_layout   = False
            is_published = False
            object_count = 0
        result.append({
            "id":           a.pk,
            "name":         a.name,
            "building":     a.building,
            "floor":        a.floor,
            "has_layout":   has_layout,
            "is_published": is_published,
            "object_count": object_count,
        })
    return _ok(apartments=result)


# ─────────────────────────────────────────────────────────────────────────────
# Layout CRUD
# ─────────────────────────────────────────────────────────────────────────────

@api_view(["GET", "POST", "PUT"])
@permission_classes([IsAuthenticated])
def layout(request, apartment_id):
    try:
        apartment = Apartment.objects.get(pk=apartment_id)
    except Apartment.DoesNotExist:
        return _err("Apartment not found", 404)

    if not _is_member(request.user, apartment):
        return _err("Not a member of this apartment", 403)

    # ── GET: any authenticated member reads the layout ──────────────────────
    if request.method == "GET":
        try:
            ml = MapLayout.objects.prefetch_related("layers", "objects").get(apartment=apartment)
        except MapLayout.DoesNotExist:
            return _ok(layout=None)
        return _ok(layout=_layout_dict(ml))

    # ── POST / PUT: staff only ───────────────────────────────────────────────
    if not request.user.is_staff:
        return _err("Tech Team access required", 403)

    try:
        data = json.loads(request.body)
    except (json.JSONDecodeError, ValueError):
        return _err("Invalid JSON body")

    # POST = create if absent, PUT = update
    if request.method == "POST":
        ml, created = MapLayout.objects.get_or_create(
            apartment=apartment,
            defaults={"created_by": request.user},
        )
        if created:
            _create_default_layers(ml)
    else:  # PUT
        ml, created = MapLayout.objects.get_or_create(
            apartment=apartment,
            defaults={"created_by": request.user},
        )
        if created:
            _create_default_layers(ml)

    # Update canvas / background settings if provided
    canvas_fields = [
        "canvas_width", "canvas_height",
        "background_url", "background_x", "background_y",
        "background_width", "background_height", "background_rotation",
        "background_opacity", "background_locked", "background_visible",
    ]
    changed = False
    for f in canvas_fields:
        if f in data:
            setattr(ml, f, data[f])
            changed = True

    # Bulk-replace layers if provided
    if "layers" in data:
        existing_ids = set(ml.layers.values_list("id", flat=True))
        seen_ids = set()
        for ld in data["layers"]:
            lid = ld.get("id")
            if lid and lid in existing_ids:
                MapLayer.objects.filter(pk=lid, layout=ml).update(
                    name=ld.get("name", "Layer"),
                    layer_type=ld.get("layer_type", "labels"),
                    visible=ld.get("visible", True),
                    locked=ld.get("locked", False),
                    sort_order=ld.get("sort_order", 0),
                )
                seen_ids.add(lid)
            else:
                new_layer = MapLayer.objects.create(
                    layout=ml,
                    name=ld.get("name", "Layer"),
                    layer_type=ld.get("layer_type", "labels"),
                    visible=ld.get("visible", True),
                    locked=ld.get("locked", False),
                    sort_order=ld.get("sort_order", 0),
                )
                seen_ids.add(new_layer.pk)
        # Delete layers not in the new set
        ml.layers.exclude(pk__in=seen_ids).delete()
        changed = True

    # Bulk-replace objects if provided
    if "objects" in data:
        # Build a lookup from layer name → layer id for convenience
        layer_map = {l.pk: l for l in ml.layers.all()}
        # Delete all existing and re-create (simpler than diff for bulk save)
        ml.objects.all().delete()
        for i, od in enumerate(data["objects"]):
            layer_id = od.get("layer_id")
            layer    = layer_map.get(layer_id)
            apt_dev_id = od.get("apartment_device_id")
            room_id    = od.get("room_id")
            CanvasObject.objects.create(
                layout=ml,
                layer=layer,
                object_type=od.get("object_type", "device"),
                device_type=od.get("device_type", ""),
                name=od.get("name", ""),
                x=od.get("x", 100),
                y=od.get("y", 100),
                width=od.get("width", 48),
                height=od.get("height", 48),
                rotation=od.get("rotation", 0),
                plc_variable=od.get("plc_variable", ""),
                apartment_device_id=apt_dev_id,
                room_id=room_id,
                color=od.get("color", ""),
                label_visible=od.get("label_visible", True),
                group_id=od.get("group_id", ""),
                properties=od.get("properties", {}),
                sort_order=i,
            )
        changed = True

    if changed:
        ml.save()

    return _ok(layout=_layout_dict(ml))


# ─────────────────────────────────────────────────────────────────────────────
# Background image URL
# ─────────────────────────────────────────────────────────────────────────────

@api_view(["POST", "DELETE"])
@permission_classes([IsAdminUser])
def background(request, apartment_id):
    try:
        ml = MapLayout.objects.get(apartment_id=apartment_id)
    except MapLayout.DoesNotExist:
        return _err("Layout not found — create layout first", 404)

    if request.method == "DELETE":
        ml.background_url = ""
        ml.save(update_fields=["background_url", "updated_at"])
        return _ok(message="Background removed")

    # POST — accept either JSON {"url": "..."} or multipart file
    if request.content_type and "multipart" in request.content_type:
        f = request.FILES.get("file")
        if not f:
            return _err("No file in request")
        from django.conf import settings as django_settings
        import uuid
        media_root = getattr(django_settings, "MEDIA_ROOT", "/app/media")
        media_url  = getattr(django_settings, "MEDIA_URL", "/media/")
        os.makedirs(os.path.join(media_root, "map_backgrounds"), exist_ok=True)
        ext      = os.path.splitext(f.name)[1].lower()
        filename = f"map_backgrounds/{uuid.uuid4().hex}{ext}"
        dest     = os.path.join(media_root, filename)
        with open(dest, "wb") as fh:
            for chunk in f.chunks():
                fh.write(chunk)
        url = f"{media_url}{filename}"
    else:
        try:
            data = json.loads(request.body)
        except (json.JSONDecodeError, ValueError):
            return _err("Invalid JSON body")
        url = data.get("url", "")

    if not url:
        return _err("No URL provided")

    ml.background_url = url
    ml.save(update_fields=["background_url", "updated_at"])
    return _ok(url=url)


# ─────────────────────────────────────────────────────────────────────────────
# Publish / versioning
# ─────────────────────────────────────────────────────────────────────────────

@api_view(["POST"])
@permission_classes([IsAdminUser])
def publish(request, apartment_id):
    try:
        ml = MapLayout.objects.get(apartment_id=apartment_id)
    except MapLayout.DoesNotExist:
        return _err("Layout not found", 404)

    try:
        data = json.loads(request.body) if request.body else {}
    except (json.JSONDecodeError, ValueError):
        data = {}
    description = data.get("description", "")

    snapshot = [obj.to_dict() for obj in ml.objects.all()]
    last = MapVersion.objects.filter(layout=ml).order_by("-version_number").first()
    version_number = (last.version_number + 1) if last else 1

    # Mark any previous published version as not published
    MapVersion.objects.filter(layout=ml, is_published=True).update(is_published=False)

    v = MapVersion.objects.create(
        layout=ml,
        version_number=version_number,
        snapshot=snapshot,
        created_by=request.user,
        description=description,
        is_published=True,
    )
    ml.is_published  = True
    ml.published_at  = timezone.now()
    ml.save(update_fields=["is_published", "published_at", "updated_at"])

    return _ok(version={
        "id":             v.pk,
        "version_number": v.version_number,
        "description":    v.description,
        "created_at":     v.created_at.isoformat(),
        "is_published":   v.is_published,
    })


@api_view(["GET"])
@permission_classes([IsAdminUser])
def version_list(request, apartment_id):
    try:
        ml = MapLayout.objects.get(apartment_id=apartment_id)
    except MapLayout.DoesNotExist:
        return _ok(versions=[])

    versions = []
    for v in ml.versions.all():
        versions.append({
            "id":             v.pk,
            "version_number": v.version_number,
            "description":    v.description,
            "created_at":     v.created_at.isoformat(),
            "created_by":     v.created_by.username if v.created_by else None,
            "is_published":   v.is_published,
            "object_count":   len(v.snapshot) if isinstance(v.snapshot, list) else 0,
        })
    return _ok(versions=versions)


@api_view(["POST"])
@permission_classes([IsAdminUser])
def version_restore(request, apartment_id, version_id):
    try:
        ml = MapLayout.objects.get(apartment_id=apartment_id)
    except MapLayout.DoesNotExist:
        return _err("Layout not found", 404)

    try:
        v = MapVersion.objects.get(pk=version_id, layout=ml)
    except MapVersion.DoesNotExist:
        return _err("Version not found", 404)

    snapshot = v.snapshot
    layer_map = {l.pk: l for l in ml.layers.all()}

    ml.objects.all().delete()
    for od in (snapshot if isinstance(snapshot, list) else []):
        layer_id = od.get("layer_id")
        layer    = layer_map.get(layer_id)
        CanvasObject.objects.create(
            layout=ml,
            layer=layer,
            object_type=od.get("object_type", "device"),
            device_type=od.get("device_type", ""),
            name=od.get("name", ""),
            x=od.get("x", 100),
            y=od.get("y", 100),
            width=od.get("width", 48),
            height=od.get("height", 48),
            rotation=od.get("rotation", 0),
            plc_variable=od.get("plc_variable", ""),
            apartment_device_id=od.get("apartment_device_id"),
            room_id=od.get("room_id"),
            color=od.get("color", ""),
            label_visible=od.get("label_visible", True),
            group_id=od.get("group_id", ""),
            properties=od.get("properties", {}),
            sort_order=od.get("sort_order", 0),
        )
    ml.save(update_fields=["updated_at"])

    return _ok(message=f"Restored to version {v.version_number}", layout=_layout_dict(ml))


# ─────────────────────────────────────────────────────────────────────────────
# Available ApartmentDevices for PLC linking (picker in properties panel)
# ─────────────────────────────────────────────────────────────────────────────

@api_view(["GET"])
@permission_classes([IsAdminUser])
def device_picker(request, apartment_id):
    try:
        apartment = Apartment.objects.get(pk=apartment_id)
    except Apartment.DoesNotExist:
        return _err("Apartment not found", 404)

    devices = ApartmentDevice.objects.filter(apartment=apartment).select_related("room")
    result  = []
    for d in devices:
        result.append({
            "id":               d.pk,
            "name":             d.name,
            "device_type":      d.device_type,
            "channel_or_index": d.channel_or_index,
            "gvl_name":         d.gvl_name,
            "room_id":          d.room_id,
            "room_name":        d.room.name if d.room else None,
        })
    rooms = list(
        Room.objects.filter(apartment=apartment).values("id", "name", "sort_order")
    )
    return _ok(devices=result, rooms=rooms)
