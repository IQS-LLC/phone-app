import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/automation_models.dart';

/// HTTP client for the Automations API (find_device/automation_views.py).
/// is_staff (IT Team) ONLY server-side — same bar as LightRelabelService;
/// an automation rule IS the "no more hand-written PLC code" capability.
class AutomationService {
  final String baseUrl;
  final Future<String?> Function()? tokenProvider;
  final Future<String?> Function()? tokenRefresher;

  static const _timeout = Duration(seconds: 15);

  AutomationService(
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

  Future<Map<String, dynamic>> _send(String method, String path, Map<String, dynamic> body) async {
    try {
      final hdrs = await _headers();
      final encoded = Uri(queryParameters: body.map((k, v) => MapEntry(k, v.toString()))).query;
      final uri = Uri.parse('$baseUrl$path');
      var resp = method == 'POST'
          ? await http.post(uri, headers: hdrs, body: encoded).timeout(_timeout)
          : await http.patch(uri, headers: hdrs, body: encoded).timeout(_timeout);
      if (resp.statusCode == 401 && tokenRefresher != null) {
        await tokenRefresher!();
        final hdrs2 = await _headers();
        resp = method == 'POST'
            ? await http.post(uri, headers: hdrs2, body: encoded).timeout(_timeout)
            : await http.patch(uri, headers: hdrs2, body: encoded).timeout(_timeout);
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

  Future<Map<String, dynamic>> _delete(String path) async {
    try {
      final hdrs = await _headers();
      var resp = await http.delete(Uri.parse('$baseUrl$path'), headers: hdrs).timeout(_timeout);
      if (resp.statusCode == 401 && tokenRefresher != null) {
        await tokenRefresher!();
        final hdrs2 = await _headers();
        resp = await http.delete(Uri.parse('$baseUrl$path'), headers: hdrs2).timeout(_timeout);
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

  Future<AutomationResult<AutomationSnapshot>> listRules(int apartmentId) async {
    final r = await _get('/automations/$apartmentId/rules/');
    if (r['ok'] != true) return AutomationResult.err(r['error'] as String? ?? 'Failed to load automations');
    List<AutomationDevice> parseDevices(String key) => (r[key] as List? ?? [])
        .whereType<Map<String, dynamic>>().map(AutomationDevice.fromJson).toList();
    final rules = (r['rules'] as List? ?? [])
        .whereType<Map<String, dynamic>>().map(AutomationRuleSummary.fromJson).toList();
    return AutomationResult.ok(AutomationSnapshot(
      rules: rules, triggers: parseDevices('triggers'), actions: parseDevices('actions'),
    ));
  }

  Future<AutomationResult<AutomationRuleSummary>> createRule(
    int apartmentId, {
    required String name,
    required int triggerDeviceId,
    required bool triggerState,
    required int actionDeviceId,
    required String actionValue,
  }) async {
    final r = await _send('POST', '/automations/$apartmentId/rules/', {
      'name': name,
      'trigger_device_id': triggerDeviceId,
      'trigger_state': triggerState,
      'action_device_id': actionDeviceId,
      'action_value': actionValue,
    });
    if (r['ok'] != true) return AutomationResult.err(r['error'] as String? ?? 'Create failed');
    return AutomationResult.ok(AutomationRuleSummary.fromJson(r['rule'] as Map<String, dynamic>));
  }

  Future<AutomationResult<void>> setEnabled(int apartmentId, int ruleId, bool enabled) async {
    final r = await _send('PATCH', '/automations/$apartmentId/rules/$ruleId/', {'enabled': enabled});
    if (r['ok'] != true) return AutomationResult.err(r['error'] as String? ?? 'Update failed');
    return AutomationResult.ok(null);
  }

  Future<AutomationResult<void>> deleteRule(int apartmentId, int ruleId) async {
    final r = await _delete('/automations/$apartmentId/rules/$ruleId/');
    if (r['ok'] != true) return AutomationResult.err(r['error'] as String? ?? 'Delete failed');
    return AutomationResult.ok(null);
  }
}

class AutomationSnapshot {
  final List<AutomationRuleSummary> rules;
  final List<AutomationDevice> triggers;
  final List<AutomationDevice> actions;

  const AutomationSnapshot({required this.rules, required this.triggers, required this.actions});
}

class AutomationResult<T> {
  final T?      data;
  final String? error;

  const AutomationResult._({this.data, this.error});

  factory AutomationResult.ok(T data) => AutomationResult._(data: data);
  factory AutomationResult.err(String error) => AutomationResult._(error: error);

  bool get success => error == null;
  T get value => data as T;
}
