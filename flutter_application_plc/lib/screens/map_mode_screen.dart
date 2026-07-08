import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// Digital Twin — Map Mode
//
// Source of truth: electrical drawing e1 lights 2207.pdf
// Scale: 1 logical unit ≈ 59.65 mm  (total width 5965 mm → logW = 100)
//
//  x:  0    40   60   72   92  100
//      ┌────┬────┬────┬────┬───┐  y=0
//      │ LR │KTCH│BATH│ B1 │GB │
//      │    │    │    │    ╘══╡  y=22
//      │    │    ╞════╡    │   │  y=26
//      │    ╞════╡ PC │    │   │  y=28
//      │    │ MC │    │    │   │
//      ╞════╡    │    ╞════╪═══╡  y=40
//      │ DR │    │    │  BR2   │
//      │    │    │    │        │
//      │    ╞══╤═╩════╡       │  y=58
//      │    │EH│              │
//      └────┴──╧══════════════┘  y=68
//      ┌────┐  ← balcony
//      └────┘  y=80
//
// Groups: A=Main Corridor, B=Kitchen+Dining, C=Dining pendants, D=Living,
//         E=Bedroom 1, F=Guest Bathroom, G=Kitchen track, H=Bedroom 2,
//         I=Private Corridor, J=Bathroom, K=Entrance Hall, CRT1/2=curtains
// ═══════════════════════════════════════════════════════════════════════════════

// ── Floor plan definitions ────────────────────────────────────────────────────

class _FP {
  // Room rectangles — digitised from electrical drawing e1 lights 2207.pdf
  // 1 unit ≈ 59.65 mm; main body y 0–68; balcony extends y 68–80
  static const living    = Rect.fromLTWH( 0,  0, 40, 40);
  static const dining    = Rect.fromLTWH( 0, 40, 40, 28);
  static const kitchen   = Rect.fromLTWH(40,  0, 20, 28);
  static const bathroom  = Rect.fromLTWH(60,  0, 12, 26);
  static const corridor  = Rect.fromLTWH(40, 28, 20, 30);  // Main Corridor
  static const privCorr  = Rect.fromLTWH(60, 26, 12, 32);  // Private Corridor
  static const entry     = Rect.fromLTWH(24, 58, 48,  9);  // Entrance Hall
  static const bedroom1  = Rect.fromLTWH(72,  0, 20, 40);
  static const guestBath = Rect.fromLTWH(92,  0,  8, 22);
  static const bedroom2  = Rect.fromLTWH(72, 40, 28, 28);
  static const balcony   = Rect.fromLTWH( 0, 68, 40, 12);

  static const logW = 100.0;
  static const logH = 80.0;

  // entry listed before dining so taps in the x=24-40, y=58-68 overlap go to Entrance Hall
  static const rects = <String, Rect>{
    'Living Room':      living,
    'Entrance Hall':    entry,
    'Dining Room':      dining,
    'Kitchen':          kitchen,
    'Bathroom':         bathroom,
    'Main Corridor':    corridor,
    'Private Corridor': privCorr,
    'Bedroom 1':        bedroom1,
    'Guest Bathroom':   guestBath,
    'Bedroom 2':        bedroom2,
    'Balcony':          balcony,
  };

  // Light fixture positions — from electrical drawing (groups A–K)
  static const lights = <_FixtureDef>[
    // Living Room — D group
    _FixtureDef('Living Room', 'D1', 28, 12),
    _FixtureDef('Living Room', 'D2', 16, 12),
    _FixtureDef('Living Room', 'D3',  6, 28),
    _FixtureDef('Living Room', 'D4', 22, 28),
    // Dining Room — B4 (dining master) + C group pendants
    _FixtureDef('Dining Room', 'B4', 18, 48),
    _FixtureDef('Dining Room', 'C1', 14, 50),
    _FixtureDef('Dining Room', 'C2', 30, 55),
    _FixtureDef('Dining Room', 'C3',  6, 62),
    _FixtureDef('Dining Room', 'C4', 26, 62),
    // Kitchen — B1-B3 downlights + G1-G2 track (H:1600)
    _FixtureDef('Kitchen', 'B1', 44, 14),
    _FixtureDef('Kitchen', 'B2', 44,  6),
    _FixtureDef('Kitchen', 'B3', 52, 14),
    _FixtureDef('Kitchen', 'G1', 42,  3),
    _FixtureDef('Kitchen', 'G2', 55,  7),
    // Main Corridor — A group
    _FixtureDef('Main Corridor', 'A1', 50, 36),
    _FixtureDef('Main Corridor', 'A2', 50, 44),
    _FixtureDef('Main Corridor', 'A3', 50, 52),
    // Entrance Hall — K group
    _FixtureDef('Entrance Hall', 'K1', 34, 62),
    _FixtureDef('Entrance Hall', 'K2', 56, 62),
    // Bedroom 1 (Master) — E group; E4 = master "All Bedroom + Group A Off"
    _FixtureDef('Bedroom 1', 'E1', 77,  8),
    _FixtureDef('Bedroom 1', 'E2', 86,  8),
    _FixtureDef('Bedroom 1', 'E3', 80, 22),
    _FixtureDef('Bedroom 1', 'E4', 77, 32),
    // Guest Bathroom — F group (vanity height H:1275)
    _FixtureDef('Guest Bathroom', 'F1', 96,  6),
    _FixtureDef('Guest Bathroom', 'F2', 96, 14),
    // Bathroom — J group
    _FixtureDef('Bathroom', 'J1', 66,  8),
    _FixtureDef('Bathroom', 'J2', 66, 18),
    // Private Corridor — I group
    _FixtureDef('Private Corridor', 'I1', 66, 30),
    _FixtureDef('Private Corridor', 'I2', 66, 46),
    // Bedroom 2 — H group; H4 = master "All Bedroom + Group A Off"
    _FixtureDef('Bedroom 2', 'H1', 86, 50),
    _FixtureDef('Bedroom 2', 'H2', 92, 50),
    _FixtureDef('Bedroom 2', 'H3', 80, 60),
    _FixtureDef('Bedroom 2', 'H4', 76, 62),
  ];

