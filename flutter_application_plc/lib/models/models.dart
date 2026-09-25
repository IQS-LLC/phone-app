// ─────────────────────────────────────────────────────────────────────────────
// Device metadata models (populated once from GET /plc/devices/)
// ─────────────────────────────────────────────────────────────────────────────

class DaliDevice {
  final int    channel;
  final String name;
  final String room;
  final int?   apartmentDeviceId;
  const DaliDevice({
    required this.channel,
    required this.name,
    required this.room,
    this.apartmentDeviceId,
  });
  factory DaliDevice.fromJson(Map<String, dynamic> j) => DaliDevice(
    channel:           j['channel']            as int,
    name:              j['name']               as String,
    room:              j['room']               as String,
    apartmentDeviceId: j['apartment_device_id'] as int?,
  );
}

class RelayDevice {
  final int    channel;
  final String name;
  final String room;
  const RelayDevice({required this.channel, required this.name, required this.room});
  factory RelayDevice.fromJson(Map<String, dynamic> j) => RelayDevice(
    channel: j['channel'] as int,
    name:    j['name']    as String,
    room:    j['room']    as String,
  );
}

class CurtainDevice {
  final int    index;
  final String name;
  final String room;
  const CurtainDevice({required this.index, required this.name, required this.room});
  factory CurtainDevice.fromJson(Map<String, dynamic> j) => CurtainDevice(
    index: j['index'] as int,
    name:  j['name']  as String,
    room:  j['room']  as String,
  );
}

class ApplianceDevice {
  final String gvlName;
  final String name;
  final String room;
  const ApplianceDevice({required this.gvlName, required this.name, required this.room});
  factory ApplianceDevice.fromJson(Map<String, dynamic> j) => ApplianceDevice(
    gvlName: j['gvl_name'] as String,
    name:    j['name']     as String,
    room:    j['room']     as String,
  );
}

class ToggleDevice {
  final String varName;
  final String name;
  final String room;
  final bool   writable;
  // Set only for a scheme-driven ("custom") device merged into this same
  // list/UI — see AppState._updateFromJson. When non-null, writes must go
  // through ApiService.setCustom(apartmentDeviceId, ...) instead of
  // setToggle(varName, ...); varName is still populated (synthetic
  // 'custom:<id>') purely as the map key every existing toggle helper
  // (effectiveToggle, toggleDeviceState, _pendingToggle) already keys off.
  final int?   apartmentDeviceId;
  const ToggleDevice({
    required this.varName,
    required this.name,
    required this.room,
    required this.writable,
    this.apartmentDeviceId,
  });
  factory ToggleDevice.fromJson(Map<String, dynamic> j) => ToggleDevice(
    varName:  j['var_name'] as String,
    name:     j['name']     as String,
    room:     j['room']     as String,
    writable: j['writable'] as bool? ?? true,
  );
  factory ToggleDevice.fromCustomJson(Map<String, dynamic> j) => ToggleDevice(
    varName:           'custom:${j['apartment_device_id']}',
    name:              j['name'] as String,
    room:              j['room'] as String,
    writable:          true,
    apartmentDeviceId: j['apartment_device_id'] as int,
  );
}

class SensorDevice {
  final int    index;
  final String sensorType; // 'door' | 'window' | 'motion'
  final String name;
  final String room;
  const SensorDevice({
    required this.index,
    required this.sensorType,
    required this.name,
    required this.room,
  });
  factory SensorDevice.fromJson(Map<String, dynamic> j, String type) => SensorDevice(
    index:      j['index'] as int,
    sensorType: type,
    name:       j['name']  as String,
    room:       j['room']  as String,
  );
}

class SwitchDevice {
  final int    index;
  final String name;
  final String room;
  const SwitchDevice({required this.index, required this.name, required this.room});
  factory SwitchDevice.fromJson(Map<String, dynamic> j) => SwitchDevice(
    index: j['index'] as int,
    name:  j['name']  as String,
    room:  j['room']  as String,
  );
}


// ─────────────────────────────────────────────────────────────────────────────
// Security state
// ─────────────────────────────────────────────────────────────────────────────

class SecurityState {
  final bool armed;
  final bool triggered;
  final bool lockdown;
  final bool keySwitch;

  const SecurityState({
    required this.armed,
    required this.triggered,
    required this.lockdown,
    required this.keySwitch,
  });

  factory SecurityState.fromJson(Map<String, dynamic> j) => SecurityState(
    armed:     j['armed']      as bool? ?? false,
    triggered: j['triggered']  as bool? ?? false,
    lockdown:  j['lockdown']   as bool? ?? false,
    keySwitch: j['key_switch'] as bool? ?? false,
  );

  static const empty = SecurityState(
    armed: false, triggered: false, lockdown: false, keySwitch: false,
  );
}


// ─────────────────────────────────────────────────────────────────────────────
// SystemState — full snapshot from GET /plc/state/  (polled every 2 s)
// ─────────────────────────────────────────────────────────────────────────────

