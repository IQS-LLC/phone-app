import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../config/runtime_config.dart';
import '../models/auth_models.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Storage keys
// ─────────────────────────────────────────────────────────────────────────────

const _kAccess   = 'lumina_access_token';
const _kRefresh  = 'lumina_refresh_token';

// ─────────────────────────────────────────────────────────────────────────────
// AuthResult
// ─────────────────────────────────────────────────────────────────────────────

class AuthResult {
  final bool    success;
  final AuthUser? user;
  final String? errorMessage;
  final String? errorCode;

  const AuthResult._({
    required this.success,
    this.user,
    this.errorMessage,
    this.errorCode,
  });

  factory AuthResult.ok(AuthUser user) =>
      AuthResult._(success: true, user: user);

  factory AuthResult.err(String message, {String? code}) =>
      AuthResult._(success: false, errorMessage: message, errorCode: code);
}

// ─────────────────────────────────────────────────────────────────────────────
// AuthService
// ─────────────────────────────────────────────────────────────────────────────

class AuthService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  static const _timeout = Duration(seconds: 10);

  final RuntimeConfig _config;

  /// [config] defaults to the app-wide singleton — every real call site
  /// gets it for free; the parameter exists mainly for tests.
  AuthService([RuntimeConfig? config]) : _config = config ?? RuntimeConfig.instance;

  // Server URL comes from RuntimeConfig on every call, never cached here —
  // AuthService used to keep its own persisted copy, which is exactly the
  // duplicated-state class of bug this session hardened against. See
  // RuntimeConfig's doc comment for the full story.
  String get _base => _config.serverUrl;

  // ── Token helpers ──────────────────────────────────────────────────────────

  Future<String?> getAccessToken()  => _storage.read(key: _kAccess);
  Future<String?> getRefreshToken() => _storage.read(key: _kRefresh);

  Future<void> _storeTokens(String access, String refresh) async {
    await Future.wait([
      _storage.write(key: _kAccess,  value: access),
      _storage.write(key: _kRefresh, value: refresh),
    ]);
  }

  Future<void> clearTokens() => Future.wait([
    _storage.delete(key: _kAccess),
    _storage.delete(key: _kRefresh),
  ]);

  // ── Register ───────────────────────────────────────────────────────────────

  Future<AuthResult> register({
    required String username,
    required String password,
    String email     = '',
    String firstName = '',
  }) async {
    return _post('$_base/auth/register/', {
      'username':   username,
      'password':   password,
      if (email.isNotEmpty)     'email':      email,
      if (firstName.isNotEmpty) 'first_name': firstName,
    });
  }

  // ── Login ──────────────────────────────────────────────────────────────────

  Future<AuthResult> login({
    required String username,
    required String password,
  }) async {
    return _post('$_base/auth/login/', {
      'username': username,
      'password': password,
    });
  }

  // ── Refresh ────────────────────────────────────────────────────────────────

  /// Silently refresh the access token.
  /// Returns the new access token on success, null on failure.
  Future<String?> refreshAccessToken() async {
    final refresh = await getRefreshToken();
    if (refresh == null) return null;

    try {
      final response = await http.post(
        Uri.parse('$_base/auth/refresh/'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'refresh': refresh}),
      ).timeout(_timeout);

      if (response.statusCode == 200) {
        final j = jsonDecode(response.body) as Map<String, dynamic>;
        if (j['ok'] == true) {
          final newAccess  = j['access']  as String;
          final newRefresh = j['refresh'] as String? ?? refresh;
          await _storeTokens(newAccess, newRefresh);
          return newAccess;
        }
      }
    } catch (_) {}
    return null;
  }

  // ── Logout ─────────────────────────────────────────────────────────────────

  Future<void> logout() async {
    final refresh = await getRefreshToken();
    final access  = await getAccessToken();

    if (refresh != null && access != null) {
      try {
        await http.post(
          Uri.parse('$_base/auth/logout/'),
          headers: {
            'Content-Type':  'application/json',
            'Authorization': 'Bearer $access',
          },
          body: jsonEncode({'refresh': refresh}),
        ).timeout(_timeout);
      } catch (_) {}
    }

    await clearTokens();
  }

  // ── Me ─────────────────────────────────────────────────────────────────────

  Future<AuthUser?> fetchMe() async {
    final access = await getAccessToken();
    if (access == null) return null;

    try {
      final response = await http.get(
        Uri.parse('$_base/auth/me/'),
        headers: {'Authorization': 'Bearer $access'},
      ).timeout(_timeout);

      if (response.statusCode == 200) {
        final j = jsonDecode(response.body) as Map<String, dynamic>;
        if (j['ok'] == true) {
          return AuthUser.fromJson(j['user'] as Map<String, dynamic>);
        }
      }

      // Access token expired — try refresh
      if (response.statusCode == 401) {
        final newAccess = await refreshAccessToken();
        if (newAccess != null) {
          final retry = await http.get(
            Uri.parse('$_base/auth/me/'),
            headers: {'Authorization': 'Bearer $newAccess'},
          ).timeout(_timeout);
          if (retry.statusCode == 200) {
            final j2 = jsonDecode(retry.body) as Map<String, dynamic>;
            if (j2['ok'] == true) {
              return AuthUser.fromJson(j2['user'] as Map<String, dynamic>);
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }

  // ── HTTP helper ────────────────────────────────────────────────────────────

  Future<AuthResult> _post(String url, Map<String, String> body) async {
    try {
      final response = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: body,
      ).timeout(_timeout);

      final j = jsonDecode(response.body) as Map<String, dynamic>;

      if (j['ok'] == true) {
        final user = AuthUser.fromJson(j['user'] as Map<String, dynamic>);
        await _storeTokens(
          j['access']  as String,
          j['refresh'] as String,
        );
        return AuthResult.ok(user);
      }

      return AuthResult.err(
        j['error']    as String? ?? 'Unknown error',
        code: j['code'] as String?,
      );
    } on TimeoutException {
      return AuthResult.err('Connection timed out', code: 'TIMEOUT');
    } on SocketException {
      return AuthResult.err('Can\'t reach the server. Check your connection.', code: 'NETWORK');
    } on FormatException {
      return AuthResult.err('Unexpected response from the server.', code: 'PARSE_ERROR');
    } on Exception {
      // Never surface raw exception text (ClientException/host-lookup
      // details, stack-trace-shaped strings) to the login screen — found
      // live 2026-08-20: a stale tunnel hostname produced a multi-line
      // "ClientException with SocketException: Failed host lookup:
      // ...errno = 7..." string rendered verbatim in the error banner.
      return AuthResult.err('Can\'t reach the server. Check your connection.', code: 'NETWORK');
    }
  }

  // ── Authorization header ───────────────────────────────────────────────────

  /// Returns auth headers for API requests.
  /// Returns null if no access token is stored.
  Future<Map<String, String>?> authHeaders() async {
    final access = await getAccessToken();
    if (access == null) return null;
    return {
      'Authorization': 'Bearer $access',
      'Content-Type':  'application/json',
    };
  }

  // ── Base URL accessor ──────────────────────────────────────────────────────

  // Returns Future<String?> (rather than a sync String) purely for source
  // compatibility with the ~10 screens that already `await svc.getBaseUrl()`
  // — the value itself is never cached or stale here, it's read straight
  // from RuntimeConfig on every call.
  Future<String?> getBaseUrl() async => _base;
}
