import '../utils/room_display.dart';

/// A device eligible to be a trigger (switch/motion/door/window sensor) or
/// an action (DALI/relay/curtain/appliance) in an AutomationRule.
class AutomationDevice {
  final int     id;
  final String  name;
  final String  deviceType;
  final int?    channelOrIndex;
  final String? roomName;

  const AutomationDevice({
    required this.id,
    required this.name,
    required this.deviceType,
    this.channelOrIndex,
    this.roomName,
  });

  factory AutomationDevice.fromJson(Map<String, dynamic> j) => AutomationDevice(
        id:             j['id'] as int,
        name:           j['name'] as String,
        deviceType:     j['device_type'] as String,
        channelOrIndex: j['channel_or_index'] as int?,
        roomName:       j['room_name'] as String?,
      );

  String get label => roomName != null ? '$name (${RoomDisplay.label(roomName!)})' : name;
}

/// "When [triggerDevice] becomes [triggerState], set [actionDevice] to
/// [actionValue]" — one automation rule, configured entirely on the phone.
class AutomationRuleSummary {
  final int    id;
  final String name;
  final bool   enabled;
  final AutomationDevice triggerDevice;
  final bool   triggerState;
  final AutomationDevice actionDevice;
  final String actionValue;

  const AutomationRuleSummary({
    required this.id,
    required this.name,
    required this.enabled,
    required this.triggerDevice,
    required this.triggerState,
    required this.actionDevice,
    required this.actionValue,
  });

  factory AutomationRuleSummary.fromJson(Map<String, dynamic> j) => AutomationRuleSummary(
        id:            j['id'] as int,
        name:          j['name'] as String,
        enabled:       j['enabled'] as bool,
        triggerDevice: AutomationDevice.fromJson(j['trigger_device'] as Map<String, dynamic>),
        triggerState:  j['trigger_state'] as bool,
        actionDevice:  AutomationDevice.fromJson(j['action_device'] as Map<String, dynamic>),
        actionValue:   j['action_value'] as String,
      );
}
