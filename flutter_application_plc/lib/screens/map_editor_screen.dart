import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../auth/auth_state.dart';
import '../config/runtime_config.dart';
import '../models/map_models.dart';
import '../services/map_service.dart';
import '../theme.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// Device catalogue — every type the toolbox exposes
// ═══════════════════════════════════════════════════════════════════════════════

class _DeviceDef {
  final String   type;
  final String   label;
  final IconData icon;
  final Color    color;
  const _DeviceDef(this.type, this.label, this.icon, this.color);
}

const _kDeviceCategories = <String, List<_DeviceDef>>{
  'Rooms': [
    _DeviceDef('room', 'Room', Icons.square_rounded, Color(0xFF5BA8FF)),
  ],
  'Lighting': [
    _DeviceDef('ceiling_light',  'Ceiling',  Icons.light_rounded,              Color(0xFFF5C542)),
    _DeviceDef('pendant_light',  'Pendant',  Icons.emoji_objects_rounded,       Color(0xFFF5A623)),
    _DeviceDef('led_strip',      'LED Strip',Icons.linear_scale_rounded,        Color(0xFF26D4BE)),
    _DeviceDef('relay_light',    'Relay',    Icons.lightbulb_rounded,           Color(0xFFCE93D8)),
  ],
  'Window/Door': [
    _DeviceDef('curtain',        'Curtain',  Icons.blinds_rounded,              Color(0xFF5BA8FF)),
    _DeviceDef('blind',          'Blind',    Icons.window_rounded,              Color(0xFF7CA0C8)),
    _DeviceDef('window',         'Window',   Icons.window_rounded,              Color(0xFF4ECDC4)),
    _DeviceDef('door',           'Door',     Icons.door_back_door_rounded,      Color(0xFFC8A050)),
  ],
  'Sensors': [
    _DeviceDef('door_sensor',     'Door Snsr',   Icons.sensor_door_rounded,      Color(0xFFFF9F59)),
    _DeviceDef('window_sensor',   'Win Snsr',    Icons.sensor_window_rounded,    Color(0xFFFF9F59)),
    _DeviceDef('presence_sensor', 'Presence',    Icons.person_outline_rounded,   Color(0xFF9F7BFA)),
    _DeviceDef('smoke_detector',  'Smoke',       Icons.warning_rounded,          Color(0xFFFF5A5A)),
    _DeviceDef('heat_detector',   'Heat',        Icons.local_fire_department_rounded, Color(0xFFFF7043)),
    _DeviceDef('leak_sensor',     'Leak',        Icons.water_drop_rounded,       Color(0xFF26D4BE)),
  ],
  'Climate': [
    _DeviceDef('hvac',               'HVAC',       Icons.ac_unit_rounded,        Color(0xFF5BA8FF)),
    _DeviceDef('thermostat',         'Thermostat', Icons.thermostat_rounded,     Color(0xFFF5A623)),
    _DeviceDef('temperature_sensor', 'Temp',       Icons.device_thermostat_rounded, Color(0xFF26D4BE)),
    _DeviceDef('humidity_sensor',    'Humidity',   Icons.water_drop_outlined,    Color(0xFF4ECDC4)),
  ],
  'Electrical': [
    _DeviceDef('power_outlet', 'Power',  Icons.power_rounded,              C.accent),
    _DeviceDef('usb_outlet',   'USB',    Icons.usb_rounded,                Color(0xFF7CA0C8)),
    _DeviceDef('tv_outlet',    'TV',     Icons.tv_rounded,                 Color(0xFF9F7BFA)),
    _DeviceDef('rj45_outlet',  'RJ45',   Icons.settings_ethernet_rounded,  Color(0xFF26D4BE)),
  ],
  'Access': [
    _DeviceDef('garage_door', 'Garage',   Icons.garage_rounded,           Color(0xFFC8A050)),
    _DeviceDef('gate',        'Gate',     Icons.fence_rounded,             Color(0xFFA0C0A0)),
    _DeviceDef('camera',      'Camera',   Icons.camera_alt_rounded,        Color(0xFF5BA8FF)),
    _DeviceDef('doorbird',    'DoorBird', Icons.doorbell_rounded,          Color(0xFFFF9F59)),
    _DeviceDef('intercom',    'Intercom', Icons.phone_rounded,             Color(0xFF9F7BFA)),
  ],
  'Audio': [
    _DeviceDef('speaker',    'Speaker',  Icons.speaker_rounded,           Color(0xFF9F7BFA)),
    _DeviceDef('microphone', 'Mic',      Icons.mic_rounded,               Color(0xFFCE93D8)),
  ],
  'Safety': [
    _DeviceDef('alarm', 'Alarm', Icons.alarm_rounded, Color(0xFFFF5A5A)),
  ],
  'Energy': [
    _DeviceDef('weather_station', 'Weather', Icons.wb_cloudy_rounded,     Color(0xFF5BA8FF)),
    _DeviceDef('solar',           'Solar',   Icons.wb_sunny_rounded,      Color(0xFFF5C542)),
    _DeviceDef('battery',         'Battery', Icons.battery_full_rounded,  Color(0xFF26D4BE)),
    _DeviceDef('ev_charger',      'EV',      Icons.ev_station_rounded,    Color(0xFF4ECDC4)),
  ],
  'Other': [
    _DeviceDef('garden', 'Garden', Icons.yard_rounded,   Color(0xFF66BB6A)),
    _DeviceDef('pool',   'Pool',   Icons.pool_rounded,   Color(0xFF26D4BE)),
    _DeviceDef('custom', 'Custom', Icons.widgets_rounded, Color(0xFF7CA0C8)),
  ],
};

// ═══════════════════════════════════════════════════════════════════════════════
// Canvas constants
// ═══════════════════════════════════════════════════════════════════════════════

const _kHandleRadius = 6.0;
const _kRotHandleOffset = 28.0;
const _kDefaultObjW = 48.0;
const _kDefaultObjH = 48.0;
const _kRoomDefaultW = 200.0;
const _kRoomDefaultH = 150.0;
const _kMinScale = 0.08;
const _kMaxScale = 8.0;

// ═══════════════════════════════════════════════════════════════════════════════
// Map Editor Screen
// ═══════════════════════════════════════════════════════════════════════════════

class MapEditorScreen extends StatefulWidget {
  final AuthState    authState;
  final int?         initialApartmentId;
  final VoidCallback? onClose;

  const MapEditorScreen({
    super.key,
    required this.authState,
    this.initialApartmentId,
    this.onClose,
  });

  @override
  State<MapEditorScreen> createState() => _MapEditorState();
}

class _MapEditorState extends State<MapEditorScreen> {
  // ── Service ──────────────────────────────────────────────────────────────────
  late final MapService _svc;

  // ── Apartment ────────────────────────────────────────────────────────────────
  List<ApartmentEditorEntry> _apartments = [];
  ApartmentEditorEntry?      _apartment;
  EditorLayout?              _layout;

  // ── Canvas state ─────────────────────────────────────────────────────────────
  List<EditorObject> _objects = [];
  List<EditorLayer>  _layers  = [];

  // Viewport transform: canvas_pt = (screen_pt - offset) / scale
  double _tx = 0, _ty = 40, _scale = 0.35;

  // ── Selection & interaction ───────────────────────────────────────────────────
  EditorObject? _selected;
  String?       _activeTool;    // device_type being placed, or null
  String?       _activeCategory = 'Lighting';

  // Drag state
  bool    _isDragging     = false;
  String? _dragHandle;          // null=body, 'nw','n','ne','e','se','s','sw','w','rot'
  Offset? _dragStart;           // screen pos where drag started
  Offset? _objOrigin;           // object x,y when drag started
  double? _objWOrigin, _objHOrigin;

  // Pan state (two-finger / background drag)
  Offset? _panStart;
  double? _panStartTx, _panStartTy;
  double? _scaleStart;
  Offset? _scaleFocal;          // canvas pos of pinch focal at scale start

  // ── Grid / snap ──────────────────────────────────────────────────────────────
  bool   _showGrid   = true;
  bool   _snapToGrid = true;
  final double _gridSize = 20.0;

  // ── Undo / redo ──────────────────────────────────────────────────────────────
  final List<String> _history = [];
  int _histIdx = -1;

  // ── UI panels ────────────────────────────────────────────────────────────────
  bool _showLayers     = false;
  bool _showProperties = false;
  bool _showVersions   = false;
  List<EditorVersion>      _versions = [];
  List<DevicePickerEntry>  _devicePicker = [];
  List<Map<String,dynamic>> _roomPicker  = [];

  // ── Loading ──────────────────────────────────────────────────────────────────
  bool _loading = true;
  bool _saving  = false;
  bool _dirty   = false;

  // ── Background image ─────────────────────────────────────────────────────────
  // Read live, not cached — see the identical comment in map_mode_screen.dart.
  String    get _baseUrl => RuntimeConfig.instance.serverUrl;
  bool      _uploadingBg = false;
  ui.Image? _bgImage;
  String    _bgImageUrl  = '';

