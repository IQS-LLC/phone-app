from django.urls import path
from . import (
    views, auth_views, device_views, user_management_views, map_views,
    commissioning_views, relabel_views, automation_views, superscan_views,
)
from .discovery import views as discovery_views
from .realtime import views as realtime_views

urlpatterns = [
    # ── Health / status ──────────────────────────────────────────────────────
    path('',             views.health),
    path('state/',       views.get_state),
    path('devices/',     views.get_devices),
    path('diagnostics/', views.get_diagnostics),

    # ── DALI dimmers ─────────────────────────────────────────────────────────
    path('dali/all/brightness/',            views.set_dali_brightness_all),
    path('dali/<int:channel>/brightness/',  views.set_dali_brightness),

    # ── Room-level brightness ────────────────────────────────────────────────
    path('room/<str:room_name>/brightness/', views.set_room_brightness),

    # ── Wall relay lights ────────────────────────────────────────────────────
    path('relay/<int:channel>/',            views.set_relay),

    # ── Curtain motors ───────────────────────────────────────────────────────
    path('curtain/all/',                    views.set_curtain_all),
    path('curtain/<int:index>/',            views.set_curtain),

    # ── Smart appliances ─────────────────────────────────────────────────────
    path('appliance/<str:gvl_name>/',       views.set_appliance),

    # ── Named relays/lights (ventilators, balcony/mirror/var lights, etc.) ──
    path('toggle/<str:var_name>/',          views.set_toggle),

    # ── Scheme-driven / DeviceAddressScheme devices ──────────────────────────
    path('custom/<int:apartment_device_id>/', views.set_custom),

    # ── Sensors (read-only) ──────────────────────────────────────────────────
    path('sensors/',                        views.get_sensors),

    # ── Security ────────────────────────────────────────────────────────────
    path('security/alarm/',                 views.set_alarm),
    path('security/lockdown/',              views.set_lockdown),
]

# Mounted at /auth/ in PLC_Project/urls.py
auth_urlpatterns = [
    path('register/',  auth_views.register,      name='auth-register'),
    path('login/',     auth_views.login,          name='auth-login'),
    path('refresh/',   auth_views.refresh_token,  name='auth-refresh'),
    path('me/',        auth_views.me,             name='auth-me'),
    path('logout/',    auth_views.logout,         name='auth-logout'),

    # Logged-in devices
    path('sessions/',             auth_views.session_list,        name='auth-sessions'),
    path('sessions/<int:pk>/revoke/', auth_views.session_revoke,  name='auth-session-revoke'),
    path('sessions/revoke-all/',  auth_views.session_revoke_all,  name='auth-session-revoke-all'),

    # Apartment selection + rename
    path('apartments/',                  auth_views.apartment_list,   name='auth-apartments'),
    path('apartments/<int:pk>/select/',  auth_views.apartment_select, name='auth-apartment-select'),
    path('apartments/<int:pk>/rename/',  auth_views.apartment_rename, name='auth-apartment-rename'),
]

# Mounted at /manage/devices/ in PLC_Project/urls.py
device_urlpatterns = [
    path('',                    device_views.device_list,         name='device-list'),
    path('<int:pk>/',            device_views.device_detail,       name='device-detail'),
    path('<int:pk>/test/',       device_views.device_test,         name='device-test'),
    path('<int:pk>/set-default/', device_views.device_set_default, name='device-set-default'),
]

# Mounted at /manage/discovery/ in PLC_Project/urls.py
discovery_urlpatterns = [
    path('network-scan/',            discovery_views.network_scan,  name='discovery-network-scan'),
    path('<int:device_id>/scan/',    discovery_views.scan,          name='discovery-scan'),
    path('<int:device_id>/symbols/', discovery_views.symbols,       name='discovery-symbols'),
    path('<int:device_id>/widgets/', discovery_views.widget_layout, name='discovery-widgets'),
]

# Mounted at /manage/users/ in PLC_Project/urls.py — Tech Team only (IsAdminUser)
user_management_urlpatterns = [
    path('',                        user_management_views.user_list,             name='users-list'),
    path('apartments/',             user_management_views.apartment_list_all,    name='users-apartments-all'),
    path('<int:pk>/',                user_management_views.user_detail,           name='users-detail'),
    path('<int:pk>/disable/',        user_management_views.user_disable,          name='users-disable'),
    path('<int:pk>/enable/',         user_management_views.user_enable,           name='users-enable'),
    path('<int:pk>/reset-password/', user_management_views.user_reset_password,   name='users-reset-password'),
    path('<int:pk>/force-logout/',   user_management_views.user_force_logout,     name='users-force-logout'),
    path('<int:pk>/assign-apartment/', user_management_views.user_assign_apartment, name='users-assign-apartment'),
    path('<int:pk>/apartments/<int:apartment_id>/', user_management_views.user_remove_apartment, name='users-remove-apartment'),
    path('<int:pk>/apartments/<int:apartment_id>/permissions/', user_management_views.user_apartment_permissions, name='users-apartment-permissions'),
    path('<int:pk>/sessions/',       user_management_views.user_sessions,         name='users-sessions'),
]

# Mounted at /manage/permissions/ in PLC_Project/urls.py — Tech Team only
permission_urlpatterns = [
    path('', user_management_views.permission_list, name='permissions-list'),
]

