import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/auth_state.dart';
import '../config.dart';
import '../theme.dart';
import '../widgets/common_widgets.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Login Screen
// ─────────────────────────────────────────────────────────────────────────────

class LoginScreen extends StatefulWidget {
  final AuthState authState;
  const LoginScreen({super.key, required this.authState});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  // ── Controllers ────────────────────────────────────────────────────────────
  final _userCtrl     = TextEditingController();
  final _passCtrl     = TextEditingController();
  final _emailCtrl    = TextEditingController();
  final _regUserCtrl  = TextEditingController();
  final _regPassCtrl  = TextEditingController();
  final _regPass2Ctrl = TextEditingController();
  final _formKey      = GlobalKey<FormState>();
  final _regFormKey   = GlobalKey<FormState>();

  // ── State ──────────────────────────────────────────────────────────────────
  bool _obscurePass     = true;
  bool _obscureRegPass  = true;
  bool _obscureRegPass2 = true;
  bool _isRegister      = false;

  late final AnimationController _shimmerCtrl;
  late final Animation<double>   _shimmerAnim;

  AuthState get _auth => widget.authState;

  @override
  void initState() {
    super.initState();
    _shimmerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
    _shimmerAnim = CurvedAnimation(parent: _shimmerCtrl, curve: Curves.linear);
  }