  // ── Layout size ──────────────────────────────────────────────────────────────
  Size _canvasSize = const Size(2000, 1500);

  @override
  void initState() {
    super.initState();
    _svc = MapService(
      getToken:   widget.authState.service.getAccessToken,
      getBaseUrl: widget.authState.service.getBaseUrl,
    );
    // _loadApartments() (and whatever loads _layout after it) already
    // triggers _loadBgImage() itself once a layout arrives — no separate
    // wait-for-baseUrl step needed now that _baseUrl is a synchronous read.
    _loadApartments();
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Data loading
  // ─────────────────────────────────────────────────────────────────────────────

  Future<void> _loadApartments() async {
    setState(() { _loading = true; });
    final list = await _svc.fetchApartments();
    if (!mounted) return;
    setState(() { _apartments = list; });

    if (widget.initialApartmentId != null) {
      final match = list.where((a) => a.id == widget.initialApartmentId).firstOrNull;
      if (match != null) {
        await _selectApartment(match);
        return;
      }
    }
    if (list.length == 1) {
      await _selectApartment(list.first);
    } else {
      setState(() { _loading = false; });
    }
  }

  Future<void> _selectApartment(ApartmentEditorEntry apt) async {
    setState(() { _loading = true; _apartment = apt; });
    final layout = await _svc.fetchLayout(apt.id);
    if (!mounted) return;

    if (layout != null) {
      _applyLayout(layout);
    } else {
      // No layout yet — start fresh
      _objects = [];
      _layers  = _defaultLayers();
      _layout  = null;
      _dirty   = false;
    }
    _resetHistory();
    // Pre-fetch device picker for PLC linking
    final (devs, rooms) = await _svc.fetchDevicePicker(apt.id);
    if (!mounted) return;
    setState(() {
      _devicePicker = devs;
      _roomPicker   = rooms;
      _loading      = false;
    });
  }

  void _applyLayout(EditorLayout layout) {
    _layout     = layout;
    _objects    = layout.objects.map((o) => o.clone()).toList();
    _layers     = layout.layers.map((l) => l.copyWith()).toList();
    _canvasSize = Size(layout.canvasWidth, layout.canvasHeight);
    _dirty      = false;
    _bgImage    = null;
    _bgImageUrl = '';
    if (layout.backgroundUrl.isNotEmpty) {
      _loadBgImage(layout.backgroundUrl);
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

  Future<void> _uploadFloorPlan() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'pdf'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.bytes == null || _apartment == null) return;

    setState(() { _uploadingBg = true; });
    try {
      final url = await _svc.uploadBackgroundFile(
        _apartment!.id, file.bytes!, file.name,
      );
      if (!mounted) return;
      if (url != null) {
        if (_layout == null) {
          // No layout yet — create one via save first
          final saved = await _svc.saveLayout(
            _apartment!.id,
            EditorLayout(
              id: 0, apartmentId: _apartment!.id,
              apartmentName: _apartment!.name,
              backgroundUrl: url,
              layers: _layers,
              objects: _objects,
            ),
          );
          if (saved != null && mounted) _applyLayout(saved);
        } else {
          setState(() {
            _layout!.backgroundUrl     = url;
            _layout!.backgroundVisible = true;
            _dirty                     = true;
          });
          _bgImageUrl = '';
          _loadBgImage(url);
        }
      }
    } finally {
      if (mounted) setState(() { _uploadingBg = false; });
    }
  }

  List<EditorLayer> _defaultLayers() => [
    EditorLayer(id: -1, name: 'Rooms',       layerType: 'walls',    sortOrder: 0),
    EditorLayer(id: -2, name: 'Lighting',    layerType: 'lighting', sortOrder: 1),
    EditorLayer(id: -3, name: 'Sensors',     layerType: 'sensors',  sortOrder: 2),
    EditorLayer(id: -4, name: 'HVAC',        layerType: 'hvac',     sortOrder: 3),
    EditorLayer(id: -5, name: 'Labels',      layerType: 'labels',   sortOrder: 4),
    EditorLayer(id: -6, name: 'Annotations', layerType: 'annotations', sortOrder: 5),
  ];

  // ─────────────────────────────────────────────────────────────────────────────
  // History (undo / redo)
  // ─────────────────────────────────────────────────────────────────────────────

  void _resetHistory() {
    _history.clear();
    _histIdx = -1;
    _pushHistory();
  }

  void _pushHistory() {
    final snap = jsonEncode(_objects.map((o) => o.toJson()).toList());
    if (_histIdx < _history.length - 1) {
      _history.removeRange(_histIdx + 1, _history.length);
    }
    _history.add(snap);
    if (_history.length > 60) _history.removeAt(0);
    _histIdx = _history.length - 1;
  }

  void _undo() {
    if (_histIdx <= 0) return;
    _histIdx--;
    _applySnapshot(_history[_histIdx]);
  }

  void _redo() {
    if (_histIdx >= _history.length - 1) return;
    _histIdx++;
    _applySnapshot(_history[_histIdx]);
  }

  void _applySnapshot(String snap) {
    final list = jsonDecode(snap) as List<dynamic>;
    setState(() {
      _objects  = list.map((e) => EditorObject.fromJson(e as Map<String, dynamic>)).toList();
      _selected = null;
      _dirty    = true;
    });
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Coordinate utilities
  // ─────────────────────────────────────────────────────────────────────────────

  Offset _screenToCanvas(Offset screen) =>
      Offset((screen.dx - _tx) / _scale, (screen.dy - _ty) / _scale);

  Offset _snap(Offset canvas) {
    if (!_snapToGrid) return canvas;
    return Offset(
      (canvas.dx / _gridSize).round() * _gridSize,
      (canvas.dy / _gridSize).round() * _gridSize,
    );
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Hit testing
  // ─────────────────────────────────────────────────────────────────────────────

  String? _handleHit(Offset canvas, EditorObject obj) {
    final handles = _handlePositions(obj);
    for (final entry in handles.entries) {
      if ((canvas - entry.value).distance <= _kHandleRadius * 1.5 / _scale) {
        return entry.key;
      }
    }
    return null;
  }

  Map<String, Offset> _handlePositions(EditorObject obj) {
    final r = Rect.fromLTWH(obj.x, obj.y, obj.width, obj.height);
    return {
      'nw':  r.topLeft,
      'n':   Offset(r.center.dx, r.top),
      'ne':  r.topRight,
      'e':   Offset(r.right, r.center.dy),
      'se':  r.bottomRight,
      's':   Offset(r.center.dx, r.bottom),
      'sw':  r.bottomLeft,
      'w':   Offset(r.left, r.center.dy),
      'rot': Offset(r.center.dx, r.top - _kRotHandleOffset),
    };
  }

  EditorObject? _objectHit(Offset canvas) {
    // Iterate in reverse (top-most rendered last)
    for (final obj in _objects.reversed) {
      final layer = _layers.where((l) => l.id == obj.layerId).firstOrNull;
      if (layer != null && (!layer.visible || layer.locked)) continue;
      final r = Rect.fromLTWH(obj.x, obj.y, obj.width, obj.height).inflate(4);
      if (r.contains(canvas)) return obj;
    }
    return null;
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Gesture handling
  // ─────────────────────────────────────────────────────────────────────────────

  void _onScaleStart(ScaleStartDetails d) {
    final canvas = _screenToCanvas(d.localFocalPoint);

    if (d.pointerCount == 1) {
      // Single touch — check handles first, then object body
      if (_selected != null) {
        _dragHandle = _handleHit(canvas, _selected!);
        if (_dragHandle != null) {
          _isDragging  = true;
          _dragStart   = canvas;
          _objOrigin   = Offset(_selected!.x, _selected!.y);
          _objWOrigin  = _selected!.width;
          _objHOrigin  = _selected!.height;
          return;
        }
      }
      final hit = _objectHit(canvas);
      if (hit != null) {
        _isDragging  = true;
        _dragHandle  = null;
        _dragStart   = canvas;
        _objOrigin   = Offset(hit.x, hit.y);
        _objWOrigin  = hit.width;
        _objHOrigin  = hit.height;
        if (_selected != hit) {
          setState(() { _selected = hit; _showProperties = true; });
        }
        return;
      }
      // Hit nothing — prepare for background pan
      _isDragging  = false;
      _dragHandle  = null;
      _panStart    = d.localFocalPoint;
      _panStartTx  = _tx;
      _panStartTy  = _ty;
    } else {
      // Multi-touch — pinch zoom
      _isDragging  = false;
      _scaleStart  = _scale;
      _scaleFocal  = canvas;
      _panStart    = d.localFocalPoint;
      _panStartTx  = _tx;
      _panStartTy  = _ty;
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_isDragging && _selected != null && _dragStart != null) {
      final canvas = _screenToCanvas(d.localFocalPoint);
      final delta  = canvas - _dragStart!;
      setState(() {
        if (_dragHandle == null) {
          // Move
          final newPos = _snap(_objOrigin! + delta);
          _selected!.x = newPos.dx;
          _selected!.y = newPos.dy;
        } else if (_dragHandle == 'rot') {
          // Rotate around object center
          final cx = _selected!.x + _selected!.width  / 2;
          final cy = _selected!.y + _selected!.height / 2;
          _selected!.rotation =
              math.atan2(canvas.dy - cy, canvas.dx - cx) * 180 / math.pi + 90;
        } else {
          // Resize
          _applyResize(_dragHandle!, delta);
        }
        _dirty = true;
      });
      return;
    }

    if (d.pointerCount >= 2 && _scaleStart != null && _scaleFocal != null) {
      // Pinch zoom + pan
      final newScale = (_scaleStart! * d.scale).clamp(_kMinScale, _kMaxScale);
      final focalScreen = d.localFocalPoint;
      setState(() {
        _scale = newScale;
        _tx    = focalScreen.dx - _scaleFocal!.dx * _scale;
        _ty    = focalScreen.dy - _scaleFocal!.dy * _scale;
      });
      return;
    }

    if (_panStart != null && _panStartTx != null) {
      // Background pan
      final delta = d.localFocalPoint - _panStart!;
      setState(() {
        _tx = _panStartTx! + delta.dx;
        _ty = _panStartTy! + delta.dy;
      });
    }
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_isDragging && _dirty) _pushHistory();
    _isDragging  = false;
    _dragHandle  = null;
    _dragStart   = null;
    _panStart    = null;
    _scaleStart  = null;
    _scaleFocal  = null;
  }

  void _onTapUp(TapUpDetails d) {
    final canvas = _screenToCanvas(d.localPosition);

    // Placing a tool
    if (_activeTool != null && _apartment != null) {
      HapticFeedback.lightImpact();
      final pos = _snap(canvas);
      final isRoom   = _activeTool == 'room';
      final newObj   = EditorObject(
        objectType: isRoom ? 'room' : 'device',
        deviceType: isRoom ? '' : _activeTool!,
        name:       _toolLabel(_activeTool!),
        x: isRoom ? pos.dx - _kRoomDefaultW / 2 : pos.dx - _kDefaultObjW / 2,
        y: isRoom ? pos.dy - _kRoomDefaultH / 2 : pos.dy - _kDefaultObjH / 2,
        width:  isRoom ? _kRoomDefaultW : _kDefaultObjW,
        height: isRoom ? _kRoomDefaultH : _kDefaultObjH,
        layerId: _defaultLayerFor(_activeTool!),
        color:   _defaultColorFor(_activeTool!),
      );
      setState(() {
        _objects.add(newObj);
        _selected       = newObj;
        _showProperties = true;
        _activeTool     = null;
        _dirty          = true;
      });
      _pushHistory();
      return;
    }

    // Selecting
    final hit = _objectHit(canvas);
    setState(() {
      if (hit != null) {
        _selected       = hit;
        _showProperties = true;
      } else {
        _selected       = null;
        _showProperties = false;
      }
    });
  }

  void _applyResize(String handle, Offset delta) {
    final obj = _selected!;
    double x = _objOrigin!.dx, y = _objOrigin!.dy;
    double w = _objWOrigin!,   h = _objHOrigin!;

    switch (handle) {
      case 'nw': x += delta.dx; y += delta.dy; w -= delta.dx; h -= delta.dy;
      case 'n':                  y += delta.dy;                h -= delta.dy;
      case 'ne':                 y += delta.dy; w += delta.dx; h -= delta.dy;
      case 'e':                               w += delta.dx;
      case 'se':                              w += delta.dx; h += delta.dy;
      case 's':                                              h += delta.dy;
      case 'sw': x += delta.dx;              w -= delta.dx; h += delta.dy;
      case 'w':  x += delta.dx;              w -= delta.dx;
    }
    const minSize = 16.0;
    obj.x = x; obj.y = y;
    obj.width  = w.clamp(minSize, 4000);
    obj.height = h.clamp(minSize, 4000);
  }

  String _toolLabel(String type) {
    for (final cat in _kDeviceCategories.values) {
      for (final d in cat) {
        if (d.type == type) return d.label;
      }
    }
    return type;
  }

  int? _defaultLayerFor(String deviceType) {
    if (deviceType == 'room') {
      return _layers.where((l) => l.layerType == 'walls').firstOrNull?.id;
    }
    const lightTypes = {'ceiling_light','pendant_light','led_strip','relay_light'};
    if (lightTypes.contains(deviceType)) {
      return _layers.where((l) => l.layerType == 'lighting').firstOrNull?.id;
    }
    const sensorTypes = {'door_sensor','window_sensor','presence_sensor','smoke_detector','heat_detector','leak_sensor'};
    if (sensorTypes.contains(deviceType)) {
      return _layers.where((l) => l.layerType == 'sensors').firstOrNull?.id;
    }
    const hvacTypes = {'hvac','thermostat','temperature_sensor','humidity_sensor'};
    if (hvacTypes.contains(deviceType)) {
      return _layers.where((l) => l.layerType == 'hvac').firstOrNull?.id;
    }
    return _layers.firstOrNull?.id;
  }

  String _defaultColorFor(String deviceType) {
    for (final cat in _kDeviceCategories.values) {
      for (final d in cat) {
        if (d.type == deviceType) {
          return '#${(d.color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
        }
      }
    }
    return '#5BA8FF';
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Save / publish
  // ─────────────────────────────────────────────────────────────────────────────

  ({List<String> errors, List<String> warnings}) _validateLayout() {
    final errors   = <String>[];
    final warnings = <String>[];
    final devObjs  = _objects.where((o) => o.objectType == 'device');

    // Duplicate PLC variables
    final plcSeen = <String, List<EditorObject>>{};
    for (final o in devObjs) {
      if (o.plcVariable.isEmpty) continue;
      (plcSeen[o.plcVariable] ??= []).add(o);
    }
    for (final entry in plcSeen.entries) {
      if (entry.value.length > 1) {
        final names = entry.value
            .map((o) => o.name.isEmpty ? o.deviceType : o.name)
            .join(', ');
        errors.add('Duplicate PLC variable "${entry.key}" used by: $names');
      }
    }

    // Missing PLC link on controllable devices
    const needsLink = {
      'ceiling_light', 'pendant_light', 'led_strip', 'relay_light',
      'curtain', 'blind',
    };
    for (final o in devObjs) {
      if (!needsLink.contains(o.deviceType)) continue;
      if (o.plcVariable.isEmpty && o.apartmentDeviceId == null) {
        final label = o.name.isEmpty ? o.deviceType : o.name;
        warnings.add('"$label" has no PLC variable or device link');
      }
    }

    return (errors: errors, warnings: warnings);
  }

  Future<void> _save() async {
    if (_apartment == null) return;

    final validation = _validateLayout();
    if (validation.errors.isNotEmpty) {
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF0F1525),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('Cannot Save', style: AppText.h2),
          content: Text(
            validation.errors.join('\n\n'),
            style: AppText.small.copyWith(color: C.textSec),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Fix Issues',
                  style: AppText.small.copyWith(color: C.accent)),
            ),
          ],
        ),
      );
      return;
    }

