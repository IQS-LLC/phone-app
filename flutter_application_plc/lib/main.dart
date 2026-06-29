import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth/auth_service.dart';
import 'auth/auth_state.dart';
import 'config.dart';
import 'state/app_state.dart';
import 'theme.dart';
import 'screens/dashboard_screen.dart';
import 'screens/login_screen.dart';
import 'screens/settings_screen.dart'; // exports kUrlPrefKey

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor:                    Colors.transparent,
    statusBarIconBrightness:           Brightness.light,
    statusBarBrightness:               Brightness.dark,
    systemNavigationBarColor:          Color(0xFF070710),
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  final prefs    = await SharedPreferences.getInstance();
  final url      = prefs.getString(kUrlPrefKey) ?? AppConfig.serverUrl;

  final authService = AuthService();
  final authState   = AuthState(authService);
  final appState    = AppState(url, getAuthToken: authService.getAccessToken);

  runApp(LughApp(appState: appState, authState: authState));
}

// ─────────────────────────────────────────────────────────────────────────────
// Root App
// ─────────────────────────────────────────────────────────────────────────────

class LughApp extends StatelessWidget {
  final AppState  appState;
  final AuthState authState;

  const LughApp({
    super.key,
    required this.appState,
    required this.authState,
  });

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Lugh',
    theme: buildTheme(),
    home:  _AuthGate(appState: appState, authState: authState),
    builder: (ctx, child) => MediaQuery(
      data: MediaQuery.of(ctx).copyWith(
        textScaler: MediaQuery.of(ctx).textScaler.clamp(
          minScaleFactor: 0.85,
          maxScaleFactor: 1.20,
        ),
      ),
      child: child!,
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Auth gate — shows login until authenticated, then the dashboard
// ─────────────────────────────────────────────────────────────────────────────

class _AuthGate extends StatelessWidget {
  final AppState  appState;
  final AuthState authState;

  const _AuthGate({required this.appState, required this.authState});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: authState,
      builder: (_, _) {
        // Splash while checking stored tokens
        if (authState.isInit) return const _SplashScreen();

        // Not logged in — show login
        if (!authState.isAuth) {
          return LoginScreen(authState: authState);
        }

        // Authenticated — show dashboard. AppState's server URL comes only
        // from the login screen / Settings (the central Django server) —
        // never from a PLCDevice's IP. The backend resolves which apartment
        // this user belongs to on every request; the app never needs to
        // know or care about a PLC's address.
        return DashboardScreen(appState: appState, authState: authState);
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Splash screen (shown during token check on startup)
// ─────────────────────────────────────────────────────────────────────────────

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: C.bg,
    body: Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 64, height: 64,
          decoration: BoxDecoration(
            color:        C.accentLo,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: C.accent.withAlpha(60)),
          ),
          child: const Icon(Icons.bolt_rounded, size: 36, color: C.accent),
        ),
        const SizedBox(height: 24),
        Text('Lugh', style: AppText.h1),
        const SizedBox(height: 4),
        Text('by IQS', style: AppText.bodySm.copyWith(color: C.textSec)),
        const SizedBox(height: 20),
        const SizedBox(
          width: 20, height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2, color: C.accent,
          ),
        ),
      ]),
    ),
  );
}
