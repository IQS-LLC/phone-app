import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// AppToast — polished feedback, slides up from bottom
// ─────────────────────────────────────────────────────────────────────────────

enum ToastKind { success, warning, error, info }

class AppToast {
  static void show(BuildContext context, String message,
      {ToastKind kind = ToastKind.success, bool error = false}) {
    final k = error ? ToastKind.error : kind;
    final color = switch (k) {
      ToastKind.success => C.green,
      ToastKind.warning => C.orange,
      ToastKind.error   => C.red,
      ToastKind.info    => C.blue,
    };
    final icon = switch (k) {
      ToastKind.success => Icons.check_circle_rounded,
      ToastKind.warning => Icons.warning_rounded,
      ToastKind.error   => Icons.error_rounded,
      ToastKind.info    => Icons.info_rounded,
    };
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Row(children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(message, style: AppText.bodyMed)),
        ]),
        backgroundColor: C.elevated,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(Sp.x4, 0, Sp.x4, Sp.x4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: color.withAlpha(80), width: 0.5),
        ),
        duration: Duration(seconds: k == ToastKind.error ? 4 : 2),
        elevation: 0,
      ));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TapScale — spring-feedback press animation with optional glow
// ─────────────────────────────────────────────────────────────────────────────

class TapScale extends StatefulWidget {
  final Widget        child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double        scale;
  final bool          haptic;

  const TapScale({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale  = 0.92,
    this.haptic = true,
  });

  @override
  State<TapScale> createState() => _TapScaleState();
}