    if (validation.warnings.isNotEmpty) {
      _showSnack(
        '${validation.warnings.length} device(s) have no PLC link',
        isError: false,
      );
    }

    setState(() { _saving = true; });
    HapticFeedback.mediumImpact();

    final toSave = (_layout ?? EditorLayout(
      id: 0, apartmentId: _apartment!.id, apartmentName: _apartment!.name,
    ))
      ..objects = _objects
      ..layers  = _layers;

    final saved = await _svc.saveLayout(_apartment!.id, toSave);
    if (!mounted) return;
    if (saved != null) {
      _applyLayout(saved);
      _pushHistory();
      _showSnack('Layout saved', isError: false);
    } else {
      _showSnack('Save failed — check connection', isError: true);
    }
    setState(() { _saving = false; _dirty = false; });
  }

  Future<void> _publish() async {
    if (_apartment == null) return;
    if (_dirty) await _save();
    if (!mounted) return;
    final ok = await _svc.publish(_apartment!.id, description: 'Published from editor');
    if (!mounted) return;
    if (ok) {
      _showSnack('Published ✓ — residents will see the updated map', isError: false);
    } else {
      _showSnack('Publish failed', isError: true);
    }
  }

  Future<void> _loadVersions() async {
    if (_apartment == null) return;
    final versions = await _svc.fetchVersions(_apartment!.id);
    if (!mounted) return;
    setState(() { _versions = versions; _showVersions = true; });
  }

  void _showSnack(String msg, {required bool isError}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.inter(fontSize: 13, color: Colors.white)),
      backgroundColor: isError ? C.red : C.green,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Keyboard shortcuts (delete, undo, redo)
  // ─────────────────────────────────────────────────────────────────────────────

  void _deleteSelected() {
    if (_selected == null) return;
    setState(() {
      _objects.remove(_selected);
      _selected       = null;
      _showProperties = false;
      _dirty          = true;
    });
    _pushHistory();
    HapticFeedback.selectionClick();
  }

  void _duplicateSelected() {
    if (_selected == null) return;
    final clone  = _selected!.clone();
    clone.id     = null;
    clone.x     += 20;
    clone.y     += 20;
    setState(() {
      _objects.add(clone);
      _selected = clone;
      _dirty    = true;
    });
    _pushHistory();
    HapticFeedback.lightImpact();
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080B12),
      body: _loading
          ? _buildLoading()
          : _apartments.isEmpty
              ? _buildNoApartments()
              : _apartment == null
                  ? _buildApartmentPicker()
                  : _buildEditor(),
    );
  }

  Widget _buildLoading() => const Center(
    child: CircularProgressIndicator(color: C.accent, strokeWidth: 2),
  );

  Widget _buildNoApartments() => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.apartment_rounded, size: 48, color: C.textTri),
      const SizedBox(height: 12),
      Text('No apartments found', style: AppText.body.copyWith(color: C.textSec)),
      const SizedBox(height: 6),
      Text('Create an apartment in the admin panel first.',
          style: AppText.small.copyWith(color: C.textTri)),
    ]),
  );

  Widget _buildApartmentPicker() {
    return Column(children: [
      SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(children: [
            _EditorBack(onClose: widget.onClose),
            const SizedBox(width: 10),
            Text('Map Editor', style: AppText.h2.copyWith(fontSize: 17)),
          ]),
        ),
      ),
      const SizedBox(height: 8),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text('Select an apartment to edit',
            style: AppText.small.copyWith(color: C.textSec)),
      ),
      const SizedBox(height: 8),
      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: _apartments.length,
          itemBuilder: (_, i) {
            final a = _apartments[i];
            return _AptCard(entry: a, onTap: () => _selectApartment(a));
          },
        ),
      ),
    ]);
  }

  Widget _buildEditor() {
    return Stack(children: [
      // ── Canvas ─────────────────────────────────────────────────────────────
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart:  _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onScaleEnd:    _onScaleEnd,
          onTapUp:       _onTapUp,
          child: CustomPaint(
            painter: _CanvasPainter(
              objects:   _objects,
              layers:    _layers,
              selected:  _selected,
              tx: _tx, ty: _ty, scale: _scale,
              canvasW: _canvasSize.width, canvasH: _canvasSize.height,
              showGrid:  _showGrid,
              gridSize:  _gridSize,
              bgUrl:     _layout?.backgroundUrl ?? '',
              bgImage:   _bgImage,
              bgX: _layout?.backgroundX ?? 0, bgY: _layout?.backgroundY ?? 0,
              bgW: _layout?.backgroundWidth  ?? _canvasSize.width,
              bgH: _layout?.backgroundHeight ?? _canvasSize.height,
              bgOpacity: _layout?.backgroundOpacity ?? 0.25,
              bgVisible: _layout?.backgroundVisible ?? true,
              activeTool: _activeTool,
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),

      // ── Top toolbar ────────────────────────────────────────────────────────
      Positioned(
        top: 0, left: 0, right: 0,
        child: _Toolbar(
          apartmentName: _apartment?.name ?? '',
          dirty: _dirty, saving: _saving,
          showGrid:   _showGrid,
          snapToGrid: _snapToGrid,
          canUndo: _histIdx > 0,
          canRedo: _histIdx < _history.length - 1,
          onBack:       () {
            setState(() { _apartment = null; });
          },
          onToggleGrid: () => setState(() => _showGrid   = !_showGrid),
          onToggleSnap: () => setState(() => _snapToGrid = !_snapToGrid),
          onUndo:       _undo,
          onRedo:       _redo,
          onLayers:     () => setState(() => _showLayers = !_showLayers),
          onSave:       _save,
          onPublish:    _publish,
          onVersions:   _loadVersions,
          onApartments: () => setState(() { _apartment = null; }),
        ),
      ),

      // ── Toolbox (bottom) ───────────────────────────────────────────────────
      if (!_showProperties && !_showLayers && !_showVersions)
        Positioned(
          bottom: 0, left: 0, right: 0,
          child: _Toolbox(
            activeCategory: _activeCategory,
            activeTool:     _activeTool,
            onCategoryTap: (cat) => setState(() {
              _activeCategory = cat;
              _activeTool     = null;
            }),
            onToolTap: (type) => setState(() {
              _activeTool = _activeTool == type ? null : type;
              _selected   = null;
              _showProperties = false;
            }),
          ),
        ),

      // ── Properties panel ───────────────────────────────────────────────────
      if (_showProperties && _selected != null)
        Positioned(
          bottom: 0, left: 0, right: 0,
          child: _PropertiesPanel(
            obj:          _selected!,
            rooms:        _roomPicker,
            devices:      _devicePicker,
            layers:       _layers,
            onChanged:    () => setState(() { _dirty = true; }),
            onDelete:     _deleteSelected,
            onDuplicate:  _duplicateSelected,
            onClose:      () => setState(() { _showProperties = false; _selected = null; }),
            onCommit:     _pushHistory,
          ),
        ),

      // ── Layers panel ───────────────────────────────────────────────────────
      if (_showLayers)
        Positioned(
          bottom: 0, left: 0, right: 0,
          child: _LayersPanel(
            layers:          _layers,
            onVisibilityToggle: (l) => setState(() { l.visible = !l.visible; }),
            onLockToggle:    (l) => setState(() { l.locked = !l.locked; }),
            onClose:         () => setState(() { _showLayers = false; }),
          ),
        ),

      // ── Versions panel ─────────────────────────────────────────────────────
      if (_showVersions)
        Positioned(
          bottom: 0, left: 0, right: 0,
          child: _VersionsPanel(
            versions: _versions,
            onRestore: (v) async {
              setState(() { _showVersions = false; _loading = true; });
              final restored = await _svc.restoreVersion(_apartment!.id, v.id);
              if (!mounted) return;
              if (restored != null) {
                _applyLayout(restored);
                _resetHistory();
                _showSnack('Restored to v${v.versionNumber}', isError: false);
              }
              setState(() { _loading = false; });
            },
            onClose: () => setState(() { _showVersions = false; }),
          ),
        ),

      // ── Active tool label ──────────────────────────────────────────────────
      if (_activeTool != null)
        Positioned(
          top: 72, left: 0, right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color:        C.accent.withAlpha(220),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                'Tap canvas to place  ${_toolLabel(_activeTool!)}',
                style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.black),
              ),
            ),
          ),
        ),

      // ── Floating action (selected object quick actions) ────────────────────
      if (_selected != null && !_showProperties)
        Positioned(
          right: 12,
          bottom: _showLayers || _showVersions ? 220 : 160,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _FabBtn(icon: Icons.tune_rounded, onTap: () => setState(() => _showProperties = true)),
            const SizedBox(height: 8),
            _FabBtn(icon: Icons.content_copy_rounded, onTap: _duplicateSelected),
            const SizedBox(height: 8),
            _FabBtn(icon: Icons.delete_outline_rounded, color: C.red, onTap: _deleteSelected),
          ]),
        ),

      // ── Floor plan upload FAB ──────────────────────────────────────────────
      if (_selected == null && _activeTool == null && _apartment != null)
        Positioned(
          right: 12,
          bottom: _showLayers || _showVersions ? 220 : 160,
          child: _uploadingBg
              ? const SizedBox(
                  width: 36, height: 36,
                  child: CircularProgressIndicator(strokeWidth: 2, color: C.accent),
                )
              : _FabBtn(
                  icon: Icons.image_outlined,
                  onTap: _uploadFloorPlan,
                  color: const Color(0xFF7B8FF5),
                ),
        ),
    ]);
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Canvas Painter
// ═══════════════════════════════════════════════════════════════════════════════

