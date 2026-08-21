import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api_service.dart' show ApiErrorCode;

/// The single, authoritative source of truth for the Django server's base
/// URL. Every other part of the app — AuthService, AppState, and every
/// screen that talks to the backend — reads the current value from here.
/// Nothing else is allowed to independently persist or cache its own copy.
///
/// This replaces a real bug found live 2026-08-20: AuthService kept its own
/// persisted copy (FlutterSecureStorage key `lumina_auth_base_url`) — a
/// *different* store than the old AppConfig's SharedPreferences key
/// (`server_url`) — synced only as a side effect of calling login(). AppState
/// held a third copy, captured once at construction and never updated unless
/// a caller remembered to push a new value into it by hand. The recovery
/// flow updated two of the three copies and missed the one the dashboard
/// actually polls with, so login succeeded against the new server while the
/// dashboard kept silently polling the old one.
///
/// Architecture this class enforces:
///   set URL → validate → persist → update in-memory value → bump [version]
///   → notify listeners → every dependent reconfigures itself
/// No service should ever be able to observe "the URL changed" without also
/// seeing the new value — persistence, memory, and notification happen as
/// one atomic step, in that order, whether the change came from a person
/// (Settings, the recovery sheet) or from automatic failover (below).
///
/// [version] exists for stale-async-response protection: a request started
/// against the old server can still be in flight when the URL changes.
/// Consumers (see AppState._poll()) capture [version] before an `await` and
/// compare it after — a mismatch means a newer config change happened while
/// the request was in flight, and the response must be discarded rather
/// than applied, or it would silently resurrect state from a server the
/// user has already moved away from. Automatic failover bumps [version]
/// through the exact same path a manual edit does, so that guard covers
/// both without AppState needing to know which kind of change happened.
///
/// Pre-login note: the login screen deliberately never exposes a bare,
/// always-visible server-URL field — that's a textbook credential-phishing
/// vector (anyone can point the login POST at any host with zero warning).
/// [setServerUrl] is reachable pre-login only through the low-prominence,
/// explicitly-labeled "Advanced (Tech Team)" recovery sheet, not the login
/// form itself; post-login it's reachable from Settings → Device Management,
/// gated the same way the rest of that section already is.
///
/// ─────────────────────────────────────────────────────────────────────────
/// Multi-endpoint failover (2026-08-21) — TEMPORARY, until the server has
/// its own WAN connectivity and this collapses back to a single URL.
///
/// The server is only reachable via Cloudflare Tunnel today, which makes
/// that one tunnel a single point of failure. This class now holds an
/// ordered *pool* of candidate URLs (still exposed to the rest of the app as
/// one [serverUrl] — nothing downstream changes) and:
///   - tracks each endpoint's health from real traffic outcomes
///     ([reportOutcome], called by AppState after every request) — no extra
///     network load for whichever endpoint is actively serving traffic;
///   - background-probes only the *backup* endpoints on a slow timer, so a
///     healthy standby is already known-good the instant it's needed;
///   - opens a circuit (stops trying) on an endpoint after repeated
///     failures, with exponential backoff + jitter, instead of hammering a
///     dead tunnel every second;
///   - promotes the next healthy endpoint automatically, through the same
///     persist → bump version → notify path as a manual edit;
///   - never treats an auth/permission/rate-limit response (401/403/429/
///     NO_APARTMENT/...) as an endpoint-health signal — those are identical
///     on every endpoint because they're all the same backend, so switching
///     tunnels can't fix them and must never be triggered by them.
class RuntimeConfig extends ChangeNotifier {
  RuntimeConfig._();

  /// App-wide singleton. Constructed once, before runApp() — every service
  /// that needs the server URL either takes this instance in its
  /// constructor (AppState) or reads [instance] directly (AuthService,
  /// screens that build their own one-off ApiService/http calls).
  static final RuntimeConfig instance = RuntimeConfig._();

  // Legacy single-URL key, read once as a migration source for installs
  // from before the pool existed. Never written again after migration.
  static const String _legacySingleUrlKey = 'server_url';
  static const String _poolKey = 'server_url_pool';

  static const String _compiledDefault = String.fromEnvironment(
    'LUGH_SERVER_URL',
    defaultValue: 'http://192.168.5.191',
  );

