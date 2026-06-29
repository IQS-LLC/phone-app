import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// TapScale — press-to-shrink micro-interaction
// ─────────────────────────────────────────────────────────────────────────────

class TapScale extends StatefulWidget {
  final Widget       child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double       scale;
  final Duration     duration;
  final bool         haptic;

  const TapScale({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale    = 0.94,
    this.duration = const Duration(milliseconds: 90),
    this.haptic   = true,
  });

  @override
  State<TapScale> createState() => _TapScaleState();
}

class _TapScaleState extends State<TapScale>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double>   _scaleAnim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: widget.duration);
    _scaleAnim = Tween<double>(begin: 1.0, end: widget.scale)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails _) => _ctrl.forward();
  void _onTapUp(TapUpDetails _)     => _ctrl.reverse();
  void _onTapCancel()               => _ctrl.reverse();

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTapDown:   _onTapDown,
    onTapUp:     _onTapUp,
    onTapCancel: _onTapCancel,
    onTap: widget.onTap == null ? null : () {
      if (widget.haptic) HapticFeedback.lightImpact();
      widget.onTap!();
    },
    onLongPress: widget.onLongPress == null ? null : () {
      if (widget.haptic) HapticFeedback.mediumImpact();
      widget.onLongPress!();
    },
    child: AnimatedBuilder(
      animation: _scaleAnim,
      builder: (_, child) => Transform.scale(
        scale: _scaleAnim.value,
        child: child,
      ),
      child: widget.child,
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// AppCard — base card container
// ─────────────────────────────────────────────────────────────────────────────

class AppCard extends StatelessWidget {
  final Widget  child;
  final EdgeInsetsGeometry? padding;
  final Color?  color;
  final Color?  borderColor;
  final double  radius;

  const AppCard({
    super.key,
    required this.child,
    this.padding,
    this.color,
    this.borderColor,
    this.radius = 16,
  });

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: padding ?? const EdgeInsets.all(0),
    decoration: BoxDecoration(
      color:        color ?? C.card,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: borderColor ?? C.border),
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: child,
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// SectionHeader — UPPERCASE label above sections
// ─────────────────────────────────────────────────────────────────────────────

class SectionHeader extends StatelessWidget {
  final String text;
  final Widget? trailing;

  const SectionHeader(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Text(text.toUpperCase(), style: AppText.label),
      if (trailing != null) ...[const Spacer(), trailing!],
    ],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// StatusPill — animated connection indicator
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
  late final Animation<double>   _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final color = widget.connected ? C.green : C.red;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color:        color.withAlpha(18),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withAlpha(55)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        AnimatedBuilder(
          animation: _anim,
          builder: (_, child) => Container(
            width: 5.5, height: 5.5,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.connected
                  ? color.withAlpha((100 + (_anim.value * 155).toInt()))
                  : color,
            ),
          ),
        ),
        const SizedBox(width: 5),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: Text(
            widget.connected ? 'Live' : 'Offline',
            key: ValueKey(widget.connected),
            style: GoogleFonts.inter(
              fontSize: 10, fontWeight: FontWeight.w700, color: color,
            ),
          ),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// OfflineBanner
// ─────────────────────────────────────────────────────────────────────────────

class OfflineBanner extends StatelessWidget {
  final String serverUrl;
  const OfflineBanner({super.key, required this.serverUrl});

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
    decoration: BoxDecoration(
      color:        C.red.withAlpha(12),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: C.red.withAlpha(50)),
    ),
    child: Row(children: [
      Container(
        width: 28, height: 28,
        decoration: BoxDecoration(
          color: C.red.withAlpha(18), borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(Icons.wifi_off_rounded, color: C.red, size: 14),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Unable to connect',
                style: AppText.bodyMed.copyWith(color: C.red, fontSize: 12)),
            Text('Trying $serverUrl',
                style: AppText.bodySm.copyWith(fontSize: 10),
                overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    ]),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// LoadingShimmer — skeleton placeholder
// ─────────────────────────────────────────────────────────────────────────────

class ShimmerBox extends StatefulWidget {
  final double width;
  final double height;
  final double radius;

  const ShimmerBox({
    super.key,
    required this.width,
    required this.height,
    this.radius = 8,
  });

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
    _ctrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1200),
    )..repeat();
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _anim,
    builder: (_, unused) => Container(
      width: widget.width, height: widget.height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.radius),
        gradient: LinearGradient(
          colors: [
            C.card2,
            C.elevated,
            C.card2,
          ],
          stops: [
            (_anim.value - 0.3).clamp(0.0, 1.0),
            _anim.value.clamp(0.0, 1.0),
            (_anim.value + 0.3).clamp(0.0, 1.0),
          ],
        ),
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// EmptyState — friendly zero-data message
// ─────────────────────────────────────────────────────────────────────────────

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String   title;
  final String?  subtitle;
  final Widget?  action;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 64, height: 64,
          decoration: BoxDecoration(
            color: C.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: C.border),
          ),
          child: Icon(icon, color: C.textTri, size: 28),
        ),
        const SizedBox(height: 16),
        Text(title,
            style: AppText.h3.copyWith(color: C.textSec),
            textAlign: TextAlign.center),
        if (subtitle != null) ...[
          const SizedBox(height: 6),
          Text(subtitle!,
              style: AppText.bodySm,
              textAlign: TextAlign.center),
        ],
        if (action != null) ...[
          const SizedBox(height: 20),
          action!,
        ],
      ]),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// PrimaryButton — full-width CTA
