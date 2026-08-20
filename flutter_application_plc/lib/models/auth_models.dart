// Lugh (by IQS) auth and device configuration data models.

// ─────────────────────────────────────────────────────────────────────────────
// AuthUser
// ─────────────────────────────────────────────────────────────────────────────

class AuthUser {
  final int    id;
  final String username;
  final String email;
  final String firstName;
  final String lastName;
  final String theme;
  final bool   pushNotifications;
  final bool   isStaff; // Tech Team — gates the in-app admin/user-management section
  final bool   showVentilatorsHome; // show Ventilators & Extra Lights on the Home tab
  final int    dimDurationMs;   // DALI fade duration when lowering brightness
  final int    undimDurationMs; // DALI fade duration when raising brightness

  const AuthUser({
    required this.id,
    required this.username,
    required this.email,
    this.firstName = '',
    this.lastName  = '',
    this.theme     = 'dark',
    this.pushNotifications = true,
    this.isStaff = false,
    this.showVentilatorsHome = true,
    this.dimDurationMs = 800,
    this.undimDurationMs = 500,
  });

  String get displayName {
    final full = '${firstName.trim()} ${lastName.trim()}'.trim();
    return full.isNotEmpty ? full : username;
  }

  factory AuthUser.fromJson(Map<String, dynamic> j) => AuthUser(
    id:                j['id']                  as int,
    username:          j['username']             as String,
    email:             j['email']               as String? ?? '',
    firstName:         j['first_name']          as String? ?? '',
    lastName:          j['last_name']           as String? ?? '',
    theme:             j['theme']               as String? ?? 'dark',
    pushNotifications: j['push_notifications']  as bool? ?? true,
    isStaff:           j['is_staff']            as bool? ?? false,
    showVentilatorsHome: j['show_ventilators_home'] as bool? ?? true,
    dimDurationMs:    j['dim_duration_ms']   as int? ?? 800,
    undimDurationMs:  j['undim_duration_ms'] as int? ?? 500,
  );

