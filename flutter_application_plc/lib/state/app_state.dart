import 'dart:async';
import 'package:flutter/widgets.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Snackbar event
// ─────────────────────────────────────────────────────────────────────────────

enum SnackSeverity { success, warning, error, info }

class SnackMsg {
  final String       text;
  final SnackSeverity severity;
  const SnackMsg(this.text, {this.severity = SnackSeverity.success});

  factory SnackMsg.ok(String text)   => SnackMsg(text);
  factory SnackMsg.err(String text)  => SnackMsg(text, severity: SnackSeverity.error);
  factory SnackMsg.warn(String text) => SnackMsg(text, severity: SnackSeverity.warning);
  factory SnackMsg.info(String text) => SnackMsg(text, severity: SnackSeverity.info);
}

// ─────────────────────────────────────────────────────────────────────────────
// Connection quality
// ─────────────────────────────────────────────────────────────────────────────

enum ConnectionQuality { none, poor, fair, good, excellent }

ConnectionQuality _latencyToQuality(int? ms) {
  if (ms == null) return ConnectionQuality.none;
  if (ms > 1500)  return ConnectionQuality.poor;
  if (ms > 500)   return ConnectionQuality.fair;
  if (ms > 150)   return ConnectionQuality.good;
  return ConnectionQuality.excellent;
}

// ─────────────────────────────────────────────────────────────────────────────
// AppState
// ─────────────────────────────────────────────────────────────────────────────

class AppState extends ChangeNotifier with WidgetsBindingObserver {

  // ── Config ─────────────────────────────────────────────────────────────────
  String _baseUrl;
  final Future<String?> Function()? _getAuthToken;
  final Future<String?> Function()? _refreshAuthToken;
  late ApiService _api;
  String get baseUrl => _baseUrl;

  // ── Connection ─────────────────────────────────────────────────────────────
  bool   _connected    = false;
  bool   _connecting   = true;
  int    _failStreak   = 0;
  int    _ticksSinceAttempt = 0;
  int?   _lastLatencyMs;

  bool              get connected       => _connected;
  bool              get connecting      => _connecting;
  int               get failStreak      => _failStreak;
  int?              get lastLatencyMs   => _lastLatencyMs;
  ConnectionQuality get connectionQuality =>
      _connected ? _latencyToQuality(_lastLatencyMs) : ConnectionQuality.none;

  // ── System state ───────────────────────────────────────────────────────────
  SystemState _state = SystemState.empty;
  SystemState get state => _state;

  // ── Device metadata (loaded once on connect) ───────────────────────────────
  List<DaliDevice>      _daliDevices      = [];
  List<RelayDevice>     _relayDevices     = [];
  List<CurtainDevice>   _curtainDevices   = [];
  List<ApplianceDevice> _applianceDevices = [];
  List<SensorDevice>    _doorSensors      = [];
  List<SensorDevice>    _windowSensors    = [];
  List<SensorDevice>    _motionSensors    = [];
  List<SwitchDevice>    _switchDevices    = [];
  List<String>          _rooms            = [];
  bool                  _securityAvailable = false;

  List<DaliDevice>      get daliDevices      => _daliDevices;
  List<RelayDevice>     get relayDevices     => _relayDevices;
  List<CurtainDevice>   get curtainDevices   => _curtainDevices;
  List<ApplianceDevice> get applianceDevices => _applianceDevices;
  List<SensorDevice>    get doorSensors      => _doorSensors;
  List<SensorDevice>    get windowSensors    => _windowSensors;
  List<SensorDevice>    get motionSensors    => _motionSensors;
  List<SwitchDevice>    get switchDevices    => _switchDevices;
  List<String>          get rooms            => _rooms;
  bool                  get securityAvailable => _securityAvailable;

  // ── Activity log ───────────────────────────────────────────────────────────
  final List<LogEntry> _log = [];
  List<LogEntry> get log => List.unmodifiable(_log);

  // ── Active scene ───────────────────────────────────────────────────────────
  int? _activeSceneIndex;
  int? get activeSceneIndex => _activeSceneIndex;

