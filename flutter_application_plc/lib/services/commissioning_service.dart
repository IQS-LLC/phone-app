import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/commissioning_models.dart';

/// HTTP service for the Tech Team Commissioning Wizard.
///
/// All endpoints require an admin JWT. The token provider is the same one used
/// by ApiService — pass it through from the main auth state.
class CommissioningService {
  final String baseUrl;
  final Future<String?> Function()? tokenProvider;
  final Future<String?> Function()? tokenRefresher;

  static const _timeout = Duration(seconds: 30); // scans can be slow

  CommissioningService(
    this.baseUrl, {
    this.tokenProvider,
    this.tokenRefresher,
  });

  // ── Auth headers ─────────────────────────────────────────────────────────────

  Future<Map<String, String>> _headers({bool json = false}) async {
    final token = await tokenProvider?.call();
    return {
      'Content-Type': json ? 'application/json' : 'application/x-www-form-urlencoded',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  // ── Low-level helpers ────────────────────────────────────────────────────────

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
    } catch (_) {
      return {'ok': false, 'error': "Can't reach the server. Check your connection."};
    }
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body,
      {bool useJson = false}) async {
    try {
      final hdrs = await _headers(json: useJson);
      final encoded =
          useJson ? jsonEncode(body) : Uri(queryParameters: body.map((k, v) => MapEntry(k, v.toString()))).query;

      var resp = await http
          .post(Uri.parse('$baseUrl$path'), headers: hdrs, body: encoded)
          .timeout(_timeout);

      if (resp.statusCode == 401 && tokenRefresher != null) {
        await tokenRefresher!();
        final hdrs2 = await _headers(json: useJson);
        resp = await http
            .post(Uri.parse('$baseUrl$path'), headers: hdrs2, body: encoded)
            .timeout(_timeout);
      }
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } on SocketException {
      return {'ok': false, 'error': 'No connection to server'};
    } on TimeoutException {
      return {'ok': false, 'error': 'Request timed out'};
    } catch (_) {
      return {'ok': false, 'error': "Can't reach the server. Check your connection."};
    }
  }

  // ── Step 0: Network Discovery ─────────────────────────────────────────────

  /// Scan configured subnets for Beckhoff ADS targets.
  Future<CommResult<List<DiscoveredPLC>>> scanNetwork() async {
    final r = await _post('/manage/discovery/network-scan/', {});
    if (r['ok'] != true) return CommResult.err(r['error'] as String? ?? 'Scan failed');

    final data = r['data'] as Map<String, dynamic>? ?? {};
    final raw  = data['devices'] as List? ?? [];
    final devices = raw
        .whereType<Map<String, dynamic>>()
        .map(DiscoveredPLC.fromJson)
        .toList();
    return CommResult.ok(devices);
  }

  /// Register a discovered PLC in the database.
  Future<CommResult<int>> registerPLC({
    required String name,
    required String ipAddress,
    required String amsNetId,
    int adsPort = 851,
  }) async {
    final r = await _post('/manage/devices/', {
      'name':       name,
      'ip_address': ipAddress,
      'ams_net_id': amsNetId,
      'ads_port':   adsPort.toString(),
    });
    if (r['ok'] != true) return CommResult.err(r['error'] as String? ?? 'Registration failed');
    final id = (r['device'] as Map<String, dynamic>?)?['id'] as int?;
    if (id == null) return CommResult.err('No device id in response');
    return CommResult.ok(id);
  }

  // ── Step 1: PLC Connectivity Test ────────────────────────────────────────

  Future<CommResult<PLCTestResult>> testPLC(int deviceId) async {
    final r = await _post('/manage/devices/$deviceId/test/', {});
    if (r['ok'] != true) return CommResult.err(r['error'] as String? ?? 'Test failed');
    final data = r['data'] as Map<String, dynamic>? ?? {};
    return CommResult.ok(PLCTestResult.fromJson(data));
  }

  // ── Step 2: Apartment & Rooms ────────────────────────────────────────────

  Future<CommResult<List<ApartmentInfo>>> listApartments() async {
    final r = await _get('/manage/apartments/');
    if (r['ok'] != true) return CommResult.err(r['error'] as String? ?? 'Failed to list apartments');
    final raw = r['apartments'] as List? ?? [];
    final list = raw.whereType<Map<String, dynamic>>().map(ApartmentInfo.fromJson).toList();
    return CommResult.ok(list);
  }

  Future<CommResult<ApartmentInfo>> createApartment({
    required String name,
    String building = '',
    String floor    = '',
  }) async {
    final r = await _post('/manage/apartments/', {
      'name':     name,
      'building': building,
      'floor':    floor,
    });
    if (r['ok'] != true) return CommResult.err(r['error'] as String? ?? 'Create failed');
    final apt = r['apartment'] as Map<String, dynamic>?;
    if (apt == null) return CommResult.err('No apartment in response');
    return CommResult.ok(ApartmentInfo.fromJson(apt));
  }

