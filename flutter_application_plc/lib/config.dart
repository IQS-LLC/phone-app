/// Compile-time server configuration.
///
/// The app must never let a user type a server address into the
/// pre-authentication login screen — an editable "server address" field
/// there is a textbook credential-phishing vector: anyone (an attacker, a
/// support script, a fat-fingered user) can point the login POST at any
/// host with zero certificate pinning, zero warning, and the username +
/// password go straight to whatever's listening there. The server address
/// belongs in build configuration, not user input.
///
/// Production builds bake the real server in at build time:
///   flutter build apk --dart-define=LUGH_SERVER_URL=https://api.lugh.example.com
/// Local dev/testing does the same with a different value:
///   flutter run --dart-define=LUGH_SERVER_URL=http://10.0.2.2:8000
/// With no --dart-define supplied, defaultValue below is used.
class AppConfig {
  static const String serverUrl = String.fromEnvironment(
    'LUGH_SERVER_URL',
    defaultValue: 'http://192.168.0.158:8000',
  );
}