  // CRT1 / CRT2 — motorized curtain relays, left wall of Living Room
  static const relayDefs = <_FixtureDef>[
    _FixtureDef('Living Room', 'CRT1', 1.5, 12),
    _FixtureDef('Living Room', 'CRT2', 1.5, 28),
  ];
}

class _FixtureDef {
  final String room, id;
  final double x, y;
  const _FixtureDef(this.room, this.id, this.x, this.y);
}

// ── Room scenes ───────────────────────────────────────────────────────────────

class _RoomScene {
  final String   id, label;
  final IconData icon;
  final Color    color;
  final int      brightness;
  const _RoomScene(this.id, this.label, this.icon, this.color, this.brightness);
}

const _roomScenes = <String, List<_RoomScene>>{
  'Living Room': [
    _RoomScene('relax',   'Relax',   Icons.weekend_rounded,          Color(0xFFFD9A3E), 40),
    _RoomScene('reading', 'Reading', Icons.menu_book_rounded,         Color(0xFFF5C542), 80),
    _RoomScene('movie',   'Movie',   Icons.movie_rounded,             Color(0xFF9F7BFA),  5),
    _RoomScene('guests',  'Guests',  Icons.people_rounded,            Color(0xFF5BA8FF), 70),
    _RoomScene('evening', 'Evening', Icons.wb_twilight_rounded,       Color(0xFFFD6A3E), 30),
    _RoomScene('off',     'Off',     Icons.dark_mode_rounded,         Color(0xFF3E3E68),  0),
  ],
  'Dining Room': [
    _RoomScene('dinner',  'Dinner',  Icons.restaurant_rounded,        Color(0xFFF5C542), 60),
    _RoomScene('relax',   'Relax',   Icons.weekend_rounded,           Color(0xFFFD9A3E), 35),
    _RoomScene('guests',  'Guests',  Icons.people_rounded,            Color(0xFF5BA8FF), 80),
    _RoomScene('off',     'Off',     Icons.dark_mode_rounded,         Color(0xFF3E3E68),  0),
  ],
  'Kitchen': [
    _RoomScene('cooking', 'Cooking', Icons.soup_kitchen_rounded,      Color(0xFFFD9A3E),100),
    _RoomScene('dinner',  'Dinner',  Icons.restaurant_rounded,        Color(0xFFF5C542), 50),
    _RoomScene('clean',   'Cleaning',Icons.cleaning_services_rounded, Color(0xFF5BA8FF),100),
    _RoomScene('night',   'Night',   Icons.nightlight_rounded,        Color(0xFF3E3E68), 15),
    _RoomScene('off',     'Off',     Icons.dark_mode_rounded,         Color(0xFF3E3E68),  0),
  ],
  'Bedroom 1': [
    _RoomScene('sleep',   'Sleep',   Icons.bedtime_rounded,           Color(0xFF5BA8FF),  0),
    _RoomScene('wake',    'Wake Up', Icons.wb_sunny_rounded,          Color(0xFFF5C542), 60),
    _RoomScene('reading', 'Reading', Icons.menu_book_rounded,         Color(0xFFCE93D8), 70),
    _RoomScene('relax',   'Relax',   Icons.spa_rounded,               Color(0xFF9F7BFA), 25),
    _RoomScene('off',     'Off',     Icons.dark_mode_rounded,         Color(0xFF3E3E68),  0),
  ],
  'Bedroom 2': [
    _RoomScene('sleep',   'Sleep',   Icons.bedtime_rounded,           Color(0xFF5BA8FF),  0),
    _RoomScene('morning', 'Morning', Icons.wb_sunny_rounded,          Color(0xFFF5C542), 80),
    _RoomScene('reading', 'Reading', Icons.menu_book_rounded,         Color(0xFFCE93D8), 60),
    _RoomScene('night',   'Night',   Icons.nightlight_rounded,        Color(0xFF9F7BFA), 10),
    _RoomScene('off',     'Off',     Icons.dark_mode_rounded,         Color(0xFF3E3E68),  0),
  ],
  'Bathroom': [
    _RoomScene('bright',  'Bright',  Icons.light_mode_rounded,        Color(0xFFF5C542),100),
    _RoomScene('relax',   'Relax',   Icons.spa_rounded,               Color(0xFF26D4BE), 40),
    _RoomScene('night',   'Night',   Icons.nightlight_rounded,        Color(0xFF5BA8FF), 10),
    _RoomScene('off',     'Off',     Icons.dark_mode_rounded,         Color(0xFF3E3E68),  0),
  ],
  'Guest Bathroom': [
    _RoomScene('bright',  'Bright',  Icons.light_mode_rounded,        Color(0xFFF5C542),100),
    _RoomScene('night',   'Night',   Icons.nightlight_rounded,        Color(0xFF5BA8FF), 10),
    _RoomScene('off',     'Off',     Icons.dark_mode_rounded,         Color(0xFF3E3E68),  0),
  ],
  'Main Corridor': [
    _RoomScene('bright',  'Bright',  Icons.light_mode_rounded,        Color(0xFFF5C542),100),
    _RoomScene('night',   'Night',   Icons.nightlight_rounded,        Color(0xFF9F7BFA), 20),
    _RoomScene('off',     'Off',     Icons.dark_mode_rounded,         Color(0xFF3E3E68),  0),
  ],
  'Private Corridor': [
    _RoomScene('bright',  'Bright',  Icons.light_mode_rounded,        Color(0xFFF5C542),100),
    _RoomScene('night',   'Night',   Icons.nightlight_rounded,        Color(0xFF9F7BFA), 20),
    _RoomScene('off',     'Off',     Icons.dark_mode_rounded,         Color(0xFF3E3E68),  0),
  ],
  'Entrance Hall': [
    _RoomScene('bright',  'Bright',  Icons.light_mode_rounded,        Color(0xFFF5C542),100),
    _RoomScene('welcome', 'Welcome', Icons.waving_hand_rounded,       Color(0xFFFD9A3E), 70),
    _RoomScene('night',   'Night',   Icons.nightlight_rounded,        Color(0xFF5BA8FF), 15),
    _RoomScene('off',     'Off',     Icons.dark_mode_rounded,         Color(0xFF3E3E68),  0),
  ],
  'Balcony': [
    _RoomScene('sunset',  'Sunset',  Icons.wb_twilight_rounded,       Color(0xFFFD6A3E), 40),
    _RoomScene('evening', 'Evening', Icons.nights_stay_rounded,       Color(0xFF5BA8FF), 25),
    _RoomScene('party',   'Party',   Icons.celebration_rounded,       Color(0xFF9F7BFA), 80),
    _RoomScene('off',     'Off',     Icons.dark_mode_rounded,         Color(0xFF3E3E68),  0),
  ],
};

