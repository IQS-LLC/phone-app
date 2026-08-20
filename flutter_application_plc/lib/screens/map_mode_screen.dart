import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../auth/auth_state.dart';
import '../models/map_models.dart';
import '../models/models.dart';
import '../services/map_service.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../utils/apartment_display.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// Room scenes — generic presets usable for any named room.
// Rooms without a specific entry fall back to _kGenericScenes.
// ═══════════════════════════════════════════════════════════════════════════════

class _RoomScene {
  final String   id, label;
  final IconData icon;
  final Color    color;
  final int      brightness;
  const _RoomScene(this.id, this.label, this.icon, this.color, this.brightness);
}

const _kGenericScenes = <_RoomScene>[
  _RoomScene('bright', 'Bright', Icons.light_mode_rounded,    Color(0xFFF5C542), 100),
  _RoomScene('relax',  'Relax',  Icons.weekend_rounded,       Color(0xFFFD9A3E),  40),
  _RoomScene('night',  'Night',  Icons.nightlight_rounded,    Color(0xFF5BA8FF),  10),
  _RoomScene('off',    'Off',    Icons.dark_mode_rounded,     Color(0xFF3E3E68),   0),
];

const _kRoomScenes = <String, List<_RoomScene>>{
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
  'Master Bedroom': [
    _RoomScene('sleep',   'Sleep',   Icons.bedtime_rounded,           Color(0xFF5BA8FF),  0),
    _RoomScene('wake',    'Wake Up', Icons.wb_sunny_rounded,          Color(0xFFF5C542), 60),
    _RoomScene('reading', 'Reading', Icons.menu_book_rounded,         Color(0xFFCE93D8), 70),
    _RoomScene('relax',   'Relax',   Icons.spa_rounded,               Color(0xFF9F7BFA), 25),
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
  'Hallway': [
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
  if (n.contains('living'))                            return const Color(0xFF5BA8FF);
  if (n.contains('kitchen'))                           return const Color(0xFFFD9A3E);
  if (n.contains('bedroom') || n.contains('master'))  return const Color(0xFF9F7BFA);
  if (n.contains('dining'))                            return const Color(0xFFFD6A3E);
  if (n.contains('entrance') || n.contains('lobby'))  return const Color(0xFFC8A050);
  if (n.contains('hallway') || n.contains('corridor'))return const Color(0xFF7CA0C8);
  if (n.contains('bath') || n.contains('wc') || n.contains('toilet')) return const Color(0xFF26D4BE);
  if (n.contains('balcony') || n.contains('terrace')) return const Color(0xFF4ECDC4);
  if (n.contains('office') || n.contains('study'))    return const Color(0xFFCE93D8);
  if (n.contains('garage'))                           return const Color(0xFFA0A0A0);
  if (n.contains('garden') || n.contains('outdoor'))  return const Color(0xFF66BB6A);
  return C.accent;
}

// Lighting device types from the editor
const _kLightTypes = {
  'ceiling_light', 'pendant_light', 'led_strip', 'relay_light',
};

// Curtain/blind device types
const _kCurtainTypes = {'curtain', 'blind'};

// Architectural element types (drawn with special symbols)
const _kDoorTypes   = {'door', 'garage_door', 'gate'};
const _kWindowTypes = {'window'};

// Returns (icon, color) for a device type shown as an icon in the viewer
(IconData, Color) _deviceIconColor(String type) => switch (type) {
  'hvac'               => (Icons.ac_unit_rounded,                   Color(0xFF5BA8FF)),
  'thermostat'         => (Icons.thermostat_rounded,                Color(0xFFF5A623)),
  'temperature_sensor' => (Icons.device_thermostat_rounded,         Color(0xFF26D4BE)),
  'humidity_sensor'    => (Icons.water_drop_outlined,               Color(0xFF4ECDC4)),
  'door_sensor'        => (Icons.sensor_door_rounded,               Color(0xFFFF9F59)),
  'window_sensor'      => (Icons.sensor_window_rounded,             Color(0xFFFF9F59)),
  'presence_sensor'    => (Icons.person_outline_rounded,            Color(0xFF9F7BFA)),
  'smoke_detector'     => (Icons.warning_rounded,                   Color(0xFFFF5A5A)),
  'heat_detector'      => (Icons.local_fire_department_rounded,     Color(0xFFFF7043)),
  'leak_sensor'        => (Icons.water_drop_rounded,                Color(0xFF26D4BE)),
  'power_outlet'       => (Icons.power_rounded,                     Color(0xFFF5C542)),
  'usb_outlet'         => (Icons.usb_rounded,                       Color(0xFF7CA0C8)),
  'tv_outlet'          => (Icons.tv_rounded,                        Color(0xFF9F7BFA)),
  'rj45_outlet'        => (Icons.settings_ethernet_rounded,         Color(0xFF26D4BE)),
  'camera'             => (Icons.camera_alt_rounded,                Color(0xFF5BA8FF)),
  'doorbird'           => (Icons.doorbell_rounded,                  Color(0xFFFF9F59)),
  'intercom'           => (Icons.phone_rounded,                     Color(0xFF9F7BFA)),
  'alarm'              => (Icons.alarm_rounded,                     Color(0xFFFF5A5A)),
  'speaker'            => (Icons.speaker_rounded,                   Color(0xFF9F7BFA)),
  'microphone'         => (Icons.mic_rounded,                       Color(0xFFCE93D8)),
  'weather_station'    => (Icons.wb_cloudy_rounded,                 Color(0xFF5BA8FF)),
  'solar'              => (Icons.wb_sunny_rounded,                  Color(0xFFF5C542)),
  'battery'            => (Icons.battery_full_rounded,              Color(0xFF26D4BE)),
  'ev_charger'         => (Icons.ev_station_rounded,                Color(0xFF4ECDC4)),
  'garden'             => (Icons.yard_rounded,                      Color(0xFF66BB6A)),
  'pool'               => (Icons.pool_rounded,                      Color(0xFF26D4BE)),
  _                    => (Icons.widgets_rounded,                   Color(0xFF7CA0C8)),
};

// ═══════════════════════════════════════════════════════════════════════════════
// Map Mode Screen — Digital Twin for residents
// Loads the published map from the API and renders it dynamically.
// ═══════════════════════════════════════════════════════════════════════════════

class MapModeScreen extends StatefulWidget {
  final AppState     appState;
  final AuthState    authState;
  final VoidCallback onClose;
  final String?      apartmentLabel;

  const MapModeScreen({
    super.key,
    required this.appState,
    required this.authState,
    required this.onClose,
    this.apartmentLabel,
  });

  @override
  State<MapModeScreen> createState() => _MapModeScreenState();
}

class _MapModeScreenState extends State<MapModeScreen>
    with TickerProviderStateMixin {
  AppState get _st => widget.appState;

  // ── API / map data ───────────────────────────────────────────────────────────
  late final MapService _svc;
  EditorLayout?      _editorLayout;
  List<EditorObject> _canvasRooms   = [];
  List<EditorObject> _canvasDevices = [];
  bool _mapLoading = true;
  bool _noMap      = false;

  // ── Background image ─────────────────────────────────────────────────────────
  String    _baseUrl     = '';
  ui.Image? _bgImage;
  String    _bgImageUrl  = '';

  double get _canvasWidth  => _editorLayout?.canvasWidth  ?? 2000;
  double get _canvasHeight => _editorLayout?.canvasHeight ?? 1500;

  // ── Interactive viewer ───────────────────────────────────────────────────────
  final _transformCtrl = TransformationController();
  String? _selectedRoom;
  Size    _canvasSize  = Size.zero;

  late final AnimationController _zoomCtrl;
  late final AnimationController _panelCtrl;
  late final AnimationController _glowCtrl;
  late final Animation<double>   _panelAnim;
  late final Animation<double>   _glowAnim;
  Animation<Matrix4>? _zoomAnim;
  Timer? _stateDebounce;

  @override
  void initState() {
    super.initState();
    _svc = MapService(
      getToken:   widget.authState.service.getAccessToken,
      getBaseUrl: widget.authState.service.getBaseUrl,
    );
    _zoomCtrl  = AnimationController(vsync: this,
        duration: const Duration(milliseconds: 650));
    _panelCtrl = AnimationController(vsync: this,
        duration: const Duration(milliseconds: 360));
    _glowCtrl  = AnimationController(vsync: this,
        duration: const Duration(seconds: 3))..repeat(reverse: true);
    _panelAnim = CurvedAnimation(parent: _panelCtrl, curve: Curves.easeOutCubic);
    _glowAnim  = Tween<double>(begin: 0.2, end: 0.9).animate(
        CurvedAnimation(parent: _glowCtrl, curve: Curves.easeInOut));
    _st.addListener(_onStateChanged);
    _loadLayout();
    _svc.getBaseUrl().then((url) {
      if (!mounted) return;
      setState(() { _baseUrl = url ?? ''; });
      final bgUrl = _editorLayout?.backgroundUrl ?? '';
      if (bgUrl.isNotEmpty && _bgImage == null) _loadBgImage(bgUrl);
    });
  }

  Future<void> _loadLayout() async {
    final aptId = _st.state.apartmentId;
    try {
      final layout = await _svc.fetchLayout(aptId);
      if (!mounted) return;
      if (layout == null || layout.objects.isEmpty) {
        setState(() { _mapLoading = false; _noMap = true; });
        return;
      }
      setState(() {
        _editorLayout  = layout;
        _canvasRooms   = layout.objects.where((o) => o.objectType == 'room').toList();
        _canvasDevices = layout.objects.where((o) => o.objectType == 'device').toList();
        _mapLoading    = false;
      });
      if (layout.backgroundUrl.isNotEmpty) _loadBgImage(layout.backgroundUrl);
    } catch (_) {
      if (mounted) setState(() { _mapLoading = false; _noMap = true; });
    }
  }

  String _fullBgUrl(String url) {
    if (url.startsWith('http')) return url;
    if (_baseUrl.isNotEmpty) return '$_baseUrl$url';
    return url;
  }

  Future<void> _loadBgImage(String url) async {
    if (url.isEmpty) return;
    final fullUrl = _fullBgUrl(url);
    if (fullUrl == _bgImageUrl) return;
    _bgImageUrl = fullUrl;
    try {
      final provider  = NetworkImage(fullUrl);
      final stream    = provider.resolve(ImageConfiguration.empty);
      final completer = Completer<ui.Image>();
      late ImageStreamListener listener;
      listener = ImageStreamListener(
        (info, _) {
          if (!completer.isCompleted) completer.complete(info.image);
          stream.removeListener(listener);
        },
        onError: (_, _) {
          if (!completer.isCompleted) completer.completeError('load failed');
          stream.removeListener(listener);
        },
      );
      stream.addListener(listener);
      final img = await completer.future;
      if (!mounted) return;
      setState(() { _bgImage = img; });
    } catch (_) {}
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
    _glowCtrl.dispose();
    _transformCtrl.dispose();
    super.dispose();
  }

  // ── PLC helpers ───────────────────────────────────────────────────────────────

  int  _brightness(int ch) => _st.pendingBrightness[ch] ?? _st.state.dali[ch]  ?? 0;
  bool _relayOn(int ch)    => _st.pendingRelay[ch]      ?? _st.state.relays[ch] ?? false;

  List<DaliDevice>  _roomLights(String r) =>
      _st.daliDevices.where((d) => d.room == r).toList();
  List<RelayDevice> _roomRelays(String r) =>
      _st.relayDevices.where((d) => d.room == r).toList();

  // ── Matrix helpers ─────────────────────────────────────────────────────────────

  static Matrix4 _buildMatrix(double scale, double tx, double ty) {
    final m = Matrix4.identity();
    m.setEntry(0, 0, scale);
    m.setEntry(1, 1, scale);
    m.setEntry(0, 3, tx);
    m.setEntry(1, 3, ty);
    return m;
  }

  Matrix4 _roomMatrix(String roomName, Size screen) {
    final room = _canvasRooms.where((o) => o.name == roomName).firstOrNull;
    if (room == null || _canvasSize == Size.zero) return Matrix4.identity();

    // Convert canvas object coords → widget pixel coords
    final rx = room.x / _canvasWidth  * _canvasSize.width;
    final ry = room.y / _canvasHeight * _canvasSize.height;
    final rw = room.width  / _canvasWidth  * _canvasSize.width;
    final rh = room.height / _canvasHeight * _canvasSize.height;

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

  // ── Tap detection ─────────────────────────────────────────────────────────────

  String? _roomAt(Offset screenPos) {
    if (_canvasRooms.isEmpty || _canvasSize == Size.zero) return null;
    final inv = Matrix4.tryInvert(_transformCtrl.value);
    if (inv == null) return null;

    // Transform screen → widget canvas coords
    final s  = inv.storage;
    final wx = s[0] * screenPos.dx + s[4] * screenPos.dy + s[12];
    final wy = s[1] * screenPos.dx + s[5] * screenPos.dy + s[13];

    // Widget canvas coords → map canvas coords
    final mapX = wx / _canvasSize.width  * _canvasWidth;
    final mapY = wy / _canvasSize.height * _canvasHeight;
    final pt   = Offset(mapX, mapY);

    // Reversed so topmost (last-painted) room wins on overlap
    for (final room in _canvasRooms.reversed) {
      if (Rect.fromLTWH(room.x, room.y, room.width, room.height)
          .inflate(2).contains(pt)) {
        return room.name;
      }
    }
    return null;
  }

  // ── Build ──────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_mapLoading) {
      return const ColoredBox(
        color: Color(0xFF02020A),
        child: Center(
          child: CircularProgressIndicator(color: C.accent, strokeWidth: 2),
        ),
      );
    }

    if (_noMap || _canvasRooms.isEmpty) {
      return _buildNoMap();
    }

    final screen = MediaQuery.of(context).size;
    return ColoredBox(
      color: const Color(0xFF02020A),
      child: Stack(children: [

        // ── Interactive floor plan ─────────────────────────────────────────────
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
                  boundaryMargin: const EdgeInsets.all(double.infinity),
                  child: SizedBox(
                    width: w, height: h,
                    child: AnimatedBuilder(
                      animation: _glowAnim,
                      builder: (_, _) => CustomPaint(
                        painter: _MapPainter(
                          rooms:       _canvasRooms,
                          devices:     _canvasDevices,
                          canvasW:     _canvasWidth,
                          canvasH:     _canvasHeight,
                          brightness:  _brightness,
                          relayOn:     _relayOn,
                          daliDevices: _st.daliDevices,
                          daliById:    {
                            for (final d in _st.daliDevices)
                              if (d.apartmentDeviceId != null)
                                d.apartmentDeviceId!: d,
                          },
                          selected:    _selectedRoom,
                          glow:        _glowAnim.value,
                          bgImage:     _bgImage,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),

        // ── Top bar ─────────────────────────────────────────────────────────────
        Positioned(
          top: 0, left: 0, right: 0,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                _TopBadge(
                  label: ApartmentDisplay.label(widget.apartmentLabel),
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
                      color:  Colors.black.withAlpha(160),
                      shape:  BoxShape.circle,
                      border: Border.all(color: C.border.withAlpha(100), width: 0.5),
                    ),
                    child: const Icon(Icons.close_rounded, color: C.textSec, size: 18),
                  ),
                ),
              ]),
            ),
          ),
        ),

        // ── Room control panel ───────────────────────────────────────────────────
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
                scenes:     _kRoomScenes[_selectedRoom!] ?? _kGenericScenes,
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

  Widget _buildNoMap() {
    return ColoredBox(
      color: const Color(0xFF02020A),
      child: Stack(children: [
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.map_outlined, size: 56, color: C.textTri),
              const SizedBox(height: 16),
              Text('No map available',
                  style: AppText.body.copyWith(color: C.textSec)),
              const SizedBox(height: 8),
              Text(
                'A Tech Team member needs to create and publish\n'
                'the map for this apartment.',
                style: AppText.small.copyWith(color: C.textTri),
                textAlign: TextAlign.center,
              ),
            ]),
          ),
        ),
        Positioned(
          top: 0, left: 0, right: 0,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                _TopBadge(
                  label: ApartmentDisplay.label(widget.apartmentLabel),
                  dot: _st.connected ? C.green : C.red,
                ),
                const Spacer(),
                GestureDetector(
                  onTap: widget.onClose,
                  child: Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      color:  Colors.black.withAlpha(160),
                      shape:  BoxShape.circle,
                      border: Border.all(color: C.border.withAlpha(100), width: 0.5),
                    ),
                    child: const Icon(Icons.close_rounded, color: C.textSec, size: 18),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

// ── Top badge ──────────────────────────────────────────────────────────────────

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
// Map CustomPainter — renders the Digital Twin from canvas objects
// ═══════════════════════════════════════════════════════════════════════════════

class _MapPainter extends CustomPainter {
  final List<EditorObject>      rooms;
  final List<EditorObject>      devices;
  final double                  canvasW, canvasH;
  final int  Function(int)      brightness;
  final bool Function(int)      relayOn;
  final List<DaliDevice>        daliDevices;
  // apartmentDeviceId → DaliDevice for O(1) fixture lookup
  final Map<int, DaliDevice>    daliById;
  final String?                 selected;
  final double                  glow;
  final ui.Image?               bgImage;

  _MapPainter({
    required this.rooms,       required this.devices,
    required this.canvasW,     required this.canvasH,
    required this.brightness,  required this.relayOn,
    required this.daliDevices, required this.daliById,
    required this.selected,    required this.glow,
    this.bgImage,
  });

  // Convert canvas coords (object space) → screen rect
  Rect _sr(double cx, double cy, double cw, double ch, Size s) => Rect.fromLTWH(
    cx / canvasW * s.width,
    cy / canvasH * s.height,
    cw / canvasW * s.width,
    ch / canvasH * s.height,
  );

  @override
  void paint(Canvas canvas, Size size) {
    // Background
    canvas.drawRect(Offset.zero & size,
        Paint()..color = const Color(0xFF03030C));

    // Floor plan background image
    if (bgImage != null) {
      canvas.saveLayer(Offset.zero & size,
          Paint()..color = const Color(0x40FFFFFF)); // ~25 % opacity
      canvas.drawImageRect(
        bgImage!,
        Rect.fromLTWH(0, 0, bgImage!.width.toDouble(), bgImage!.height.toDouble()),
        Offset.zero & size,
        Paint(),
      );
      canvas.restore();
    }

    _drawRoomFills(canvas, size);
    _drawDoors(canvas, size);
    _drawWindows(canvas, size);
    _drawLightDevices(canvas, size);
    _drawCurtainDevices(canvas, size);
    _drawDeviceIcons(canvas, size);
    _drawRoomLabels(canvas, size);
  }

  // ── Room fills ────────────────────────────────────────────────────────────────

  void _drawRoomFills(Canvas canvas, Size size) {
    for (final obj in rooms) {
      final color  = _roomColor(obj.name);
      final rect   = _sr(obj.x, obj.y, obj.width, obj.height, size);
      final devs   = daliDevices.where((d) => d.room == obj.name).toList();
      final onCt   = devs.where((d) => brightness(d.channel) > 0).length;
      final isOn   = onCt > 0;
      final isSel  = selected == obj.name;

      // Floor fill
      canvas.drawRect(rect,
          Paint()..color = isOn
              ? color.withAlpha(20 + (glow * 8).round())
              : const Color(0xFF090918));

      // Room border
      canvas.drawRect(rect,
          Paint()
            ..color = isSel
                ? color.withAlpha(160)
                : color.withAlpha(60)
            ..style = PaintingStyle.stroke
            ..strokeWidth = isSel ? 1.6 : 0.8);

      // Selection glow
      if (isSel) {
        canvas.drawRect(rect.inflate(1.5),
            Paint()
              ..color = color.withAlpha(45)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10));
      }

      // Active ambient glow
      if (isOn && devs.isNotEmpty) {
        final avg = devs.fold<int>(0, (acc, d) => acc + brightness(d.channel))
            ~/ devs.length;
        canvas.drawRect(rect.inflate(3),
            Paint()
              ..color = color.withAlpha((avg / 100 * 14 + glow * 6).round())
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16));
      }
    }
  }

  // ── Architectural doors ───────────────────────────────────────────────────────

  void _drawDoors(Canvas canvas, Size size) {
    for (final dev in devices) {
      if (!_kDoorTypes.contains(dev.deviceType)) continue;
      final rect = _sr(dev.x, dev.y, dev.width, dev.height, size);
      final isWide = rect.width >= rect.height;
      // Hinge at top-left; panel along the longer dimension; arc sweeps 90°.
      final panelLen = isWide ? rect.width : rect.height;
      final hinge    = rect.topLeft;
      final panelEnd = isWide
          ? Offset(rect.right, rect.top)
          : Offset(rect.left, rect.bottom);

      final doorPaint = Paint()
        ..color = const Color(0xFFC8A050).withAlpha(200)
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke;

      // Door panel line
      canvas.drawLine(hinge, panelEnd, doorPaint);

      // Quarter-circle arc (sweep 90° from panel direction toward open position)
      final arcRect = Rect.fromCenter(
        center: hinge,
        width:  panelLen * 2,
        height: panelLen * 2,
      );
      canvas.drawArc(arcRect, isWide ? 0 : -math.pi / 2, math.pi / 2,
          false, doorPaint..color = const Color(0xFFC8A050).withAlpha(100));

      // Hinge dot
      canvas.drawCircle(hinge, 2,
          Paint()..color = const Color(0xFFC8A050).withAlpha(180));
    }
  }

  // ── Windows ───────────────────────────────────────────────────────────────────

  void _drawWindows(Canvas canvas, Size size) {
    for (final dev in devices) {
      if (!_kWindowTypes.contains(dev.deviceType)) continue;
      final rect = _sr(dev.x, dev.y, dev.width, dev.height, size);

      // Outer border
      canvas.drawRect(rect,
          Paint()
            ..color = const Color(0xFF4ECDC4).withAlpha(180)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);

      // Inner fill (glass)
      canvas.drawRect(rect,
          Paint()..color = const Color(0xFF4ECDC4).withAlpha(18));

      // Cross pane dividers
      final midX = rect.left + rect.width  / 2;
      final midY = rect.top  + rect.height / 2;
      final panePaint = Paint()
        ..color = const Color(0xFF4ECDC4).withAlpha(80)
        ..strokeWidth = 0.6;
      if (rect.width > rect.height) {
        canvas.drawLine(Offset(midX, rect.top), Offset(midX, rect.bottom), panePaint);
      } else {
        canvas.drawLine(Offset(rect.left, midY), Offset(rect.right, midY), panePaint);
      }
    }
  }

  // ── Light device indicators (multi-pass bloom) ────────────────────────────────

  void _drawLightDevices(Canvas canvas, Size size) {
    final roomDali = <String, List<DaliDevice>>{};
    for (final d in daliDevices) {
      (roomDali[d.room] ??= []).add(d);
    }

    for (final fix in devices) {
      if (!_kLightTypes.contains(fix.deviceType)) continue;

      DaliDevice? dalDev;
      final devId = fix.apartmentDeviceId;
      if (devId != null && daliById.containsKey(devId)) {
        dalDev = daliById[devId];
      } else {
        final inRoom = roomDali[fix.roomName ?? ''];
        dalDev = (inRoom != null && inRoom.isNotEmpty) ? inRoom.first : null;
      }
      final pct = dalDev != null ? brightness(dalDev.channel) : 0;

      final cx = (fix.x + fix.width  / 2) / canvasW * size.width;
      final cy = (fix.y + fix.height / 2) / canvasH * size.height;
      final r  = math.min(
        fix.width  / canvasW * size.width,
        fix.height / canvasH * size.height,
      ) / 2;
      final c = Offset(cx, cy);

      if (pct > 0) {
        final clr   = _fixtureColor(pct);
        final scale = pct / 100.0;

        // Wide ambient scatter
        canvas.drawCircle(c, r * (8 + 4 * glow) * scale,
            Paint()
              ..color = clr.withAlpha((8 + (glow * 6).round()))
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14));

        // Medium halo
        canvas.drawCircle(c, r * (3.5 + 2 * glow) * scale,
            Paint()
              ..color = clr.withAlpha((30 + (glow * 25).round()))
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));

        // Tight inner glow
        canvas.drawCircle(c, r * (1.4 + 0.4 * glow),
            Paint()
              ..color = clr.withAlpha((90 + (glow * 60).round()))
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2));

        // Solid bright core
        canvas.drawCircle(c, r, Paint()..color = clr);

        // Specular highlight
        canvas.drawCircle(
          Offset(c.dx - r * 0.25, c.dy - r * 0.25),
          r * 0.35,
          Paint()..color = Colors.white.withAlpha(90),
        );
      } else {
        canvas.drawCircle(c, r, Paint()..color = const Color(0xFF181830));
        canvas.drawCircle(c, r,
            Paint()
              ..color = const Color(0xFF282850)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 0.6);
      }
    }
  }

  // ── Device icons (non-light, non-curtain, non-room) ───────────────────────────

  void _drawDeviceIcons(Canvas canvas, Size size) {
    for (final dev in devices) {
      if (_kLightTypes.contains(dev.deviceType))   continue;
      if (_kCurtainTypes.contains(dev.deviceType)) continue;
      if (_kDoorTypes.contains(dev.deviceType))    continue;
      if (_kWindowTypes.contains(dev.deviceType))  continue;

      final rect = _sr(dev.x, dev.y, dev.width, dev.height, size);
      final iconSize = math.min(rect.width, rect.height) * 0.6;
      if (iconSize < 4) continue;

      final (icon, color) = _deviceIconColor(dev.deviceType);

      // Background circle
      canvas.drawCircle(rect.center, math.min(rect.width, rect.height) / 2,
          Paint()..color = color.withAlpha(25));
      canvas.drawCircle(rect.center, math.min(rect.width, rect.height) / 2,
          Paint()
            ..color = color.withAlpha(70)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.8);

      // Icon
      final tp = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(icon.codePoint),
          style: TextStyle(
            fontSize:   iconSize,
            fontFamily: icon.fontFamily,
            package:    icon.fontPackage,
            color:      color.withAlpha(200),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas,
          rect.center - Offset(tp.width / 2, tp.height / 2));
    }
  }

  // ── Curtain/blind device indicators ──────────────────────────────────────────

  void _drawCurtainDevices(Canvas canvas, Size size) {
    final crtPaint = Paint()
      ..color = const Color(0xFFCC3333).withAlpha(160)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    for (final dev in devices) {
      if (!_kCurtainTypes.contains(dev.deviceType)) continue;
      final x1 = dev.x / canvasW * size.width;
      final y1 = dev.y / canvasH * size.height;
      final x2 = (dev.x + dev.width)  / canvasW * size.width;
      final y2 = (dev.y + dev.height) / canvasH * size.height;
      _drawDashed(canvas, crtPaint, x1, y1, x2, y2);
    }
  }

  // ── Room labels ───────────────────────────────────────────────────────────────

  void _drawRoomLabels(Canvas canvas, Size size) {
    for (final obj in rooms) {
      final rect  = _sr(obj.x, obj.y, obj.width, obj.height, size);
      if (rect.width < 30 || rect.height < 20) continue;
      final isSel = selected == obj.name;
      final color = _roomColor(obj.name);
      final tp = TextPainter(
        text: TextSpan(
          text: obj.name,
          style: GoogleFonts.inter(
            fontSize: (isSel ? 10.5 : 9) * (size.width / 360),
            fontWeight: isSel ? FontWeight.w700 : FontWeight.w500,
            color: isSel ? color : color.withAlpha(140),
            letterSpacing: -0.2,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: rect.width);
      tp.paint(canvas,
          Offset(rect.left + (rect.width  - tp.width)  / 2,
                 rect.top  + (rect.height - tp.height) / 2));
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────────

  Color _fixtureColor(int pct) {
    if (pct < 25) return C.purple;
    if (pct < 50) return C.blue;
    if (pct < 75) return C.orange;
    return C.accent;
  }

  void _drawDashed(Canvas c, Paint p,
      double x1, double y1, double x2, double y2) {
    const seg = 5.0, gap = 4.0;
    final dx = x2 - x1, dy = y2 - y1;
    final len = math.sqrt(dx * dx + dy * dy);
    var pos = 0.0;
    while (pos < len) {
      final e = math.min(pos + seg, len);
      c.drawLine(
        Offset(x1 + dx * (pos / len), y1 + dy * (pos / len)),
        Offset(x1 + dx * (e   / len), y1 + dy * (e   / len)),
        p,
      );
      pos += seg + gap;
    }
  }

  @override
  bool shouldRepaint(_MapPainter o) =>
      o.selected != selected || o.glow != glow ||
      o.rooms != rooms || o.devices != devices ||
      o.daliDevices.length != daliDevices.length ||
      o.bgImage != bgImage;
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
          // Light sliders + relay controls
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

bool _isCurtain(RelayDevice r) {
  final n = r.name.toLowerCase();
  return n.contains('curtain') || n.contains('blind') ||
      n.contains('shade') || n.contains('rolladen');
}

// ── Small widgets ──────────────────────────────────────────────────────────────

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
