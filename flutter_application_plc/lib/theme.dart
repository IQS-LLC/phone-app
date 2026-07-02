import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Color System — precisely tuned for luxury smart-home feel
// ─────────────────────────────────────────────────────────────────────────────

class C {
  // Surfaces — true deep navy with visible depth separation between layers
  static const bg       = Color(0xFF05050F);   // deepest — never cluttered
  static const surface  = Color(0xFF09091A);   // navigation surfaces
  static const card     = Color(0xFF0F0F21);   // primary cards
  static const card2    = Color(0xFF141430);   // secondary / elevated cards
  static const elevated = Color(0xFF191942);   // modals / sheets / popovers

  // Borders — structural, not decorative
  static const border   = Color(0xFF18183A);   // subtle structural separation
  static const border2  = Color(0xFF222248);   // interactive element focus ring

  // ── Semantic palette ──────────────────────────────────────────────────────
  static const accent    = Color(0xFFF5C542);  // warm gold — primary brand color
  static const accentDim = Color(0xFFD4A535);  // pressed / darker state
  static const accentLo  = Color(0xFF2E2208);  // ambient gold background

  static const green     = Color(0xFF2DD987);  // success, active, on
  static const greenLo   = Color(0xFF061A0F);
  static const red       = Color(0xFFFF4B4B);  // error, alert, danger
  static const redLo     = Color(0xFF1A0505);
  static const blue      = Color(0xFF5BA8FF);  // info, secondary
  static const blueLo    = Color(0xFF071528);
  static const orange    = Color(0xFFFD9A3E);  // warm / dim lighting
  static const orangeLo  = Color(0xFF1A0B00);
  static const purple    = Color(0xFF9F7BFA);  // cinema / night
  static const purpleLo  = Color(0xFF100B28);
  static const teal      = Color(0xFF26D4BE);  // connected / sync

  // Text — clean neutral hierarchy, no color cast
  static const textPri  = Color(0xFFF5F5FF);  // near-white primary text
  static const textSec  = Color(0xFF7272A8);  // muted secondary
  static const textTri  = Color(0xFF3E3E68);  // very muted / disabled
  static const textDim  = Color(0xFF1E1E40);  // barely visible / placeholder
}

// ─────────────────────────────────────────────────────────────────────────────
// Spacing scale — mathematical rhythm: 4/8/12/16/20/24/32/40/48/64
// Never use arbitrary values outside this scale.
// ─────────────────────────────────────────────────────────────────────────────

class Sp {
  static const x1  = 4.0;
  static const x2  = 8.0;
  static const x3  = 12.0;
  static const x4  = 16.0;
  static const x5  = 20.0;
  static const x6  = 24.0;
  static const x8  = 32.0;
  static const x10 = 40.0;
  static const x12 = 48.0;
  static const x16 = 64.0;
}

// ─────────────────────────────────────────────────────────────────────────────
// Elevation / Shadow System — actual depth, not decorative borders
// ─────────────────────────────────────────────────────────────────────────────

class S {
  // Micro — for small interactive elements (chips, badges)
  static List<BoxShadow> get micro => [
    BoxShadow(color: Colors.black.withAlpha(40), blurRadius: 4, offset: const Offset(0, 1)),
  ];

  // Card — standard card elevation
  static List<BoxShadow> get card => [
    BoxShadow(color: Colors.black.withAlpha(70), blurRadius: 16, offset: const Offset(0, 4)),
    BoxShadow(color: Colors.black.withAlpha(30), blurRadius: 4,  offset: const Offset(0, 1)),
  ];

  // Elevated — modals, bottom sheets, important surfaces
  static List<BoxShadow> get elevated => [
    BoxShadow(color: Colors.black.withAlpha(120), blurRadius: 32, offset: const Offset(0, 12)),
    BoxShadow(color: Colors.black.withAlpha(50),  blurRadius: 8,  offset: const Offset(0, 3)),
  ];

  // Glow — active states, brand CTAs
  static List<BoxShadow> get accentGlow => [
    BoxShadow(color: C.accent.withAlpha(100), blurRadius: 24, offset: const Offset(0, 4)),
    BoxShadow(color: C.accent.withAlpha(50),  blurRadius: 8,  offset: const Offset(0, 2)),
  ];

  // Dynamic color glow — pass the active color
  static List<BoxShadow> colorGlow(Color c, {int alpha = 70, double blur = 16}) => [
    BoxShadow(color: c.withAlpha(alpha),        blurRadius: blur,       spreadRadius: 0),
    BoxShadow(color: c.withAlpha(alpha ~/ 3),   blurRadius: blur / 2),
  ];

