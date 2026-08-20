import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/relabel_models.dart';

/// HTTP client for the Light/Device Relabel flow (find_device/relabel_views.py).
///
/// is_staff (IT Team) ONLY server-side — not Owner, not Installer, not even
/// Building Owner (see has_relabel_access in permissions.py). This is its
/// own small client rather than bolted onto CommissioningService, since the
/// UX (guided single-channel wizard, not a full 9-step onboarding flow) and
/// the "test a channel with no ApartmentDevice row yet" capability are both
/// distinct from what the commissioning wizard does.
class LightRelabelService {
  final String baseUrl;
  final Future<String?> Function()? tokenProvider;
  final Future<String?> Function()? tokenRefresher;

  static const _timeout = Duration(seconds: 15);

  LightRelabelService(
    this.baseUrl, {
    this.tokenProvider,
    this.tokenRefresher,
  });

  Future<Map<String, String>> _headers({bool json = false}) async {
    final token = await tokenProvider?.call();
    return {
      'Content-Type': json ? 'application/json' : 'application/x-www-form-urlencoded',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  Future<Map<String, dynamic>> _get(String path) async {
    try {
      var resp = await http
          .get(Uri.parse('$baseUrl$path'), headers: await _headers())
          .timeout(_timeout);
      if (resp.statusCode == 401 && tokenRefresher != null) {
        await tokenRefresher!();
        resp = await http
            .get(Uri.parse('$baseUrl$path'), headers: await _headers())
            .timeout(_timeout);
      }
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } on SocketException {
      return {'ok': false, 'error': 'No connection to server'};
    } on TimeoutException {
      return {'ok': false, 'error': 'Request timed out'};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    try {
      final hdrs = await _headers();
      final encoded = Uri(queryParameters: body.map((k, v) => MapEntry(k, v.toString()))).query;
      var resp = await http
          .post(Uri.parse('$baseUrl$path'), headers: hdrs, body: encoded)
          .timeout(_timeout);
      if (resp.statusCode == 401 && tokenRefresher != null) {
        await tokenRefresher!();
        final hdrs2 = await _headers();
        resp = await http
            .post(Uri.parse('$baseUrl$path'), headers: hdrs2, body: encoded)
            .timeout(_timeout);
      }
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } on SocketException {
      return {'ok': false, 'error': 'No connection to server'};
    } on TimeoutException {
      return {'ok': false, 'error': 'Request timed out'};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  // ── Outputs: DALI / relay / curtain ─────────────────────────────────────────

  /// Every channel of [deviceType] ('dali'|'relay'|'curtain') plus the
  /// apartment's room list.
  Future<RelabelResult<(List<OutputChannelSlot>, List<RelabelRoom>)>> listOutputChannels(
    int apartmentId,
    String deviceType,
  ) async {
    final r = await _get('/relabel/$apartmentId/outputs/$deviceType/');
    if (r['ok'] != true) {
      return RelabelResult.err(r['error'] as String? ?? 'Failed to load channels');
    }
    final channels = (r['channels'] as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(OutputChannelSlot.fromJson)
        .toList();
    final rooms = (r['rooms'] as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(RelabelRoom.fromJson)
        .toList();
    return RelabelResult.ok((channels, rooms));
  }

  /// Flash-test one output channel, whether or not it's assigned yet.
  Future<RelabelResult<String>> flashOutputChannel(
    int apartmentId,
    String deviceType,
    int channel,
  ) async {
    final r = await _post('/relabel/$apartmentId/outputs/$deviceType/$channel/flash/', {});
    if (r['ok'] != true) return RelabelResult.err(r['error'] as String? ?? 'Flash failed');
    return RelabelResult.ok(r['action'] as String? ?? 'Flashed');
  }

  /// Set/replace this output channel's room + display name. Pass exactly
  /// one of roomId (reuse an existing room) or roomName (create/reuse by name).
  Future<RelabelResult<OutputChannelSlot>> assignOutputChannel(
    int apartmentId,
    String deviceType,
    int channel, {
    required String name,
    int? roomId,
    String? roomName,
  }) async {
    final r = await _post('/relabel/$apartmentId/outputs/$deviceType/$channel/assign/', {
      'name': name,
      if (roomId != null) 'room_id': roomId,
      if (roomId == null && roomName != null) 'room_name': roomName,
    });
    if (r['ok'] != true) return RelabelResult.err(r['error'] as String? ?? 'Assign failed');
    return RelabelResult.ok(OutputChannelSlot(
      channel:  r['channel'] as int,
      assigned: true,
      deviceId: r['device_id'] as int?,
      name:     r['name'] as String?,
      roomId:   r['room_id'] as int?,
      roomName: r['room_name'] as String?,
    ));
  }

  // ── Inputs: switch / motion / door / window sensor ──────────────────────────

  /// Live state for every raw input channel — switches, motion sensors,
  /// door sensors, window sensors — whether or not they're assigned yet,
  /// plus the room list. Poll this repeatedly to build a "press the switch
  /// and watch which one lights up" identify flow.
  Future<RelabelResult<InputSnapshot>> listInputs(int apartmentId) async {
    final r = await _get('/relabel/$apartmentId/inputs/');
    if (r['ok'] != true) {
      return RelabelResult.err(r['error'] as String? ?? 'Failed to load inputs');
    }
    List<InputChannelSlot> parse(String key) => (r[key] as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(InputChannelSlot.fromJson)
        .toList();
    final rooms = (r['rooms'] as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(RelabelRoom.fromJson)
        .toList();
    return RelabelResult.ok(InputSnapshot(
      switches:      parse('switches'),
      motionSensors: parse('motion_sensors'),
      doorSensors:   parse('door_sensors'),
      windowSensors: parse('window_sensors'),
      rooms: rooms,
    ));
  }

  /// Assign a room + display name to one raw input channel. [deviceType]
  /// is one of 'switch'|'motion_sensor'|'door_sensor'|'window_sensor'.
  Future<RelabelResult<InputChannelSlot>> assignInput(
    int apartmentId, {
    required String deviceType,
    required int index,
    required String name,
    int? roomId,
    String? roomName,
  }) async {
    final r = await _post('/relabel/$apartmentId/inputs/assign/', {
      'device_type': deviceType,
      'index': index,
      'name': name,
      if (roomId != null) 'room_id': roomId,
      if (roomId == null && roomName != null) 'room_name': roomName,
    });
    if (r['ok'] != true) return RelabelResult.err(r['error'] as String? ?? 'Assign failed');
    return RelabelResult.ok(InputChannelSlot(
      index:    r['index'] as int,
      state:    null,
      assigned: true,
      deviceId: r['device_id'] as int?,
      name:     r['name'] as String?,
      roomId:   r['room_id'] as int?,
      roomName: r['room_name'] as String?,
    ));
  }
}

class InputSnapshot {
  final List<InputChannelSlot> switches;
  final List<InputChannelSlot> motionSensors;
  final List<InputChannelSlot> doorSensors;
  final List<InputChannelSlot> windowSensors;
  final List<RelabelRoom> rooms;

  const InputSnapshot({
    required this.switches,
    required this.motionSensors,
    required this.doorSensors,
    required this.windowSensors,
    required this.rooms,
  });
}

class RelabelResult<T> {
  final T?      data;
  final String? error;

  const RelabelResult._({this.data, this.error});

  factory RelabelResult.ok(T data) => RelabelResult._(data: data);
  factory RelabelResult.err(String error) => RelabelResult._(error: error);

  bool get success => error == null;
  T get value => data as T;
}