// ── Room identity ──────────────────────────────────────────────────────────────

Color _roomColor(String r) {
  final n = r.toLowerCase();
  if (n.contains('living'))                       return const Color(0xFF5BA8FF);
  if (n.contains('kitchen'))                      return const Color(0xFFFD9A3E);
  if (n.contains('bedroom') || n.contains('bed')) return const Color(0xFF9F7BFA);
  if (n.contains('dining'))                       return const Color(0xFFFD6A3E);
  if (n.contains('entrance'))                     return const Color(0xFFC8A050);
  if (n.contains('corridor'))                     return const Color(0xFF7CA0C8);
  if (n.contains('bath') || n.contains('wc'))     return const Color(0xFF26D4BE);
  if (n.contains('balcony'))                      return const Color(0xFF4ECDC4);
  return C.accent;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Map Mode Screen
// ═══════════════════════════════════════════════════════════════════════════════

class MapModeScreen extends StatefulWidget {
  final AppState     appState;
  final VoidCallback onClose;

  const MapModeScreen({super.key, required this.appState, required this.onClose});

  @override
  State<MapModeScreen> createState() => _MapModeScreenState();
}

class _MapModeScreenState extends State<MapModeScreen>
    with TickerProviderStateMixin {
  AppState get _st => widget.appState;

  final _transformCtrl = TransformationController();
  String? _selectedRoom;
  Size    _canvasSize  = Size.zero;

  late final AnimationController _zoomCtrl;
  late final AnimationController _panelCtrl;
  late final Animation<double>   _panelAnim;
  Animation<Matrix4>? _zoomAnim;
  Timer? _stateDebounce;

  @override
  void initState() {
    super.initState();
    _zoomCtrl  = AnimationController(vsync: this,
        duration: const Duration(milliseconds: 650));
    _panelCtrl = AnimationController(vsync: this,
        duration: const Duration(milliseconds: 360));
    _panelAnim = CurvedAnimation(parent: _panelCtrl, curve: Curves.easeOutCubic);
    // Debounced listener — rebuild at most once per 600ms regardless of
    // how frequently AppState fires (it polls every 2 s but may fire faster)
    _st.addListener(_onStateChanged);
  }

  void _onStateChanged() {
    _stateDebounce?.cancel();
    _stateDebounce = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _st.removeListener(_onStateChanged);
    _stateDebounce?.cancel();
    _zoomCtrl.dispose();
    _panelCtrl.dispose();
    _transformCtrl.dispose();
    super.dispose();
  }

  // ── State helpers ─────────────────────────────────────────────────────────

  int  _brightness(int ch) => _st.pendingBrightness[ch] ?? _st.state.dali[ch]  ?? 0;
  bool _relayOn(int ch)    => _st.pendingRelay[ch]      ?? _st.state.relays[ch] ?? false;

  List<DaliDevice>  _roomLights(String r) =>
      _st.daliDevices.where((d) => d.room == r).toList();
  List<RelayDevice> _roomRelays(String r) =>
      _st.relayDevices.where((d) => d.room == r).toList();

  // ── Matrix helpers ─────────────────────────────────────────────────────────

  // Build a 2D scale+translate matrix: point → point*scale + (tx,ty)
  static Matrix4 _buildMatrix(double scale, double tx, double ty) {
    final m = Matrix4.identity();
    m.setEntry(0, 0, scale);
    m.setEntry(1, 1, scale);
    m.setEntry(0, 3, tx);
    m.setEntry(1, 3, ty);
    return m;
  }

  Matrix4 _roomMatrix(String room, Size screen) {
    final r = _FP.rects[room];
    if (r == null || _canvasSize == Size.zero) return Matrix4.identity();

    final cw = _canvasSize.width, ch = _canvasSize.height;
    final rx = r.left / _FP.logW * cw,  ry = r.top    / _FP.logH * ch;
    final rw = r.width/ _FP.logW * cw,  rh = r.height / _FP.logH * ch;

    final sx = screen.width  * 0.82 / rw;
    final sy = screen.height * 0.62 / rh;
    final s  = math.min(sx, sy).clamp(1.0, 6.0);

    final tx = screen.width  / 2 - (rx + rw / 2) * s;
    final ty = screen.height * 0.38 - (ry + rh / 2) * s;
    return _buildMatrix(s, tx, ty);
  }

  void _animateTo(Matrix4 target) {
    _zoomAnim = Matrix4Tween(
      begin: _transformCtrl.value,
      end:   target,
    ).animate(CurvedAnimation(parent: _zoomCtrl, curve: Curves.easeOutCubic));
    _zoomAnim!.addListener(() => _transformCtrl.value = _zoomAnim!.value);
    _zoomCtrl..reset()..forward();
  }

  void _selectRoom(String room, Size screen) {
    HapticFeedback.mediumImpact();
    setState(() => _selectedRoom = room);
    _animateTo(_roomMatrix(room, screen));
    _panelCtrl.forward();
  }

  void _clearRoom() {
    HapticFeedback.selectionClick();
    setState(() => _selectedRoom = null);
    _panelCtrl.reverse().then((_) {
      _animateTo(Matrix4.identity());
    });
  }

  void _applyRoomScene(_RoomScene scene, String room) {
    HapticFeedback.selectionClick();
    for (final d in _roomLights(room)) {
      _st.setDaliBrightness(d.channel, scene.brightness);
    }
  }

  // ── Tap detection (screen → canvas → logical) ─────────────────────────────

  String? _roomAt(Offset screenPos) {
    final inv = Matrix4.tryInvert(_transformCtrl.value);
    if (inv == null || _canvasSize == Size.zero) return null;

    // Transform screen point to canvas point using matrix storage (column-major)
    final s  = inv.storage;
    final cx = s[0] * screenPos.dx + s[4] * screenPos.dy + s[12];
    final cy = s[1] * screenPos.dx + s[5] * screenPos.dy + s[13];

    final lx = cx / _canvasSize.width  * _FP.logW;
    final ly = cy / _canvasSize.height * _FP.logH;
    final pt = Offset(lx, ly);

    for (final entry in _FP.rects.entries) {
      if (entry.value.inflate(1).contains(pt)) return entry.key;
    }
    return null;
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    return ColoredBox(
          color: const Color(0xFF02020A),
          child: Stack(children: [

            // ── Interactive floor plan ───────────────────────────────────
            Positioned.fill(
              child: LayoutBuilder(
                builder: (ctx, constraints) {
                  final w = constraints.maxWidth;
                  final h = constraints.maxHeight;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    final s = Size(w, h);
                    if (_canvasSize != s && w > 0 && h > 0) {
                      setState(() => _canvasSize = s);
                    }
                  });
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (details) {
                      final room = _roomAt(details.localPosition);
                      if (room != null) {
                        _selectRoom(room, screen);
                      } else if (_selectedRoom != null) {
                        _clearRoom();
                      }
                    },
                    child: InteractiveViewer(
                      transformationController: _transformCtrl,
                      minScale: 0.8,
                      maxScale: 6.0,
                      boundaryMargin: EdgeInsets.all(double.infinity),
                      child: SizedBox(
                        width: w, height: h,
                        child: CustomPaint(
                          painter: _ApartmentPainter(
                            allRooms:    _FP.rects,
                            fixtures:    _FP.lights,
                            relayDefs:   _FP.relayDefs,
                            brightness:  _brightness,
                            relayOn:     _relayOn,
                            daliDevices: _st.daliDevices,
                            selected:    _selectedRoom,
                            glow:        0.5,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),

            // ── Top bar ──────────────────────────────────────────────────
            Positioned(
              top: 0, left: 0, right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(children: [
                    _TopBadge(
                      label: 'Apartment ${_st.state.apartmentId}',
                      dot: _st.connected ? C.green : C.red,
                    ),
                    if (_selectedRoom != null) ...[
                      const SizedBox(width: 8),
                      _TopBadge(
                        label: _selectedRoom!,
                        dot:   _roomColor(_selectedRoom!),
                        color: _roomColor(_selectedRoom!),
                      ),
                    ],
                    const Spacer(),
                    GestureDetector(
                      onTap: widget.onClose,
                      child: Container(
                        width: 36, height: 36,
                        decoration: BoxDecoration(
                          color:        Colors.black.withAlpha(160),
                          shape:        BoxShape.circle,
                          border:       Border.all(
                              color: C.border.withAlpha(100), width: 0.5),
                        ),
                        child: const Icon(Icons.close_rounded,
                            color: C.textSec, size: 18),
                      ),
                    ),
                  ]),
                ),
              ),
            ),

            // ── Room control panel ────────────────────────────────────────
            AnimatedBuilder(
              animation: _panelAnim,
              builder: (_, _) {
                final h = screen.height * 0.48 * _panelAnim.value;
                if (h < 1 || _selectedRoom == null) return const SizedBox.shrink();
                return Positioned(
                  bottom: 0, left: 0, right: 0,
                  height: h,
                  child: _RoomPanel(
                    room:       _selectedRoom!,
                    appState:   _st,
                    scenes:     _roomScenes[_selectedRoom!] ?? [],
                    lights:     _roomLights(_selectedRoom!),
                    relays:     _roomRelays(_selectedRoom!),
                    brightness: _brightness,
                    relayOn:    _relayOn,
                    onClose:    _clearRoom,
                    onScene:    (s) => _applyRoomScene(s, _selectedRoom!),
                    onLight:    (ch, v) => _st.setDaliBrightness(ch, v),
                    onRelay:    (ch, v) => _st.setRelay(ch, v),
                    onRoomOn:   () => _st.setRoomBrightness(_selectedRoom!, 100),
                    onRoomOff:  () => _st.setRoomBrightness(_selectedRoom!, 0),
                  ),
                );
              },
            ),

          ]),
        );
  }
}

// ── Top badge ─────────────────────────────────────────────────────────────────

class _TopBadge extends StatelessWidget {
  final String  label;
  final Color   dot;
  final Color?  color;
  const _TopBadge({required this.label, required this.dot, this.color});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: (color ?? Colors.black).withAlpha(color != null ? 35 : 160),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(
          color: (color ?? C.border).withAlpha(color != null ? 70 : 100),
          width: 0.5),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 6, height: 6,
          decoration: BoxDecoration(shape: BoxShape.circle, color: dot)),
      const SizedBox(width: 7),
      Text(label, style: GoogleFonts.inter(
          fontSize: 12, fontWeight: FontWeight.w600,
          color: color ?? C.textPri)),
    ]),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// Apartment CustomPainter
// ═══════════════════════════════════════════════════════════════════════════════

class _ApartmentPainter extends CustomPainter {
  final Map<String, Rect>  allRooms;
  final List<_FixtureDef>  fixtures;
  final List<_FixtureDef>  relayDefs;
  final int  Function(int) brightness;
  final bool Function(int) relayOn;
  final List<DaliDevice>   daliDevices;
  final String?            selected;
  final double             glow;

  const _ApartmentPainter({
    required this.allRooms,  required this.fixtures,  required this.relayDefs,
    required this.brightness,required this.relayOn,   required this.daliDevices,
    required this.selected,  required this.glow,
  });

  Offset _p(double lx, double ly, Size s) =>
      Offset(lx / _FP.logW * s.width, ly / _FP.logH * s.height);

  Rect _r(Rect log, Size s) => Rect.fromLTWH(
    log.left   / _FP.logW * s.width,
    log.top    / _FP.logH * s.height,
    log.width  / _FP.logW * s.width,
    log.height / _FP.logH * s.height,
  );

  @override
  void paint(Canvas canvas, Size size) {
    _bg(canvas, size);
    _roomFills(canvas, size);
    _furniture(canvas, size);
    _walls(canvas, size);
    _doors(canvas, size);
    _windows(canvas, size);
    _lightFixtures(canvas, size);
    _roomLabels(canvas, size);
  }

  // ── Background ────────────────────────────────────────────────────────────

  void _bg(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size,
        Paint()..color = const Color(0xFF03030C));
  }

  // ── Room fills ────────────────────────────────────────────────────────────

  void _roomFills(Canvas canvas, Size size) {
    for (final entry in allRooms.entries) {
      final name  = entry.key;
      final color = _roomColor(name);
      final rect  = _r(entry.value, size);
      final devs  = daliDevices.where((d) => d.room == name).toList();
      final onCt  = devs.where((d) => brightness(d.channel) > 0).length;
      final isOn  = onCt > 0;
      final isSel = selected == name;

      // Floor
      canvas.drawRect(rect,
          Paint()..color = isOn
              ? color.withAlpha(20 + (glow * 8).round())
              : const Color(0xFF090918));

      // Selected highlight
      if (isSel) {
        canvas.drawRect(rect.inflate(1.5),
            Paint()
              ..color = color.withAlpha(45)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10));
      }

      // Active ambient glow
      if (isOn) {
        final avg = devs.fold<int>(0, (s, d) => s + brightness(d.channel))
            ~/ devs.length;
        canvas.drawRect(rect.inflate(3),
            Paint()
              ..color = color.withAlpha((avg / 100 * 14 + glow * 6).round())
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16));
      }
    }
  }

  // ── Furniture ─────────────────────────────────────────────────────────────

  void _furniture(Canvas canvas, Size size) {
    final fill   = Paint()..color = const Color(0xFF111128);
    final stroke = Paint()
      ..color = const Color(0xFF1C1C3A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7;

    void rr(double lx, double ly, double lw, double lh, double rad) {
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(lx / _FP.logW * size.width,  ly / _FP.logH * size.height,
            lw / _FP.logW * size.width, lh / _FP.logH * size.height),
        Radius.circular(rad / _FP.logW * size.width),
      );
      canvas.drawRRect(r, fill);
      canvas.drawRRect(r, stroke);
    }

    // Living Room — sofa L-shape against left wall, TV console near x=40 partition
    rr( 1.5,  8,  6, 22, 2);   // sofa back
    rr( 1.5, 28, 18,  5, 2);   // sofa chaise
    rr(31,    3,  7, 1.5, 0.5); // TV console

    // Dining Room — round table + chairs
    final tc = _p(20, 54, size);
    final tr = 5.5 / _FP.logW * size.width;
    canvas.drawCircle(tc, tr, fill);
    canvas.drawCircle(tc, tr, stroke);
    for (var i = 0; i < 6; i++) {
      final a  = i * math.pi / 3;
      final cr = tr + 2.4 / _FP.logW * size.width;
      canvas.drawCircle(
          Offset(tc.dx + cr * math.cos(a), tc.dy + cr * math.sin(a)),
          1.8 / _FP.logW * size.width, fill);
    }

    // Kitchen — counter along top + right walls; appliance indicators
    rr(40.5,  0.5, 18,  4.5, 0.4);   // top counter
    rr(56.0,  0.5,  3, 27,   0.4);   // right counter
    rr(41,    1,   3.5, 3, 0.3);     // FRIDGE
    rr(45,    1,   3,   3, 0.3);     // Microwave
    rr(49,    1,   3,   3, 0.3);     // Oven
    rr(53,    1,   2.5, 3, 0.3);     // DW

    // Bedroom 1 (Master) — bed + pillows + wardrobe strip
    rr(72,    1,  3.5, 12, 0.4);  // wardrobe along x=72 wall
    rr(75,    8, 15,  22, 2);     // bed frame
    rr(75.5,  8,  6,   4, 1);    // pillow left
    rr(83,    8,  6,   4, 1);    // pillow right

    // Bedroom 2 — bed + pillows
    rr(75,   44, 20,  18, 2);    // bed frame
    rr(75.5, 44,  8,   4, 1);   // pillow left
    rr(85,   44,  8,   4, 1);   // pillow right

    // Guest Bathroom — shower unit
    rr(92.5,  2,  6,   8, 1);

    // Bathroom — bathtub + basin
    rr(60.5,  2,  9,   8, 1);   // bathtub
    rr(60.5, 14,  4,   4, 0.8); // basin

    // Balcony — railing posts + planter + small table
    final railPost = Paint()
      ..color = const Color(0xFF1E3A38)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    for (var i = 0; i <= 7; i++) {
      final lx = i * (40.0 / 7);
      canvas.drawLine(_p(lx, 68.0, size), _p(lx, 80.0, size), railPost);
    }
    rr(1, 75, 8, 3.5, 0.5);
    final tbc = _p(22, 74, size);
    canvas.drawCircle(tbc, 3.5 / _FP.logW * size.width, fill);
    canvas.drawCircle(tbc, 3.5 / _FP.logW * size.width, stroke);
  }

  // ── Walls ─────────────────────────────────────────────────────────────────

  void _walls(Canvas canvas, Size size) {
    final outer = Paint()
      ..color = const Color(0xFF5A5A94)
      ..strokeWidth = 3.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square;
    final inner = Paint()
      ..color = const Color(0xFF3A3A70)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square;
    final dashed = Paint()
      ..color = const Color(0xFF252548)
      ..strokeWidth = 0.9
      ..style = PaintingStyle.stroke;

    // Main apartment outer boundary (y 0–68)
    canvas.drawRect(
        Rect.fromLTWH(1.5, 1.5, size.width - 3,
            68.0 / _FP.logH * size.height - 3),
        outer);

    // Balcony — side walls + dashed front railing
    final balRail = Paint()
      ..color = const Color(0xFF3A5A58)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;
    final bR = _r(_FP.balcony, size);
    canvas.drawLine(Offset(bR.left,  bR.top), Offset(bR.left,  bR.bottom), balRail);
    canvas.drawLine(Offset(bR.right, bR.top), Offset(bR.right, bR.bottom), balRail);
    _drawDashed(canvas, balRail,
        _FP.balcony.left, _FP.balcony.bottom,
        _FP.balcony.right, _FP.balcony.bottom, size);

    void ln(double x1, double y1, double x2, double y2) =>
        canvas.drawLine(_p(x1, y1, size), _p(x2, y2, size), inner);

    // Major vertical partitions
    ln(40,  0, 40, 58);    // Living/Dining | Kitchen/Main Corridor
    ln(60,  0, 60, 58);    // Kitchen/Bath  | Corridor/Private Corridor
    ln(72,  0, 72, 68);    // Bath+PC       | Bedroom 1+2
    ln(92,  0, 92, 22);    // Bedroom 1     | Guest Bathroom (inner)

    // Major horizontal partitions
    ln(40, 28, 60, 28);    // Kitchen bottom | Main Corridor top
    ln(60, 26, 72, 26);    // Bathroom bottom | Private Corridor top
    ln(72, 22, 100, 22);   // Guest Bathroom bottom
    ln(72, 40, 100, 40);   // Bedroom 1 bottom | Bedroom 2 top

    // Entrance Hall box (top + left side; right at x=72 already drawn)
    ln(24, 58, 40, 58);    // EH top-left segment
    ln(24, 58, 24, 68);    // EH left wall

    // Open-plan Living Room / Dining Room dashed divider
    _drawDashed(canvas, dashed, 0, 40, 40, 40, size);
  }

  // ── Doors ─────────────────────────────────────────────────────────────────

  void _doors(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0xFF323265)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    // Front door — Entrance Hall, bottom-center, opens inward
    _doorArc(canvas, p, 48, 68,  4,  math.pi,         size);
    // Main Corridor → Kitchen
    _doorArc(canvas, p, 40, 16,  4,  0,               size);
    // Private Corridor → Bathroom (door in y=26 wall)
    _doorArc(canvas, p, 66, 26,  3.5, math.pi / 2,    size);
    // Private Corridor → Bedroom 1 (door in x=72 wall)
    _doorArc(canvas, p, 72, 18,  4,  math.pi / 2,     size);
    // Private Corridor → Bedroom 2 (door in x=72 wall)
    _doorArc(canvas, p, 72, 52,  4,  math.pi / 2,     size);
    // Bedroom 1 → Guest Bathroom (door in x=92 wall)
    _doorArc(canvas, p, 92, 10,  3, -math.pi / 2,     size);
    // Living Room → Balcony (door in y=68 wall)
    _doorArc(canvas, p, 18, 68,  4, -math.pi,         size);
  }

  // ── Windows ───────────────────────────────────────────────────────────────

  void _windows(Canvas canvas, Size size) {
    final fill  = Paint()..color = const Color(0xFF080820);
    final frame = Paint()
      ..color = const Color(0xFF4A4A88)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final glass = Paint()
      ..color = const Color(0xFF0D1535).withAlpha(200);

    void wnd(double lx, double ly, double lw, double lh) {
      final r = Rect.fromLTWH(
          lx / _FP.logW * size.width,  ly / _FP.logH * size.height,
          lw / _FP.logW * size.width,  lh / _FP.logH * size.height);
      canvas.drawRect(r, fill);
      canvas.drawRect(r, frame);
      canvas.drawRect(r.deflate(1), glass);
    }

    // Left wall — Living Room windows (behind CRT1/CRT2 curtains)
    wnd( 0,  7, 2,  14);   // upper window — CRT1 position
    wnd( 0, 25, 2,  10);   // lower window — CRT2 position

    // Top wall — Kitchen
    wnd(44,  0, 13,   2);

    // Top wall — Bedroom 1
    wnd(74,  0, 14,   2);

    // Right wall — Bedroom 2
    wnd(97.5, 48, 2.5, 12);

    // CRT1/CRT2 curtain rail indicators (red dashed vertical lines on left wall)
    final crt = Paint()
      ..color = const Color(0xFFCC3333).withAlpha(160)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    _drawDashed(canvas, crt, 1.5,  7, 1.5, 21, size);  // CRT1
    _drawDashed(canvas, crt, 1.5, 25, 1.5, 35, size);  // CRT2
  }

  // ── Light fixtures ─────────────────────────────────────────────────────────

  void _lightFixtures(Canvas canvas, Size size) {
    for (final fix in fixtures) {
      final devs = daliDevices.where((d) => d.room == fix.room).toList();
      final idx  = fixtures
          .where((f) => f.room == fix.room)
          .toList()
          .indexOf(fix);
      final dev  = idx < devs.length ? devs[idx] : null;
      final pct  = dev != null ? brightness(dev.channel) : 0;
      final isOn = pct > 0;
      final c    = _p(fix.x, fix.y, size);
      final r    = 2.8 / _FP.logW * size.width;

      if (isOn) {
        final clr = _fixtureColor(pct);
        // Ambient glow
        canvas.drawCircle(c, r * (3.5 + 2 * glow) * (pct / 100),
            Paint()
              ..color = clr.withAlpha((35 + 20 * glow).round())
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
        // Bright spot
        canvas.drawCircle(c, r, Paint()..color = clr);
      } else {
        canvas.drawCircle(c, r, Paint()..color = const Color(0xFF181830));
        canvas.drawCircle(c, r, Paint()
          ..color = const Color(0xFF282850)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.6);
      }
    }
  }

  Color _fixtureColor(int pct) {
    if (pct < 25) return C.purple;
    if (pct < 50) return C.blue;
    if (pct < 75) return C.orange;
    return C.accent;
  }

  // ── Room labels ───────────────────────────────────────────────────────────

  void _roomLabels(Canvas canvas, Size size) {
    for (final entry in allRooms.entries) {
      final name  = entry.key;
      final rect  = _r(entry.value, size);
      if (rect.width < 30 || rect.height < 20) continue;
      final isSel = selected == name;
      final color = _roomColor(name);
      final tp = TextPainter(
        text: TextSpan(
          text: name,
          style: GoogleFonts.inter(
            fontSize: (isSel ? 10.5 : 9) * (size.width / 360),
            fontWeight: isSel ? FontWeight.w700 : FontWeight.w500,
            color: isSel ? color : color.withAlpha(140),
            letterSpacing: -0.2,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas,
          Offset(rect.left + (rect.width  - tp.width)  / 2,
                 rect.top  + (rect.height - tp.height) / 2));
    }
  }

  // ── Draw utilities ─────────────────────────────────────────────────────────

  void _doorArc(Canvas c, Paint p,
      double cx, double cy, double rLog, double startAngle, Size s) {
    final ctr = _p(cx, cy, s);
    final r   = rLog / _FP.logW * s.width;
    c.drawArc(
      Rect.fromCircle(center: ctr, radius: r),
      startAngle, math.pi / 2, false, p,
    );
    c.drawLine(ctr,
        Offset(ctr.dx + r * math.cos(startAngle + math.pi / 2),
               ctr.dy + r * math.sin(startAngle + math.pi / 2)),
        p);
  }

  void _drawDashed(Canvas c, Paint p,
      double x1, double y1, double x2, double y2, Size s) {
    const seg = 5.0, gap = 4.0;
    final a = _p(x1, y1, s), b = _p(x2, y2, s);
    final dx = b.dx - a.dx, dy = b.dy - a.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    var pos = 0.0;
    while (pos < len) {
      final e = math.min(pos + seg, len);
      c.drawLine(
          Offset(a.dx + dx * (pos / len), a.dy + dy * (pos / len)),
          Offset(a.dx + dx * (e   / len), a.dy + dy * (e   / len)), p);
      pos += seg + gap;
    }
  }

  @override
  bool shouldRepaint(_ApartmentPainter o) =>
      o.selected != selected || o.glow != glow ||
      o.daliDevices.length != daliDevices.length;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Room control panel
// ═══════════════════════════════════════════════════════════════════════════════

class _RoomPanel extends StatelessWidget {
  final String             room;
  final AppState           appState;
  final List<_RoomScene>   scenes;
  final List<DaliDevice>   lights;
  final List<RelayDevice>  relays;
  final int  Function(int) brightness;
  final bool Function(int) relayOn;
  final VoidCallback       onClose, onRoomOn, onRoomOff;
  final void Function(_RoomScene)    onScene;
  final void Function(int, int)      onLight;
  final void Function(int, bool)     onRelay;

  const _RoomPanel({
    required this.room,     required this.appState,  required this.scenes,
    required this.lights,   required this.relays,
    required this.brightness, required this.relayOn,
    required this.onClose,  required this.onRoomOn,  required this.onRoomOff,
    required this.onScene,  required this.onLight,   required this.onRelay,
  });

  @override
  Widget build(BuildContext context) {
    final color   = _roomColor(room);
    final onCount = lights.where((d) => brightness(d.channel) > 0).length;

    return Material(
      color: Colors.transparent,
      child: Container(
      decoration: BoxDecoration(
        color: const Color(0xF2060610),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(top: BorderSide(color: color.withAlpha(50), width: 0.5)),
        boxShadow: [
          BoxShadow(color: color.withAlpha(20), blurRadius: 24,
              offset: const Offset(0, -4))
        ],
      ),
      child: Column(children: [
        // Handle
        Container(
          margin: const EdgeInsets.only(top: 10),
          width: 32, height: 4,
          decoration: BoxDecoration(
            color: C.textTri.withAlpha(80),
            borderRadius: BorderRadius.circular(2)),
        ),
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Row(children: [
            Text(room,
                style: AppText.h2.copyWith(fontSize: 15, letterSpacing: -0.5)),
            const SizedBox(width: 8),
            Text(onCount > 0 ? '$onCount of ${lights.length} on' : 'All off',
                style: AppText.small.copyWith(
                    color: onCount > 0 ? color : C.textTri,
                    fontWeight: onCount > 0 ? FontWeight.w600 : FontWeight.w400)),
            const Spacer(),
            _Pill(label: 'Off', onTap: onRoomOff),
            const SizedBox(width: 6),
            _Pill(label: 'On',  onTap: onRoomOn, accent: true),
            const SizedBox(width: 6),
            GestureDetector(
              onTap: onClose,
              child: const Icon(Icons.keyboard_arrow_down_rounded,
                  color: C.textTri, size: 22)),
          ]),
        ),
        // Scenes
        if (scenes.isNotEmpty)
          SizedBox(
            height: 62,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: scenes.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final s = scenes[i];
                return GestureDetector(
                  onTap: () => onScene(s),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color:  s.color.withAlpha(18),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: s.color.withAlpha(50), width: 0.5),
                    ),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(s.icon, color: s.color, size: 15),
                        const SizedBox(height: 4),
                        Text(s.label,
                            style: AppText.small.copyWith(
                                color: s.color, fontSize: 9,
                                fontWeight: FontWeight.w600)),
                      ]),
                  ),
                );
              },
            ),
          ),
        const SizedBox(height: 4),
        // Light sliders + relay pills
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              ...lights.map((d) {
                final pct = brightness(d.channel);
                final clr = _fixtureColor(pct);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(children: [
                    AnimatedContainer(
                      duration: Dur.fast,
                      width: 7, height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: pct > 0 ? clr : C.border,
                        boxShadow: pct > 0
                            ? [BoxShadow(color: clr.withAlpha(120), blurRadius: 5)]
                            : null),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(d.name,
                        style: AppText.small.copyWith(
                            color: pct > 0 ? C.textSec : C.textTri,
                            fontWeight: pct > 0 ? FontWeight.w600 : FontWeight.w400,
                            fontSize: 11))),
                    SizedBox(
                      width: 26,
                      child: Text('$pct%',
                          textAlign: TextAlign.right,
                          style: AppText.small.copyWith(
                              color: pct > 0 ? clr : C.textTri,
                              fontSize: 10, fontWeight: FontWeight.w700,
                              fontFeatures: [const FontFeature.tabularFigures()])),
                    ),
                    Expanded(
                      flex: 3,
                      child: SliderTheme(
                        data: SliderThemeData(
                          trackHeight:        3,
                          activeTrackColor:   clr,
                          inactiveTrackColor: C.border2,
                          thumbColor:         clr,
                          overlayColor:       clr.withAlpha(16),
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                        ),
                        child: Slider(
                          value:     pct.toDouble(),
                          min: 0, max: 100, divisions: 10,
                          onChanged: (v) => onLight(d.channel, v.round()),
                        ),
                      ),
                    ),
                  ]),
                );
              }),
              // Curtain / blind controls
              ...relays.where(_isCurtain).map((r) {
                final open = relayOn(r.channel);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(children: [
                    const Icon(Icons.blinds_rounded, size: 14, color: C.textSec),
                    const SizedBox(width: 8),
                    Expanded(child: Text(r.name,
                        style: AppText.small.copyWith(fontSize: 11, color: C.textSec))),
                    _CurtainBtn(
                      label: 'Open',
                      active: open,
                      icon: Icons.expand_less_rounded,
                      color: C.accent,
                      onTap: () { HapticFeedback.selectionClick(); onRelay(r.channel, true); },
                    ),
                    const SizedBox(width: 4),
                    _CurtainBtn(
                      label: 'Close',
                      active: !open,
                      icon: Icons.expand_more_rounded,
                      color: C.textSec,
                      onTap: () { HapticFeedback.selectionClick(); onRelay(r.channel, false); },
                    ),
                  ]),
                );
              }),
              // Generic relay toggles (non-curtain)
              if (relays.any((r) => !_isCurtain(r)))
                Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 8),
                  child: Wrap(
                    spacing: 8, runSpacing: 8,
                    children: relays.where((r) => !_isCurtain(r)).map((r) {
                      final on = relayOn(r.channel);
                      return GestureDetector(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          onRelay(r.channel, !on);
                        },
                        child: AnimatedContainer(
                          duration: Dur.fast,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                          decoration: BoxDecoration(
                            color: on ? C.green.withAlpha(22) : C.card,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color: on ? C.green.withAlpha(80) : C.border,
                                width: 0.5)),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Container(width: 5, height: 5,
                                decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: on ? C.green : C.textTri)),
                            const SizedBox(width: 6),
                            Text(r.name,
                                style: AppText.small.copyWith(
                                    fontSize: 11,
                                    color: on ? C.textPri : C.textSec,
                                    fontWeight: on ? FontWeight.w600 : FontWeight.w400)),
                          ]),
                        ),
                      );
                    }).toList(),
                  ),
                ),
            ],
          ),
        ),
      ]),
      ),
    );
  }

  Color _fixtureColor(int pct) {
    if (pct == 0)  return C.textTri;
    if (pct < 25)  return C.purple;
    if (pct < 50)  return C.blue;
    if (pct < 75)  return C.orange;
    return C.accent;
  }
}