# Mounted at /manage/apartments/ in PLC_Project/urls.py — Tech Team only
apartment_management_urlpatterns = [
    path('',          user_management_views.apartment_management_list,   name='apartments-mgmt-list'),
    path('<int:pk>/', user_management_views.apartment_management_detail, name='apartments-mgmt-detail'),
    path('<int:pk>/plc/',              user_management_views.apartment_plc,             name='apartments-mgmt-plc'),
    path('<int:pk>/building-settings/', user_management_views.apartment_building_settings, name='apartments-mgmt-building-settings'),
    path('<int:pk>/christmas-mode/',   user_management_views.apartment_christmas_mode,  name='apartments-mgmt-christmas-mode'),
    path('<int:pk>/rooms/',            user_management_views.apartment_rooms,           name='apartments-mgmt-rooms'),
    path('<int:pk>/rooms/reorder/',    user_management_views.apartment_rooms_reorder,   name='apartments-mgmt-rooms-reorder'),
    path('<int:pk>/rooms/<int:room_id>/', user_management_views.apartment_room_detail,  name='apartments-mgmt-room-detail'),
    path('<int:pk>/devices/',          user_management_views.apartment_devices,         name='apartments-mgmt-devices'),
    path('<int:pk>/devices/reorder/',  user_management_views.apartment_devices_reorder, name='apartments-mgmt-devices-reorder'),
    path('<int:pk>/devices/<int:device_id>/', user_management_views.apartment_device_detail, name='apartments-mgmt-device-detail'),
]

# Mounted at /realtime/ in PLC_Project/urls.py
# JWT is passed as ?token=<access_token> (EventSource can't set headers)
realtime_urlpatterns = [
    path('<int:device_id>/stream/',   realtime_views.sse_stream,  name='realtime-sse-stream'),
    path('<int:device_id>/snapshot/', realtime_views.snapshot,    name='realtime-snapshot'),
]

# Mounted at /commissioning/ in PLC_Project/urls.py — Tech Team wizard only
commissioning_urlpatterns = [
    path('<int:apartment_id>/checklist/', commissioning_views.checklist, name='commissioning-checklist'),
    path('<int:apartment_id>/test-io/',   commissioning_views.test_io,   name='commissioning-test-io'),
    path('<int:apartment_id>/summary/',   commissioning_views.summary,   name='commissioning-summary'),
]

# Mounted at /relabel/ in PLC_Project/urls.py — is_staff (IT Team) ONLY, see
# has_relabel_access. Lets them walk every output channel (DALI/relay/
# curtain), flash it, and fix its room/name; and separately watch every raw
# input channel (switch/motion/door/window sensor) live so a physical
# switch press or sensor trip is visibly identifiable before assigning it.
# Independent of the (also is_staff-only) commissioning wizard.
relabel_urlpatterns = [
    path('<int:apartment_id>/outputs/<str:device_type>/',
         relabel_views.list_output_channels, name='relabel-outputs'),
    path('<int:apartment_id>/outputs/<str:device_type>/<int:channel>/flash/',
         relabel_views.flash_output_channel, name='relabel-outputs-flash'),
    path('<int:apartment_id>/outputs/<str:device_type>/<int:channel>/assign/',
         relabel_views.assign_output_channel, name='relabel-outputs-assign'),

    path('<int:apartment_id>/inputs/',        relabel_views.list_inputs,  name='relabel-inputs'),
    path('<int:apartment_id>/inputs/assign/', relabel_views.assign_input, name='relabel-inputs-assign'),
]

# Mounted at /automations/ in PLC_Project/urls.py — is_staff (IT Team) ONLY,
# same has_relabel_access bar as relabel_urlpatterns above. "When this
# input does X, do Y to that output" configured from the phone — see
# AutomationRule docstring for why this is additive, never a replacement
# for whatever's already hardwired in the PLC's own program.
automation_urlpatterns = [
    path('<int:apartment_id>/rules/',            automation_views.rule_list,   name='automation-rules'),
    path('<int:apartment_id>/rules/<int:rule_id>/', automation_views.rule_detail, name='automation-rule-detail'),
]

# Mounted at /superscan/ in PLC_Project/urls.py — is_staff (IT Team) ONLY.
# Generic discovery/capability-mapping/safe-testing tool — see superscan.py
# module docstring. Deliberately never exposed to Building Owner/resident,
# same as relabel_urlpatterns/automation_urlpatterns above.
superscan_urlpatterns = [
    path('<int:apartment_id>/start/',                    superscan_views.start,             name='superscan-start'),
    path('<int:apartment_id>/runs/',                      superscan_views.run_list,          name='superscan-runs'),
    path('<int:apartment_id>/runs/<int:scan_id>/',        superscan_views.run_status,        name='superscan-run-status'),
    path('<int:apartment_id>/runs/<int:scan_id>/stop/',   superscan_views.stop,               name='superscan-run-stop'),
    path('<int:apartment_id>/capabilities/',              superscan_views.capability_list,   name='superscan-capabilities'),
    path('<int:apartment_id>/capabilities/<int:cap_id>/', superscan_views.capability_detail,  name='superscan-capability-detail'),
    path('<int:apartment_id>/capabilities/<int:cap_id>/promote/', superscan_views.promote_capability, name='superscan-capability-promote'),
]

# Mounted at /map/ in PLC_Project/urls.py
# GET  is authenticated-member accessible (resident reads published layout)
# POST/PUT/DELETE require is_staff (Tech Team Map Editor)
map_urlpatterns = [
    path('apartments/',                                       map_views.apartment_list,   name='map-apartment-list'),
    path('<int:apartment_id>/',                               map_views.layout,            name='map-layout'),
    path('<int:apartment_id>/background/',                    map_views.background,        name='map-background'),
    path('<int:apartment_id>/publish/',                       map_views.publish,           name='map-publish'),
    path('<int:apartment_id>/versions/',                      map_views.version_list,      name='map-versions'),
    path('<int:apartment_id>/versions/<int:version_id>/restore/', map_views.version_restore, name='map-version-restore'),
    path('<int:apartment_id>/devices/',                       map_views.device_picker,     name='map-device-picker'),
]