  Map<String, dynamic> toJson() => {
    'id':                 id,
    'username':           username,
    'email':              email,
    'first_name':         firstName,
    'last_name':          lastName,
    'theme':              theme,
    'push_notifications': pushNotifications,
    'is_staff':           isStaff,
    'show_ventilators_home': showVentilatorsHome,
    'dim_duration_ms':    dimDurationMs,
    'undim_duration_ms':  undimDurationMs,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// AuthTokens
// ─────────────────────────────────────────────────────────────────────────────

class AuthTokens {
  final String access;
  final String refresh;

  const AuthTokens({required this.access, required this.refresh});
}

// ─────────────────────────────────────────────────────────────────────────────
// PlcDeviceConfig  (mirrors backend PLCDevice)
// ─────────────────────────────────────────────────────────────────────────────

class PlcDeviceConfig {
  final int    id;
  final String name;
  final String description;
  final String ipAddress;
  final String amsNetId;
  final int    adsPort;
  final bool   isActive;
  final bool   isDefault;
  final String? lastSeenAt;

  const PlcDeviceConfig({
    required this.id,
    required this.name,
    required this.ipAddress,
    required this.amsNetId,
    this.description = '',
    this.adsPort     = 851,
    this.isActive    = true,
    this.isDefault   = false,
    this.lastSeenAt,
  });

  factory PlcDeviceConfig.fromJson(Map<String, dynamic> j) => PlcDeviceConfig(
    id:          j['id']           as int,
    name:        j['name']         as String,
    description: j['description']  as String? ?? '',
    ipAddress:   j['ip_address']   as String,
    amsNetId:    j['ams_net_id']   as String,
    adsPort:     j['ads_port']     as int? ?? 851,
    isActive:    j['is_active']    as bool? ?? true,
    isDefault:   j['is_default']   as bool? ?? false,
    lastSeenAt:  j['last_seen_at'] as String?,
  );

  String get baseUrl => 'http://$ipAddress:8000';
}

// ─────────────────────────────────────────────────────────────────────────────
// DiscoveredSymbol  (mirrors backend SymbolDescriptor)
// ─────────────────────────────────────────────────────────────────────────────

enum WidgetType {
  daliSlider,
  toggle,
  thermostat,
  alarmCard,
  modeSelector,
  numericDisplay,
  textDisplay,
  gauge,
  unknown,
}

extension WidgetTypeX on WidgetType {
  static WidgetType fromString(String s) {
    const map = {
      'dali_slider':     WidgetType.daliSlider,
      'toggle':          WidgetType.toggle,
      'thermostat':      WidgetType.thermostat,
      'alarm_card':      WidgetType.alarmCard,
      'mode_selector':   WidgetType.modeSelector,
      'numeric_display': WidgetType.numericDisplay,
      'text_display':    WidgetType.textDisplay,
      'gauge':           WidgetType.gauge,
    };
    return map[s] ?? WidgetType.unknown;
  }
}

class DiscoveredSymbol {
  final String     fullName;
  final String     gvl;
  final String     name;
  final String     typeName;
  final String     comment;
  final String     category;
  final WidgetType widgetType;
  final String     label;
  final String     unit;
  final double?    minValue;
  final double?    maxValue;
  final bool       readOnly;
  final String     group;

  const DiscoveredSymbol({
    required this.fullName,
    required this.gvl,
    required this.name,
    required this.typeName,
    this.comment    = '',
    this.category   = 'other',
    this.widgetType = WidgetType.unknown,
    this.label      = '',
    this.unit       = '',
    this.minValue,
    this.maxValue,
    this.readOnly   = false,
    this.group      = '',
  });

  factory DiscoveredSymbol.fromJson(Map<String, dynamic> j) => DiscoveredSymbol(
    fullName:   j['full_name']   as String,
    gvl:        j['gvl']        as String? ?? '',
    name:       j['name']       as String,
    typeName:   j['type_name']  as String,
    comment:    j['comment']    as String? ?? '',
    category:   j['category']  as String? ?? 'other',
    widgetType: WidgetTypeX.fromString(j['widget_type'] as String? ?? ''),
    label:      j['label']      as String? ?? '',
    unit:       j['unit']       as String? ?? '',
    minValue:   (j['min_value'] as num?)?.toDouble(),
    maxValue:   (j['max_value'] as num?)?.toDouble(),
    readOnly:   j['read_only']  as bool? ?? false,
    group:      j['group']      as String? ?? '',
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// DiscoveryGroup  (widget layout group from backend)
// ─────────────────────────────────────────────────────────────────────────────

class DiscoveryGroup {
  final String               id;
  final String               title;
  final String               category;
  final List<DiscoveredSymbol> widgets;

  const DiscoveryGroup({
    required this.id,
    required this.title,
    required this.category,
    required this.widgets,
  });

  factory DiscoveryGroup.fromJson(Map<String, dynamic> j) => DiscoveryGroup(
    id:       j['id']       as String,
    title:    j['title']    as String,
    category: j['category'] as String? ?? 'other',
    widgets:  (j['widgets'] as List<dynamic>)
        .map((e) => DiscoveredSymbol.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// DiscoveredPlc — one result from a network-wide PLC discovery scan
// (mirrors backend network_scanner.scan() output, see find_device/discovery/views.py)
// ─────────────────────────────────────────────────────────────────────────────

class DiscoveredPlc {
  final String  ip;
  final double?  latencyMs;
  final String  amsNetId;
  final String  deviceName;
  final String  version;
  final bool    reachableAds;
  final String  registrationStatus; // 'registered' | 'unregistered'
  final String? apartmentName;
  final String  connectionQuality;  // 'excellent' | 'good' | 'poor' | 'unknown'

  const DiscoveredPlc({
    required this.ip,
    required this.amsNetId,
    required this.deviceName,
    required this.version,
    required this.reachableAds,
    required this.registrationStatus,
    required this.connectionQuality,
    this.latencyMs,
    this.apartmentName,
  });

  bool get isRegistered => registrationStatus == 'registered';

  factory DiscoveredPlc.fromJson(Map<String, dynamic> j) => DiscoveredPlc(
    ip:                 j['ip'] as String,
    latencyMs:          (j['latency_ms'] as num?)?.toDouble(),
    amsNetId:           j['ams_net_id'] as String? ?? '',
    deviceName:         j['device_name'] as String? ?? '',
    version:            j['version'] as String? ?? '',
    reachableAds:       j['reachable_ads'] as bool? ?? false,
    registrationStatus: j['registration_status'] as String? ?? 'unregistered',
    apartmentName:      j['apartment_name'] as String?,
    connectionQuality:  j['connection_quality'] as String? ?? 'unknown',
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// ManagedApartmentLink — one row in ManagedUser.apartments
// ─────────────────────────────────────────────────────────────────────────────

class ManagedApartmentLink {
  final int    id;
  final String name;
  final String role;
  final bool   isDefault;

  const ManagedApartmentLink({
    required this.id,
    required this.name,
    required this.role,
    required this.isDefault,
  });

  factory ManagedApartmentLink.fromJson(Map<String, dynamic> j) => ManagedApartmentLink(
    id:        j['id'] as int,
    name:      j['name'] as String,
    role:      j['role'] as String,
    isDefault: j['is_default'] as bool? ?? false,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// ManagedUser — one row in the Tech Team's User Management table
// (mirrors find_device/user_management_views.py's _user_summary())
// ─────────────────────────────────────────────────────────────────────────────

class ManagedUser {
  final int    id;
  final String firstName;
  final String lastName;
  final String username;
  final String email;
  final bool   isActive;
  final bool   isStaff;
  final String? lastLogin;
  final String dateJoined;
  final int    activeSessions;
  final List<ManagedApartmentLink> apartments;

  const ManagedUser({
    required this.id,
    required this.firstName,
    required this.lastName,
    required this.username,
    required this.email,
    required this.isActive,
    required this.isStaff,
    required this.dateJoined,
    required this.activeSessions,
    required this.apartments,
    this.lastLogin,
  });

  String get displayName {
    final full = '${firstName.trim()} ${lastName.trim()}'.trim();
    return full.isNotEmpty ? full : username;
  }

  factory ManagedUser.fromJson(Map<String, dynamic> j) => ManagedUser(
    id:             j['id'] as int,
    firstName:      j['first_name'] as String? ?? '',
    lastName:       j['last_name'] as String? ?? '',
    username:       j['username'] as String,
    email:          j['email'] as String? ?? '',
    isActive:       j['is_active'] as bool? ?? true,
    isStaff:        j['is_staff'] as bool? ?? false,
    lastLogin:      j['last_login'] as String?,
    dateJoined:     j['date_joined'] as String? ?? '',
    activeSessions: j['active_sessions'] as int? ?? 0,
    apartments: (j['apartments'] as List<dynamic>? ?? [])
        .map((e) => ManagedApartmentLink.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// ManagedPlc — the controller assigned to one apartment, as edited by the
// Tech Team (mirrors find_device/user_management_views.py's apartment_plc())
// ─────────────────────────────────────────────────────────────────────────────

class ManagedPlc {
  final String  name;
  final String  ipAddress;
  final String  amsNetId;
  final int     adsPort;
  final bool    isActive;
  final String? lastSeenAt;

  const ManagedPlc({
    required this.name,
    required this.ipAddress,
    required this.amsNetId,
    required this.adsPort,
    required this.isActive,
    this.lastSeenAt,
  });

  factory ManagedPlc.fromJson(Map<String, dynamic> j) => ManagedPlc(
    name:       j['name'] as String,
    ipAddress:  j['ip_address'] as String,
    amsNetId:   j['ams_net_id'] as String,
    adsPort:    j['ads_port'] as int? ?? 851,
    isActive:   j['is_active'] as bool? ?? true,
    lastSeenAt: j['last_seen_at'] as String?,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// ManagedRoom / ManagedDevice — Tech Team layout control (rename/reorder)
// (mirrors find_device/user_management_views.py's apartment_rooms()/devices())
// ─────────────────────────────────────────────────────────────────────────────

class ManagedRoom {
  final int    id;
  final String name;
  final int    sortOrder;
  final int    deviceCount;

  const ManagedRoom({
    required this.id, required this.name, required this.sortOrder, required this.deviceCount,
  });

  factory ManagedRoom.fromJson(Map<String, dynamic> j) => ManagedRoom(
    id:          j['id'] as int,
    name:        j['name'] as String,
    sortOrder:   j['sort_order'] as int? ?? 0,
    deviceCount: j['device_count'] as int? ?? 0,
  );
}

class ManagedDevice {
  final int     id;
  final String  name;
  final String  deviceType;
  final int?    roomId;
  final String? roomName;
  final int     sortOrder;
  final int?    channelOrIndex;

  const ManagedDevice({
    required this.id, required this.name, required this.deviceType,
    required this.sortOrder, this.roomId, this.roomName, this.channelOrIndex,
  });

  factory ManagedDevice.fromJson(Map<String, dynamic> j) => ManagedDevice(
    id:             j['id'] as int,
    name:           j['name'] as String,
    deviceType:     j['device_type'] as String,
    roomId:         j['room_id'] as int?,
    roomName:       j['room_name'] as String?,
    sortOrder:      j['sort_order'] as int? ?? 0,
    channelOrIndex: j['channel_or_index'] as int?,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// ManagedSession — one device session, as seen by the Tech Team
// (mirrors find_device/user_management_views.py's user_sessions())
// ─────────────────────────────────────────────────────────────────────────────

class ManagedSession {
  final int     id;
  final String  deviceName;
  final String  os;
  final String  appVersion;
  final String? ipAddress;
  final String  createdAt;
  final String  lastSeenAt;

  const ManagedSession({
    required this.id,
    required this.deviceName,
    required this.os,
    required this.appVersion,
    required this.createdAt,
    required this.lastSeenAt,
    this.ipAddress,
  });

  factory ManagedSession.fromJson(Map<String, dynamic> j) => ManagedSession(
    id:         j['id'] as int,
    deviceName: j['device_name'] as String? ?? 'Unknown device',
    os:         j['os'] as String? ?? '',
    appVersion: j['app_version'] as String? ?? '',
    ipAddress:  j['ip_address'] as String?,
    createdAt:  j['created_at'] as String? ?? '',
    lastSeenAt: j['last_seen_at'] as String? ?? '',
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// PermissionInfo — one assignable capability (mirrors backend Permission)
// ─────────────────────────────────────────────────────────────────────────────

class PermissionInfo {
  final String code;
  final String label;
  const PermissionInfo({required this.code, required this.label});

  factory PermissionInfo.fromJson(Map<String, dynamic> j) => PermissionInfo(
    code:  j['code'] as String,
    label: j['label'] as String,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// ApartmentOverview — Tech Team's apartment-management list/detail row
// (mirrors find_device/user_management_views.py's _apartment_summary())
// ─────────────────────────────────────────────────────────────────────────────

class ApartmentPerson {
  final int    id;
  final String username;
  final String displayName;
  const ApartmentPerson({required this.id, required this.username, required this.displayName});

  factory ApartmentPerson.fromJson(Map<String, dynamic> j) => ApartmentPerson(
    id:          j['id'] as int,
    username:    j['username'] as String,
    displayName: j['display_name'] as String? ?? j['username'] as String,
  );
}

class ApartmentRoomSummary {
  final int    id;
  final String name;
  final int    deviceCount;
  const ApartmentRoomSummary({required this.id, required this.name, required this.deviceCount});

  factory ApartmentRoomSummary.fromJson(Map<String, dynamic> j) => ApartmentRoomSummary(
    id:          j['id'] as int,
    name:        j['name'] as String,
    deviceCount: j['device_count'] as int? ?? 0,
  );
}

class ApartmentPlcStatus {
  final String  name;
  final bool    isActive;
  final String? lastSeenAt;
  const ApartmentPlcStatus({required this.name, required this.isActive, this.lastSeenAt});

  factory ApartmentPlcStatus.fromJson(Map<String, dynamic> j) => ApartmentPlcStatus(
    name:       j['name'] as String,
    isActive:   j['is_active'] as bool? ?? false,
    lastSeenAt: j['last_seen_at'] as String?,
  );
}

class ApartmentOverview {
  final int    id;
  final String name;
  final String building;
  final String floor;
  final ApartmentPerson?      owner;
  final List<ApartmentPerson> residents;
  final int    roomCount;
  final int    deviceCount;
  final ApartmentPlcStatus?   plc;
  final List<ApartmentRoomSummary> rooms;

  const ApartmentOverview({
    required this.id,
    required this.name,
    required this.building,
    required this.floor,
    required this.residents,
    required this.roomCount,
    required this.deviceCount,
    this.owner,
    this.plc,
    this.rooms = const [],
  });

  factory ApartmentOverview.fromJson(Map<String, dynamic> j) => ApartmentOverview(
    id:          j['id'] as int,
    name:        j['name'] as String,
    building:    j['building'] as String? ?? '',
    floor:       j['floor'] as String? ?? '',
    owner:       j['owner'] != null ? ApartmentPerson.fromJson(j['owner'] as Map<String, dynamic>) : null,
    residents: (j['residents'] as List<dynamic>? ?? [])
        .map((e) => ApartmentPerson.fromJson(e as Map<String, dynamic>))
        .toList(),
    roomCount:   j['room_count'] as int? ?? 0,
    deviceCount: j['device_count'] as int? ?? 0,
    plc: j['plc'] != null ? ApartmentPlcStatus.fromJson(j['plc'] as Map<String, dynamic>) : null,
    rooms: (j['rooms'] as List<dynamic>? ?? [])
        .map((e) => ApartmentRoomSummary.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}
