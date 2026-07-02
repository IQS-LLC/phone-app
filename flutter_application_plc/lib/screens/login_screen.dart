import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../auth/auth_state.dart';
import '../config.dart';
import '../theme.dart';
import '../widgets/common_widgets.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Login Screen — first impression; must feel premium
// ─────────────────────────────────────────────────────────────────────────────

class LoginScreen extends StatefulWidget {
  final AuthState authState;
  const LoginScreen({super.key, required this.authState});

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
    final ok = await _auth.login(
      username:  _userCtrl.text.trim(),
      password:  _passCtrl.text,
      serverUrl: await AppConfig.resolve(),
    );
    if (!ok && mounted) {
      AppToast.show(context, _auth.error ?? 'Login failed', error: true);
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
                    'Your account was created by your building administrator.',
                    style: AppText.caption,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
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