  // Room ambient — subtle warm glow when room lights are on
  static List<BoxShadow> ambientGlow(Color c) => [
    BoxShadow(color: c.withAlpha(30), blurRadius: 24, spreadRadius: 2),
    BoxShadow(color: Colors.black.withAlpha(60), blurRadius: 12, offset: const Offset(0, 4)),
  ];
}

// ─────────────────────────────────────────────────────────────────────────────
// Motion — consistent timing and curves
// ─────────────────────────────────────────────────────────────────────────────

class Dur {
  static const micro  = Duration(milliseconds: 60);
  static const fast   = Duration(milliseconds: 140);
  static const normal = Duration(milliseconds: 260);
  static const slow   = Duration(milliseconds: 420);
  static const enter  = Duration(milliseconds: 340);   // elements entering view
  static const exit   = Duration(milliseconds: 200);   // elements leaving view
}

class Cur {
  static const snap     = Curves.easeOutCubic;     // selections, taps
  static const smooth   = Curves.easeInOutCubic;   // transitions
  static const spring   = Curves.elasticOut;        // delightful moments
  static const enter    = Curves.easeOutQuart;      // things appearing
  static const exit     = Curves.easeInQuart;       // things disappearing
  static const decel    = Curves.decelerate;        // settling
  static const overshoot = Curves.easeOutBack;      // satisfying snaps
}

// ─────────────────────────────────────────────────────────────────────────────
// Gradients — curated, purposeful
// ─────────────────────────────────────────────────────────────────────────────

class G {
  // Primary brand CTA — warm gold
  static const accent = LinearGradient(
    begin: Alignment.topLeft,
    end:   Alignment.bottomRight,
    colors: [Color(0xFFF8CB4A), Color(0xFFE8A820)],
  );

  // Ambient card gradient — subtle depth on glass surfaces
  static LinearGradient card({double opacity = 1.0}) => LinearGradient(
    begin: Alignment.topLeft,
    end:   Alignment.bottomRight,
    colors: [
      C.card2.withAlpha((opacity * 255).round()),
      C.card.withAlpha((opacity * 0.8 * 255).round()),
    ],
  );

  // Scene-specific gradients — each preset has its own ambient color
  static const morning = LinearGradient(
    begin: Alignment.topLeft, end: Alignment.bottomRight,
    colors: [Color(0xFF2C1E00), Color(0xFF1A1200)],
  );
  static const work = LinearGradient(
    begin: Alignment.topLeft, end: Alignment.bottomRight,
    colors: [Color(0xFF151530), Color(0xFF0F0F28)],
  );
  static const evening = LinearGradient(
    begin: Alignment.topLeft, end: Alignment.bottomRight,
    colors: [Color(0xFF1C0C00), Color(0xFF110800)],
  );
  static const cinema = LinearGradient(
    begin: Alignment.topLeft, end: Alignment.bottomRight,
    colors: [Color(0xFF0E0520), Color(0xFF08030F)],
  );
  static const night = LinearGradient(
    begin: Alignment.topLeft, end: Alignment.bottomRight,
    colors: [Color(0xFF000818), Color(0xFF000510)],
  );

