import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/superscan_models.dart';

/// HTTP client for the SuperScan API (find_device/superscan_views.py).
/// is_staff (IT Team) ONLY server-side — same bar as AutomationService.
class SuperscanService {
  final String baseUrl;
  final Future<String?> Function()? tokenProvider;
  final Future<String?> Function()? tokenRefresher;

  static const _timeout = Duration(seconds: 15);

  SuperscanService(this.baseUrl, {this.tokenProvider, this.tokenRefresher});

  Future<Map<String, String>> _headers() async {
    final token = await tokenProvider?.call();
    return {
      'Content-Type': 'application/x-www-form-urlencoded',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  Future<Map<String, dynamic>> _get(String path) async {
    try {
      var resp = await http.get(Uri.parse('$baseUrl$path'), headers: await _headers()).timeout(_timeout);
      if (resp.statusCode == 401 && tokenRefresher != null) {
        await tokenRefresher!();
        resp = await http.get(Uri.parse('$baseUrl$path'), headers: await _headers()).timeout(_timeout);
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
      final uri = Uri.parse('$baseUrl$path');
      var resp = await http.post(uri, headers: hdrs, body: encoded).timeout(_timeout);
      if (resp.statusCode == 401 && tokenRefresher != null) {
        await tokenRefresher!();
        final hdrs2 = await _headers();
        resp = await http.post(uri, headers: hdrs2, body: encoded).timeout(_timeout);
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

  Future<SuperscanResult<ScanRunSummary>> start(int apartmentId, String mode) async {
    final r = await _post('/superscan/$apartmentId/start/', {'mode': mode});
    if (r['ok'] != true) return SuperscanResult.err(r['error'] as String? ?? 'Could not start scan');
    return SuperscanResult.ok(ScanRunSummary.fromJson(r['run'] as Map<String, dynamic>));
  }

  Future<SuperscanResult<ScanRunSummary>> stop(int apartmentId, int scanId) async {
    final r = await _post('/superscan/$apartmentId/runs/$scanId/stop/', {});
    if (r['ok'] != true) return SuperscanResult.err(r['error'] as String? ?? 'Could not stop scan');
    return SuperscanResult.ok(ScanRunSummary.fromJson(r['run'] as Map<String, dynamic>));
  }

  Future<SuperscanResult<ScanRunSummary>> runStatus(int apartmentId, int scanId) async {
    final r = await _get('/superscan/$apartmentId/runs/$scanId/');
    if (r['ok'] != true) return SuperscanResult.err(r['error'] as String? ?? 'Could not load scan status');
    return SuperscanResult.ok(ScanRunSummary.fromJson(r['run'] as Map<String, dynamic>));
  }

  Future<SuperscanResult<List<ScanRunSummary>>> runList(int apartmentId) async {
    final r = await _get('/superscan/$apartmentId/runs/');
    if (r['ok'] != true) return SuperscanResult.err(r['error'] as String? ?? 'Could not load scan history');
    final runs = (r['runs'] as List? ?? [])
        .whereType<Map<String, dynamic>>().map(ScanRunSummary.fromJson).toList();
    return SuperscanResult.ok(runs);
  }

  Future<SuperscanResult<(List<DiscoveredCapabilitySummary>, CapabilitySummaryCounts)>> capabilityList(
    int apartmentId, {
    String? deviceType, String? direction, String? testStatus, bool? known, String present = 'true',
  }) async {
    final q = <String, String>{'present': present};
    if (deviceType != null) q['device_type'] = deviceType;
    if (direction != null) q['direction'] = direction;
    if (testStatus != null) q['test_status'] = testStatus;
    if (known != null) q['known'] = known.toString();
    final uri = '/superscan/$apartmentId/capabilities/?${Uri(queryParameters: q).query}';
    final r = await _get(uri);
    if (r['ok'] != true) return SuperscanResult.err(r['error'] as String? ?? 'Could not load capabilities');
    final caps = (r['capabilities'] as List? ?? [])
        .whereType<Map<String, dynamic>>().map(DiscoveredCapabilitySummary.fromJson).toList();
    final summary = CapabilitySummaryCounts.fromJson(r['summary'] as Map<String, dynamic>? ?? {});
    return SuperscanResult.ok((caps, summary));
  }

  Future<SuperscanResult<(DiscoveredCapabilitySummary, List<CapabilityTestLogSummary>)>> capabilityDetail(
    int apartmentId, int capId,
  ) async {
    final r = await _get('/superscan/$apartmentId/capabilities/$capId/');
    if (r['ok'] != true) return SuperscanResult.err(r['error'] as String? ?? 'Could not load capability');
    final cap = DiscoveredCapabilitySummary.fromJson(r['capability'] as Map<String, dynamic>);
    final logs = (r['test_logs'] as List? ?? [])
        .whereType<Map<String, dynamic>>().map(CapabilityTestLogSummary.fromJson).toList();
    return SuperscanResult.ok((cap, logs));
  }
}
