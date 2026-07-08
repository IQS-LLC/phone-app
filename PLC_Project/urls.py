from django.contrib import admin
from django.urls import path, include
from django.http import HttpResponse

from find_device.urls import (
    auth_urlpatterns,
    device_urlpatterns,
    discovery_urlpatterns,
    user_management_urlpatterns,
    permission_urlpatterns,
    apartment_management_urlpatterns,
    realtime_urlpatterns,
    map_urlpatterns,
)


def health_check(request):
    return HttpResponse("healthy\n", content_type="text/plain")


urlpatterns = [
    path('admin/',       admin.site.urls),
    path('health/',      health_check),

    # ── PLC control ───────────────────────────────────────────────────────────
    path('plc/',         include('find_device.urls')),

    # ── Real-time SSE (live PLC variable push) ────────────────────────────────
    path('realtime/',    include(realtime_urlpatterns)),

    # ── Authentication ────────────────────────────────────────────────────────
    path('auth/',        include(auth_urlpatterns)),

    # ── PLC Device management ─────────────────────────────────────────────────
    path('manage/devices/',    include(device_urlpatterns)),

    # ── TwinCAT discovery ─────────────────────────────────────────────────────
    path('manage/discovery/',  include(discovery_urlpatterns)),

    # ── Tech Team user management ─────────────────────────────────────────────
    path('manage/users/',      include(user_management_urlpatterns)),
    path('manage/permissions/', include(permission_urlpatterns)),
    path('manage/apartments/', include(apartment_management_urlpatterns)),

    # ── Digital Twin Map Editor ───────────────────────────────────────────────
    # GET readable by apartment members; all writes require is_staff
    path('map/',              include(map_urlpatterns)),
]