class _CanvasPainter extends CustomPainter {
  final List<EditorObject> objects;
  final List<EditorLayer>  layers;
  final EditorObject?      selected;
  final double tx, ty, scale;
  final double canvasW, canvasH;
  final bool   showGrid;
  final double gridSize;
  final String    bgUrl;
  final ui.Image? bgImage;
  final double bgX, bgY, bgW, bgH, bgOpacity;
  final bool   bgVisible;
  final String? activeTool;

  _CanvasPainter({
    required this.objects, required this.layers, required this.selected,
    required this.tx, required this.ty, required this.scale,
    required this.canvasW, required this.canvasH,
    required this.showGrid, required this.gridSize,
    required this.bgUrl, required this.bgImage,
    required this.bgX, required this.bgY,
    required this.bgW, required this.bgH, required this.bgOpacity,
    required this.bgVisible, required this.activeTool,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Background
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF080B12));

    canvas.save();
    canvas.translate(tx, ty);
    canvas.scale(scale);

    // Canvas boundary
    canvas.drawRect(
      Rect.fromLTWH(0, 0, canvasW, canvasH),
      Paint()..color = const Color(0xFF0D1020),
    );
    canvas.drawRect(
      Rect.fromLTWH(0, 0, canvasW, canvasH),
      Paint()
        ..color = const Color(0xFF1E2540)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 / scale,
    );

