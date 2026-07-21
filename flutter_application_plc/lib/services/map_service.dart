import 'dart:convert';
import 'package:http/http.dart' as http;

import '../models/map_models.dart';

/// HTTP service for the Digital Twin Map Editor API.
/// All mutating endpoints require is_staff; reads are accessible to members.
class MapService {
  final Future<String?> Function() _getToken;
  final Future<String?> Function() _getBaseUrl;

  MapService({
    required Future<String?> Function() getToken,
    required Future<String?> Function() getBaseUrl,
  })  : _getToken   = getToken,
        _getBaseUrl = getBaseUrl;

  // ── Helpers ─────────────────────────────────────────────────────────────────

  Future<Map<String, String>> _headers({bool json = true}) async {
    final token   = await _getToken();
    final headers = <String, String>{
      if (json) 'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
    return headers;
  }

  Future<Uri> _uri(String path) async {
    final base = await _getBaseUrl() ?? 'http://10.0.2.2:8000';
    return Uri.parse('$base$path');
  }

  Future<String?> getBaseUrl() => _getBaseUrl();

  Map<String, dynamic>? _ok(http.Response resp) {
    try {
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      if (j['ok'] == true) return j;
    } catch (_) {}
    return null;
  }

  // ── Apartment list (editor picker) ─────────────────────────────────────────

  Future<List<ApartmentEditorEntry>> fetchApartments() async {
    final resp = await http
        .get(await _uri('/map/apartments/'), headers: await _headers(json: false))
        .timeout(const Duration(seconds: 10));
    final j = _ok(resp);
    if (j == null) return [];
    return (j['apartments'] as List<dynamic>)
        .map((e) => ApartmentEditorEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ── Layout CRUD ─────────────────────────────────────────────────────────────

  Future<EditorLayout?> fetchLayout(int apartmentId) async {
    final resp = await http
        .get(await _uri('/map/$apartmentId/'), headers: await _headers(json: false))
        .timeout(const Duration(seconds: 10));
    final j = _ok(resp);
    if (j == null || j['layout'] == null) return null;
    return EditorLayout.fromJson(j['layout'] as Map<String, dynamic>);
  }

  Future<EditorLayout?> saveLayout(int apartmentId, EditorLayout layout) async {
    final body = jsonEncode(layout.toSaveJson());
    final resp = await http
        .put(
          await _uri('/map/$apartmentId/'),
          headers: await _headers(),
          body: body,
        )
        .timeout(const Duration(seconds: 20));
    final j = _ok(resp);
    if (j == null || j['layout'] == null) return null;
    return EditorLayout.fromJson(j['layout'] as Map<String, dynamic>);
  }

  // ── Background image ────────────────────────────────────────────────────────

  Future<String?> setBackgroundUrl(int apartmentId, String url) async {
    final resp = await http
        .post(
          await _uri('/map/$apartmentId/background/'),
          headers: await _headers(),
          body: jsonEncode({'url': url}),
        )
        .timeout(const Duration(seconds: 10));
    final j = _ok(resp);
    return j?['url'] as String?;
  }

  Future<bool> removeBackground(int apartmentId) async {
    final resp = await http
        .delete(await _uri('/map/$apartmentId/background/'), headers: await _headers(json: false))
        .timeout(const Duration(seconds: 10));
    return _ok(resp) != null;
  }

  Future<String?> uploadBackgroundFile(int apartmentId, List<int> bytes, String filename) async {
    final token   = await _getToken();
    final baseUrl = await _getBaseUrl() ?? 'http://10.0.2.2:8000';
    final uri     = Uri.parse('$baseUrl/map/$apartmentId/background/');
    final req     = http.MultipartRequest('POST', uri);
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    req.files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final streamed = await req.send().timeout(const Duration(seconds: 30));
    final resp    = await http.Response.fromStream(streamed);
    final j = _ok(resp);
    return j?['url'] as String?;
  }

  // ── Publish ─────────────────────────────────────────────────────────────────

  Future<bool> publish(int apartmentId, {String description = ''}) async {
    final resp = await http
        .post(
          await _uri('/map/$apartmentId/publish/'),
          headers: await _headers(),
          body: jsonEncode({'description': description}),
        )
        .timeout(const Duration(seconds: 10));
    return _ok(resp) != null;
  }

  // ── Versions ────────────────────────────────────────────────────────────────

  Future<List<EditorVersion>> fetchVersions(int apartmentId) async {
    final resp = await http
        .get(await _uri('/map/$apartmentId/versions/'), headers: await _headers(json: false))
        .timeout(const Duration(seconds: 10));
    final j = _ok(resp);
    if (j == null) return [];
    return (j['versions'] as List<dynamic>)
        .map((e) => EditorVersion.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<EditorLayout?> restoreVersion(int apartmentId, int versionId) async {
    final resp = await http
        .post(
          await _uri('/map/$apartmentId/versions/$versionId/restore/'),
          headers: await _headers(json: false),
        )
        .timeout(const Duration(seconds: 10));
    final j = _ok(resp);
    if (j == null || j['layout'] == null) return null;
    return EditorLayout.fromJson(j['layout'] as Map<String, dynamic>);
  }

  // ── Device picker (PLC linking) ─────────────────────────────────────────────

  Future<(List<DevicePickerEntry>, List<Map<String, dynamic>>)> fetchDevicePicker(int apartmentId) async {
    final resp = await http
        .get(await _uri('/map/$apartmentId/devices/'), headers: await _headers(json: false))
        .timeout(const Duration(seconds: 10));
    final j = _ok(resp);
    if (j == null) return (<DevicePickerEntry>[], <Map<String, dynamic>>[]);
    final devices = (j['devices'] as List<dynamic>)
        .map((e) => DevicePickerEntry.fromJson(e as Map<String, dynamic>))
        .toList();
    final rooms = (j['rooms'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .toList();
    return (devices, rooms);
  }
}
