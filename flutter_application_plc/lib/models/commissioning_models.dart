/// Data models for the Tech Team Commissioning Wizard.
library;

// ── PLC Discovery ─────────────────────────────────────────────────────────────

class DiscoveredPLC {
  final String  ipAddress;
  final String  amsNetId;
  final int?    deviceId;        // null if not yet registered
  final String  registrationStatus; // "registered" | "unregistered"
  final String  connectionQuality;  // "excellent" | "good" | "poor"
  final int     latencyMs;
  final String? apartmentName;

  const DiscoveredPLC({
    required this.ipAddress,
    required this.amsNetId,
    this.deviceId,
    required this.registrationStatus,
    required this.connectionQuality,
    required this.latencyMs,
    this.apartmentName,
  });

  bool get isRegistered => registrationStatus == "registered";

  factory DiscoveredPLC.fromJson(Map<String, dynamic> j) => DiscoveredPLC(
    ipAddress:          j['ip_address']          as String,
    amsNetId:           j['ams_net_id']           as String,
    deviceId:           j['registered_device_id'] as int?,
    registrationStatus: j['registration_status']  as String? ?? 'unregistered',
    connectionQuality:  j['connection_quality']   as String? ?? 'unknown',
    latencyMs:          j['latency_ms']           as int? ?? 0,
    apartmentName:      j['apartment_name']       as String?,
  );
}

// ── PLC Connectivity Test ─────────────────────────────────────────────────────

class PLCProbeResult {
  final bool reachable;
  final int  latencyMs;

  const PLCProbeResult({required this.reachable, required this.latencyMs});

  factory PLCProbeResult.fromJson(Map<String, dynamic> j) => PLCProbeResult(
    reachable:  j['reachable'] as bool? ?? false,
    latencyMs:  j['latency_ms'] as int? ?? 0,
  );
}

class PLCTestResult {
  final PLCProbeResult adsRouter;
  final PLCProbeResult adsRuntime;

  const PLCTestResult({required this.adsRouter, required this.adsRuntime});

  bool get fullyReachable => adsRouter.reachable && adsRuntime.reachable;

  factory PLCTestResult.fromJson(Map<String, dynamic> data) => PLCTestResult(
    adsRouter:  PLCProbeResult.fromJson(data['ads_router']  as Map<String, dynamic>? ?? {}),
    adsRuntime: PLCProbeResult.fromJson(data['ads_runtime'] as Map<String, dynamic>? ?? {}),
  );
}

// ── Apartment Info ────────────────────────────────────────────────────────────

class ApartmentInfo {
  final int    id;
  final String name;
  final String building;
  final String floor;

  const ApartmentInfo({
    required this.id,
    required this.name,
    required this.building,
    required this.floor,
  });

  factory ApartmentInfo.fromJson(Map<String, dynamic> j) => ApartmentInfo(
    id:       j['id']       as int,
    name:     j['name']     as String,
    building: j['building'] as String? ?? '',
    floor:    j['floor']    as String? ?? '',
  );
}

// ── Symbol Discovery ──────────────────────────────────────────────────────────

class SymbolScanResult {
  final int symbolCount;
  final int scanDurationMs;
  final Map<String, int> categoryCounts;

  const SymbolScanResult({
    required this.symbolCount,
    required this.scanDurationMs,
    required this.categoryCounts,
  });

  factory SymbolScanResult.fromJson(Map<String, dynamic> data) => SymbolScanResult(
    symbolCount:    data['symbol_count']    as int? ?? 0,
    scanDurationMs: data['scan_duration_ms'] as int? ?? 0,
    categoryCounts: Map<String, int>.from(
      (data['category_counts'] as Map<String, dynamic>?)?.map(
        (k, v) => MapEntry(k, v as int),
      ) ?? {},
    ),
  );
}

// ── Apartment Device ──────────────────────────────────────────────────────────

class AptDevice {
  final int    id;
  final String name;
  final String deviceType;
  final int    channelOrIndex;
  final String gvlName;
  final int?   roomId;

  const AptDevice({
    required this.id,
    required this.name,
    required this.deviceType,
    required this.channelOrIndex,
    required this.gvlName,
    this.roomId,
  });

  factory AptDevice.fromJson(Map<String, dynamic> j) => AptDevice(
    id:             j['id']               as int,
    name:           j['name']             as String,
    deviceType:     j['device_type']      as String,
    channelOrIndex: j['channel_or_index'] as int? ?? 0,
    gvlName:        j['gvl_name']         as String? ?? '',
    roomId:         j['room_id']          as int?,
  );