    // Background image
    if (bgVisible) {
      if (bgImage != null) {
        canvas.saveLayer(
          Rect.fromLTWH(bgX, bgY, bgW, bgH),
          Paint()..color = Color.fromRGBO(255, 255, 255, bgOpacity.clamp(0.0, 1.0)),
        );
        canvas.drawImageRect(
          bgImage!,
          Rect.fromLTWH(0, 0, bgImage!.width.toDouble(), bgImage!.height.toDouble()),
          Rect.fromLTWH(bgX, bgY, bgW, bgH),
          Paint(),
        );
        canvas.restore();
      } else if (bgUrl.isNotEmpty) {
        // Guide placeholder shown while image is loading
        canvas.drawRect(
          Rect.fromLTWH(bgX, bgY, bgW, bgH),
          Paint()..color = Color(0xFF1A2030).withValues(alpha: bgOpacity * 0.6),
        );
        canvas.drawRect(
          Rect.fromLTWH(bgX, bgY, bgW, bgH),
          Paint()
            ..color = Color(0xFF2A3A5A).withValues(alpha: bgOpacity)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1 / scale,
        );
        _drawText(canvas, 'Loading background…', Offset(bgX + 8, bgY + 8),
            fontSize: 10, color: const Color(0xFF3A4A6A));
      }
    }

    // Grid
    if (showGrid) _drawGrid(canvas);

    // Objects by layer order
    final visibleLayers = layers.where((l) => l.visible).map((l) => l.id).toSet();
    final byLayer = <int?, List<EditorObject>>{};
    for (final obj in objects) {
      (byLayer[obj.layerId] ??= []).add(obj);
    }
    for (final layer in [...layers.where((l) => l.visible)]
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder))) {
      for (final obj in (byLayer[layer.id] ?? [])) {
        _drawObject(canvas, obj, isSelected: obj == selected);
      }
    }
    // Objects with no layer
    for (final obj in (byLayer[null] ?? [])) {
      _drawObject(canvas, obj, isSelected: obj == selected);
    }
    // Objects on invisible layers are skipped — already excluded above

    // Selection handles
    if (selected != null && visibleLayers.contains(selected!.layerId)) {
      _drawHandles(canvas, selected!);
    }

    canvas.restore();
  }

  // ── Grid ──────────────────────────────────────────────────────────────────

  void _drawGrid(Canvas canvas) {
    final paint = Paint()
      ..color = const Color(0xFF1A2035)
      ..strokeWidth = 0.5 / scale;

    final startX = (0 / gridSize).floor() * gridSize;
    final startY = (0 / gridSize).floor() * gridSize;

    for (double x = startX; x <= canvasW; x += gridSize) {
      canvas.drawLine(Offset(x, 0), Offset(x, canvasH), paint);
    }
    for (double y = startY; y <= canvasH; y += gridSize) {
      canvas.drawLine(Offset(0, y), Offset(canvasW, y), paint);
    }
    // Major grid lines every 100 units
    final majorPaint = Paint()
      ..color = const Color(0xFF1E2B45)
      ..strokeWidth = 1.0 / scale;
    for (double x = 0; x <= canvasW; x += 100) {
      canvas.drawLine(Offset(x, 0), Offset(x, canvasH), majorPaint);
    }
    for (double y = 0; y <= canvasH; y += 100) {
      canvas.drawLine(Offset(0, y), Offset(canvasW, y), majorPaint);
    }
  }

  // ── Object rendering ───────────────────────────────────────────────────────

  void _drawObject(Canvas canvas, EditorObject obj, {required bool isSelected}) {
    if (obj.objectType == 'room') {
      _drawRoom(canvas, obj, isSelected: isSelected);
    } else if (obj.objectType == 'device') {
      _drawDevice(canvas, obj, isSelected: isSelected);
    } else if (obj.objectType == 'label') {
      _drawLabel(canvas, obj, isSelected: isSelected);
    }
  }

  void _drawRoom(Canvas canvas, EditorObject obj, {required bool isSelected}) {
    final r     = Rect.fromLTWH(obj.x, obj.y, obj.width, obj.height);
    final color = _parseColor(obj.color, const Color(0xFF5BA8FF));
    final rr    = RRect.fromRectAndRadius(r, const Radius.circular(4));

    canvas.drawRRect(rr, Paint()..color = color.withAlpha(isSelected ? 35 : 20));
    canvas.drawRRect(rr, Paint()
      ..color = isSelected ? color.withAlpha(220) : color.withAlpha(120)
      ..style = PaintingStyle.stroke
      ..strokeWidth = (isSelected ? 1.5 : 1.0) / scale);

    if (obj.labelVisible && obj.name.isNotEmpty) {
      _drawText(
        canvas, obj.name,
        Offset(r.left + r.width / 2, r.top + r.height / 2),
        fontSize:  11,
        color:     color.withAlpha(isSelected ? 230 : 160),
        bold:      isSelected,
        centered:  true,
      );
    }
  }

  void _drawDevice(Canvas canvas, EditorObject obj, {required bool isSelected}) {
    final cx    = obj.x + obj.width  / 2;
    final cy    = obj.y + obj.height / 2;
    final r     = math.min(obj.width, obj.height) / 2;
    final color = _parseColor(obj.color, C.accent);
    final center = Offset(cx, cy);

    // Glow
    if (isSelected) {
      canvas.drawCircle(center, r * 1.4,
          Paint()
            ..color = color.withAlpha(40)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.6));
    }

    // Background circle
    canvas.drawCircle(center, r,
        Paint()..color = color.withAlpha(isSelected ? 55 : 30));
    canvas.drawCircle(center, r,
        Paint()
          ..color = color.withAlpha(isSelected ? 220 : 140)
          ..style = PaintingStyle.stroke
          ..strokeWidth = (isSelected ? 1.5 : 1.0) / scale);

    // Icon
    final def = _defFor(obj.deviceType);
    if (def != null) {
      _drawIcon(canvas, def.icon, center, r * 1.1, color.withAlpha(isSelected ? 255 : 200));
    }

    // Label
    if (obj.labelVisible && obj.name.isNotEmpty) {
      _drawText(
        canvas, obj.name,
        Offset(cx, obj.y + obj.height + 6 / scale),
        fontSize: 8, color: color.withAlpha(isSelected ? 220 : 160),
        bold: isSelected,
        centered: true,
      );
    }
  }

  void _drawLabel(Canvas canvas, EditorObject obj, {required bool isSelected}) {
    _drawText(
      canvas, obj.name,
      Offset(obj.x, obj.y),
      fontSize: 12, color: isSelected ? C.accent : C.textSec, bold: isSelected,
    );
  }

  // ── Selection handles ──────────────────────────────────────────────────────

  void _drawHandles(Canvas canvas, EditorObject obj) {
    final r = Rect.fromLTWH(obj.x, obj.y, obj.width, obj.height);
    final hr = _kHandleRadius / scale;

    // Dashed selection border
    _drawDashedRect(canvas, r.inflate(3 / scale), C.accent.withAlpha(200), 1.5 / scale);

    // 8 resize handles
    final handles = {
      r.topLeft, Offset(r.center.dx, r.top), r.topRight,
      Offset(r.right, r.center.dy), r.bottomRight,
      Offset(r.center.dx, r.bottom), r.bottomLeft,
      Offset(r.left, r.center.dy),
    };
    final hFill   = Paint()..color = Colors.white;
    final hStroke = Paint()
      ..color = C.accent
      ..style  = PaintingStyle.stroke
      ..strokeWidth = 1.5 / scale;

    for (final h in handles) {
      canvas.drawCircle(h, hr, hFill);
      canvas.drawCircle(h, hr, hStroke);
    }

    // Rotation handle
    final rotCenter = Offset(r.center.dx, r.top - _kRotHandleOffset / scale);
    canvas.drawLine(
        Offset(r.center.dx, r.top), rotCenter,
        Paint()..color = C.accent.withAlpha(160)..strokeWidth = 1.0 / scale);
    canvas.drawCircle(rotCenter, hr * 1.2,
        Paint()..color = const Color(0xFF9F7BFA));
    canvas.drawCircle(rotCenter, hr * 1.2,
        Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.5 / scale);
  }

  void _drawDashedRect(Canvas canvas, Rect r, Color color, double strokeWidth) {
    final paint = Paint()
      ..color = color
      ..style  = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    const dash = 6.0, gap = 4.0;

    void dashedLine(Offset a, Offset b) {
      final dx = b.dx - a.dx, dy = b.dy - a.dy;
      final len = math.sqrt(dx * dx + dy * dy);
      var pos = 0.0;
      while (pos < len) {
        final end = math.min(pos + dash, len);
        canvas.drawLine(
          Offset(a.dx + dx * pos / len, a.dy + dy * pos / len),
          Offset(a.dx + dx * end / len, a.dy + dy * end / len),
          paint,
        );
        pos += dash + gap;
      }
    }
    dashedLine(r.topLeft,     r.topRight);
    dashedLine(r.topRight,    r.bottomRight);
    dashedLine(r.bottomRight, r.bottomLeft);
    dashedLine(r.bottomLeft,  r.topLeft);
  }

  // ── Icon drawing ───────────────────────────────────────────────────────────

  void _drawIcon(Canvas canvas, IconData icon, Offset center, double size, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontFamily: icon.fontFamily,
          package:    icon.fontPackage,
          fontSize:   size * 0.9,
          color:      color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  void _drawText(Canvas canvas, String text, Offset pos, {
    double fontSize = 10,
    Color color = Colors.white,
    bool bold = false,
    bool centered = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize:   fontSize / scale,
          color:      color,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 200 / scale);

    final offset = centered
        ? pos - Offset(tp.width / 2, tp.height / 2)
        : pos;
    tp.paint(canvas, offset);
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  _DeviceDef? _defFor(String deviceType) {
    for (final cat in _kDeviceCategories.values) {
      for (final d in cat) {
        if (d.type == deviceType) return d;
      }
    }
    return null;
  }

  Color _parseColor(String hex, Color fallback) {
    try {
      if (hex.startsWith('#') && hex.length >= 7) {
        return Color(int.parse('FF${hex.substring(1)}', radix: 16));
      }
    } catch (_) {}
    return fallback;
  }

  @override
  bool shouldRepaint(_CanvasPainter old) =>
      old.objects != objects || old.selected != selected ||
      old.tx != tx || old.ty != ty || old.scale != scale ||
      old.showGrid != showGrid || old.activeTool != activeTool ||
      old.bgUrl != bgUrl || old.bgImage != bgImage;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Toolbar widget
// ═══════════════════════════════════════════════════════════════════════════════

class _Toolbar extends StatelessWidget {
  final String       apartmentName;
  final bool         dirty, saving, showGrid, snapToGrid, canUndo, canRedo;
  final VoidCallback onBack, onToggleGrid, onToggleSnap, onUndo, onRedo,
                     onLayers, onSave, onPublish, onVersions, onApartments;

  const _Toolbar({
    required this.apartmentName, required this.dirty, required this.saving,
    required this.showGrid, required this.snapToGrid,
    required this.canUndo, required this.canRedo,
    required this.onBack, required this.onToggleGrid, required this.onToggleSnap,
    required this.onUndo, required this.onRedo, required this.onLayers,
    required this.onSave, required this.onPublish, required this.onVersions,
    required this.onApartments,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Container(
        height: 56,
        decoration: BoxDecoration(
          color: const Color(0xFF0D1120).withAlpha(245),
          border: const Border(bottom: BorderSide(color: C.border, width: 0.5)),
        ),
        child: Row(children: [
          const SizedBox(width: 4),
          _ToolBtn(icon: Icons.arrow_back_rounded, onTap: onBack, tooltip: 'Apartments'),
          const SizedBox(width: 4),
          Expanded(
            child: GestureDetector(
              onTap: onApartments,
              child: Text(
                apartmentName,
                style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w700,
                    color: C.textPri),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          _ToolBtn(
            icon: showGrid ? Icons.grid_on_rounded : Icons.grid_off_rounded,
            onTap: onToggleGrid, tooltip: 'Grid',
            active: showGrid, activeColor: C.accent,
          ),
          _ToolBtn(
            icon: Icons.border_inner_rounded,
            onTap: onToggleSnap, tooltip: 'Snap',
            active: snapToGrid, activeColor: C.accent,
          ),
          _ToolBtn(icon: Icons.layers_rounded, onTap: onLayers, tooltip: 'Layers'),
          _ToolBtn(icon: Icons.undo_rounded, onTap: canUndo ? onUndo : null, tooltip: 'Undo'),
          _ToolBtn(icon: Icons.redo_rounded, onTap: canRedo ? onRedo : null, tooltip: 'Redo'),
          _ToolBtn(icon: Icons.history_rounded, onTap: onVersions, tooltip: 'History'),
          _SaveBtn(saving: saving, dirty: dirty, onSave: onSave, onPublish: onPublish),
          const SizedBox(width: 4),
        ]),
      ),
    );
  }
}

class _ToolBtn extends StatelessWidget {
  final IconData     icon;
  final VoidCallback? onTap;
  final String       tooltip;
  final bool         active;
  final Color        activeColor;

  const _ToolBtn({
    required this.icon, required this.tooltip,
    this.onTap, this.active = false, this.activeColor = C.textSec,
  });

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: GestureDetector(
      onTap: onTap != null ? () {
        HapticFeedback.selectionClick();
        onTap!();
      } : null,
      child: Container(
        width: 36, height: 36,
        margin: const EdgeInsets.symmetric(horizontal: 1),
        decoration: BoxDecoration(
          color:        active ? activeColor.withAlpha(20) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon,
            size: 18,
            color: onTap == null ? C.textTri : (active ? activeColor : C.textSec)),
      ),
    ),
  );
}

class _SaveBtn extends StatelessWidget {
  final bool saving, dirty;
  final VoidCallback onSave, onPublish;
  const _SaveBtn({required this.saving, required this.dirty,
                  required this.onSave, required this.onPublish});

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      GestureDetector(
        onTap: saving ? null : onSave,
        child: AnimatedContainer(
          duration: Dur.fast,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color:        dirty ? C.accent.withAlpha(28) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: dirty ? Border.all(color: C.accent.withAlpha(80), width: 0.5) : null,
          ),
          child: saving
              ? const SizedBox(width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: C.accent))
              : Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.save_rounded, size: 15,
                      color: dirty ? C.accent : C.textTri),
                  if (dirty) ...[
                    const SizedBox(width: 4),
                    Text('Save', style: GoogleFonts.inter(
                        fontSize: 11, fontWeight: FontWeight.w700, color: C.accent)),
                  ],
                ]),
        ),
      ),
      const SizedBox(width: 2),
      GestureDetector(
        onTap: onPublish,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            gradient: G.accent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text('Publish', style: GoogleFonts.inter(
              fontSize: 11, fontWeight: FontWeight.w700, color: Colors.black)),
        ),
      ),
    ]);
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Toolbox
// ═══════════════════════════════════════════════════════════════════════════════

