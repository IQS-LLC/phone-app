import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../auth/auth_state.dart';
import '../config.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common_widgets.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Login Screen — first impression; must feel premium
// ─────────────────────────────────────────────────────────────────────────────

class LoginScreen extends StatefulWidget {
  final AuthState authState;
  final AppState  appState;
  const LoginScreen({super.key, required this.authState, required this.appState});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _formKey  = GlobalKey<FormState>();
  bool _obscurePass = true;

  late final AnimationController _bgCtrl;
  late final Animation<double>   _bgAnim;

  AuthState get _auth => widget.authState;

  @override
  void initState() {
    super.initState();
    _bgCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();
    _bgAnim = CurvedAnimation(parent: _bgCtrl, curve: Curves.linear);
  }

  @override
  void dispose() {
    _bgCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    _auth.clearError();
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final serverUrl = await AppConfig.resolve();
    final ok = await _auth.login(
      username:  _userCtrl.text.trim(),
      password:  _passCtrl.text,
      serverUrl: serverUrl,
    );
    if (ok) {
      // AppState is constructed once at cold start with whatever URL was
      // resolved then. If the user just recovered from a dead tunnel via
      // the Advanced sheet below, that's a different (newer) URL than the
      // one AppState has been polling with — without this, login succeeds
      // but the dashboard keeps silently polling the old dead address
      // forever. setBaseUrl() is a no-op when the URL hasn't changed.
      widget.appState.setBaseUrl(serverUrl);
    } else if (mounted) {
      AppToast.show(context, _auth.error ?? 'Login failed', error: true);
    }
  }

