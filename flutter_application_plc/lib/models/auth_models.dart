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

  const AuthUser({
    required this.id,
    required this.username,
    required this.email,
    this.firstName = '',
    this.lastName  = '',
    this.theme     = 'dark',
    this.pushNotifications = true,
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
  );

  Map<String, dynamic> toJson() => {
    'id':                 id,
    'username':           username,
    'email':              email,
    'first_name':         firstName,
    'last_name':          lastName,
    'theme':              theme,
    'push_notifications': pushNotifications,
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