// Returns true for relay devices that should render as curtain / blind controls
bool _isCurtain(RelayDevice r) {
  final n = r.name.toLowerCase();
  return n.contains('curtain') || n.contains('blind') ||
      n.contains('shade') || n.contains('rolladen');
}

// ── Curtain open/close button ─────────────────────────────────────────────────

class _CurtainBtn extends StatelessWidget {
  final String   label;
  final bool     active;
  final IconData icon;
  final Color    color;
  final VoidCallback onTap;
  const _CurtainBtn({
    required this.label, required this.active, required this.icon,
    required this.color, required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: Dur.fast,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: active ? color.withAlpha(28) : C.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: active ? color.withAlpha(90) : C.border, width: 0.5),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: active ? color : C.textTri),
        const SizedBox(width: 4),
        Text(label,
            style: AppText.small.copyWith(
                fontSize: 10, fontWeight: FontWeight.w600,
                color: active ? color : C.textSec)),
      ]),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────

class _Pill extends StatelessWidget {
  final String label;
  final bool   accent;
  final VoidCallback onTap;
  const _Pill({required this.label, required this.onTap, this.accent = false});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () {
      HapticFeedback.selectionClick();
      onTap();
    },
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        gradient: accent ? G.accent : null,
        color:    accent ? null : C.card2,
        borderRadius: BorderRadius.circular(14),
        border: accent ? null : Border.all(color: C.border, width: 0.5),
      ),
      child: Text(label,
          style: AppText.small.copyWith(
              fontSize: 11, fontWeight: FontWeight.w700,
              color: accent ? Colors.black : C.textSec)),
    ),
  );
}