  // Room ambient glow based on theme color
  static LinearGradient room(Color c) => LinearGradient(
    begin: Alignment.topLeft, end: Alignment.bottomRight,
    colors: [c.withAlpha(28), c.withAlpha(8), Colors.transparent],
    stops: const [0.0, 0.5, 1.0],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Typography — 6 distinct sizes, no overlapping roles
// Weight + size together create hierarchy. Never one without the other.
// ─────────────────────────────────────────────────────────────────────────────

class AppText {
  // XL — hero greeting, splash, major headings (36px)
  static TextStyle get hero => GoogleFonts.inter(
    fontSize: 36, fontWeight: FontWeight.w800,
    color: C.textPri, letterSpacing: -1.5, height: 1.1,
  );

  // L — page titles, section names (24px)
  static TextStyle get h1 => GoogleFonts.inter(
    fontSize: 24, fontWeight: FontWeight.w700,
    color: C.textPri, letterSpacing: -0.8, height: 1.2,
  );

  // M+ — card titles, list section headers (18px)
  static TextStyle get h2 => GoogleFonts.inter(
    fontSize: 18, fontWeight: FontWeight.w700,
    color: C.textPri, letterSpacing: -0.5, height: 1.3,
  );

  // M — room names, device names, prominent labels (15px)
  static TextStyle get title => GoogleFonts.inter(
    fontSize: 15, fontWeight: FontWeight.w600,
    color: C.textPri, letterSpacing: -0.3,
  );

  // S — body text, descriptions (13px)
  static TextStyle get body => GoogleFonts.inter(
    fontSize: 13, fontWeight: FontWeight.w400,
    color: C.textPri, height: 1.5,
  );

  // S medium — emphasized body, button labels
  static TextStyle get bodyMed => GoogleFonts.inter(
    fontSize: 13, fontWeight: FontWeight.w600, color: C.textPri,
  );

  // XS — helper text, timestamps, captions (11px)
  static TextStyle get small => GoogleFonts.inter(
    fontSize: 11, fontWeight: FontWeight.w400, color: C.textSec, height: 1.4,
  );

  // Chip / badge — all-caps status text (9px)
  static TextStyle get badge => GoogleFonts.inter(
    fontSize: 9, fontWeight: FontWeight.w700,
    color: C.textSec, letterSpacing: 1.0,
  );

  // Monospace — technical values only (IP, AMS, port)
  static TextStyle get mono => GoogleFonts.jetBrainsMono(
    fontSize: 12, fontWeight: FontWeight.w400, color: C.textSec,
  );

  // Number — large stat display
  static TextStyle get stat => GoogleFonts.inter(
    fontSize: 28, fontWeight: FontWeight.w800,
    color: C.textPri, letterSpacing: -1.0,
    fontFeatures: [const FontFeature.tabularFigures()],
  );

  // ── Backward-compatible aliases (old names → new names) ─────────────────
  static TextStyle get display   => hero;
  static TextStyle get h3        => title;
  static TextStyle get cardTitle => title;
  static TextStyle get bodySm    => small;
  static TextStyle get caption   => small;
  static TextStyle get label     => badge;
  static TextStyle get labelSm   => badge.copyWith(fontSize: 8, letterSpacing: 0.8);
  static TextStyle get num       => stat;
}

// ─────────────────────────────────────────────────────────────────────────────
// Scene Presets — each with its own color identity
// ─────────────────────────────────────────────────────────────────────────────

class LightScene {
  final String   name;
  final String   emoji;
  final IconData icon;
  final Color    color;
  final int      brightness;
  final LinearGradient gradient;

  const LightScene({
    required this.name,
    required this.emoji,
    required this.icon,
    required this.color,
    required this.brightness,
    required this.gradient,
  });

  static const presets = [
    LightScene(
      name: 'Morning', emoji: '☀️',
      icon: Icons.wb_sunny_rounded,
      color: Color(0xFFF5C542), brightness: 70,
      gradient: G.morning,
    ),
    LightScene(
      name: 'Focus', emoji: '💡',
      icon: Icons.lightbulb_rounded,
      color: Color(0xFFE2E8F0), brightness: 100,
      gradient: G.work,
    ),
    LightScene(
      name: 'Evening', emoji: '🌅',
      icon: Icons.wb_twilight_rounded,
      color: Color(0xFFFD9A3E), brightness: 35,
      gradient: G.evening,
    ),
    LightScene(
      name: 'Cinema', emoji: '🎬',
      icon: Icons.movie_rounded,
      color: Color(0xFF9F7BFA), brightness: 5,
      gradient: G.cinema,
    ),
    LightScene(
      name: 'Sleep', emoji: '🌙',
      icon: Icons.bedtime_rounded,
      color: Color(0xFF5BA8FF), brightness: 0,
      gradient: G.night,
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
      iconTheme: const IconThemeData(color: C.textSec, size: 22),
      titleTextStyle: GoogleFonts.inter(
        fontSize: 17, fontWeight: FontWeight.w700,
        color: C.textPri, letterSpacing: -0.3,
      ),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: C.surface,
      selectedItemColor: C.accent,
      unselectedItemColor: C.textTri,
      elevation: 0,
      type: BottomNavigationBarType.fixed,
    ),
    sliderTheme: SliderThemeData(
      trackHeight:        6.0,
      activeTrackColor:   C.accent,
      inactiveTrackColor: C.border2,
      thumbColor:         C.accent,
      overlayColor:       C.accent.withAlpha(24),
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 22),
      trackShape: const RoundedRectSliderTrackShape(),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? C.bg : C.textTri,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? C.green : C.border2,
      ),
    ),
    dividerTheme: const DividerThemeData(color: C.border, thickness: 0.5, space: 1),
    splashFactory:  InkRipple.splashFactory,
    highlightColor: Colors.white.withAlpha(8),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS:     CupertinoPageTransitionsBuilder(),
        TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
      },
    ),
  );
}