class _TapScaleState extends State<TapScale>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double>   _scale;

  @override
  void initState() {
    super.initState();
    _ctrl  = AnimationController(vsync: this, duration: const Duration(milliseconds: 120));
    _scale = Tween<double>(begin: 1, end: widget.scale)
        .animate(CurvedAnimation(parent: _ctrl, curve: Cur.snap));
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  void _down(TapDownDetails _) => _ctrl.forward();
  void _up(TapUpDetails _)     => _ctrl.reverse();
  void _cancel()               => _ctrl.reverse();

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTapDown:   _down,
    onTapUp:     _up,
    onTapCancel: _cancel,
    onTap: widget.onTap == null ? null : () {
      if (widget.haptic) HapticFeedback.lightImpact();
      widget.onTap!();
    },
    onLongPress: widget.onLongPress == null ? null : () {
      if (widget.haptic) HapticFeedback.mediumImpact();
      widget.onLongPress!();
    },
    child: AnimatedBuilder(
      animation: _scale,
      builder: (_, child) => Transform.scale(scale: _scale.value, child: child),
      child: widget.child,
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// AppCard — elevated, shadowed card — the fundamental building block
// ─────────────────────────────────────────────────────────────────────────────

class AppCard extends StatelessWidget {
  final Widget                  child;
  final EdgeInsetsGeometry?     padding;
  final Color?                  color;
  final Color?                  borderColor;
  final double                  radius;
  final List<BoxShadow>?        shadows;

  const AppCard({
    super.key,
    required this.child,
    this.padding,
    this.color,
    this.borderColor,
    this.radius  = 20,
    this.shadows,
  });

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: padding ?? EdgeInsets.zero,
    decoration: BoxDecoration(
      color:        color ?? C.card,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: borderColor ?? C.border, width: 0.5),
      boxShadow: shadows ?? S.card,
    ),
    child: ClipRRect(borderRadius: BorderRadius.circular(radius), child: child),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// GlassCard — frosted glass surface with gradient and optional accent border
// ─────────────────────────────────────────────────────────────────────────────

class GlassCard extends StatelessWidget {
  final Widget                  child;
  final EdgeInsetsGeometry      padding;
  final Color                   accentColor;
  final double                  radius;

  const GlassCard({
    super.key,
    required this.child,
    this.padding     = const EdgeInsets.all(Sp.x5),
    this.accentColor = C.accent,
    this.radius      = 20,
  });

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end:   Alignment.bottomRight,
        colors: [C.card2, C.card.withAlpha(220)],
      ),
      border: Border.all(color: accentColor.withAlpha(40), width: 0.5),
      boxShadow: S.elevated,
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Padding(padding: padding, child: child),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// BottomSheetHandle — always consistent drag indicator
// ─────────────────────────────────────────────────────────────────────────────

class BottomSheetHandle extends StatelessWidget {
  const BottomSheetHandle({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      width: 44, height: 5,
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: C.border2,
        borderRadius: BorderRadius.circular(3),
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// StatusPill — live / offline indicator, premium animation
// ─────────────────────────────────────────────────────────────────────────────

class StatusPill extends StatefulWidget {
  final bool connected;
  const StatusPill({super.key, required this.connected});

  @override
  State<StatusPill> createState() => _StatusPillState();
}

class _StatusPillState extends State<StatusPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double>   _pulse;

  @override
  void initState() {
    super.initState();
    _ctrl  = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat(reverse: true);
    _pulse = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final color = widget.connected ? C.green : C.red;
    return AnimatedContainer(
      duration: Dur.normal,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withAlpha(16),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withAlpha(50), width: 0.5),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        AnimatedBuilder(
          animation: _pulse,
          builder: (_, _) => Container(
            width: 7, height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.connected
                  ? color.withAlpha(130 + (_pulse.value * 125).toInt())
                  : color,
              boxShadow: widget.connected
                  ? [BoxShadow(color: color.withAlpha(120), blurRadius: 6)]
                  : null,
            ),
          ),
        ),
        const SizedBox(width: 7),
        AnimatedSwitcher(
          duration: Dur.fast,
          child: Text(
            widget.connected ? 'Live' : 'Offline',
            key: ValueKey(widget.connected),
            style: GoogleFonts.inter(
              fontSize: 12, fontWeight: FontWeight.w700, color: color,
            ),
          ),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// OfflineBanner — prominent, actionable
// ─────────────────────────────────────────────────────────────────────────────

class OfflineBanner extends StatelessWidget {
  final String serverUrl;
  const OfflineBanner({super.key, required this.serverUrl});

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.fromLTRB(Sp.x4, Sp.x3, Sp.x4, 0),
    padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x3),
    decoration: BoxDecoration(
      gradient: LinearGradient(colors: [C.red.withAlpha(18), C.red.withAlpha(8)]),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: C.red.withAlpha(45), width: 0.5),
    ),
    child: Row(children: [
      Container(
        width: 34, height: 34,
        decoration: BoxDecoration(
          color: C.red.withAlpha(24), borderRadius: BorderRadius.circular(10),
        ),
        child: const Icon(Icons.wifi_off_rounded, color: C.red, size: 17),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Unable to connect', style: AppText.bodyMed.copyWith(color: C.red, fontSize: 13)),
          const SizedBox(height: 1),
          Text('Retrying $serverUrl', style: AppText.small, overflow: TextOverflow.ellipsis),
        ]),
      ),
    ]),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// ShimmerBox — skeleton placeholder with smooth shimmer
// ─────────────────────────────────────────────────────────────────────────────

class ShimmerBox extends StatefulWidget {
  final double width;
  final double height;
  final double radius;

  const ShimmerBox({super.key, required this.width, required this.height, this.radius = 12});

  @override
  State<ShimmerBox> createState() => _ShimmerBoxState();
}

class _ShimmerBoxState extends State<ShimmerBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double>   _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _anim,
    builder: (_, _) => Container(
      width: widget.width, height: widget.height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.radius),
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end:   Alignment.centerRight,
          colors: [C.card2, C.elevated, C.card2],
          stops: [
            (_anim.value - 0.35).clamp(0.0, 1.0),
            _anim.value.clamp(0.0, 1.0),
            (_anim.value + 0.35).clamp(0.0, 1.0),
          ],
        ),
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// EmptyState — friendly, clear, centered
// ─────────────────────────────────────────────────────────────────────────────

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String   title;
  final String?  subtitle;
  final Widget?  action;

  const EmptyState({super.key, required this.icon, required this.title, this.subtitle, this.action});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(Sp.x10),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 76, height: 76,
          decoration: BoxDecoration(
            color: C.card2,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: C.border, width: 0.5),
            boxShadow: S.card,
          ),
          child: Icon(icon, color: C.textTri, size: 32),
        ),
        const SizedBox(height: Sp.x5),
        Text(title, style: AppText.h2.copyWith(color: C.textSec, fontSize: 17), textAlign: TextAlign.center),
        if (subtitle != null) ...[
          const SizedBox(height: Sp.x2),
          Text(subtitle!, style: AppText.body.copyWith(color: C.textTri), textAlign: TextAlign.center),
        ],
        if (action != null) ...[const SizedBox(height: Sp.x6), action!],
      ]),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// PrimaryButton — 56px minimum, gradient for brand gold, real glow
// ─────────────────────────────────────────────────────────────────────────────

class PrimaryButton extends StatelessWidget {
  final String       label;
  final VoidCallback onTap;
  final IconData?    icon;
  final Color?       color;
  final bool         loading;
  final double       height;

