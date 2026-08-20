/// One output channel slot (DALI dimmer, wall relay, or curtain) as
/// reported by GET `/relabel/{apt}/outputs/{type}/` — either already
/// assigned to a room+name, or still unlabeled.
class OutputChannelSlot {
  final int     channel;
  final bool    assigned;
  final int?    deviceId;
  final String? name;
  final int?    roomId;
  final String? roomName;

  const OutputChannelSlot({
    required this.channel,
    required this.assigned,
    this.deviceId,
    this.name,
    this.roomId,
    this.roomName,
  });

  factory OutputChannelSlot.fromJson(Map<String, dynamic> j) => OutputChannelSlot(
        channel:  j['channel'] as int,
        assigned: j['assigned'] as bool? ?? false,
        deviceId: j['device_id'] as int?,
        name:     j['name'] as String?,
        roomId:   j['room_id'] as int?,
        roomName: j['room_name'] as String?,
      );

  OutputChannelSlot copyWith({String? name, int? roomId, String? roomName}) => OutputChannelSlot(
        channel:  channel,
        assigned: true,
        deviceId: deviceId,
        name:     name ?? this.name,
        roomId:   roomId ?? this.roomId,
        roomName: roomName ?? this.roomName,
      );
}

/// One raw input channel (switch, motion/door/window sensor) as reported
/// by GET `/relabel/{apt}/inputs/` — includes its LIVE boolean state so the
/// app can highlight whichever one just changed when a physical switch is
/// pressed or a sensor trips, whether or not it's assigned yet.
class InputChannelSlot {
  final int     index;
  final bool?   state;
  final bool    assigned;
  final int?    deviceId;
  final String? name;
  final int?    roomId;
  final String? roomName;

  const InputChannelSlot({
    required this.index,
    required this.state,
    required this.assigned,
    this.deviceId,
    this.name,
    this.roomId,
    this.roomName,
  });

  factory InputChannelSlot.fromJson(Map<String, dynamic> j) => InputChannelSlot(
        index:    j['index'] as int,
        state:    j['state'] as bool?,
        assigned: j['assigned'] as bool? ?? false,
        deviceId: j['device_id'] as int?,
        name:     j['name'] as String?,
        roomId:   j['room_id'] as int?,
        roomName: j['room_name'] as String?,
      );
}

/// A room/group the picker can offer or create — deliberately just an
/// {id, name} pair: Room.name is free text server-side, so "Bathroom 1",
/// "Bathroom 2", "Bedroom Main", "Guest Bedroom" are just distinct rows,
/// no separate numbering scheme needed.
class RelabelRoom {
  final int    id;
  final String name;

  const RelabelRoom({required this.id, required this.name});

  factory RelabelRoom.fromJson(Map<String, dynamic> j) => RelabelRoom(
        id:   j['id'] as int,
        name: j['name'] as String,
      );
}