// ─────────────────────────────────────────────────────────────────────────────

class PrimaryButton extends StatelessWidget {
  final String       label;
  final VoidCallback onTap;
  final IconData?    icon;
  final Color?       color;
  final bool         loading;

  const PrimaryButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.color,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? C.accent;
    return TapScale(
      onTap: loading ? null : onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color:        c.withAlpha(22),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.withAlpha(70)),
        ),
        child: loading
            ? Center(
                child: SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2, color: c,
                  ),
                ),
              )
            : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                if (icon != null) ...[
                  Icon(icon, color: c, size: 16),
                  const SizedBox(width: 7),
                ],
                Text(label,
                    style: GoogleFonts.inter(
                      fontSize: 13, fontWeight: FontWeight.w600, color: c,
                    )),
              ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// IconButton2 — compact header button
// ─────────────────────────────────────────────────────────────────────────────

class IconBtn extends StatelessWidget {
  final IconData     icon;
  final VoidCallback onTap;
  final Color?       iconColor;
  final bool         active;

  const IconBtn({
    super.key,
    required this.icon,
    required this.onTap,
    this.iconColor,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) => TapScale(
    onTap: onTap,
    child: Container(
      width: 36, height: 36,
      decoration: BoxDecoration(
        color:        active ? C.accent.withAlpha(20) : C.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: active ? C.accent.withAlpha(70) : C.border,
        ),
      ),
      child: Icon(
        icon,
        color: iconColor ?? (active ? C.accent : C.textSec),
        size: 17,
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// SceneChip — scene preset button
// ─────────────────────────────────────────────────────────────────────────────

class SceneChip extends StatelessWidget {
  final LightScene scene;
  final bool       selected;
  final VoidCallback onTap;

  const SceneChip({
    super.key,
    required this.scene,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = scene.color;
    return TapScale(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color:        selected ? c.withAlpha(28) : C.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? c.withAlpha(90) : C.border,
            width: selected ? 1.5 : 1.0,
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(scene.icon,
              color: selected ? c : C.textSec,
              size: 15),
          const SizedBox(width: 7),
          Text(
            scene.name,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? c : C.textSec,
            ),
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BrightnessChip — 25 / 50 / 75 / 100 quick-tap chips
// ─────────────────────────────────────────────────────────────────────────────

class BrightnessChip extends StatelessWidget {
  final String       label;
  final bool         active;
  final VoidCallback onTap;

  const BrightnessChip({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => TapScale(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color:        active ? C.accent.withAlpha(22) : C.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: active ? C.accent.withAlpha(80) : C.border,
          width: active ? 1.5 : 1.0,
        ),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: active ? FontWeight.w700 : FontWeight.w500,
          color:  active ? C.accent : C.textSec,
        ),
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Divider variant
// ─────────────────────────────────────────────────────────────────────────────

class AppDivider extends StatelessWidget {
  final EdgeInsetsGeometry? indent;
  const AppDivider({super.key, this.indent});

  @override
  Widget build(BuildContext context) => Divider(
    height: 1, thickness: 1, color: C.border,
    indent:    indent != null ? (indent as EdgeInsets).left   : 0,
    endIndent: indent != null ? (indent as EdgeInsets).right  : 0,
  );
}

