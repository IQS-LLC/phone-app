/// SuperScan — discovery/capability-mapping data models. Mirrors the shape
/// of find_device.superscan_views._run_dict / DiscoveredCapability.to_dict /
/// CapabilityTestLog.to_dict on the backend.

class ScanRunSummary {
  final int    id;
  final String mode;
  final String status;
  final String? startedBy;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final bool   cancelRequested;
  final int    progressCurrent;
  final int    progressTotal;
  final String progressLabel;
  final int    devicesDiscovered;
  final int    capabilitiesDiscovered;
  final int    capabilitiesTested;
  final int    testsPassed;
  final int    testsFailed;
  final int    unknownCount;
  final int    newSinceLast;
  final int    changedSinceLast;
  final int    removedSinceLast;
  final String errorMessage;

  const ScanRunSummary({
    required this.id,
    required this.mode,
    required this.status,
    this.startedBy,
    required this.startedAt,
    this.finishedAt,
    required this.cancelRequested,
    required this.progressCurrent,
    required this.progressTotal,
    required this.progressLabel,
    required this.devicesDiscovered,
    required this.capabilitiesDiscovered,
    required this.capabilitiesTested,
    required this.testsPassed,
    required this.testsFailed,
    required this.unknownCount,
    required this.newSinceLast,
    required this.changedSinceLast,
    required this.removedSinceLast,
    required this.errorMessage,
  });

  bool get isRunning => status == 'running';
  double get progressFraction =>
      progressTotal <= 0 ? 0 : (progressCurrent / progressTotal).clamp(0, 1);

  factory ScanRunSummary.fromJson(Map<String, dynamic> j) => ScanRunSummary(
        id:      j['id'] as int,
        mode:    j['mode'] as String,
        status:  j['status'] as String,
        startedBy: j['started_by'] as String?,
        startedAt: DateTime.parse(j['started_at'] as String),
        finishedAt: j['finished_at'] == null ? null : DateTime.parse(j['finished_at'] as String),
        cancelRequested: j['cancel_requested'] as bool? ?? false,
        progressCurrent: j['progress_current'] as int? ?? 0,
        progressTotal:   j['progress_total'] as int? ?? 0,
        progressLabel:   j['progress_label'] as String? ?? '',
        devicesDiscovered:       j['devices_discovered'] as int? ?? 0,
        capabilitiesDiscovered:  j['capabilities_discovered'] as int? ?? 0,
        capabilitiesTested:      j['capabilities_tested'] as int? ?? 0,
        testsPassed:             j['tests_passed'] as int? ?? 0,
        testsFailed:             j['tests_failed'] as int? ?? 0,
        unknownCount:            j['unknown_count'] as int? ?? 0,
        newSinceLast:            j['new_since_last'] as int? ?? 0,
        changedSinceLast:        j['changed_since_last'] as int? ?? 0,
        removedSinceLast:        j['removed_since_last'] as int? ?? 0,
        errorMessage: j['error_message'] as String? ?? '',
      );
}

class DiscoveredCapabilitySummary {
  final int     id;
  final int?    apartmentDeviceId;
  final String  deviceType;
  final String  identifier;
  final String  name;
  final String  room;
  final String  direction;
  final bool    isKnownType;
  final String  rawVarName;
  final String  dataType;
  final String  validRange;
  final String  testStatus;
  final String  confidence;
  final bool    physicalEffectConfirmed;
  final bool    canSafelyTest;
  final String  lastValue;
  final DateTime? lastTestedAt;
  final DateTime firstSeenAt;
  final bool    stillPresent;
  final String  notes;

  const DiscoveredCapabilitySummary({
    required this.id,
    this.apartmentDeviceId,
    required this.deviceType,
    required this.identifier,
    required this.name,
    required this.room,
    required this.direction,
    required this.isKnownType,
    required this.rawVarName,
    required this.dataType,
    required this.validRange,
    required this.testStatus,
    required this.confidence,
    required this.physicalEffectConfirmed,
    required this.canSafelyTest,
    required this.lastValue,
    this.lastTestedAt,
    required this.firstSeenAt,
    required this.stillPresent,
    required this.notes,
  });

