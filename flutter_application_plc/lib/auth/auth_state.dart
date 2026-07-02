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

  // Whether this user holds PLC-connection/installer permissions on ANY
  // apartment they belong to. PLC IP/AMS Net ID/connection settings are an
  // installer/owner/admin concern — normal residents must never see them
  // (gates the Settings -> Device Management section).
  bool _hasInstallerAccess = false;

  // The apartment this user's app opens to by default — used purely for
  // dashboard greeting copy ("Welcome home to <name>"), never for routing
  // PLC requests (the backend resolves that from the JWT, never the client).
  String? _apartmentName;

  AuthStatus            get status             => _status;
  AuthUser?             get user               => _user;
  String?               get error              => _error;
  bool                  get loading            => _loading;
  bool                  get isAuth             => _status == AuthStatus.authenticated;
  bool                  get isInit             => _status == AuthStatus.initializing;
  List<PlcDeviceConfig> get devices            => List.unmodifiable(_devices);
  PlcDeviceConfig?      get activeDevice       => _activeDevice;
  bool                  get hasInstallerAccess => _hasInstallerAccess;
  String?               get apartmentName      => _apartmentName;
  AuthService           get service            => _svc;

  // ── Authenticated request helper ────────────────────────────────────────
  //
  // The access token lives for 30 minutes (SIMPLE_JWT ACCESS_TOKEN_LIFETIME).
  // Every call below routes through here so a single 401 doesn't strand the
  // user mid-session — it transparently refreshes the access token using the
  // (7-day-lived) refresh token and retries once before giving up. Without
  // this, every screen in the app would start failing silently 30 minutes
  // into any session, with no recovery short of a full logout/login.
  Future<http.Response?> _request(
    String method, String path, {
    Object? body, Duration timeout = const Duration(seconds: 10),
  }) async {
    var headers = await _svc.authHeaders();
    final baseUrl = await _svc.getBaseUrl();
    if (headers == null || baseUrl == null) return null;
    final uri = Uri.parse('$baseUrl$path');

    Future<http.Response> send(Map<String, String> h) {
      switch (method) {
        case 'GET':    return http.get(uri, headers: h);
        case 'POST':   return http.post(uri, headers: h, body: body);
        case 'PATCH':  return http.patch(uri, headers: h, body: body);
        case 'DELETE': return http.delete(uri, headers: h);
        default: throw UnsupportedError('Unsupported method $method');
      }
    }

    try {
      var resp = await send(headers).timeout(timeout);
      if (resp.statusCode == 401) {
        final newAccess = await _svc.refreshAccessToken();
        if (newAccess != null) {
          headers = {...headers, 'Authorization': 'Bearer $newAccess'};
          resp = await send(headers).timeout(timeout);
        }
      }
      return resp;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic>? _decodeOk(http.Response? resp, {int okStatus = 200}) {
    if (resp == null || resp.statusCode != okStatus) return null;
    try {
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      return j['ok'] == true ? j : null;
    } catch (_) {
      return null;
    }
  }

  /// Decodes any 2xx-or-not JSON body and returns its "error" string if
  /// present, for the create/mutate methods that surface failure reasons.
  String? _decodeError(http.Response? resp, String fallback) {
    if (resp == null) return 'Network error';
    try {
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      if (j['ok'] == true) return null;
      return j['error'] as String? ?? fallback;
    } catch (_) {
      return fallback;
    }
  }

  // ── Initialize (check stored tokens) ──────────────────────────────────────

  Future<void> _initialize() async {
    _user = await _svc.fetchMe();
    if (_user != null) {
      _status = AuthStatus.authenticated;
      await _loadDevices();
      await _loadPermissions();
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
      await _loadPermissions();
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
    _user               = null;
    _devices            = [];
    _activeDevice       = null;
    _hasInstallerAccess = false;
    _status             = AuthStatus.unauthenticated;
    _error              = null;
    notifyListeners();
  }

  // ── Permissions ────────────────────────────────────────────────────────────

  static const _installerPermissions = {'plc_connection_settings', 'installer_functions'};

  Future<void> _loadPermissions() async {
    final j = _decodeOk(await _request('GET', '/auth/apartments/', timeout: const Duration(seconds: 8)));
    if (j == null) return;
    final apartments = j['apartments'] as List<dynamic>;
    _hasInstallerAccess = apartments.any((a) {
      final perms = (a as Map<String, dynamic>)['permissions'] as List<dynamic>? ?? [];
      return perms.any((p) => _installerPermissions.contains(p));
    });
    if (apartments.isNotEmpty) {
      final byDefault = apartments.firstWhere(
        (a) => (a as Map<String, dynamic>)['is_default'] == true,
        orElse: () => apartments.first,
      ) as Map<String, dynamic>;
      _apartmentName = byDefault['name'] as String?;
    }
    notifyListeners();
  }

  /// PATCH /auth/me/ — currently only push-notification preference is wired
  /// up in the UI; theme/first_name/last_name are supported server-side but
  /// have no editor yet.
  Future<bool> updatePushNotifications(bool enabled) async {
    final j = _decodeOk(await _request(
      'PATCH', '/auth/me/', body: jsonEncode({'push_notifications': enabled}),
      timeout: const Duration(seconds: 8),
    ));
    if (j == null) return false;
    _user = AuthUser.fromJson(j['user'] as Map<String, dynamic>);
    notifyListeners();
    return true;
  }

  // ── Network discovery ──────────────────────────────────────────────────────

  /// Scans configured subnets for live Beckhoff CX controllers. Installer-only
  /// server-side (403 otherwise) — only call this when hasInstallerAccess.
  /// Returns null on network/parse failure so the UI can show a clean error
  /// instead of an empty list that looks like "found nothing".
  Future<List<DiscoveredPlc>?> discoverPlcs() async {
    final j = _decodeOk(await _request(
      'POST', '/manage/discovery/network-scan/', timeout: const Duration(seconds: 30),
    ));
    if (j == null) return null;
    return (j['results'] as List<dynamic>)
        .map((e) => DiscoveredPlc.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ── Tech Team — user management (staff-only server-side, IsAdminUser) ──────

  /// Creates a brand-new account. /auth/register/ is IsAdminUser-gated
  /// server-side (residents can never self-register — see RegistrationLockdownTests)
  /// so this only succeeds when the caller is staff. Returns an error
  /// message on failure (e.g. "Username already taken"), null on success.
  Future<String?> createUser({
    required String username,
    required String password,
    String email = '',
    String firstName = '',
  }) async {
    final resp = await _request('POST', '/auth/register/', body: jsonEncode({
      'username': username, 'password': password,
      if (email.isNotEmpty) 'email': email,
      if (firstName.isNotEmpty) 'first_name': firstName,
    }));
    return _decodeError(resp, 'Could not create the account');
  }

  Future<List<ManagedUser>?> fetchManagedUsers() async {
    final j = _decodeOk(await _request('GET', '/manage/users/'));
    if (j == null) return null;
    return (j['users'] as List<dynamic>)
        .map((e) => ManagedUser.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<bool> _userAction(int userId, String action, {Map<String, String>? body, String method = 'POST'}) async {
    final resp = await _request(method, '/manage/users/$userId/$action', body: body);
    return _decodeOk(resp) != null;
  }

  Future<bool> disableUser(int userId)  => _userAction(userId, 'disable/');
  Future<bool> enableUser(int userId)   => _userAction(userId, 'enable/');
  Future<bool> forceLogoutUser(int userId) => _userAction(userId, 'force-logout/');
  Future<bool> deleteUser(int userId)   => _userAction(userId, '', method: 'DELETE');

  Future<bool> resetUserPassword(int userId, String newPassword) =>
      _userAction(userId, 'reset-password/', body: {'new_password': newPassword});

  Future<bool> assignApartment(int userId, int apartmentId, String role) =>
      _userAction(userId, 'assign-apartment/', body: {
        'apartment_id': apartmentId.toString(),
        'role': role,
      });

  /// Every apartment in the system (for the assign-apartment picker) —
  /// distinct from the apartment-selector's own list, which is scoped to
  /// the caller's apartments only.
  Future<List<ManagedApartmentLink>?> fetchAllApartments() async {
    final j = _decodeOk(await _request('GET', '/manage/users/apartments/'));
    if (j == null) return null;
    return (j['apartments'] as List<dynamic>).map((e) {
      final m = e as Map<String, dynamic>;
      return ManagedApartmentLink(
        id: m['id'] as int, name: m['name'] as String,
        role: '', isDefault: false,
      );
    }).toList();
  }

  Future<List<ManagedSession>?> fetchUserSessions(int userId) async {
    final j = _decodeOk(await _request('GET', '/manage/users/$userId/sessions/'));
    if (j == null) return null;
    return (j['sessions'] as List<dynamic>)
        .map((e) => ManagedSession.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<PermissionInfo>?> fetchPermissionCatalog() async {
    final j = _decodeOk(await _request('GET', '/manage/permissions/'));
    if (j == null) return null;
    return (j['permissions'] as List<dynamic>)
        .map((e) => PermissionInfo.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// extra_permissions for one user's membership on one apartment — returns
  /// (effectivePermissionCodes, extraPermissionCodes), or null on failure.
  Future<(List<String>, List<String>)?> fetchMembershipPermissions(int userId, int apartmentId) async {
    final j = _decodeOk(await _request(
      'GET', '/manage/users/$userId/apartments/$apartmentId/permissions/',
    ));
    if (j == null) return null;
    return (
      (j['effective_permissions'] as List<dynamic>).cast<String>(),
      (j['extra_permissions'] as List<dynamic>).cast<String>(),
    );
  }

  Future<bool> setMembershipPermissions(int userId, int apartmentId, List<String> codes) async {
    final resp = await _request(
      'POST', '/manage/users/$userId/apartments/$apartmentId/permissions/',
      body: jsonEncode({'permissions': codes}),
    );
    return _decodeOk(resp) != null;
  }

  // ── Tech Team — apartment management ────────────────────────────────────

  Future<List<ApartmentOverview>?> fetchApartmentOverview() async {
    final j = _decodeOk(await _request('GET', '/manage/apartments/'));
    if (j == null) return null;
    return (j['apartments'] as List<dynamic>)
        .map((e) => ApartmentOverview.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<ApartmentOverview?> fetchApartmentDetail(int apartmentId) async {
    final j = _decodeOk(await _request('GET', '/manage/apartments/$apartmentId/'));
    if (j == null) return null;
    return ApartmentOverview.fromJson(j['apartment'] as Map<String, dynamic>);
  }

  /// Creates a new apartment/house. Returns an error message on failure
  /// (e.g. duplicate name), null on success.
  Future<String?> createApartment({
    required String name, String building = '', String floor = '',
  }) async {
    final resp = await _request(
      'POST', '/manage/apartments/',
      body: jsonEncode({'name': name, 'building': building, 'floor': floor}),
    );
    return _decodeError(resp, 'Could not create the apartment');
  }

  // ── Tech Team — PLC assignment per apartment ────────────────────────────

  Future<ManagedPlc?> fetchApartmentPlc(int apartmentId) async {
    final j = _decodeOk(await _request('GET', '/manage/apartments/$apartmentId/plc/'));
    if (j == null || j['plc'] == null) return null;
    return ManagedPlc.fromJson(j['plc'] as Map<String, dynamic>);
  }

  /// Assigns/updates the controller serving an apartment. Returns an error
  /// message on failure (e.g. invalid AMS Net ID), null on success.
  Future<String?> setApartmentPlc(int apartmentId, {
    required String ipAddress, required String amsNetId,
    String name = '', int adsPort = 851,
  }) async {
    final resp = await _request(
      'POST', '/manage/apartments/$apartmentId/plc/',
      body: jsonEncode({
        'ip_address': ipAddress, 'ams_net_id': amsNetId,
        'ads_port': adsPort, if (name.isNotEmpty) 'name': name,
      }),
    );
    return _decodeError(resp, 'Could not assign the controller');
  }

  Future<bool> unassignApartmentPlc(int apartmentId) async {
    final resp = await _request('DELETE', '/manage/apartments/$apartmentId/plc/');
    return _decodeOk(resp) != null;
  }

  // ── Tech Team — room & device layout (rename/reorder) ───────────────────

  Future<List<ManagedRoom>?> fetchApartmentRooms(int apartmentId) async {
    final j = _decodeOk(await _request('GET', '/manage/apartments/$apartmentId/rooms/'));
    if (j == null) return null;
    return (j['rooms'] as List<dynamic>)
        .map((e) => ManagedRoom.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<String?> createRoom(int apartmentId, String name) async {
    final resp = await _request(
      'POST', '/manage/apartments/$apartmentId/rooms/', body: jsonEncode({'name': name}),
    );
    return _decodeError(resp, 'Could not create the room');
  }

  Future<bool> renameRoom(int apartmentId, int roomId, String name) async {
    final resp = await _request(
      'PATCH', '/manage/apartments/$apartmentId/rooms/$roomId/', body: jsonEncode({'name': name}),
    );
    return _decodeOk(resp) != null;
  }

  Future<bool> deleteRoom(int apartmentId, int roomId) async {
    final resp = await _request('DELETE', '/manage/apartments/$apartmentId/rooms/$roomId/');
    return _decodeOk(resp) != null;
  }

  Future<bool> reorderRooms(int apartmentId, List<int> orderedRoomIds) async {
    final resp = await _request(
      'POST', '/manage/apartments/$apartmentId/rooms/reorder/',
      body: jsonEncode({'order': orderedRoomIds}),
    );
    return _decodeOk(resp) != null;
  }

  Future<List<ManagedDevice>?> fetchApartmentDevices(int apartmentId) async {
    final j = _decodeOk(await _request('GET', '/manage/apartments/$apartmentId/devices/'));
    if (j == null) return null;
    return (j['devices'] as List<dynamic>)
        .map((e) => ManagedDevice.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<bool> renameDevice(int apartmentId, int deviceId, String name) async {
    final resp = await _request(
      'PATCH', '/manage/apartments/$apartmentId/devices/$deviceId/', body: jsonEncode({'name': name}),
    );
    return _decodeOk(resp) != null;
  }

  Future<bool> moveDeviceToRoom(int apartmentId, int deviceId, int? roomId) async {
    final resp = await _request(
      'PATCH', '/manage/apartments/$apartmentId/devices/$deviceId/', body: jsonEncode({'room_id': roomId}),
    );
    return _decodeOk(resp) != null;
  }

  Future<bool> reorderDevices(int apartmentId, List<int> orderedDeviceIds) async {
    final resp = await _request(
      'POST', '/manage/apartments/$apartmentId/devices/reorder/',
      body: jsonEncode({'order': orderedDeviceIds}),
    );
    return _decodeOk(resp) != null;
  }

  // ── Device management ──────────────────────────────────────────────────────

  Future<void> _loadDevices() async {
    final j = _decodeOk(await _request('GET', '/manage/devices/', timeout: const Duration(seconds: 8)));
    if (j == null) return;
    _devices = (j['devices'] as List<dynamic>)
        .map((e) => PlcDeviceConfig.fromJson(e as Map<String, dynamic>))
        .toList();
    _activeDevice = _devices.where((d) => d.isDefault).firstOrNull ?? _devices.firstOrNull;
    notifyListeners();
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
    final j = _decodeOk(await _request(
      'POST', '/manage/devices/',
      body: jsonEncode({
        'name':        name,
        'ip_address':  ipAddress,
        'ams_net_id':  amsNetId,
        'description': description,
        'ads_port':    adsPort,
        'is_default':  isDefault,
      }),
      timeout: const Duration(seconds: 8),
    ), okStatus: 201);
    if (j == null) return null;
    final dev = PlcDeviceConfig.fromJson(j['device'] as Map<String, dynamic>);
    _devices.add(dev);
    if (dev.isDefault || _devices.length == 1) _activeDevice = dev;
    notifyListeners();
    return dev;
  }

  Future<bool> deleteDevice(int id) async {
    final resp = await _request('DELETE', '/manage/devices/$id/', timeout: const Duration(seconds: 8));
    if (resp == null || resp.statusCode != 200) return false;
    _devices.removeWhere((d) => d.id == id);
    if (_activeDevice?.id == id) {
      _activeDevice = _devices.where((d) => d.isDefault).firstOrNull ?? _devices.firstOrNull;
    }
    notifyListeners();
    return true;
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