  // ── Failover tuning ────────────────────────────────────────────────────
  static const int _failuresToOpenCircuit = 3;
  static const Duration _baseBackoff = Duration(seconds: 10);
  static const Duration _maxBackoff  = Duration(minutes: 5);
  static const Duration _probeInterval = Duration(seconds: 30);
  static const Duration _probeTimeout  = Duration(seconds: 4);
  // How many consecutive clean background probes a higher-priority (lower
  // index) endpoint needs before we migrate back to it from a lower-priority
  // one that's currently working fine — deliberately sticky, so a briefly
  // flaky endpoint recovering doesn't cause a switch on its very first good
  // probe.
  static const int _reclaimAfterProbes = 3;

  final List<_Endpoint> _endpoints = [];
  int _activeIndex = 0;
  int _version = 0;
  bool _ready = false;
  Timer? _prober;
  final _rng = Random();

  /// The current server URL — the active pool member. Never null/empty:
  /// falls back to the first compiled-in default
  /// (`--dart-define=LUGH_SERVER_URL=...`) until [initialize] resolves
  /// storage, and to that same default if storage has nothing saved yet.
  String get serverUrl =>
      _endpoints.isEmpty ? _compiledDefault : _endpoints[_activeIndex].url;

  /// Just the host, for compact display (Settings' "via `host`" line).
  String get activeHost => Uri.tryParse(serverUrl)?.host ?? serverUrl;

  /// Bumped by exactly 1 every time the active URL actually changes —
  /// whether from a person saving a new address or from automatic
  /// failover promoting a different pool member. A no-op call (same URL
  /// already active) never bumps it.
  int get version => _version;

  bool get isReady => _ready;

  /// How many endpoints are currently configured. 1 means failover is
  /// effectively inert (nothing to fail over *to*) — the whole pool
  /// machinery degrades gracefully to "just use the one URL," which is
  /// exactly the pre-failover behavior.
  int get endpointCount => _endpoints.length;

  /// Read-only snapshot for status display (Settings, future per-endpoint
  /// UI). Order matches configured priority, not current health.
  List<EndpointStatus> get endpoints => List.unmodifiable(_endpoints
      .asMap()
      .entries
      .map((e) => EndpointStatus(
            url: e.value.url,
            isActive: e.key == _activeIndex,
            isHealthy: !e.value.isCircuitOpen,
            lastLatencyMs: e.value.lastLatencyMs,
          )));

  /// Must be awaited once, before runApp(), before any service that reads
  /// [serverUrl] is constructed. Resolves the persisted pool if any,
  /// migrating a pre-failover single-URL install forward automatically.
  Future<void> initialize() async {
    if (_ready) return;
    final prefs = await SharedPreferences.getInstance();

    List<String>? urls;
    final poolJson = prefs.getString(_poolKey);
    if (poolJson != null) {
      try {
        urls = (jsonDecode(poolJson) as List<dynamic>).cast<String>();
      } catch (_) {
        urls = null; // corrupt prefs — fall through to legacy/compiled
      }
    }
    final legacySingle = prefs.getString(_legacySingleUrlKey);
    urls ??= legacySingle != null ? [legacySingle] : null;
    urls ??= _compiledDefault
        .split(',')
        .map((u) => u.trim())
        .where((u) => u.isNotEmpty)
        .toList();
    if (urls.isEmpty) urls = [_compiledDefault];

    _endpoints
      ..clear()
      ..addAll(urls.map(_Endpoint.new));
    _activeIndex = 0;
    _ready = true;

    _prober?.cancel();
    _prober = Timer.periodic(_probeInterval, (_) => _probeBackups());
  }

  /// Validates, persists, updates the in-memory value, bumps [version], and
  /// notifies every listener — in that exact order, so nothing can observe
  /// a state where the value changed but storage or the version counter
  /// hasn't caught up yet.
  ///
  /// Replaces the *entire* pool with this one URL — the manual "point
  /// everything at exactly this address" escape hatch Settings and the
  /// login recovery sheet already use. Failover-discovered endpoints from
  /// before this call are discarded, which is the right behavior for an
  /// explicit human override.
  ///
  /// Returns a user-facing error string on an invalid URL, `null` on
  /// success (including the no-op case where [url] already equals the
  /// current active value — callers can call this unconditionally without
  /// worrying about triggering a spurious reconnect).
  Future<String?> setServerUrl(String url) => setEndpoints([url]);