  // ── Snackbar stream ────────────────────────────────────────────────────────
  final _snackCtrl = StreamController<SnackMsg>.broadcast();
  Stream<SnackMsg> get snackStream => _snackCtrl.stream;

  // ── Polling ────────────────────────────────────────────────────────────────
  Timer? _poller;
  bool   _initializedDevices = false;
  bool   _paused             = false;
  // Guards against overlapping _poll() calls: a single getState() can take
  // 15-25s when the PLC is timing out, but the timer still fires every 2s
  // (or 6s backed off) regardless — without this, each tick starts a new
  // request on top of ones still in flight, unboundedly.
  bool   _polling            = false;

  static const _fastInterval = Duration(seconds: 2);

  // ── Optimistic / pending updates ───────────────────────────────────────────
  final Map<int, int>    _pendingBrightness = {};  // channel → pct
  final Map<int, bool>   _pendingRelay      = {};  // channel → on
  final Map<int, int>    _pendingCurtain    = {};  // index   → 0/1/2 cmd
  final Map<String, bool> _pendingAppliance = {};  // gvl_name → on
  bool?   _pendingAlarm;     // null = not pending
  bool?   _pendingLockdown;

  Map<int, int>    get pendingBrightness => _pendingBrightness;
  Map<int, bool>   get pendingRelay      => _pendingRelay;
  Map<int, int>    get pendingCurtain    => _pendingCurtain;
  Map<String, bool> get pendingAppliance => _pendingAppliance;

  // ── Constructor ────────────────────────────────────────────────────────────

  AppState(this._baseUrl, {
    Future<String?> Function()? getAuthToken,
    Future<String?> Function()? refreshAuthToken,
  }) : _getAuthToken = getAuthToken, _refreshAuthToken = refreshAuthToken {
    _api = ApiService(_baseUrl, tokenProvider: _getAuthToken, tokenRefresher: _refreshAuthToken);
    _addLog('Connecting to $_baseUrl');
    WidgetsBinding.instance.addObserver(this);
    _poll();
    _poller = Timer.periodic(_fastInterval, (_) {
      if (_paused) return;
      // Back off to every 3rd tick (~6s) after 3+ consecutive failures, to
      // avoid hammering a server that's down. _ticksSinceAttempt always
      // advances regardless of whether we skip, so a skipped tick can
      // never permanently freeze retries the way checking _failStreak's
      // own value directly would (_failStreak only changes inside _poll(),
      // so skipping forever would never let the skip condition clear).
      _ticksSinceAttempt++;
      final backoffTicks = _failStreak > 3 ? 3 : 1;
      if (_ticksSinceAttempt < backoffTicks) return;
      _ticksSinceAttempt = 0;
      _poll();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poller?.cancel();
    _snackCtrl.close();
    super.dispose();
  }

  // ── App lifecycle ──────────────────────────────────────────────────────────

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _paused = true;
      case AppLifecycleState.resumed:
        _paused = false;
        _poll();
      case AppLifecycleState.inactive:
        break;
    }
  }

  // ── Server URL change ──────────────────────────────────────────────────────

  void setBaseUrl(String url) {
    if (url == _baseUrl) return;
    _baseUrl            = url;
    _api                = ApiService(url, tokenProvider: _getAuthToken, tokenRefresher: _refreshAuthToken);
    _connected          = false;
    _connecting         = true;
    _failStreak         = 0;
    _lastLatencyMs      = null;
    _state              = SystemState.empty;
    _initializedDevices = false;
    _daliDevices        = [];
    _relayDevices       = [];
    _curtainDevices     = [];
    _applianceDevices   = [];
    _doorSensors        = [];
    _windowSensors      = [];
    _motionSensors      = [];
    _switchDevices      = [];
    _rooms              = [];
    _pendingBrightness.clear();
    _pendingRelay.clear();
    _pendingCurtain.clear();
    _pendingAppliance.clear();
    _pendingAlarm    = null;
    _pendingLockdown = null;
    _activeSceneIndex = null;
    _addLog('Server changed → $url');
    notifyListeners();
    _poll();
  }

