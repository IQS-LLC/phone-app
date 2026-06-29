import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../models/auth_models.dart';
import 'auth_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Auth status
// ─────────────────────────────────────────────────────────────────────────────

enum AuthStatus { initializing, unauthenticated, authenticated }

// ─────────────────────────────────────────────────────────────────────────────
// AuthState
// ─────────────────────────────────────────────────────────────────────────────

class AuthState extends ChangeNotifier {
  final AuthService _svc;

  AuthState(this._svc) {
    _initialize();
  }

  // ── State ──────────────────────────────────────────────────────────────────
  AuthStatus _status  = AuthStatus.initializing;
  AuthUser?  _user;
  String?    _error;
  bool       _loading = false;

  // Managed PLC devices
  List<PlcDeviceConfig> _devices      = [];
  PlcDeviceConfig?      _activeDevice;

  AuthStatus            get status       => _status;
  AuthUser?             get user         => _user;
  String?               get error        => _error;
  bool                  get loading      => _loading;
  bool                  get isAuth       => _status == AuthStatus.authenticated;
  bool                  get isInit       => _status == AuthStatus.initializing;
  List<PlcDeviceConfig> get devices      => List.unmodifiable(_devices);
  PlcDeviceConfig?      get activeDevice => _activeDevice;
  AuthService           get service      => _svc;

  // ── Initialize (check stored tokens) ──────────────────────────────────────

  Future<void> _initialize() async {
    _user = await _svc.fetchMe();
    if (_user != null) {
      _status = AuthStatus.authenticated;
      await _loadDevices();
    } else {
      _status = AuthStatus.unauthenticated;
    }
    notifyListeners();
  }

  // ── Login ──────────────────────────────────────────────────────────────────

  Future<bool> login({
    required String username,
    required String password,
    required String serverUrl,
  }) async {
    _loading = true;
    _error   = null;
    notifyListeners();

    final result = await _svc.login(
      username: username,
      password: password,
      baseUrl:  serverUrl,
    );

    if (result.success) {
      _user    = result.user;
      _status  = AuthStatus.authenticated;
      _error   = null;
      _loading = false;
      notifyListeners();
      await _loadDevices();
      return true;
    }

    _error   = result.errorMessage;
    _loading = false;
    notifyListeners();
    return false;
  }

  // ── Register ───────────────────────────────────────────────────────────────

  Future<bool> register({
    required String username,
    required String password,
    required String serverUrl,
    String email     = '',
    String firstName = '',
  }) async {
    _loading = true;
    _error   = null;
    notifyListeners();

    final result = await _svc.register(
      username:  username,
      password:  password,
      email:     email,
      firstName: firstName,
      baseUrl:   serverUrl,
    );

    if (result.success) {
      _user    = result.user;
      _status  = AuthStatus.authenticated;
      _error   = null;
      _loading = false;
      notifyListeners();
      return true;
    }

    _error   = result.errorMessage;
    _loading = false;
    notifyListeners();
    return false;
  }

  // ── Logout ─────────────────────────────────────────────────────────────────

  Future<void> logout() async {
    await _svc.logout();
    _user         = null;
    _devices      = [];
    _activeDevice = null;
    _status       = AuthStatus.unauthenticated;
    _error        = null;
    notifyListeners();
  }

  // ── Device management ──────────────────────────────────────────────────────

  Future<void> _loadDevices() async {
    final headers = await _svc.authHeaders();
    final baseUrl = await _svc.getBaseUrl();
    if (headers == null || baseUrl == null) return;

    try {
      final resp = await http.get(
        Uri.parse('$baseUrl/manage/devices/'),
        headers: headers,
      ).timeout(const Duration(seconds: 8));

      if (resp.statusCode == 200) {
        final j = jsonDecode(resp.body) as Map<String, dynamic>;
        if (j['ok'] == true) {
          _devices = (j['devices'] as List<dynamic>)
              .map((e) => PlcDeviceConfig.fromJson(e as Map<String, dynamic>))
              .toList();
          _activeDevice = _devices.where((d) => d.isDefault).firstOrNull
              ?? _devices.firstOrNull;
          notifyListeners();
        }
      }
    } catch (_) {}
  }

  Future<void> refreshDevices() => _loadDevices();

  Future<PlcDeviceConfig?> addDevice({
    required String name,
    required String ipAddress,
    required String amsNetId,
    String description = '',
    int    adsPort     = 851,
    bool   isDefault   = false,
  }) async {
    final headers = await _svc.authHeaders();
    final baseUrl = await _svc.getBaseUrl();
    if (headers == null || baseUrl == null) return null;

    try {
      final resp = await http.post(
        Uri.parse('$baseUrl/manage/devices/'),
        headers: headers,
        body: jsonEncode({
          'name':        name,
          'ip_address':  ipAddress,
          'ams_net_id':  amsNetId,
          'description': description,
          'ads_port':    adsPort,
          'is_default':  isDefault,
        }),
      ).timeout(const Duration(seconds: 8));

      if (resp.statusCode == 201) {
        final j = jsonDecode(resp.body) as Map<String, dynamic>;
        if (j['ok'] == true) {
          final dev = PlcDeviceConfig.fromJson(
            j['device'] as Map<String, dynamic>,
          );
          _devices.add(dev);
          if (dev.isDefault || _devices.length == 1) _activeDevice = dev;
          notifyListeners();
          return dev;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<bool> deleteDevice(int id) async {
    final headers = await _svc.authHeaders();
    final baseUrl = await _svc.getBaseUrl();
    if (headers == null || baseUrl == null) return false;

    try {
      final resp = await http.delete(
        Uri.parse('$baseUrl/manage/devices/$id/'),
        headers: headers,
      ).timeout(const Duration(seconds: 8));

      if (resp.statusCode == 200) {
        _devices.removeWhere((d) => d.id == id);
        if (_activeDevice?.id == id) {
          _activeDevice = _devices.where((d) => d.isDefault).firstOrNull
              ?? _devices.firstOrNull;
        }
        notifyListeners();
        return true;
      }
    } catch (_) {}
    return false;
  }

  void setActiveDevice(PlcDeviceConfig dev) {
    _activeDevice = dev;
    notifyListeners();
  }

  void clearError() {
    if (_error != null) {
      _error = null;
      notifyListeners();
    }
  }
}
