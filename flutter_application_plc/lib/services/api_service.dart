import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

// ─────────────────────────────────────────────────────────────────────────────
// Result type — every API call returns one of these
// ─────────────────────────────────────────────────────────────────────────────

enum ApiErrorCode {
  network,       // SocketException, no connectivity
  timeout,       // request timed out
  serverError,   // HTTP 5xx
  clientError,   // HTTP 4xx (bad request, not found)
  parseError,    // response body wasn't valid JSON
  unknown,
}

class ApiResult<T> {
  final T?           data;
  final String?      errorMessage;
  final ApiErrorCode? errorCode;
  final int          latencyMs;

  const ApiResult._({
    required this.latencyMs,
    this.data,
    this.errorMessage,
    this.errorCode,
  });

  factory ApiResult.ok(T data, int latencyMs) => ApiResult._(
    data: data, latencyMs: latencyMs,
  );

  factory ApiResult.err(
    String message, ApiErrorCode code, int latencyMs,
  ) => ApiResult._(
    errorMessage: message, errorCode: code, latencyMs: latencyMs,
  );

  bool get success   => errorCode == null;
  bool get isNetwork => errorCode == ApiErrorCode.network;
  bool get isTimeout => errorCode == ApiErrorCode.timeout;
}

// ─────────────────────────────────────────────────────────────────────────────
// Connection test result
// ─────────────────────────────────────────────────────────────────────────────

class ConnectionTestResult {
  final bool   reachable;
  final bool   mock;
  final int    latencyMs;
  final String? errorMessage;
  final String? serverVersion;

