import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
/// one atomic step inside [setServerUrl], in that order.
///
/// [version] exists for stale-async-response protection: a request started
/// against the old server can still be in flight when the URL changes.
/// Consumers (see AppState._poll()) capture [version] before an `await` and
/// compare it after — a mismatch means a newer config change happened while
/// the request was in flight, and the response must be discarded rather
/// than applied, or it would silently resurrect state from a server the
/// user has already moved away from.
///
/// Pre-login note: the login screen deliberately never exposes a bare,
/// always-visible server-URL field — that's a textbook credential-phishing
/// vector (anyone can point the login POST at any host with zero warning).
/// [setServerUrl] is reachable pre-login only through the low-prominence,
/// explicitly-labeled "Advanced (Tech Team)" recovery sheet, not the login
/// form itself; post-login it's reachable from Settings → Device Management,
/// gated the same way the rest of that section already is.
class RuntimeConfig extends ChangeNotifier {
  RuntimeConfig._();

  /// App-wide singleton. Constructed once, before runApp() — every service
  /// that needs the server URL either takes this instance in its
  /// constructor (AppState) or reads [instance] directly (AuthService,
  /// screens that build their own one-off ApiService/http calls).
  static final RuntimeConfig instance = RuntimeConfig._();

  static const String _prefsKey = 'server_url';
  static const String _compiledDefault = String.fromEnvironment(
    'LUGH_SERVER_URL',
    defaultValue: 'http://192.168.5.191',
  );

  String _serverUrl = _compiledDefault;
  int _version = 0;
  bool _ready = false;

  /// The current server URL. Never null/empty — falls back to the
  /// compiled-in default (`--dart-define=LUGH_SERVER_URL=...`) until
  /// [initialize] resolves storage, and to that same default if storage has
  /// nothing saved yet.
  String get serverUrl => _serverUrl;

  /// Bumped by exactly 1 on every call to [setServerUrl] that actually
  /// changes the value (a no-op call — same URL — does not bump it).
  int get version => _version;

  bool get isReady => _ready;

  /// Must be awaited once, before runApp(), before any service that reads
  /// [serverUrl] is constructed. Resolves the persisted value, if any.
  Future<void> initialize() async {
    if (_ready) return;
    final prefs = await SharedPreferences.getInstance();
    _serverUrl = prefs.getString(_prefsKey) ?? _compiledDefault;
    _ready = true;
  }

  /// Validates, persists, updates the in-memory value, bumps [version], and
  /// notifies every listener — in that exact order, so nothing can observe
  /// a state where the value changed but storage or the version counter
  /// hasn't caught up yet.
  ///
  /// Returns a user-facing error string on an invalid URL, `null` on
  /// success (including the no-op case where [url] already equals the
  /// current value — callers can call this unconditionally without
  /// worrying about triggering a spurious reconnect).
  Future<String?> setServerUrl(String url) async {
    final trimmed = url.trim().replaceAll(RegExp(r'/+$'), '');
    if (trimmed.isEmpty) return 'Enter a server address.';
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return 'Enter a valid URL, e.g. http://192.168.0.158:9080';
    }
    if (trimmed == _serverUrl) return null;

    final old = _serverUrl;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, trimmed);
    _serverUrl = trimmed;
    _version++;
    // Diagnostics only — never log tokens/credentials here. old/new
    // endpoint + version + timestamp is enough to reconstruct "what changed
    // when" without touching anything sensitive.
    debugPrint(
      '[RuntimeConfig] server changed: "$old" -> "$trimmed" '
      '(v$_version, ${DateTime.now().toIso8601String()})',
    );
    notifyListeners();
    return null;
  }
}