  /// Replaces the whole configured endpoint list, in priority order
  /// (index 0 = most preferred). Used by the manual override paths (via
  /// [setServerUrl] for the single-URL case) and available directly for a
  /// future multi-endpoint management UI.
  Future<String?> setEndpoints(List<String> urls) async {
    final cleaned = <String>[];
    for (final raw in urls) {
      final trimmed = raw.trim().replaceAll(RegExp(r'/+$'), '');
      if (trimmed.isEmpty) continue;
      final uri = Uri.tryParse(trimmed);
      if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
        return 'Enter a valid URL, e.g. http://192.168.0.158:9080';
      }
      if (!cleaned.contains(trimmed)) cleaned.add(trimmed);
    }
    if (cleaned.isEmpty) return 'Enter a server address.';

    if (cleaned.length == _endpoints.length &&
        _activeIndex == 0 &&
        _listEquals(cleaned, _endpoints.map((e) => e.url).toList())) {
      return null; // no-op — identical pool already active from the top
    }

    final oldActive = serverUrl;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_poolKey, jsonEncode(cleaned));

    _endpoints
      ..clear()
      ..addAll(cleaned.map(_Endpoint.new));
    _activeIndex = 0;
    _version++;
    debugPrint(
      '[RuntimeConfig] endpoint pool replaced: "$oldActive" -> "$serverUrl" '
      '(${cleaned.length} endpoint(s), v$_version, ${DateTime.now().toIso8601String()})',
    );
    notifyListeners();
    return null;
  }

  // ── Health reporting (called by AppState after every real request) ─────

  /// Feeds one real request's outcome into the active endpoint's health
  /// tracking. This is the *primary* health signal — it rides on traffic
  /// that's already happening (the ~1/s poll, every write command), so a
  /// healthy active endpoint costs zero extra requests to keep monitoring.
  ///
  /// [url] is the endpoint the request actually went to (`ApiService.baseUrl`)
  /// — reported explicitly rather than assumed to be "whatever's active
  /// right now," because by the time an async request resolves, failover
  /// may already have moved on; a stale result must not corrupt a
  /// *different* endpoint's health record.
  void reportOutcome({
    required String url,
    required bool success,
    ApiErrorCode? errorCode,
    int? statusCode,
    int? latencyMs,
  }) {
    final idx = _endpoints.indexWhere((e) => e.url == url);
    if (idx == -1) return; // pool has moved on; nothing to record against

    final ep = _endpoints[idx];
    if (latencyMs != null) ep.lastLatencyMs = latencyMs;

    if (success) {
      _recordSuccess(ep);
      return;
    }

    // Auth/permission/rate-limit responses say nothing about *this
    // endpoint's* health — they're identical no matter which tunnel
    // carried the request, because every tunnel reaches the same backend.
    // Counting them would cause failover to "fix" a problem that exists on
    // every endpoint equally, which just churns the pool for no benefit.
    final isEndpointSignal = switch (errorCode) {
      ApiErrorCode.network ||
      ApiErrorCode.timeout ||
      ApiErrorCode.parseError ||
      ApiErrorCode.unknown =>
        true,
      ApiErrorCode.serverError => true, // 5xx from *this* tunnel/edge
      ApiErrorCode.clientError => false, // 401/403/429/NO_APARTMENT/...
      null => false,
    };
    if (!isEndpointSignal) return;

    _recordFailure(ep, isActive: idx == _activeIndex);
  }

  void _recordSuccess(_Endpoint ep) {
    ep.consecutiveFailures = 0;
    ep.circuitOpenCount = 0;
    ep.circuitOpenUntil = null;
    ep.consecutiveProbeSuccesses++;
    ep.lastSuccessAt = DateTime.now();
    _maybeReclaimHigherPriority();
  }

  void _recordFailure(_Endpoint ep, {required bool isActive}) {
    ep.consecutiveFailures++;
    ep.consecutiveProbeSuccesses = 0;
    if (ep.consecutiveFailures < _failuresToOpenCircuit) return;

    ep.circuitOpenCount++;
    final backoff = _backoffFor(ep.circuitOpenCount);
    ep.circuitOpenUntil = DateTime.now().add(backoff);
    debugPrint(
      '[RuntimeConfig] circuit open: ${ep.url} '
      '(${ep.consecutiveFailures} failures, retry in ${backoff.inSeconds}s)',
    );

    if (isActive) _promoteNextHealthyEndpoint();
  }

  Duration _backoffFor(int openCount) {
    final scaled = _baseBackoff * pow(2, openCount - 1).toDouble();
    final capped = scaled > _maxBackoff ? _maxBackoff : scaled;
    // ±20% jitter so a fleet of endpoints that all failed together don't
    // all retry on the exact same tick.
    final jitter = 0.8 + _rng.nextDouble() * 0.4;
    return capped * jitter;
  }

  // ── Failover selection ──────────────────────────────────────────────────

  /// Picks the next usable endpoint after the active one fails: first
  /// closed-circuit candidate in configured priority order. If every
  /// endpoint is currently open, degrades gracefully by trying whichever
  /// recovers soonest rather than refusing to ever try again.
  void _promoteNextHealthyEndpoint() {
    if (_endpoints.length <= 1) return; // nothing to fail over to

    var bestOpenIdx = -1;
    for (var i = 0; i < _endpoints.length; i++) {
      if (!_endpoints[i].isCircuitOpen) {
        _switchActive(i);
        return;
      }
      if (bestOpenIdx == -1 ||
          _endpoints[i].circuitOpenUntil!.isBefore(_endpoints[bestOpenIdx].circuitOpenUntil!)) {
        bestOpenIdx = i;
      }
    }
    // Every endpoint is in backoff — pick the one recovering soonest so the
    // app keeps trying *something* instead of giving up entirely.
    if (bestOpenIdx != -1) _switchActive(bestOpenIdx);
  }

  /// After the active endpoint has been demoted below a higher-priority
  /// one that's since proven itself stable (several consecutive clean
  /// background probes), migrate back. Deliberately conservative — this
  /// only fires from [_recordSuccess], i.e. on real evidence, never
  /// speculatively.
  void _maybeReclaimHigherPriority() {
    for (var i = 0; i < _activeIndex; i++) {
      final ep = _endpoints[i];
      if (!ep.isCircuitOpen && ep.consecutiveProbeSuccesses >= _reclaimAfterProbes) {
        _switchActive(i);
        return;
      }
    }
  }

  void _switchActive(int newIndex) {
    if (newIndex == _activeIndex) return;
    final oldUrl = serverUrl;
    _activeIndex = newIndex;
    _version++;
    debugPrint(
      '[RuntimeConfig] failover: "$oldUrl" -> "$serverUrl" '
      '(v$_version, ${DateTime.now().toIso8601String()})',
    );
    notifyListeners();
  }

  // ── Background probing of backup endpoints ──────────────────────────────

  /// Every [_probeInterval], checks the health of every endpoint *except*
  /// the active one (which is already continuously exercised by real
  /// traffic — probing it too would just be redundant load). Skips any
  /// endpoint still inside its circuit-breaker cooldown. Single in-flight
  /// guard per endpoint via [_Endpoint.probing], so a slow probe can never
  /// stack up across ticks.
  Future<void> _probeBackups() async {
    final now = DateTime.now();
    for (var i = 0; i < _endpoints.length; i++) {
      if (i == _activeIndex) continue;
      final ep = _endpoints[i];
      if (ep.probing) continue;
      if (ep.circuitOpenUntil != null && ep.circuitOpenUntil!.isAfter(now)) continue;

      ep.probing = true;
      unawaited(_probeOne(ep).whenComplete(() => ep.probing = false));
    }
  }

  Future<void> _probeOne(_Endpoint ep) async {
    final sw = Stopwatch()..start();
    try {
      final resp = await http.get(Uri.parse('${ep.url}/health/')).timeout(_probeTimeout);
      sw.stop();
      if (resp.statusCode == 200) {
        ep.lastLatencyMs = sw.elapsedMilliseconds;
        _recordSuccess(ep);
      } else {
        _recordFailure(ep, isActive: false);
      }
    } catch (_) {
      _recordFailure(ep, isActive: false);
    }
  }

  @override
  void dispose() {
    _prober?.cancel();
    super.dispose();
  }
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// One candidate server URL and its health-tracking state. Private —
/// nothing outside [RuntimeConfig] touches this directly; [EndpointStatus]
/// is the read-only view exposed for UI.
class _Endpoint {
  final String url;
  int consecutiveFailures = 0;
  int consecutiveProbeSuccesses = 0;
  int circuitOpenCount = 0;
  DateTime? circuitOpenUntil;
  DateTime? lastSuccessAt;
  int? lastLatencyMs;
  bool probing = false;

  _Endpoint(this.url);

  bool get isCircuitOpen =>
      circuitOpenUntil != null && circuitOpenUntil!.isAfter(DateTime.now());
}

/// Read-only snapshot of one pool endpoint, for status display.
class EndpointStatus {
  final String url;
  final bool isActive;
  final bool isHealthy;
  final int? lastLatencyMs;

  const EndpointStatus({
    required this.url,
    required this.isActive,
    required this.isHealthy,
    this.lastLatencyMs,
  });
}
