import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'auth/auth_service.dart';
import 'auth/auth_state.dart';
import 'config.dart';
import 'state/app_state.dart';
import 'theme.dart';
import 'screens/login_screen.dart';
import 'screens/main_shell.dart';

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

  final url = await AppConfig.resolve();

  final authService = AuthService();
  final authState   = AuthState(authService);
  final appState    = AppState(
    url,
    getAuthToken:     authService.getAccessToken,
    refreshAuthToken: authService.refreshAccessToken,
  );

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
          return LoginScreen(authState: authState, appState: appState);
        }

        // Authenticated — show dashboard. AppState's server URL comes only
        // from the login screen / Settings (the central Django server) —
        // never from a PLCDevice's IP. The backend resolves which apartment
        // this user belongs to on every request; the app never needs to
        // know or care about a PLC's address.
        return MainShell(appState: appState, authState: authState);
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Splash screen (shown during token check on startup)
// ─────────────────────────────────────────────────────────────────────────────

class _SplashScreen extends StatefulWidget {
  const _SplashScreen();
  @override
  State<_SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<_SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double>   _fade;
  late final Animation<double>   _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 800));
    _fade  = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide = Tween<double>(begin: 24, end: 0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic),
    );
    _ctrl.forward();
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: C.bg,
    body: Center(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, _) => Opacity(
          opacity: _fade.value,
          child: Transform.translate(
            offset: Offset(0, _slide.value),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 88, height: 88,
                decoration: BoxDecoration(
                  gradient: G.accent,
                  borderRadius: BorderRadius.circular(26),
                  boxShadow: S.accentGlow,
                ),
                child: const Icon(Icons.bolt_rounded, size: 48, color: Colors.black),
              ),
              const SizedBox(height: 28),
              Text('Lugh', style: AppText.display),
              const SizedBox(height: 6),
              Text('by IQS', style: AppText.bodySm.copyWith(
                  color: C.textSec, fontWeight: FontWeight.w600, letterSpacing: 2)),
              const SizedBox(height: 6),
              Text('Smart Building Control', style: AppText.caption),
              const SizedBox(height: 40),
              SizedBox(
                width: 120,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    backgroundColor: C.border2,
                    valueColor: const AlwaysStoppedAnimation<Color>(C.accent),
                    minHeight: 2,
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    ),
  );
}
