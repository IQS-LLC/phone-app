/// Tri/quad-state device representation — the single place "what does this
/// reading actually mean" gets decided, so no widget has to reinvent
/// `value ?? false` (which silently turns "we don't know" into a confident
/// OFF — the exact bug this type exists to make structurally hard to write
/// again; found live 2026-08-20 during QA, see AppState._poll()).
enum DeviceState {
  /// Confirmed on, from a live, connected read (or an in-flight optimistic
  /// command not yet contradicted by the server).
  on,

  /// Confirmed off, same confidence level as [on].
  off,

  /// The system is connected and otherwise healthy, but this specific
  /// symbol's own read failed (e.g. the long-standing Switch 3 PLC symbol
  /// mismatch) — everything else on the poll is trustworthy, just not this
  /// one value.
  unknown,

  /// The server or the PLC itself is unreachable — nothing read this poll
  /// can be trusted, this device included. Distinct from [unknown] because
  /// the UI copy and recovery action differ: "check this switch" vs.
  /// "check your connection."
  unavailable,
}

extension DeviceStateX on DeviceState {
  bool get isKnown => this == DeviceState.on || this == DeviceState.off;
  bool get isOn => this == DeviceState.on;
  bool get isIndeterminate => this == DeviceState.unknown || this == DeviceState.unavailable;

  /// Short, plain-language label for badges/pills. Never "null" or "?" —
  /// residents should never see a raw programming artifact.
  String get label => switch (this) {
        DeviceState.on => 'ON',
        DeviceState.off => 'OFF',
        DeviceState.unknown => 'UNKNOWN',
        DeviceState.unavailable => 'UNAVAILABLE',
      };
}

/// Resolves a nullable bool reading (pending optimistic value, live poll
/// value, and whether the system is currently connected) into a
/// [DeviceState]. Free function, not a method on AppState, so the same
/// logic is trivially reusable/testable outside it.
DeviceState resolveDeviceState({
  required bool? pending,
  required bool? raw,
  required bool systemConnected,
}) {
  if (pending != null) return pending ? DeviceState.on : DeviceState.off;
  if (!systemConnected) return DeviceState.unavailable;
  if (raw == null) return DeviceState.unknown;
  return raw ? DeviceState.on : DeviceState.off;
}

/// Brightness (0-100) is never boolean, but needs the same three-way
/// "do we actually know this" resolution — 0% is a legitimate, confident
/// OFF, not the same thing as "we have no reading."
class BrightnessReading {
  final int? percent; // null only when state is unknown/unavailable
  final DeviceState state;
  const BrightnessReading(this.percent, this.state);

  /// For call sites that need *some* number regardless (slider fill
  /// position while disconnected, etc.) — never for deciding what badge
  /// or color to show, which must branch on [state] instead.
  int get orZero => percent ?? 0;
}

BrightnessReading resolveBrightnessState({
  required int? pending,
  required int? raw,
  required bool systemConnected,
}) {
  if (pending != null) {
    return BrightnessReading(pending, pending > 0 ? DeviceState.on : DeviceState.off);
  }
  if (!systemConnected) return const BrightnessReading(null, DeviceState.unavailable);
  if (raw == null) return const BrightnessReading(null, DeviceState.unknown);
  return BrightnessReading(raw, raw > 0 ? DeviceState.on : DeviceState.off);
}
