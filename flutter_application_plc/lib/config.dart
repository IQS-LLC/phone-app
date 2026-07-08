import 'package:shared_preferences/shared_preferences.dart';

/// Compile-time server configuration.
///
/// The pre-authentication login screen must never let a user type a server
/// address — an editable field there is a textbook credential-phishing
/// vector: anyone (an attacker, a support script, a fat-fingered user) can
/// point the login POST at any host with zero certificate pinning, zero
/// warning, and the username + password go straight to whatever's
/// listening there.
///
/// Production builds bake the real server in at build time:
///   flutter build apk --dart-define=LUGH_SERVER_URL=https://api.lugh.example.com
/// Local dev/testing does the same with a different value:
///   flutter run --dart-define=LUGH_SERVER_URL=http://10.0.2.2:8000
/// With no --dart-define supplied, defaultValue below is used.
///
/// Post-login, the Tech Team (Settings → Device Management, installer-only)
/// CAN repoint the server at runtime — that's a legitimate ops need (moving
/// to a new host, switching environments) and is gated behind an
/// authenticated installer/staff session, not exposed to an anonymous user
/// on the login screen. [resolve] is the single source of truth both
/// main.dart (startup) and the login screen consult, so a Tech-Team-set
/// address survives logout/login instead of reverting to the compiled-in
/// default.
class AppConfig {
  static const String serverUrl = String.fromEnvironment(
    'LUGH_SERVER_URL',
    defaultValue: 'http://192.168.0.158:8000',
  );

  static const String prefsKey = 'server_url';

  static Future<String> resolve() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(prefsKey) ?? serverUrl;
  }

  static Future<void> persist(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, url);
  }
}