class _Toolbox extends StatelessWidget {
  final String?  activeCategory;
  final String?  activeTool;
  final void Function(String) onCategoryTap;
  final void Function(String) onToolTap;

  const _Toolbox({
    required this.activeCategory, required this.activeTool,
    required this.onCategoryTap, required this.onToolTap,
  });

  @override
  Widget build(BuildContext context) {
    final tools = _kDeviceCategories[activeCategory] ?? [];
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF0D1120).withAlpha(245),
          border: const Border(top: BorderSide(color: C.border, width: 0.5)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Category row
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              children: _kDeviceCategories.keys.map((cat) {
                final active = cat == activeCategory;
                return GestureDetector(
                  onTap: () => onCategoryTap(cat),
                  child: AnimatedContainer(
                    duration: Dur.fast,
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color:        active ? C.accent.withAlpha(30) : C.card,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: active ? C.accent.withAlpha(100) : C.border,
                        width: 0.5,
                      ),
                    ),
                    child: Text(cat, style: GoogleFonts.inter(
                        fontSize: 11,
                        color:  active ? C.accent : C.textSec,
                        fontWeight: active ? FontWeight.w700 : FontWeight.w400)),
                  ),
                );
              }).toList(),
            ),
          ),
          // Device chips
          SizedBox(
            height: 70,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              children: tools.map((d) {
                final isActive = d.type == activeTool;
                return GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    onToolTap(d.type);
                  },
                  child: AnimatedContainer(
                    duration: Dur.fast,
                    width: 60,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color:        isActive ? d.color.withAlpha(35) : C.card,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isActive ? d.color.withAlpha(160) : C.border,
                        width: isActive ? 1.5 : 0.5,
                      ),
                    ),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(d.icon, size: 20, color: isActive ? d.color : C.textSec),
                      const SizedBox(height: 3),
                      Text(d.label,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.inter(
                              fontSize: 9,
                              color:  isActive ? d.color : C.textTri,
                              fontWeight: isActive ? FontWeight.w700 : FontWeight.w400)),
                    ]),
                  ),
                );
              }).toList(),
            ),
          ),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Properties Panel
// ═══════════════════════════════════════════════════════════════════════════════

class _PropertiesPanel extends StatefulWidget {
  final EditorObject           obj;
  final List<Map<String,dynamic>> rooms;
  final List<DevicePickerEntry>   devices;
  final List<EditorLayer>         layers;
  final VoidCallback onChanged, onDelete, onDuplicate, onClose, onCommit;

  const _PropertiesPanel({
    required this.obj, required this.rooms, required this.devices,
    required this.layers, required this.onChanged, required this.onDelete,
    required this.onDuplicate, required this.onClose, required this.onCommit,
  });