  const PrimaryButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.color,
    this.loading = false,
    this.height  = 56,
  });

  @override
  Widget build(BuildContext context) {
    final isGold = color == null;
    final c = color ?? C.accent;
    return TapScale(
      onTap: loading ? null : onTap,
      scale: 0.96,
      child: Container(
        width: double.infinity,
        height: height,
        decoration: BoxDecoration(
          gradient: isGold ? G.accent : LinearGradient(colors: [c, c.withAlpha(200)]),
          borderRadius: BorderRadius.circular(16),
          boxShadow: loading ? null : (isGold ? S.accentGlow : S.colorGlow(c)),
        ),
        child: loading
            ? Center(child: SizedBox(
                width: 20, height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: isGold ? Colors.black.withAlpha(160) : Colors.white,
                )))
            : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                if (icon != null) ...[Icon(icon, color: isGold ? Colors.black : Colors.white, size: 19), const SizedBox(width: 9)],
                Text(label, style: GoogleFonts.inter(
                  fontSize: 15, fontWeight: FontWeight.w700,
                  color: isGold ? Colors.black : Colors.white,
                  letterSpacing: -0.2,
                )),
              ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// IconBtn — 44x44 touch target, clearly interactive
// ─────────────────────────────────────────────────────────────────────────────

class IconBtn extends StatelessWidget {
  final IconData     icon;
  final VoidCallback onTap;
  final Color?       iconColor;
  final bool         active;
  final double       size;

  const IconBtn({super.key, required this.icon, required this.onTap, this.iconColor, this.active = false, this.size = 44});

  @override
  Widget build(BuildContext context) => TapScale(
    onTap: onTap,
    child: Container(
      width: size, height: size,
      decoration: BoxDecoration(
        color: active ? C.accent.withAlpha(22) : C.surface,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: active ? C.accent.withAlpha(70) : C.border, width: 0.5),
      ),
      child: Icon(icon, color: iconColor ?? (active ? C.accent : C.textSec), size: 19),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// SceneChip — large enough to be a real target, color-coded per scene
// ─────────────────────────────────────────────────────────────────────────────

class SceneChip extends StatelessWidget {
  final LightScene   scene;
  final bool         selected;
  final VoidCallback onTap;

  const SceneChip({super.key, required this.scene, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = scene.color;
    return TapScale(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Dur.normal,
        curve: Cur.snap,
        padding: const EdgeInsets.symmetric(horizontal: Sp.x5, vertical: Sp.x3),
        decoration: BoxDecoration(
          gradient: selected ? scene.gradient : null,
          color:  selected ? null : C.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? c.withAlpha(100) : C.border, width: selected ? 1.0 : 0.5,
          ),
          boxShadow: selected ? S.colorGlow(c, alpha: 60) : S.card,
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(scene.icon, color: selected ? c : C.textTri, size: 18),
          const SizedBox(width: 9),
          Text(scene.name, style: GoogleFonts.inter(
            fontSize: 13, fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? c : C.textSec,
          )),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SectionHeader — sentence-case section label (not uppercase — premium apps
// use visual hierarchy, not "SHOUTING" text labels)
// ─────────────────────────────────────────────────────────────────────────────

class SectionHeader extends StatelessWidget {
  final String  text;
  final Widget? trailing;

  const SectionHeader(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 2, bottom: 2),
    child: Row(children: [
      Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 11, fontWeight: FontWeight.w700,
          color: C.textTri, letterSpacing: 1.2,
        ),
      ),
      if (trailing != null) ...[const Spacer(), trailing!],
    ]),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// AppDivider — ultra-fine separator
// ─────────────────────────────────────────────────────────────────────────────

class AppDivider extends StatelessWidget {
  final EdgeInsetsGeometry? indent;
  const AppDivider({super.key, this.indent});

  @override
  Widget build(BuildContext context) => Container(
    height: 0.5, color: C.border,
    margin: indent ?? EdgeInsets.zero,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// DeviceIndicator — the glowing on/off dot used everywhere
// ─────────────────────────────────────────────────────────────────────────────

class DeviceIndicator extends StatelessWidget {
  final bool   on;
  final Color  onColor;
  final double size;

  const DeviceIndicator({super.key, required this.on, this.onColor = C.green, this.size = 9});

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: Dur.normal,
    width: size, height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: on ? onColor : C.textTri,
      boxShadow: on ? [BoxShadow(color: onColor.withAlpha(120), blurRadius: 6)] : null,
    ),
  );
}
