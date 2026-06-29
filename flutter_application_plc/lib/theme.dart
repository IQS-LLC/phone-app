import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Color System
// ─────────────────────────────────────────────────────────────────────────────

class C {
  // Backgrounds — deep navy/charcoal dark
  static const bg       = Color(0xFF070710);
  static const surface  = Color(0xFF0D0D1C);
  static const card     = Color(0xFF121224);
  static const card2    = Color(0xFF17172C);
  static const elevated = Color(0xFF1C1C34);

  // Borders
  static const border   = Color(0xFF1E1E38);
  static const border2  = Color(0xFF282844);

  // ── Semantic palette ──────────────────────────────────────────────────────
  static const accent    = Color(0xFFF5C542);   // warm gold — primary CTA
  static const accentLo  = Color(0xFF3B2E0A);   // accent dark bg
  static const green     = Color(0xFF34D399);   // success / on
  static const greenLo   = Color(0xFF052E1A);
  static const red       = Color(0xFFFF4F4F);   // error / off
  static const redLo     = Color(0xFF2E0505);
  static const blue      = Color(0xFF60A5FA);   // info / mid
  static const blueLo    = Color(0xFF0A1E3B);
  static const orange    = Color(0xFFFB923C);   // warm / dim
  static const orangeLo  = Color(0xFF2D1200);
  static const purple    = Color(0xFFA78BFA);   // cinema / night
  static const purpleLo  = Color(0xFF1A0F35);
  static const teal      = Color(0xFF2DD4BF);

  // Text hierarchy
  static const textPri  = Color(0xFFF2F2FC);
  static const textSec  = Color(0xFF6868A0);
  static const textTri  = Color(0xFF3A3A62);
  static const textDim  = Color(0xFF1E1E3A);
}

// ─────────────────────────────────────────────────────────────────────────────
// Text Styles
// ─────────────────────────────────────────────────────────────────────────────

class AppText {
  static TextStyle get h1 => GoogleFonts.inter(
    fontSize: 24, fontWeight: FontWeight.w700,
    color: C.textPri, letterSpacing: -0.8, height: 1.2,
  );
  static TextStyle get h2 => GoogleFonts.inter(
    fontSize: 18, fontWeight: FontWeight.w700,
    color: C.textPri, letterSpacing: -0.5, height: 1.3,
  );
  static TextStyle get h3 => GoogleFonts.inter(
    fontSize: 15, fontWeight: FontWeight.w600,
    color: C.textPri, letterSpacing: -0.3,
  );
  static TextStyle get body => GoogleFonts.inter(
    fontSize: 13, fontWeight: FontWeight.w400,
    color: C.textPri, height: 1.5,
  );
  static TextStyle get bodyMed => GoogleFonts.inter(
    fontSize: 13, fontWeight: FontWeight.w500, color: C.textPri,
  );
  static TextStyle get bodySm => GoogleFonts.inter(
    fontSize: 12, fontWeight: FontWeight.w400, color: C.textSec,
  );
  static TextStyle get label => GoogleFonts.inter(
    fontSize: 10, fontWeight: FontWeight.w600,
    color: C.textSec, letterSpacing: 1.6,
  );
  static TextStyle get labelSm => GoogleFonts.inter(
    fontSize: 9, fontWeight: FontWeight.w600,
    color: C.textTri, letterSpacing: 1.4,
  );
  static TextStyle get mono => GoogleFonts.jetBrainsMono(
    fontSize: 11, fontWeight: FontWeight.w400, color: C.textSec,
  );
  static TextStyle get num => GoogleFonts.inter(
    fontSize: 13, fontWeight: FontWeight.w700,
    color: C.accent, fontFeatures: [const FontFeature.tabularFigures()],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Scene Presets
// ─────────────────────────────────────────────────────────────────────────────

class LightScene {
  final String   name;
  final IconData icon;
  final Color    color;
  final int      brightness; // 0–100 applied to all DALI channels

  const LightScene({
    required this.name,
    required this.icon,
    required this.color,
    required this.brightness,
  });

  static const presets = [
    LightScene(
      name: 'Morning',  icon: Icons.wb_sunny_outlined,
      color: Color(0xFFFBBF24), brightness: 70,
    ),
    LightScene(
      name: 'Work',     icon: Icons.lightbulb_outline_rounded,
      color: Color(0xFFE2E8F0), brightness: 100,
    ),
    LightScene(
      name: 'Evening',  icon: Icons.wb_twilight,
      color: Color(0xFFFB923C), brightness: 35,
    ),
    LightScene(
      name: 'Cinema',   icon: Icons.movie_filter_outlined,
      color: Color(0xFFA78BFA), brightness: 5,
    ),
    LightScene(
      name: 'Night',    icon: Icons.bedtime_outlined,
      color: Color(0xFF60A5FA), brightness: 0,
    ),
  ];
}

// ─────────────────────────────────────────────────────────────────────────────
// ThemeData
// ─────────────────────────────────────────────────────────────────────────────

ThemeData buildTheme() {
  final base = ThemeData(brightness: Brightness.dark);
  return base.copyWith(
    scaffoldBackgroundColor: C.bg,
    colorScheme: const ColorScheme.dark(
      primary:   C.accent,
      secondary: C.blue,
      surface:   C.surface,
      error:     C.red,
    ),
    textTheme: GoogleFonts.interTextTheme(base.textTheme).apply(
      bodyColor:    C.textPri,
      displayColor: C.textPri,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: C.surface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      iconTheme: const IconThemeData(color: C.textSec, size: 20),
      titleTextStyle: GoogleFonts.inter(
        fontSize: 15, fontWeight: FontWeight.w600, color: C.textPri,
      ),
    ),
    sliderTheme: SliderThemeData(
      trackHeight:        2.0,
      activeTrackColor:   C.accent,
      inactiveTrackColor: C.border2,
      thumbColor:         C.accent,
      overlayColor:       C.accent.withAlpha(18),
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? C.bg : C.textTri,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? C.green : C.border2,
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: C.border, thickness: 1, space: 1,
    ),
    splashFactory:  NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS:     CupertinoPageTransitionsBuilder(),
        TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
      },
    ),
  );
}