  @override
  State<_PropertiesPanel> createState() => _PropertiesPanelState();
}

class _PropertiesPanelState extends State<_PropertiesPanel> {
  late TextEditingController _nameCtrl;
  late TextEditingController _plcCtrl;
  late TextEditingController _xCtrl, _yCtrl, _wCtrl, _hCtrl;

  @override
  void initState() {
    super.initState();
    final o = widget.obj;
    _nameCtrl = TextEditingController(text: o.name);
    _plcCtrl  = TextEditingController(text: o.plcVariable);
    _xCtrl = TextEditingController(text: o.x.toStringAsFixed(0));
    _yCtrl = TextEditingController(text: o.y.toStringAsFixed(0));
    _wCtrl = TextEditingController(text: o.width.toStringAsFixed(0));
    _hCtrl = TextEditingController(text: o.height.toStringAsFixed(0));
  }

  @override
  void dispose() {
    _nameCtrl.dispose(); _plcCtrl.dispose();
    _xCtrl.dispose(); _yCtrl.dispose(); _wCtrl.dispose(); _hCtrl.dispose();
    super.dispose();
  }

  void _commit() {
    final o = widget.obj;
    o.name         = _nameCtrl.text.trim();
    o.plcVariable  = _plcCtrl.text.trim();
    o.x = double.tryParse(_xCtrl.text) ?? o.x;
    o.y = double.tryParse(_yCtrl.text) ?? o.y;
    o.width  = double.tryParse(_wCtrl.text) ?? o.width;
    o.height = double.tryParse(_hCtrl.text) ?? o.height;
    widget.onChanged();
    widget.onCommit();
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.obj;
    return SafeArea(
      top: false,
      child: Container(
        constraints: const BoxConstraints(maxHeight: 480),
        decoration: const BoxDecoration(
          color: Color(0xFF0F1525),
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
          border: Border(top: BorderSide(color: C.border, width: 0.5)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Handle
          Container(
            margin: const EdgeInsets.only(top: 10),
            width: 32, height: 4,
            decoration: BoxDecoration(color: C.textTri.withAlpha(80),
                borderRadius: BorderRadius.circular(2)),
          ),
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(children: [
              Text('Properties', style: AppText.h2.copyWith(fontSize: 14)),
              const Spacer(),
              _PillBtn(icon: Icons.content_copy_rounded, label: 'Dup',
                  onTap: widget.onDuplicate),
              const SizedBox(width: 8),
              _PillBtn(icon: Icons.delete_outline_rounded, label: 'Delete',
                  color: C.red, onTap: widget.onDelete),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () { _commit(); widget.onClose(); },
                child: const Icon(Icons.keyboard_arrow_down_rounded,
                    color: C.textTri, size: 22),
              ),
            ]),
          ),
          const SizedBox(height: 4),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Name
                _PropField(label: 'Name', ctrl: _nameCtrl,
                    onChanged: (_) => widget.onChanged()),
                const SizedBox(height: 8),

                // Layer
                _PropRow(label: 'Layer', child: DropdownButton<int?>(
                  value: o.layerId,
                  dropdownColor: C.surface,
                  style: AppText.small.copyWith(fontSize: 12, color: C.textPri),
                  underline: const SizedBox.shrink(),
                  isDense: true,
                  onChanged: (v) { setState(() { o.layerId = v; widget.onChanged(); }); },
                  items: [
                    const DropdownMenuItem(value: null, child: Text('(none)')),
                    ...widget.layers.map((l) => DropdownMenuItem(
                      value: l.id,
                      child: Text(l.name),
                    )),
                  ],
                )),
                const SizedBox(height: 8),

                // Room
                if (widget.rooms.isNotEmpty)
                  _PropRow(label: 'Room', child: DropdownButton<int?>(
                    value: o.roomId,
                    dropdownColor: C.surface,
                    style: AppText.small.copyWith(fontSize: 12, color: C.textPri),
                    underline: const SizedBox.shrink(),
                    isDense: true,
                    onChanged: (v) {
                      setState(() {
                        o.roomId = v;
                        if (v != null) {
                          final room = widget.rooms.where((r) => r['id'] == v).firstOrNull;
                          o.roomName = room?['name'] as String?;
                        } else {
                          o.roomName = null;
                        }
                        widget.onChanged();
                      });
                    },
                    items: [
                      const DropdownMenuItem(value: null, child: Text('(none)')),
                      ...widget.rooms.map((r) => DropdownMenuItem(
                        value: r['id'] as int,
                        child: Text(r['name'] as String),
                      )),
                    ],
                  )),
                if (widget.rooms.isNotEmpty) const SizedBox(height: 8),

                // PLC Variable
                _PropField(label: 'PLC Variable', ctrl: _plcCtrl,
                    hint: 'gvlDALI.aPyLevel[1]',
                    onChanged: (_) { setState(() {}); widget.onChanged(); }),
                if (o.objectType == 'device' &&
                    _plcCtrl.text.trim().isEmpty &&
                    o.apartmentDeviceId == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 3, bottom: 2),
                    child: Row(children: [
                      const Icon(Icons.warning_amber_rounded,
                          size: 12, color: Color(0xFFFFB74D)),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          'No PLC variable or device link — not functional in Digital Twin',
                          style: AppText.small.copyWith(
                              fontSize: 10, color: const Color(0xFFFFB74D)),
                        ),
                      ),
                    ]),
                  ),
                if (widget.devices.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  _PropRow(label: 'Link Device', child: DropdownButton<int?>(
                    value: o.apartmentDeviceId,
                    dropdownColor: C.surface,
                    style: AppText.small.copyWith(fontSize: 11, color: C.textPri),
                    underline: const SizedBox.shrink(),
                    isDense: true,
                    isExpanded: true,
                    onChanged: (v) {
                      setState(() {
                        o.apartmentDeviceId = v;
                        if (v != null) {
                          final dev = widget.devices.where((d) => d.id == v).firstOrNull;
                          if (dev != null && o.plcVariable.isEmpty) {
                            o.plcVariable = dev.gvlName;
                            _plcCtrl.text  = dev.gvlName;
                          }
                        }
                        widget.onChanged();
                      });
                    },
                    items: [
                      const DropdownMenuItem(value: null, child: Text('(not linked)')),
                      ...widget.devices.map((d) => DropdownMenuItem(
                        value: d.id,
                        child: Text(d.displayLabel, overflow: TextOverflow.ellipsis),
                      )),
                    ],
                  )),
                ],
                const SizedBox(height: 8),

                // Position / size
                Row(children: [
                  Expanded(child: _PropField(label: 'X', ctrl: _xCtrl,
                      keyboardType: TextInputType.number, onChanged: (_) => widget.onChanged())),
                  const SizedBox(width: 8),
                  Expanded(child: _PropField(label: 'Y', ctrl: _yCtrl,
                      keyboardType: TextInputType.number, onChanged: (_) => widget.onChanged())),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: _PropField(label: 'Width', ctrl: _wCtrl,
                      keyboardType: TextInputType.number, onChanged: (_) => widget.onChanged())),
                  const SizedBox(width: 8),
                  Expanded(child: _PropField(label: 'Height', ctrl: _hCtrl,
                      keyboardType: TextInputType.number, onChanged: (_) => widget.onChanged())),
                ]),
                const SizedBox(height: 8),

                // Label toggle
                Row(children: [
                  Text('Show label', style: AppText.small.copyWith(color: C.textSec, fontSize: 11)),
                  const Spacer(),
                  Switch(
                    value: o.labelVisible,
                    activeThumbColor: C.accent,
                    onChanged: (v) { setState(() { o.labelVisible = v; widget.onChanged(); }); },
                  ),
                ]),

                // Apply button
                const SizedBox(height: 4),
                SizedBox(width: double.infinity,
                  child: GestureDetector(
                    onTap: _commit,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        gradient: G.accent, borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text('Apply', textAlign: TextAlign.center,
                          style: GoogleFonts.inter(
                              fontSize: 13, fontWeight: FontWeight.w700, color: Colors.black)),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

class _PropField extends StatelessWidget {
  final String              label;
  final TextEditingController ctrl;
  final String?             hint;
  final TextInputType       keyboardType;
  final void Function(String) onChanged;

  const _PropField({
    required this.label, required this.ctrl, required this.onChanged,
    this.hint, this.keyboardType = TextInputType.text,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: AppText.small.copyWith(color: C.textTri, fontSize: 10)),
      const SizedBox(height: 3),
      TextField(
        controller:  ctrl,
        onChanged:   onChanged,
        keyboardType: keyboardType,
        style:  AppText.small.copyWith(fontSize: 12, color: C.textPri),
        cursorColor: C.accent,
        decoration: InputDecoration(
          hintText:       hint,
          hintStyle: AppText.small.copyWith(fontSize: 11, color: C.textTri),
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          filled: true, fillColor: C.card,
          border:        OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: C.border, width: 0.5)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: C.border, width: 0.5)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: C.accent, width: 1)),
        ),
      ),
    ],
  );
}