  // ── Manual refresh ─────────────────────────────────────────────────────────

  Future<void> refresh() async {
    await _poll();
    if (!_initializedDevices) await _loadDevices();
  }

  // ── Polling ────────────────────────────────────────────────────────────────

  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    try {
      final result       = await _api.getState();
      final wasConnected = _connected;
      _connecting        = false;
      _lastLatencyMs     = result.latencyMs;
      _connected         = result.success;

      if (!wasConnected && _connected) {
        _failStreak = 0;
        _addLog('Connected  (${result.latencyMs}ms)');
      }
      if (wasConnected && !_connected) {
        _addLog('Connection lost', isError: true);
      }

      _failStreak = _connected ? 0 : _failStreak + 1;

      if (result.success && result.data != null) {
        _state = SystemState.fromJson(result.data!);

        // Clear optimistic updates that the server has confirmed
        _pendingBrightness.removeWhere((ch, pct) => _state.dali[ch] == pct);
        _pendingRelay.removeWhere((ch, on) => _state.relays[ch] == on);
        _pendingCurtain.removeWhere((idx, cmd) => _state.curtains[idx] == cmd);
        _pendingAppliance.removeWhere((name, on) => _state.appliances[name] == on);
        if (_pendingAlarm    != null && _state.security.armed    == _pendingAlarm!)    _pendingAlarm    = null;
        if (_pendingLockdown != null && _state.security.lockdown == _pendingLockdown!) _pendingLockdown = null;
      }

      if (_connected && !_initializedDevices) await _loadDevices();

      notifyListeners();
    } finally {
      _polling = false;
    }
  }

  Future<void> _loadDevices() async {
    final result = await _api.getDevices();
    if (!result.success || result.data == null) {
      _addLog('Failed to load device list', isError: true);
      return;
    }
    final data = result.data!;

    _daliDevices = (data['dali'] as List<dynamic>? ?? [])
        .map((e) => DaliDevice.fromJson(e as Map<String, dynamic>))
        .toList();
    _relayDevices = (data['relays'] as List<dynamic>? ?? [])
        .map((e) => RelayDevice.fromJson(e as Map<String, dynamic>))
        .toList();
    _curtainDevices = (data['curtains'] as List<dynamic>? ?? [])
        .map((e) => CurtainDevice.fromJson(e as Map<String, dynamic>))
        .toList();
    _applianceDevices = (data['appliances'] as List<dynamic>? ?? [])
        .map((e) => ApplianceDevice.fromJson(e as Map<String, dynamic>))
        .toList();
    _doorSensors = (data['door_sensors'] as List<dynamic>? ?? [])
        .map((e) => SensorDevice.fromJson(e as Map<String, dynamic>, 'door'))
        .toList();
    _windowSensors = (data['window_sensors'] as List<dynamic>? ?? [])
        .map((e) => SensorDevice.fromJson(e as Map<String, dynamic>, 'window'))
        .toList();
    _motionSensors = (data['motion_sensors'] as List<dynamic>? ?? [])
        .map((e) => SensorDevice.fromJson(e as Map<String, dynamic>, 'motion'))
        .toList();
    _switchDevices = (data['switches'] as List<dynamic>? ?? [])
        .map((e) => SwitchDevice.fromJson(e as Map<String, dynamic>))
        .toList();
    _rooms              = List<String>.from(data['rooms'] as List<dynamic>? ?? []);
    _securityAvailable  = data['security_available'] as bool? ?? false;
    _initializedDevices = true;
    _addLog(
      'Loaded ${_daliDevices.length} lights, ${_relayDevices.length} relays, '
      '${_curtainDevices.length} curtains, ${_applianceDevices.length} appliances',
    );
  }

  // ── DALI actions ───────────────────────────────────────────────────────────

  Future<void> setDaliBrightness(int channel, int pct) async {
    _pendingBrightness[channel] = pct;
    _activeSceneIndex           = null;
    notifyListeners();

    final result = await _api.setDaliBrightness(channel, pct);
    if (!result.success) {
      final msg = result.errorMessage ?? 'Command failed';
      _addLog('Ch$channel: $msg', isError: true);
      _snackCtrl.add(SnackMsg.err(msg));
      _pendingBrightness.remove(channel);
      notifyListeners();
    } else {
      _addLog('DALI ch$channel → $pct%');
    }
  }

  Future<void> setAllDaliBrightness(int pct, {int? sceneIndex}) async {
    for (final d in _daliDevices) { _pendingBrightness[d.channel] = pct; }
    _activeSceneIndex = sceneIndex;
    notifyListeners();

    final result = await _api.setAllDaliBrightness(pct);
    if (!result.success) {
      final msg = result.errorMessage ?? 'Set all failed';
      _addLog('Set all: $msg', isError: true);
      _snackCtrl.add(SnackMsg.err(msg));
      _pendingBrightness.clear();
      _activeSceneIndex = null;
      notifyListeners();
    } else {
      _addLog('All lights → $pct%');
      if (sceneIndex != null) {
        _snackCtrl.add(SnackMsg.ok('${LightScene.presets[sceneIndex].name} scene applied'));
      }
    }
  }

  Future<void> setRoomBrightness(String room, int pct) async {
    final devices = _daliDevices.where((d) => d.room == room).toList();
    for (final d in devices) { _pendingBrightness[d.channel] = pct; }
    _activeSceneIndex = null;
    notifyListeners();

    final result = await _api.setRoomBrightness(room, pct);
    if (!result.success) {
      final msg = result.errorMessage ?? 'Room command failed';
      _addLog('$room: $msg', isError: true);
      _snackCtrl.add(SnackMsg.err(msg));
      for (final d in devices) { _pendingBrightness.remove(d.channel); }
      notifyListeners();
    } else {
      _addLog('$room → $pct%');
    }
  }

  Future<void> applyScene(LightScene scene, int index) =>
      setAllDaliBrightness(scene.brightness, sceneIndex: index);

  // ── Relay actions ──────────────────────────────────────────────────────────

  Future<void> setRelay(int channel, bool on) async {
    _pendingRelay[channel] = on;
    notifyListeners();

    final result = await _api.setRelay(channel, on);
    if (!result.success) {
      final msg = result.errorMessage ?? 'Relay command failed';
      _addLog('Relay ch$channel: $msg', isError: true);
      _snackCtrl.add(SnackMsg.err(msg));
      _pendingRelay.remove(channel);
      notifyListeners();
    } else {
      _addLog('Relay ch$channel → ${on ? "ON" : "OFF"}');
    }
  }

  // ── Curtain actions ────────────────────────────────────────────────────────

  /// cmd: 0=stop, 1=up, 2=down
  Future<void> setCurtain(int index, int cmd) async {
    _pendingCurtain[index] = cmd;
    notifyListeners();

    const cmdStr = {0: 'stop', 1: 'up', 2: 'down'};
    final result = await _api.setCurtain(index, cmdStr[cmd]!);
    if (!result.success) {
      final msg = result.errorMessage ?? 'Curtain command failed';
      _addLog('Curtain $index: $msg', isError: true);
      _snackCtrl.add(SnackMsg.err(msg));
      _pendingCurtain.remove(index);
      notifyListeners();
    } else {
      _addLog('Curtain $index → ${cmdStr[cmd]}');
    }
  }

  Future<void> setCurtainAll(int cmd) async {
    for (final d in _curtainDevices) { _pendingCurtain[d.index] = cmd; }
    notifyListeners();

    const cmdStr = {0: 'stop', 1: 'up', 2: 'down'};
    final result = await _api.setCurtainAll(cmdStr[cmd]!);
    if (!result.success) {
      final msg = result.errorMessage ?? 'Curtain all failed';
      _addLog('Curtain all: $msg', isError: true);
      _snackCtrl.add(SnackMsg.err(msg));
      _pendingCurtain.clear();
      notifyListeners();
    } else {
      _addLog('All curtains → ${cmdStr[cmd]}');
    }
  }

  // ── Appliance actions ──────────────────────────────────────────────────────

  Future<void> setAppliance(String gvlName, bool on) async {
    _pendingAppliance[gvlName] = on;
    notifyListeners();

    final result = await _api.setAppliance(gvlName, on);
    if (!result.success) {
      final msg = result.errorMessage ?? 'Appliance command failed';
      _addLog('$gvlName: $msg', isError: true);
      _snackCtrl.add(SnackMsg.err(msg));
      _pendingAppliance.remove(gvlName);
      notifyListeners();
    } else {
      _addLog('$gvlName → ${on ? "ON" : "OFF"}');
    }
  }

  // ── Security actions ───────────────────────────────────────────────────────

  Future<void> setAlarm(bool armed) async {
    _pendingAlarm = armed;
    notifyListeners();

    final result = await _api.setAlarm(armed);
    if (!result.success) {
      final msg = result.errorMessage ?? 'Alarm command failed';
      _addLog('Alarm: $msg', isError: true);
      _snackCtrl.add(SnackMsg.err(msg));
      _pendingAlarm = null;
      notifyListeners();
    } else {
      _addLog('Alarm → ${armed ? "ARMED" : "DISARMED"}');
      if (armed) {
        _snackCtrl.add(SnackMsg.warn('Alarm armed'));
      }
    }
  }

  Future<void> setLockdown(bool active) async {
    _pendingLockdown = active;
    notifyListeners();

    final result = await _api.setLockdown(active);
    if (!result.success) {
      final msg = result.errorMessage ?? 'Lockdown command failed';
      _addLog('Lockdown: $msg', isError: true);
      _snackCtrl.add(SnackMsg.err(msg));
      _pendingLockdown = null;
      notifyListeners();
    } else {
      _addLog('Lockdown → ${active ? "ACTIVE" : "INACTIVE"}');
      if (active) {
        _snackCtrl.add(SnackMsg.warn('Lockdown activated — curtains closing, lights off'));
      }
    }
  }

  void clearLog() {
    _log.clear();
    notifyListeners();
  }

  // ── Computed helpers ────────────────────────────────────────────────────────

  int effectiveBrightness(int channel) =>
      _pendingBrightness[channel] ?? _state.dali[channel] ?? 0;

  bool effectiveRelay(int channel) =>
      _pendingRelay[channel] ?? _state.relays[channel] ?? false;

  int effectiveCurtain(int index) =>
      _pendingCurtain[index] ?? _state.curtains[index] ?? 0;

  bool effectiveAppliance(String gvlName) =>
      _pendingAppliance[gvlName] ?? _state.appliances[gvlName] ?? false;

  bool get effectiveAlarmArmed =>
      _pendingAlarm ?? _state.security.armed;

  bool get effectiveLockdown =>
      _pendingLockdown ?? _state.security.lockdown;

  bool get alarmTriggered => _state.security.triggered;

  int get lightsOnCount =>
      _daliDevices.where((d) => effectiveBrightness(d.channel) > 0).length;

  int get avgBrightness {
    final on = _daliDevices
        .map((d) => effectiveBrightness(d.channel))
        .where((b) => b > 0)
        .toList();
    if (on.isEmpty) return 0;
    return (on.reduce((a, b) => a + b) / on.length).round();
  }

  int roomLightsOn(String room) => _daliDevices
      .where((d) => d.room == room && effectiveBrightness(d.channel) > 0)
      .length;

  String daliName(int channel) =>
      _daliDevices.where((d) => d.channel == channel)
          .map((d) => d.name).firstOrNull ?? 'Light $channel';

  String relayName(int channel) =>
      _relayDevices.where((r) => r.channel == channel)
          .map((r) => r.name).firstOrNull ?? 'Relay $channel';

  void _addLog(String msg, {bool isError = false}) {
    _log.insert(0, LogEntry(msg, isError: isError));
    if (_log.length > 200) _log.removeLast();
  }
}