  Future<void> _openServerAddressSheet(BuildContext context) async {
    final currentUrl = await AppConfig.resolve();
    if (!context.mounted) return;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _ServerAddressSheet(currentUrl: currentUrl),
    );
    if (saved == true && mounted) {
      AppToast.show(context, 'Server address saved. Try signing in again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor:          Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ));

    return ListenableBuilder(
      listenable: _auth,
      builder: (_, _) => Scaffold(
        backgroundColor: C.bg,
        resizeToAvoidBottomInset: true,
        body: Stack(children: [
          // Animated gradient background
          AnimatedBuilder(
            animation: _bgAnim,
            builder: (_, _) => Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(
                    0.6 * (_bgAnim.value < 0.5
                        ? _bgAnim.value * 2 - 0.5
                        : 1 - (_bgAnim.value - 0.5) * 2),
                    -0.4,
                  ),
                  radius: 1.2,
                  colors: const [
                    Color(0xFF1A1505),
                    Color(0xFF080812),
                    Color(0xFF060611),
                  ],
                ),
              ),
            ),
          ),
          // Subtle gold orb top-right
          Positioned(
            top: -80, right: -60,
            child: Container(
              width: 260, height: 260,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    C.accent.withAlpha(30),
                    C.accent.withAlpha(0),
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 32),
                  _LogoSection(bgAnim: _bgAnim),
                  const SizedBox(height: 52),
                  _LoginForm(
                    formKey:     _formKey,
                    userCtrl:    _userCtrl,
                    passCtrl:    _passCtrl,
                    obscurePass: _obscurePass,
                    onToggle:    () => setState(() => _obscurePass = !_obscurePass),
                    onSubmit:    _submit,
                  ),
                  const SizedBox(height: 20),
                  PrimaryButton(
                    label:   'Sign In',
                    loading: _auth.loading,
                    onTap:   _submit,
                  ),
                  const SizedBox(height: 32),
                  Text(
                    'Access is granted by your building administrator.',
                    style: AppText.caption,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  GestureDetector(
                    onTap: () => showDialog(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        backgroundColor: C.card,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20)),
                        title: Text('Request Access',
                            style: AppText.h2.copyWith(fontSize: 17)),
                        content: Text(
                          'To get access to Lugh, contact your building manager or '
                          'the IQS technical team. They will create your account '
                          'and assign you to your apartment.',
                          style: AppText.bodySm,
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: Text('Got it',
                                style: AppText.bodySm.copyWith(
                                    color: C.accent,
                                    fontWeight: FontWeight.w700)),
                          ),
                        ],
                      ),
                    ),
                    child: Text(
                      'Need access? Contact your building manager',
                      style: AppText.caption.copyWith(
                          color: C.accent.withAlpha(180),
                          decoration: TextDecoration.underline,
                          decorationColor: C.accent.withAlpha(100)),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 20),
                  // Deliberately NOT a bare text field on the login form
                  // itself — see config.dart's docstring on why that's a
                  // credential-phishing vector. This is a separate,
                  // low-prominence, explicitly-labeled technical action
                  // that requires the Cloudflare quick-tunnel-rotation
                  // recovery gap found live 2026-08-20 (a stale compiled-in
                  // URL otherwise locks out every user, Tech Team included,
                  // until a full rebuild) without weakening that guarantee
                  // for the resident who never taps it.
                  Center(
                    child: TextButton(
                      onPressed: () => _openServerAddressSheet(context),
                      style: TextButton.styleFrom(
                        foregroundColor: C.textTri,
                        minimumSize: const Size(0, 0),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text('Advanced (Tech Team)',
                          style: AppText.caption.copyWith(color: C.textTri, fontSize: 11)),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Logo section
// ─────────────────────────────────────────────────────────────────────────────

class _LogoSection extends StatelessWidget {
  final Animation<double> bgAnim;
  const _LogoSection({required this.bgAnim});

  @override
  Widget build(BuildContext context) => Column(
    children: [
      AnimatedBuilder(
        animation: bgAnim,
        builder: (_, _) => Container(
          width: 88, height: 88,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            gradient: SweepGradient(
              center:     Alignment.center,
              startAngle: bgAnim.value * 6.28,
              colors:     const [
                Color(0xFFF5C542), Color(0xFFFF8C00),
                Color(0xFFF5C542), Color(0xFFFFD700),
                Color(0xFFF5C542),
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: C.accent.withAlpha(100),
                blurRadius: 40,
                spreadRadius: 4,
              ),
            ],
          ),
          child: const Icon(Icons.bolt_rounded, size: 48, color: Colors.black),
        ),
      ),
      const SizedBox(height: 24),
      Text('Lugh',
          style: AppText.display.copyWith(
            letterSpacing: -1.5,
            foreground: Paint()
              ..shader = const LinearGradient(
                colors: [Color(0xFFF5C542), Color(0xFFFFD580)],
              ).createShader(const Rect.fromLTWH(0, 0, 120, 40)),
          )),
      const SizedBox(height: 6),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(width: 24, height: 0.5, color: C.textTri),
        const SizedBox(width: 10),
        Text('by IQS',
            style: AppText.bodySm.copyWith(
              color: C.textSec, fontWeight: FontWeight.w600, letterSpacing: 2,
            )),
        const SizedBox(width: 10),
        Container(width: 24, height: 0.5, color: C.textTri),
      ]),
      const SizedBox(height: 8),
      Text('Smart Building Control', style: AppText.caption),
    ],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Login form
// ─────────────────────────────────────────────────────────────────────────────

class _LoginForm extends StatelessWidget {
  final GlobalKey<FormState>  formKey;
  final TextEditingController userCtrl;
  final TextEditingController passCtrl;
  final bool                  obscurePass;
  final VoidCallback          onToggle;
  final VoidCallback          onSubmit;

  const _LoginForm({
    required this.formKey, required this.userCtrl, required this.passCtrl,
    required this.obscurePass, required this.onToggle, required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) => Form(
    key: formKey,
    child: Column(children: [
      _Field(
        hint:     'Username',
        ctrl:     userCtrl,
        icon:     Icons.person_outline_rounded,
        action:   TextInputAction.next,
        validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter your username' : null,
      ),
      const SizedBox(height: Sp.x4),
      _Field(
        hint:       'Password',
        ctrl:       passCtrl,
        icon:       Icons.lock_outline_rounded,
        obscure:    obscurePass,
        action:     TextInputAction.done,
        onSubmit:   (_) => onSubmit(),
        suffix: GestureDetector(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Icon(
              obscurePass ? Icons.visibility_outlined : Icons.visibility_off_outlined,
              color: C.textSec, size: 20,
            ),
          ),
        ),
        validator: (v) => (v == null || v.isEmpty) ? 'Enter your password' : null,
      ),
    ]),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Server address recovery sheet — Tech Team only, reached via the
// low-prominence "Advanced" link above, never a field on the login form
// itself. See config.dart's docstring and the comment at that link for why.
// ─────────────────────────────────────────────────────────────────────────────

class _ServerAddressSheet extends StatefulWidget {
  final String currentUrl;
  const _ServerAddressSheet({required this.currentUrl});

  @override
  State<_ServerAddressSheet> createState() => _ServerAddressSheetState();
}

class _ServerAddressSheetState extends State<_ServerAddressSheet> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.currentUrl);
  bool _saving = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final url = _ctrl.text.trim();
    if (url.isEmpty) return;
    setState(() => _saving = true);
    await AppConfig.persist(url);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(
      left: 20, right: 20, top: 20,
      bottom: MediaQuery.viewInsetsOf(context).bottom + 28,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Center(child: BottomSheetHandle()),
        const SizedBox(height: 16),
        Row(children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(color: C.orange.withAlpha(22), borderRadius: BorderRadius.circular(11)),
            child: const Icon(Icons.dns_rounded, color: C.orange, size: 17),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text('Server Address', style: AppText.h2.copyWith(fontSize: 18))),
        ]),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: C.orange.withAlpha(14), borderRadius: BorderRadius.circular(12)),
          child: Text(
            'Only change this if instructed by your building\'s technical team. '
            'This determines where your sign-in details are sent — this device only, '
            'and only until you sign in successfully.',
            style: AppText.bodySm.copyWith(color: C.textSec),
          ),
        ),
        const SizedBox(height: 16),
        Text('SERVER URL', style: AppText.label),
        const SizedBox(height: 6),
        TextField(
          controller: _ctrl,
          autocorrect: false,
          keyboardType: TextInputType.url,
          style: AppText.mono.copyWith(fontSize: 13, color: C.textPri),
          decoration: InputDecoration(
            hintText: 'https://your-server.example.com',
            hintStyle: AppText.mono.copyWith(color: C.textTri, fontSize: 13),
            filled: true, fillColor: C.elevated,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: C.border)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: C.border)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: C.accent, width: 1.5)),
          ),
        ),
        const SizedBox(height: 18),
        PrimaryButton(label: 'Save & Retry Sign In', loading: _saving, onTap: _save),
        const SizedBox(height: 8),
      ],
    ),
  );
}