  factory DiscoveredCapabilitySummary.fromJson(Map<String, dynamic> j) => DiscoveredCapabilitySummary(
        id: j['id'] as int,
        apartmentDeviceId: j['apartment_device_id'] as int?,
        deviceType: j['device_type'] as String,
        identifier: j['identifier'] as String,
        name: j['name'] as String? ?? '',
        room: j['room'] as String? ?? '',
        direction: j['direction'] as String? ?? 'output',
        isKnownType: j['is_known_type'] as bool? ?? true,
        rawVarName: j['raw_var_name'] as String? ?? '',
        dataType: j['data_type'] as String? ?? '',
        validRange: j['valid_range'] as String? ?? '',
        testStatus: j['test_status'] as String? ?? 'not_tested',
        confidence: j['confidence'] as String? ?? 'high',
        physicalEffectConfirmed: j['physical_effect_confirmed'] as bool? ?? false,
        canSafelyTest: j['can_safely_test'] as bool? ?? false,
        lastValue: j['last_value'] as String? ?? '',
        lastTestedAt: j['last_tested_at'] == null ? null : DateTime.parse(j['last_tested_at'] as String),
        firstSeenAt: DateTime.parse(j['first_seen_at'] as String),
        stillPresent: j['still_present'] as bool? ?? true,
        notes: j['notes'] as String? ?? '',
      );
}

class CapabilityTestLogSummary {
  final int     id;
  final DateTime timestamp;
  final String  commandSent;
  final Map<String, dynamic> params;
  final String  stateBefore;
  final String  stateAfter;
  final String  response;
  final bool    success;
  final double? latencyMs;
  final String  error;

  const CapabilityTestLogSummary({
    required this.id,
    required this.timestamp,
    required this.commandSent,
    required this.params,
    required this.stateBefore,
    required this.stateAfter,
    required this.response,
    required this.success,
    this.latencyMs,
    required this.error,
  });

  factory CapabilityTestLogSummary.fromJson(Map<String, dynamic> j) => CapabilityTestLogSummary(
        id: j['id'] as int,
        timestamp: DateTime.parse(j['timestamp'] as String),
        commandSent: j['command_sent'] as String? ?? '',
        params: (j['params'] as Map?)?.cast<String, dynamic>() ?? {},
        stateBefore: j['state_before'] as String? ?? '',
        stateAfter: j['state_after'] as String? ?? '',
        response: j['response'] as String? ?? '',
        success: j['success'] as bool? ?? false,
        latencyMs: (j['latency_ms'] as num?)?.toDouble(),
        error: j['error'] as String? ?? '',
      );
}

class CapabilitySummaryCounts {
  final int total, known, unknown, testedOk, testedFailed, observedOnly, notTested;
  const CapabilitySummaryCounts({
    required this.total, required this.known, required this.unknown,
    required this.testedOk, required this.testedFailed,
    required this.observedOnly, required this.notTested,
  });

  factory CapabilitySummaryCounts.fromJson(Map<String, dynamic> j) => CapabilitySummaryCounts(
        total: j['total'] as int? ?? 0,
        known: j['known'] as int? ?? 0,
        unknown: j['unknown'] as int? ?? 0,
        testedOk: j['tested_ok'] as int? ?? 0,
        testedFailed: j['tested_failed'] as int? ?? 0,
        observedOnly: j['observed_only'] as int? ?? 0,
        notTested: j['not_tested'] as int? ?? 0,
      );

  static const empty = CapabilitySummaryCounts(
    total: 0, known: 0, unknown: 0, testedOk: 0, testedFailed: 0, observedOnly: 0, notTested: 0,
  );
}

class SuperscanResult<T> {
  final T?      data;
  final String? error;
  const SuperscanResult._({this.data, this.error});
  factory SuperscanResult.ok(T data) => SuperscanResult._(data: data);
  factory SuperscanResult.err(String error) => SuperscanResult._(error: error);
  bool get success => error == null;
  T get value => data as T;
}