  String get typeLabel {
    const labels = {
      'dali':          'DALI Light',
      'relay':         'Wall Relay',
      'curtain':       'Curtain Motor',
      'appliance':     'Appliance',
      'door_sensor':   'Door Sensor',
      'window_sensor': 'Window Sensor',
      'motion_sensor': 'Motion Sensor',
      'switch':        'Switch Input',
    };
    return labels[deviceType] ?? deviceType;
  }

  bool get isActuator => const {'dali', 'relay', 'curtain', 'appliance'}.contains(deviceType);
}

// ── I/O Test Result ───────────────────────────────────────────────────────────

enum IOTestStatus { untested, testing, passed, failed }

class IOTestResult {
  final int          deviceId;
  final String       deviceName;
  final String       deviceType;
  final IOTestStatus status;
  final String?      action;
  final String?      error;

  const IOTestResult({
    required this.deviceId,
    required this.deviceName,
    required this.deviceType,
    required this.status,
    this.action,
    this.error,
  });

  IOTestResult copyWith({IOTestStatus? status, String? action, String? error}) =>
    IOTestResult(
      deviceId:   deviceId,
      deviceName: deviceName,
      deviceType: deviceType,
      status:     status ?? this.status,
      action:     action ?? this.action,
      error:      error ?? this.error,
    );
}

// ── Commissioning Checklist ───────────────────────────────────────────────────

class CommissioningChecklist {
  final Map<String, CheckStep> steps;
  final Map<String, int>        counts;
  final ApartmentInfo?          apartment;

  const CommissioningChecklist({
    required this.steps,
    required this.counts,
    this.apartment,
  });

  int get completedSteps => steps.values.where((s) => s.done).length;
  int get totalSteps     => steps.length;
  bool get allDone       => completedSteps == totalSteps;

  bool stepDone(String key) => (steps[key])?.done ?? false;

  factory CommissioningChecklist.fromJson(Map<String, dynamic> j) {
    final rawSteps = (j['steps'] as Map<String, dynamic>?) ?? {};
    final rawCounts = (j['counts'] as Map<String, dynamic>?) ?? {};
    final rawApt = j['apartment'] as Map<String, dynamic>?;

    return CommissioningChecklist(
      steps: rawSteps.map(
        (k, v) => MapEntry(k, CheckStep.fromJson(v as Map<String, dynamic>)),
      ),
      counts: rawCounts.map(
        (k, v) => MapEntry(k, (v as num).toInt()),
      ),
      apartment: rawApt != null ? ApartmentInfo.fromJson(rawApt) : null,
    );
  }
}

class CheckStep {
  final bool   done;
  final String label;

  const CheckStep({required this.done, required this.label});

  factory CheckStep.fromJson(Map<String, dynamic> j) => CheckStep(
    done:  j['done']  as bool? ?? false,
    label: j['label'] as String? ?? '',
  );
}

// ── Handover Summary ──────────────────────────────────────────────────────────

class HandoverSummary {
  final ApartmentInfo       apartment;
  final Map<String, dynamic>? plc;
  final List<Map<String, dynamic>> rooms;
  final List<Map<String, dynamic>> devices;
  final Map<String, int>    deviceCounts;
  final List<Map<String, dynamic>> residents;
  final Map<String, dynamic>? map;

  const HandoverSummary({
    required this.apartment,
    required this.rooms,
    required this.devices,
    required this.deviceCounts,
    required this.residents,
    this.plc,
    this.map,
  });

  factory HandoverSummary.fromJson(Map<String, dynamic> j) => HandoverSummary(
    apartment:    ApartmentInfo.fromJson(j['apartment'] as Map<String, dynamic>),
    plc:          j['plc'] as Map<String, dynamic>?,
    rooms:        List<Map<String, dynamic>>.from(j['rooms'] as List? ?? []),
    devices:      List<Map<String, dynamic>>.from(j['devices'] as List? ?? []),
    deviceCounts: Map<String, int>.from(
      (j['device_counts'] as Map<String, dynamic>? ?? {}).map(
        (k, v) => MapEntry(k, (v as num).toInt()),
      ),
    ),
    residents:    List<Map<String, dynamic>>.from(j['residents'] as List? ?? []),
    map:          j['map'] as Map<String, dynamic>?,
  );
}