class _PropRow extends StatelessWidget {
  final String label;
  final Widget child;
  const _PropRow({required this.label, required this.child});

  @override
  Widget build(BuildContext context) => Row(children: [
    Text(label, style: AppText.small.copyWith(color: C.textTri, fontSize: 10)),
    const Spacer(),
    child,
  ]);
}

class _PillBtn extends StatelessWidget {
  final IconData     icon;
  final String       label;
  final VoidCallback onTap;
  final Color        color;
  const _PillBtn({required this.icon, required this.label,
                  required this.onTap, this.color = C.accent});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color:        color.withAlpha(20),
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: color.withAlpha(60), width: 0.5),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 4),
        Text(label, style: AppText.small.copyWith(fontSize: 10, color: color,
            fontWeight: FontWeight.w600)),
      ]),
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// Layers Panel
// ═══════════════════════════════════════════════════════════════════════════════

class _LayersPanel extends StatelessWidget {
  final List<EditorLayer> layers;
  final void Function(EditorLayer) onVisibilityToggle, onLockToggle;
  final VoidCallback onClose;

  const _LayersPanel({
    required this.layers, required this.onVisibilityToggle,
    required this.onLockToggle, required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        constraints: const BoxConstraints(maxHeight: 320),
        decoration: const BoxDecoration(
          color: Color(0xFF0F1525),
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
          border: Border(top: BorderSide(color: C.border, width: 0.5)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            margin: const EdgeInsets.only(top: 10),
            width: 32, height: 4,
            decoration: BoxDecoration(color: C.textTri.withAlpha(80),
                borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(children: [
              const Icon(Icons.layers_rounded, size: 16, color: C.accent),
              const SizedBox(width: 8),
              Text('Layers', style: AppText.h2.copyWith(fontSize: 14)),
              const Spacer(),
              GestureDetector(onTap: onClose,
                  child: const Icon(Icons.keyboard_arrow_down_rounded,
                      color: C.textTri, size: 22)),
            ]),
          ),
          Flexible(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: layers.length,
              itemBuilder: (_, i) {
                final l = layers[i];
                return Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color:        C.card,
                    borderRadius: BorderRadius.circular(10),
                    border:       Border.all(color: C.border, width: 0.5),
                  ),
                  child: Row(children: [
                    Icon(_layerIcon(l.layerType), size: 15, color: C.textSec),
                    const SizedBox(width: 10),
                    Expanded(child: Text(l.name,
                        style: AppText.small.copyWith(
                            fontSize: 12,
                            color: l.visible ? C.textPri : C.textTri))),
                    GestureDetector(
                      onTap: () => onVisibilityToggle(l),
                      child: Icon(
                        l.visible ? Icons.visibility_rounded : Icons.visibility_off_rounded,
                        size: 16, color: l.visible ? C.accent : C.textTri),
                    ),
                    const SizedBox(width: 12),
                    GestureDetector(
                      onTap: () => onLockToggle(l),
                      child: Icon(
                        l.locked ? Icons.lock_rounded : Icons.lock_open_rounded,
                        size: 16, color: l.locked ? C.orange : C.textTri),
                    ),
                  ]),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }

  IconData _layerIcon(String type) {
    switch (type) {
      case 'walls':       return Icons.square_rounded;
      case 'lighting':    return Icons.light_rounded;
      case 'sensors':     return Icons.sensors_rounded;
      case 'hvac':        return Icons.ac_unit_rounded;
      case 'security':    return Icons.security_rounded;
      case 'electrical':  return Icons.power_rounded;
      case 'networking':  return Icons.wifi_rounded;
      default:            return Icons.label_rounded;
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Versions Panel
// ═══════════════════════════════════════════════════════════════════════════════

class _VersionsPanel extends StatelessWidget {
  final List<EditorVersion>           versions;
  final void Function(EditorVersion)  onRestore;
  final VoidCallback                  onClose;

  const _VersionsPanel({
    required this.versions, required this.onRestore, required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        constraints: const BoxConstraints(maxHeight: 360),
        decoration: const BoxDecoration(
          color: Color(0xFF0F1525),
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
          border: Border(top: BorderSide(color: C.border, width: 0.5)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            margin: const EdgeInsets.only(top: 10),
            width: 32, height: 4,
            decoration: BoxDecoration(color: C.textTri.withAlpha(80),
                borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(children: [
              const Icon(Icons.history_rounded, size: 16, color: C.accent),
              const SizedBox(width: 8),
              Text('Version History', style: AppText.h2.copyWith(fontSize: 14)),
              const Spacer(),
              GestureDetector(onTap: onClose,
                  child: const Icon(Icons.keyboard_arrow_down_rounded,
                      color: C.textTri, size: 22)),
            ]),
          ),
          if (versions.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text('No saved versions yet. Click Publish to create the first.',
                  style: AppText.small.copyWith(color: C.textTri),
                  textAlign: TextAlign.center),
            ),
          Flexible(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: versions.length,
              itemBuilder: (_, i) {
                final v = versions[i];
                return Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: v.isPublished ? C.green.withAlpha(15) : C.card,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: v.isPublished ? C.green.withAlpha(60) : C.border,
                      width: 0.5),
                  ),
                  child: Row(children: [
                    Container(
                      width: 32, height: 32,
                      decoration: BoxDecoration(
                        color: v.isPublished ? C.green.withAlpha(30) : C.card2,
                        shape: BoxShape.circle,
                      ),
                      child: Center(child: Text('v${v.versionNumber}',
                          style: AppText.small.copyWith(
                              fontSize: 10, fontWeight: FontWeight.w700,
                              color: v.isPublished ? C.green : C.textSec))),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(v.description.isNotEmpty ? v.description : 'Snapshot',
                            style: AppText.small.copyWith(fontSize: 12, color: C.textPri)),
                        Text('${v.createdAt.substring(0, 10)}  ·  ${v.objectCount} objects'
                            '${v.createdBy != null ? "  ·  ${v.createdBy}" : ""}',
                            style: AppText.small.copyWith(fontSize: 10, color: C.textTri)),
                      ]),
                    ),
                    if (v.isPublished)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: C.green.withAlpha(25),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('live', style: AppText.small.copyWith(
                            fontSize: 9, color: C.green, fontWeight: FontWeight.w700)),
                      ),
                    if (!v.isPublished) ...[
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () => onRestore(v),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: C.accent.withAlpha(20),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: C.accent.withAlpha(60), width: 0.5),
                          ),
                          child: Text('Restore', style: AppText.small.copyWith(
                              fontSize: 10, color: C.accent, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ],
                  ]),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Apartment picker card
// ═══════════════════════════════════════════════════════════════════════════════

class _AptCard extends StatelessWidget {
  final ApartmentEditorEntry entry;
  final VoidCallback         onTap;
  const _AptCard({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: C.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: C.border, width: 0.5),
      ),
      child: Row(children: [
        Container(
          width: 44, height: 44,
          decoration: BoxDecoration(
            color:        C.accent.withAlpha(25),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(Icons.apartment_rounded, size: 22, color: C.accent),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(entry.name, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(
              entry.hasLayout
                  ? '${entry.objectCount} objects · ${entry.isPublished ? "Published" : "Draft"}'
                  : 'No layout yet — tap to create',
              style: AppText.small.copyWith(
                  color: entry.hasLayout ? C.textSec : C.textTri, fontSize: 11),
            ),
          ]),
        ),
        Icon(
          entry.isPublished ? Icons.check_circle_rounded : Icons.edit_rounded,
          size: 16,
          color: entry.isPublished ? C.green : C.textTri,
        ),
        const SizedBox(width: 4),
        const Icon(Icons.chevron_right_rounded, size: 18, color: C.textTri),
      ]),
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// Small widgets
// ═══════════════════════════════════════════════════════════════════════════════

class _FabBtn extends StatelessWidget {
  final IconData     icon;
  final VoidCallback onTap;
  final Color        color;
  const _FabBtn({required this.icon, required this.onTap, this.color = C.accent});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 36, height: 36,
      decoration: BoxDecoration(
        color:  const Color(0xFF0F1525).withAlpha(230),
        shape:  BoxShape.circle,
        border: Border.all(color: color.withAlpha(80), width: 0.5),
      ),
      child: Icon(icon, size: 17, color: color),
    ),
  );
}

class _EditorBack extends StatelessWidget {
  final VoidCallback? onClose;
  const _EditorBack({this.onClose});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () {
      if (onClose != null) {
        onClose!();
      } else {
        Navigator.of(context).maybePop();
      }
    },
    child: Container(
      width: 34, height: 34,
      decoration: BoxDecoration(
        color: C.card, borderRadius: BorderRadius.circular(10),
        border: Border.all(color: C.border, width: 0.5),
      ),
      child: const Icon(Icons.close_rounded, size: 16, color: C.textSec),
    ),
  );
}