  Future<CommResult<void>> assignPLC(int apartmentId, int deviceId) async {
    final r = await _post('/manage/apartments/$apartmentId/plc/', {
      'device_id': deviceId.toString(),
    });
    if (r['ok'] != true) return CommResult.err(r['error'] as String? ?? 'Assign failed');
    return CommResult.ok(null);
  }

  Future<CommResult<void>> addRoom(int apartmentId, String name) async {
    final r = await _post('/manage/apartments/$apartmentId/rooms/', {'name': name});
    if (r['ok'] != true) return CommResult.err(r['error'] as String? ?? 'Add room failed');
    return CommResult.ok(null);
  }

  // ── Step 3: Symbol Discovery ─────────────────────────────────────────────

  Future<CommResult<SymbolScanResult>> scanSymbols(int deviceId) async {
    final r = await _post('/manage/discovery/$deviceId/scan/', {});
    if (r['ok'] != true) return CommResult.err(r['error'] as String? ?? 'Symbol scan failed');
    final data = r['data'] as Map<String, dynamic>? ?? {};
    return CommResult.ok(SymbolScanResult.fromJson(data));
  }

  // ── Step 5: Apartment Devices ─────────────────────────────────────────────

  Future<CommResult<List<AptDevice>>> listDevices(int apartmentId) async {
    final r = await _get('/manage/apartments/$apartmentId/devices/');
    if (r['ok'] != true) return CommResult.err(r['error'] as String? ?? 'Failed');
    final raw = r['devices'] as List? ?? [];
    final list = raw.whereType<Map<String, dynamic>>().map(AptDevice.fromJson).toList();
    return CommResult.ok(list);
  }

  // ── Step 6: I/O Test ─────────────────────────────────────────────────────

  Future<CommResult<Map<String, dynamic>>> testIODevice(
    int apartmentId,
    int deviceId,
  ) async {
    final r = await _post(
      '/commissioning/$apartmentId/test-io/',
      {'device_id': deviceId.toString()},
    );
    if (r['ok'] != true) return CommResult.err(r['error'] as String? ?? 'Test failed');
    return CommResult.ok(r);
  }

  // ── Step 7: Publish Map ──────────────────────────────────────────────────

  Future<CommResult<void>> publishMap(int apartmentId) async {
    final r = await _post(
      '/map/$apartmentId/publish/',
      {'description': 'Commissioned ${DateTime.now().toIso8601String()}'},
    );
    if (r['ok'] != true) return CommResult.err(r['error'] as String? ?? 'Publish failed');
    return CommResult.ok(null);
  }

  // ── Step 8: Resident Accounts ────────────────────────────────────────────

  Future<CommResult<int>> createResident({
    required String username,
    required String email,
    required String password,
  }) async {
    final r = await _post('/auth/register/', {
      'username': username,
      'email':    email,
      'password': password,
    });
    if (r['ok'] != true) return CommResult.err(r['error'] as String? ?? 'Create user failed');
    final uid = (r['user'] as Map<String, dynamic>?)?['id'] as int?;
    if (uid == null) return CommResult.err('No user id in response');
    return CommResult.ok(uid);
  }

  Future<CommResult<void>> assignResident(int userId, int apartmentId) async {
    final r = await _post('/manage/users/$userId/assign-apartment/', {
      'apartment_id': apartmentId.toString(),
      'role':         'resident',
    });
    if (r['ok'] != true) return CommResult.err(r['error'] as String? ?? 'Assign failed');
    return CommResult.ok(null);
  }

  // ── Checklist & Summary ──────────────────────────────────────────────────

  Future<CommResult<CommissioningChecklist>> getChecklist(int apartmentId) async {
    final r = await _get('/commissioning/$apartmentId/checklist/');
    if (r['ok'] != true) return CommResult.err(r['error'] as String? ?? 'Failed');
    return CommResult.ok(CommissioningChecklist.fromJson(r));
  }

  Future<CommResult<HandoverSummary>> getSummary(int apartmentId) async {
    final r = await _get('/commissioning/$apartmentId/summary/');
    if (r['ok'] != true) return CommResult.err(r['error'] as String? ?? 'Failed');
    return CommResult.ok(HandoverSummary.fromJson(r));
  }
}

// ── Result type ───────────────────────────────────────────────────────────────

class CommResult<T> {
  final T?      data;
  final String? error;

  const CommResult._({this.data, this.error});

  factory CommResult.ok(T data)       => CommResult._(data: data);
  factory CommResult.err(String error) => CommResult._(error: error);

  bool get success => error == null;
  T get value      => data as T;
}