  const ConnectionTestResult({
    required this.reachable,
    required this.latencyMs,
    this.mock          = true,
    this.errorMessage,
    this.serverVersion,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// ApiService
// ─────────────────────────────────────────────────────────────────────────────

class ApiService {
  final String baseUrl;

  /// Supplies the current JWT access token for every request, if signed in.
  /// /plc/* endpoints require auth (PLC_REQUIRE_AUTH) so every building
  /// command can be attributed to a user.
  final Future<String?> Function()? tokenProvider;

  /// Refreshes the access token (using the longer-lived refresh token) and
  /// returns the new one, or null on failure. The access token lives only
  /// 30 minutes — without this, a session left open past that point would
  /// poll forever as "offline" against a perfectly healthy server, with no
  /// way to recover short of a full logout/login.
  final Future<String?> Function()? tokenRefresher;

  ApiService(this.baseUrl, {this.tokenProvider, this.tokenRefresher});

  ApiResult<Map<String, dynamic>> _parseResponse(http.Response response, int ms) {
    if (response.statusCode == 200 || response.statusCode == 207) {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return ApiResult.ok(json, ms);
    }
    final errMsg = _extractErrorMessage(response.body, response.statusCode);
    return ApiResult.err(
      errMsg,
      response.statusCode >= 500 ? ApiErrorCode.serverError : ApiErrorCode.clientError,
      ms,
    );
  }

  Future<Map<String, String>> _authHeaders([Map<String, String>? extra]) async {
    final token = await tokenProvider?.call();
    return {
      ...?extra,
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  // Timeouts
  static const _pollTimeout    = Duration(seconds: 3);   // GET /plc/state/
  static const _commandTimeout = Duration(seconds: 5);   // POST commands
  static const _testTimeout    = Duration(seconds: 4);   // connection test

  // Retry (GET only — POST commands are single-shot to prevent double-fire)
  static const _maxGetRetries  = 2;
  static const _retryBaseDelay = Duration(milliseconds: 300);

  // ── GET with retry ──────────────────────────────────────────────────────────

  Future<ApiResult<Map<String, dynamic>>> _get(
    String path, {
    Duration timeout = _pollTimeout,
    bool retry = true,
  }) async {
    final sw      = Stopwatch()..start();
    int retries   = retry ? _maxGetRetries : 0;
    Object? lastEx;

    bool refreshedOnce = false;

    for (int attempt = 0; attempt <= retries; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(_retryBaseDelay * attempt);
      }
      try {
        var response = await http
            .get(Uri.parse('$baseUrl$path'), headers: await _authHeaders())
            .timeout(timeout);

        if (response.statusCode == 401 && !refreshedOnce && tokenRefresher != null) {
          refreshedOnce = true;
          final newToken = await tokenRefresher!.call();
          if (newToken != null) {
            response = await http
                .get(Uri.parse('$baseUrl$path'), headers: await _authHeaders())
                .timeout(timeout);
          }
        }

        sw.stop();
        return _parseResponse(response, sw.elapsedMilliseconds);
      } on SocketException catch (e) {
        lastEx = e;
      } on TimeoutException catch (e) {
        lastEx = e;
      } on HandshakeException catch (e) {
        lastEx = e;
      } catch (e) {
        lastEx = e;
      }
    }

    sw.stop();
    return _exceptionToResult(lastEx, sw.elapsedMilliseconds);
  }

  // ── POST (no retry — command semantics, except a single 401 refresh) ───────

  Future<ApiResult<Map<String, dynamic>>> _post(
    String path,
    Map<String, String> body,
  ) async {
    final sw = Stopwatch()..start();
    try {
      var response = await http.post(
        Uri.parse('$baseUrl$path'),
        headers: await _authHeaders({'Content-Type': 'application/x-www-form-urlencoded'}),
        body: body,
      ).timeout(_commandTimeout);

      if (response.statusCode == 401 && tokenRefresher != null) {
        final newToken = await tokenRefresher!.call();
        if (newToken != null) {
          response = await http.post(
            Uri.parse('$baseUrl$path'),
            headers: await _authHeaders({'Content-Type': 'application/x-www-form-urlencoded'}),
            body: body,
          ).timeout(_commandTimeout);
        }
      }

      sw.stop();
      return _parseResponse(response, sw.elapsedMilliseconds);
    } on SocketException catch (e) {
      sw.stop();
      return _exceptionToResult(e, sw.elapsedMilliseconds);
    } on TimeoutException catch (e) {
      sw.stop();
      return _exceptionToResult(e, sw.elapsedMilliseconds);
    } catch (e) {
      sw.stop();
      return _exceptionToResult(e, sw.elapsedMilliseconds);
    }
  }

  // ── Endpoints ──────────────────────────────────────────────────────────────

  Future<ApiResult<Map<String, dynamic>>> getState() =>
      _get('/plc/state/');

  Future<ApiResult<Map<String, dynamic>>> getDevices() =>
      _get('/plc/devices/', retry: false);

  /// durationMs > 0 fades the channel over that time server-side instead of
  /// jumping instantly. Bounded 100-5000 server-side regardless of what's
  /// passed here — see find_device.views._parse_duration_ms.
  Future<ApiResult<Map<String, dynamic>>> setDaliBrightness(
    int channel, int pct, {int durationMs = 0}
  ) => _post(
    '/plc/dali/$channel/brightness/',
    {
      'brightness': pct.toString(),
      if (durationMs > 0) 'duration_ms': durationMs.toString(),
    },
  );

  Future<ApiResult<Map<String, dynamic>>> setAllDaliBrightness(int pct) =>
      _post('/plc/dali/all/brightness/', {'brightness': pct.toString()});

  Future<ApiResult<Map<String, dynamic>>> setRoomBrightness(
    String room, int pct,
  ) => _post(
    '/plc/room/${Uri.encodeComponent(room)}/brightness/',
    {'brightness': pct.toString()},
  );

  Future<ApiResult<Map<String, dynamic>>> setRelay(int channel, bool on) =>
      _post('/plc/relay/$channel/', {'state': on ? 'true' : 'false'});

  // ── Curtain motors ──────────────────────────────────────────────────────────

  /// cmd: 'stop' | 'up' | 'down'
  Future<ApiResult<Map<String, dynamic>>> setCurtain(int index, String cmd) =>
      _post('/plc/curtain/$index/', {'cmd': cmd});

  Future<ApiResult<Map<String, dynamic>>> setCurtainAll(String cmd) =>
      _post('/plc/curtain/all/', {'cmd': cmd});

  // ── Appliances ──────────────────────────────────────────────────────────────

  Future<ApiResult<Map<String, dynamic>>> setAppliance(
    String gvlName, bool on,
  ) => _post('/plc/appliance/$gvlName/', {'state': on ? 'true' : 'false'});

  // ── Named relays/lights (ventilators, balcony/mirror/var lights, etc.) ──────

  Future<ApiResult<Map<String, dynamic>>> setToggle(
    String varName, bool on,
  ) => _post('/plc/toggle/$varName/', {'state': on ? 'true' : 'false'});

  // ── Security ────────────────────────────────────────────────────────────────

  Future<ApiResult<Map<String, dynamic>>> setAlarm(bool armed) =>
      _post('/plc/security/alarm/', {'armed': armed ? 'true' : 'false'});

  Future<ApiResult<Map<String, dynamic>>> setLockdown(bool active) =>
      _post('/plc/security/lockdown/', {'active': active ? 'true' : 'false'});

  // ── Connection test ─────────────────────────────────────────────────────────

  Future<ConnectionTestResult> testConnection() async {
    final sw = Stopwatch()..start();
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/health/'))
          .timeout(_testTimeout);
      sw.stop();
      final ms = sw.elapsedMilliseconds;

      if (response.statusCode == 200) {
        Map<String, dynamic>? json;
        try {
          json = jsonDecode(response.body) as Map<String, dynamic>;
        } catch (_) {}

        return ConnectionTestResult(
          reachable:     true,
          latencyMs:     ms,
          mock:          json?['mock'] as bool? ?? true,
          serverVersion: json?['version'] as String?,
        );
      }

      return ConnectionTestResult(
        reachable:    false,
        latencyMs:    ms,
        errorMessage: 'Server returned ${response.statusCode}',
      );
    } on SocketException {
      sw.stop();
      return ConnectionTestResult(
        reachable:    false,
        latencyMs:    sw.elapsedMilliseconds,
        errorMessage: 'No route to host. Check IP and network.',
      );
    } on TimeoutException {
      sw.stop();
      return ConnectionTestResult(
        reachable:    false,
        latencyMs:    sw.elapsedMilliseconds,
        errorMessage: 'Connection timed out after ${_testTimeout.inSeconds}s.',
      );
    } catch (e) {
      sw.stop();
      return ConnectionTestResult(
        reachable:    false,
        latencyMs:    sw.elapsedMilliseconds,
        errorMessage: e.toString(),
      );
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  static String _extractErrorMessage(String body, int statusCode) {
    try {
      final j = jsonDecode(body) as Map<String, dynamic>;
      return j['error'] as String?
          ?? j['detail'] as String?
          ?? 'Server error ($statusCode)';
    } catch (_) {
      return 'Server error ($statusCode)';
    }
  }

  static ApiResult<Map<String, dynamic>> _exceptionToResult(
    Object? e, int ms,
  ) {
    if (e is SocketException) {
      return ApiResult.err('No connection to server', ApiErrorCode.network, ms);
    }
    if (e is TimeoutException) {
      return ApiResult.err('Request timed out', ApiErrorCode.timeout, ms);
    }
    if (e is FormatException) {
      return ApiResult.err('Invalid server response', ApiErrorCode.parseError, ms);
    }
    return ApiResult.err(
      e?.toString() ?? 'Unknown error', ApiErrorCode.unknown, ms,
    );
  }
}