  @override
  void dispose() {
    _shimmerCtrl.dispose();
    for (final c in [
      _userCtrl, _passCtrl, _emailCtrl,
      _regUserCtrl, _regPassCtrl, _regPass2Ctrl,
    ]) { c.dispose(); }
    super.dispose();
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  Future<void> _submit() async {
    _auth.clearError();

    if (_isRegister) {
      if (!(_regFormKey.currentState?.validate() ?? false)) return;
      if (_regPassCtrl.text != _regPass2Ctrl.text) {
        _showError('Passwords do not match');
        return;
      }
      final ok = await _auth.register(
        username:  _regUserCtrl.text.trim(),
        password:  _regPassCtrl.text,
        email:     _emailCtrl.text.trim(),
        serverUrl: AppConfig.serverUrl,
      );
      if (!ok && mounted) _showError(_auth.error ?? 'Registration failed');
    } else {
      if (!(_formKey.currentState?.validate() ?? false)) return;
      final ok = await _auth.login(
        username:  _userCtrl.text.trim(),
        password:  _passCtrl.text,
        serverUrl: AppConfig.serverUrl,
      );
      if (!ok && mounted) _showError(_auth.error ?? 'Login failed');
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: AppText.body.copyWith(color: C.textPri)),
        backgroundColor: C.card,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
          side: BorderSide(color: C.red, width: 1.5),
        ),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor:             Colors.transparent,
      statusBarIconBrightness:    Brightness.light,
    ));

    return ListenableBuilder(
      listenable: _auth,
      builder: (_, _) => Scaffold(
        backgroundColor: C.bg,
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 24),
                _LogoSection(shimmerAnim: _shimmerAnim),
                const SizedBox(height: 48),

                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 280),
                  transitionBuilder: (child, anim) => FadeTransition(
                    opacity: anim,
                    child: SlideTransition(
                      position: Tween(
                        begin: const Offset(0.05, 0),
                        end:   Offset.zero,
                      ).animate(anim),
                      child: child,
                    ),
                  ),
                  child: _isRegister
                      ? _RegisterForm(
                          key:           const ValueKey('register'),
                          formKey:       _regFormKey,
                          userCtrl:      _regUserCtrl,
                          emailCtrl:     _emailCtrl,
                          passCtrl:      _regPassCtrl,
                          pass2Ctrl:     _regPass2Ctrl,
                          obscurePass:   _obscureRegPass,
                          obscurePass2:  _obscureRegPass2,
                          onTogglePass:  () => setState(() => _obscureRegPass  = !_obscureRegPass),
                          onTogglePass2: () => setState(() => _obscureRegPass2 = !_obscureRegPass2),
                        )
                      : _LoginForm(
                          key:         const ValueKey('login'),
                          formKey:     _formKey,
                          userCtrl:    _userCtrl,
                          passCtrl:    _passCtrl,
                          obscurePass: _obscurePass,
                          onToggle:    () => setState(() => _obscurePass = !_obscurePass),
                          onSubmit:    _submit,
                        ),
                ),

                const SizedBox(height: 24),
                PrimaryButton(
                  label:   _isRegister ? 'Create Account' : 'Sign In',
                  loading: _auth.loading,
                  onTap:   _submit,
                ),
                const SizedBox(height: 20),
                _ToggleMode(
                  isRegister: _isRegister,
                  onTap: () => setState(() {
                    _isRegister = !_isRegister;
                    _auth.clearError();
                  }),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Logo section
// ─────────────────────────────────────────────────────────────────────────────

class _LogoSection extends StatelessWidget {
  final Animation<double> shimmerAnim;
  const _LogoSection({required this.shimmerAnim});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        AnimatedBuilder(
          animation: shimmerAnim,
          builder: (_, _) => Container(
            width: 80, height: 80,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: SweepGradient(
                center:     Alignment.center,
                startAngle: shimmerAnim.value * 6.28,
                colors:     const [C.accent, Color(0xFFF97316), C.accent],
              ),
              boxShadow: [
                BoxShadow(
                  color: C.accent.withAlpha(80),
                  blurRadius: 32,
                  spreadRadius: 4,
                ),
              ],
            ),
            child: const Icon(Icons.bolt_rounded, size: 44, color: Colors.black),
          ),
        ),
        const SizedBox(height: 20),
        Text('Lugh', style: AppText.h1.copyWith(fontSize: 32, letterSpacing: -1)),
        const SizedBox(height: 4),
        Text('by IQS', style: AppText.bodySm.copyWith(color: C.textSec, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text('Smart Building Control', style: AppText.bodySm.copyWith(color: C.textTri)),
      ],
    );
  }
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
    super.key,
    required this.formKey,
    required this.userCtrl,
    required this.passCtrl,
    required this.obscurePass,
    required this.onToggle,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return Form(
      key: formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('USERNAME', style: AppText.label),
          const SizedBox(height: 8),
          TextFormField(
            controller:      userCtrl,
            style:           AppText.body,
            textInputAction: TextInputAction.next,
            autocorrect:     false,
            decoration:      _inputDeco(hint: 'your_username', icon: Icons.person_outline_rounded),
            validator:       (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
          ),
          const SizedBox(height: 16),
          Text('PASSWORD', style: AppText.label),
          const SizedBox(height: 8),
          TextFormField(
            controller:      passCtrl,
            style:           AppText.body,
            obscureText:     obscurePass,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => onSubmit(),
            decoration:      _inputDeco(
              hint: '••••••••',
              icon: Icons.lock_outline_rounded,
              suffix: IconButton(
                onPressed: onToggle,
                icon: Icon(
                  obscurePass
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  color: C.textSec, size: 20,
                ),
              ),
            ),
            validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Register form
// ─────────────────────────────────────────────────────────────────────────────

class _RegisterForm extends StatelessWidget {
  final GlobalKey<FormState>  formKey;
  final TextEditingController userCtrl;
  final TextEditingController emailCtrl;
  final TextEditingController passCtrl;
  final TextEditingController pass2Ctrl;
  final bool                  obscurePass;
  final bool                  obscurePass2;
  final VoidCallback          onTogglePass;
  final VoidCallback          onTogglePass2;

  const _RegisterForm({
    super.key,
    required this.formKey,
    required this.userCtrl,
    required this.emailCtrl,
    required this.passCtrl,
    required this.pass2Ctrl,
    required this.obscurePass,
    required this.obscurePass2,
    required this.onTogglePass,
    required this.onTogglePass2,
  });

  @override
  Widget build(BuildContext context) {
    return Form(
      key: formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('USERNAME', style: AppText.label),
          const SizedBox(height: 8),
          TextFormField(
            controller:      userCtrl,
            style:           AppText.body,
            textInputAction: TextInputAction.next,
            autocorrect:     false,
            decoration:      _inputDeco(hint: 'choose_a_username', icon: Icons.person_outline_rounded),
            validator: (v) {
              if (v == null || v.trim().isEmpty) return 'Required';
              if (v.trim().length < 3) return 'At least 3 characters';
              return null;
            },
          ),
          const SizedBox(height: 16),
          Text('EMAIL (OPTIONAL)', style: AppText.label),
          const SizedBox(height: 8),
          TextFormField(
            controller:      emailCtrl,
            style:           AppText.body,
            keyboardType:    TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autocorrect:     false,
            decoration:      _inputDeco(hint: 'you@example.com', icon: Icons.mail_outline_rounded),
          ),
          const SizedBox(height: 16),
          Text('PASSWORD', style: AppText.label),
          const SizedBox(height: 8),
          TextFormField(
            controller:      passCtrl,
            style:           AppText.body,
            obscureText:     obscurePass,
            textInputAction: TextInputAction.next,
            decoration:      _inputDeco(
              hint: '••••••••',
              icon: Icons.lock_outline_rounded,
              suffix: IconButton(
                onPressed: onTogglePass,
                icon: Icon(
                  obscurePass
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  color: C.textSec, size: 20,
                ),
              ),
            ),
            validator: (v) {
              if (v == null || v.isEmpty) return 'Required';
              if (v.length < 8) return 'At least 8 characters';
              return null;
            },
          ),
          const SizedBox(height: 16),
          Text('CONFIRM PASSWORD', style: AppText.label),
          const SizedBox(height: 8),
          TextFormField(
            controller:      pass2Ctrl,
            style:           AppText.body,
            obscureText:     obscurePass2,
            textInputAction: TextInputAction.done,
            decoration:      _inputDeco(
              hint: '••••••••',
              icon: Icons.lock_outline_rounded,
              suffix: IconButton(
                onPressed: onTogglePass2,
                icon: Icon(
                  obscurePass2
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  color: C.textSec, size: 20,
                ),
              ),
            ),
            validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Toggle login ↔ register
// ─────────────────────────────────────────────────────────────────────────────

class _ToggleMode extends StatelessWidget {
  final bool         isRegister;
  final VoidCallback onTap;
  const _ToggleMode({required this.isRegister, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          isRegister ? 'Already have an account? ' : "Don't have an account? ",
          style: AppText.body.copyWith(color: C.textSec),
        ),
        GestureDetector(
          onTap: onTap,
          child: Text(
            isRegister ? 'Sign In' : 'Create one',
            style: AppText.body.copyWith(
              color: C.accent,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared input decoration factory
// ─────────────────────────────────────────────────────────────────────────────

InputDecoration _inputDeco({
  required String   hint,
  required IconData icon,
  Widget?           suffix,
}) {
  return InputDecoration(
    hintText:    hint,
    hintStyle:   AppText.body.copyWith(color: C.textTri),
    prefixIcon:  Icon(icon, color: C.textSec, size: 20),
    suffixIcon:  suffix,
    filled:      true,
    fillColor:   C.card,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide:   const BorderSide(color: C.border),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide:   const BorderSide(color: C.border),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide:   const BorderSide(color: C.accent, width: 1.5),
    ),
    errorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide:   const BorderSide(color: C.red),
    ),
    focusedErrorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide:   const BorderSide(color: C.red, width: 1.5),
    ),
    errorStyle: AppText.bodySm.copyWith(color: C.red),
  );
}
