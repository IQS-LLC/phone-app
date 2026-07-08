from django.contrib import admin
from .models import (
    Apartment, ApartmentDevice, ApartmentMembership, AuditLog,
    DiscoveryCache, PLCDevice, Permission, Role, Room, SessionInfo,
    TemporaryAccess, UserProfile,
)


@admin.register(Apartment)
class ApartmentAdmin(admin.ModelAdmin):
    list_display  = ("name", "building", "floor", "updated_at")
    search_fields = ("name", "building")
    readonly_fields = ("created_at", "updated_at")


@admin.register(ApartmentMembership)
class ApartmentMembershipAdmin(admin.ModelAdmin):
    list_display  = ("user", "apartment", "role", "custom_role", "is_default", "created_at")
    list_filter   = ("role", "custom_role", "is_default")
    search_fields = ("user__username", "apartment__name")
    autocomplete_fields = ("user", "apartment", "custom_role")


@admin.register(PLCDevice)
class PLCDeviceAdmin(admin.ModelAdmin):
    list_display  = ("name", "apartment", "owner", "ip_address", "ams_net_id", "is_active", "is_default", "updated_at")
    list_filter   = ("is_active", "is_default")
    search_fields = ("name", "ip_address", "ams_net_id", "owner__username", "apartment__name")
    readonly_fields = ("created_at", "updated_at", "last_seen_at")
    autocomplete_fields = ("owner", "apartment")


@admin.register(Room)
class RoomAdmin(admin.ModelAdmin):
    list_display  = ("name", "apartment", "sort_order")
    list_filter   = ("apartment",)
    search_fields = ("name", "apartment__name")
    autocomplete_fields = ("apartment",)


@admin.register(ApartmentDevice)
class ApartmentDeviceAdmin(admin.ModelAdmin):
    list_display  = ("name", "apartment", "device_type", "channel_or_index", "gvl_name", "room", "sort_order")
    list_filter   = ("device_type", "apartment")
    search_fields = ("name", "apartment__name", "gvl_name")
    autocomplete_fields = ("apartment", "room")


@admin.register(Permission)
class PermissionAdmin(admin.ModelAdmin):
    list_display  = ("code", "label")
    search_fields = ("code", "label")


@admin.register(Role)
class RoleAdmin(admin.ModelAdmin):
    list_display  = ("name", "is_system", "created_at")
    list_filter   = ("is_system",)
    search_fields = ("name",)
    filter_horizontal = ("permissions",)


@admin.register(TemporaryAccess)
class TemporaryAccessAdmin(admin.ModelAdmin):
    list_display  = ("user", "apartment", "role", "starts_at", "expires_at", "revoked", "created_by")
    list_filter   = ("revoked", "role")
    search_fields = ("user__username", "apartment__name")
    autocomplete_fields = ("user", "apartment", "role", "created_by")
    filter_horizontal = ("allowed_rooms", "allowed_devices")
    readonly_fields = ("created_at",)


@admin.register(SessionInfo)
class SessionInfoAdmin(admin.ModelAdmin):
    list_display  = ("user", "device_name", "os", "ip_address", "created_at", "last_seen_at", "revoked")
    list_filter   = ("revoked",)
    search_fields = ("user__username", "device_name", "ip_address")
    readonly_fields = ("jti", "created_at", "last_seen_at")


@admin.register(AuditLog)
class AuditLogAdmin(admin.ModelAdmin):
    list_display  = ("created_at", "user", "apartment", "action", "result", "ip_address")
    list_filter   = ("action", "result")
    search_fields = ("user__username", "apartment__name", "action", "ip_address")
    readonly_fields = ("user", "apartment", "action", "result", "reason", "ip_address", "metadata", "created_at")

    def has_add_permission(self, request):
        return False  # audit logs are written by the app, never hand-created

    def has_change_permission(self, request, obj=None):
        return False  # immutable


@admin.register(UserProfile)
class UserProfileAdmin(admin.ModelAdmin):
    list_display  = ("user", "theme", "push_notifications_enabled", "updated_at")
    list_filter   = ("theme",)
    search_fields = ("user__username", "user__email")
    readonly_fields = ("created_at", "updated_at")


@admin.register(DiscoveryCache)
class DiscoveryCacheAdmin(admin.ModelAdmin):
    list_display  = ("device", "symbol_count", "scan_duration_ms", "scanned_at")
    search_fields = ("device__name",)
    readonly_fields = ("scanned_at", "symbol_count", "scan_duration_ms")