class _Field extends StatelessWidget {
  final String hint;
  final TextEditingController ctrl;
  final IconData icon;
  final bool obscure;
  final TextInputAction action;
  final void Function(String)? onSubmit;
  final Widget? suffix;
  final String? Function(String?)? validator;

  const _Field({required this.hint, required this.ctrl,
    required this.icon, this.obscure = false,
    required this.action, this.onSubmit, this.suffix, this.validator,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextFormField(
        controller:      ctrl,
        style:           GoogleFonts.inter(fontSize: 14, color: C.textPri),
        textInputAction: action,
        autocorrect:     false,
        obscureText:     obscure,
        onFieldSubmitted: onSubmit,
        decoration: InputDecoration(
          hintText:    hint,
          hintStyle:   GoogleFonts.inter(fontSize: 14, color: C.textTri),
          prefixIcon:  Icon(icon, color: C.textSec, size: 20),
          suffixIcon:  suffix,
          filled:      true,
          fillColor:   C.card,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: C.border, width: 0.5),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: C.border, width: 0.5),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: C.accent, width: 1.5),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: C.red, width: 0.5),
          ),
          focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: C.red, width: 1.5),
          ),
          errorStyle: AppText.bodySm.copyWith(color: C.red, fontSize: 11),
        ),
        validator: validator,
      ),
    ],
  );
}