class SystemState {
  final bool                mock;
  final int                 apartmentId;
  final bool                plcConnected;     // real ADS status, not just "did the HTTP call succeed"
  final bool                modbusConnected;  // TF6250 fallback (see PLC_MODBUS_ENABLED) — usually false until enabled

  // Keyed by channel/index (int) or gvl_name (String)
  final Map<int, int?>      dali;           // channel → brightness %
  final Map<int, bool?>     relays;         // channel → on/off
  final Map<int, int?>      curtains;       // index   → 0=stopped 1=up 2=down
  final Map<int, bool?>     switches;       // index   → pressed
  final Map<int, bool?>     doorSensors;    // index   → open
  final Map<int, bool?>     windowSensors;  // index   → open
  final Map<int, bool?>     motionSensors;  // index   → detected
  final Map<String, bool?>  appliances;     // gvl_name → on/off
  final Map<String, bool?>  toggles;        // var_name → on/off
  final SecurityState       security;

  const SystemState({
    required this.mock,
    required this.apartmentId,
    required this.plcConnected,
    required this.modbusConnected,
    required this.dali,
    required this.relays,
    required this.curtains,
    required this.switches,
    required this.doorSensors,
    required this.windowSensors,
    required this.motionSensors,
    required this.appliances,
    required this.toggles,
    required this.security,
  });

  factory SystemState.fromJson(Map<String, dynamic> j) {
    Map<int, int?>     dali          = {};
    Map<int, bool?>    relays        = {};
    Map<int, int?>     curtains      = {};
    Map<int, bool?>    switches      = {};
    Map<int, bool?>    doorSensors   = {};
    Map<int, bool?>    windowSensors = {};
    Map<int, bool?>    motionSensors = {};
    Map<String, bool?> appliances    = {};
    Map<String, bool?> toggles       = {};

    (j['dali']    as Map<String, dynamic>? ?? {}).forEach((k, v) {
      dali[int.parse(k)] = v as int?;
    });
    (j['relays']  as Map<String, dynamic>? ?? {}).forEach((k, v) {
      relays[int.parse(k)] = v as bool?;
    });
    (j['curtains'] as Map<String, dynamic>? ?? {}).forEach((k, v) {
      curtains[int.parse(k)] = v as int?;
    });
    (j['switches'] as Map<String, dynamic>? ?? {}).forEach((k, v) {
      switches[int.parse(k)] = v as bool?;
    });
    (j['door_sensors'] as Map<String, dynamic>? ?? {}).forEach((k, v) {
      doorSensors[int.parse(k)] = v as bool?;
    });
    (j['window_sensors'] as Map<String, dynamic>? ?? {}).forEach((k, v) {
      windowSensors[int.parse(k)] = v as bool?;
    });
    (j['motion_sensors'] as Map<String, dynamic>? ?? {}).forEach((k, v) {
      motionSensors[int.parse(k)] = v as bool?;
    });
    (j['appliances'] as Map<String, dynamic>? ?? {}).forEach((k, v) {
      appliances[k] = v as bool?;
    });
    (j['toggles'] as Map<String, dynamic>? ?? {}).forEach((k, v) {
      toggles[k] = v as bool?;
    });
    // Scheme-driven devices ride in the same toggles map, keyed the same
    // way ToggleDevice.fromCustomJson names them — see AppState._loadDevices.
    (j['custom'] as Map<String, dynamic>? ?? {}).forEach((k, v) {
      toggles['custom:$k'] = v as bool?;
    });

    final sec = j['security'] as Map<String, dynamic>?;

    return SystemState(
      mock:            j['mock']            as bool? ?? true,
      apartmentId:     j['apartment_id']    as int?  ?? 16,
      plcConnected:    j['plc_connected']    as bool? ?? false,
      modbusConnected: j['modbus_connected'] as bool? ?? false,
      dali:          dali,
      relays:        relays,
      curtains:      curtains,
      switches:      switches,
      doorSensors:   doorSensors,
      windowSensors: windowSensors,
      motionSensors: motionSensors,
      appliances:    appliances,
      toggles:       toggles,
      security:      sec != null ? SecurityState.fromJson(sec) : SecurityState.empty,
    );
  }

  static const empty = SystemState(
    mock: true, apartmentId: 16,
    plcConnected: false, modbusConnected: false,
    dali: {}, relays: {}, curtains: {}, switches: {},
    doorSensors: {}, windowSensors: {}, motionSensors: {},
    appliances: {}, toggles: {}, security: SecurityState.empty,
  );
}


// ─────────────────────────────────────────────────────────────────────────────
// Activity log entry
// ─────────────────────────────────────────────────────────────────────────────

class LogEntry {
  final String   message;
  final DateTime time;
  final bool     isError;
  LogEntry(this.message, {this.isError = false}) : time = DateTime.now();
}
