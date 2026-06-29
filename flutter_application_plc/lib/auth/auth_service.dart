import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../models/auth_models.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Storage keys
// ─────────────────────────────────────────────────────────────────────────────

const _kAccess   = 'lumina_access_token';
const _kRefresh  = 'lumina_refresh_token';
const _kBaseUrl  = 'lumina_auth_base_url';

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

  // Base URL of the Django backend (e.g. "http://192.168.0.158:8000")
  String? _baseUrl;

  Future<String?> get _resolvedBase async {
    _baseUrl ??= await _storage.read(key: _kBaseUrl);
    return _baseUrl;
  }

  // ── Configuration ──────────────────────────────────────────────────────────

  Future<void> configure(String baseUrl) async {
    _baseUrl = baseUrl.trimRight().replaceAll(RegExp(r'/+$'), '');
    await _storage.write(key: _kBaseUrl, value: _baseUrl);
  }

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
    String baseUrl   = '',
  }) async {
    if (baseUrl.isNotEmpty) await configure(baseUrl);
    final base = await _resolvedBase;
    if (base == null) return AuthResult.err('Server URL not configured');

    return _post('$base/auth/register/', {
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
    String baseUrl = '',
  }) async {
    if (baseUrl.isNotEmpty) await configure(baseUrl);
    final base = await _resolvedBase;
    if (base == null) return AuthResult.err('Server URL not configured');

    return _post('$base/auth/login/', {
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

    final base = await _resolvedBase;
    if (base == null) return null;

    try {
      final response = await http.post(
        Uri.parse('$base/auth/refresh/'),
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
    final base    = await _resolvedBase;
    final refresh = await getRefreshToken();
    final access  = await getAccessToken();

    if (base != null && refresh != null && access != null) {
      try {
        await http.post(
          Uri.parse('$base/auth/logout/'),
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
    final base   = await _resolvedBase;
    final access = await getAccessToken();
    if (base == null || access == null) return null;

    try {
      final response = await http.get(
        Uri.parse('$base/auth/me/'),
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
            Uri.parse('$base/auth/me/'),
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
    } on Exception catch (e) {
      return AuthResult.err(e.toString(), code: 'NETWORK');
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

  Future<String?> getBaseUrl() async => _resolvedBase;
}
