import 'dart:async';
import 'package:flutter/widgets.dart';
import '../config/runtime_config.dart';
import '../models/connectivity_status.dart';
import '../models/device_state.dart';
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
  // AppState no longer owns its own copy of the server URL — it reads
  // RuntimeConfig.serverUrl and reacts to _onConfigChanged whenever that
  // value changes, instead of relying on some external caller to remember
  // to push a new URL in by hand (the exact bug that shipped 2026-08-20:
  // the tunnel-recovery flow updated RuntimeConfig's predecessor and
  // AuthService's own copy, but nothing told AppState, so the dashboard
  // kept polling the dead address after a successful login against the
  // corrected one). See RuntimeConfig's doc comment for the full story.
  final RuntimeConfig _config;
  final Future<String?> Function()? _getAuthToken;
  final Future<String?> Function()? _refreshAuthToken;
  late ApiService _api;
  String get baseUrl => _config.serverUrl;

  // ── Connection ─────────────────────────────────────────────────────────────
  bool   _connected    = false;
  bool   _connecting   = true;
  int    _failStreak   = 0;
  int    _ticksSinceAttempt = 0;
  int?   _lastLatencyMs;

  // WHY the last poll wasn't a clean success — the classification the old
  // bare `connected` bool couldn't express, collapsing "no apartment
  // assigned" and "PLC unplugged" and "phone has no internet" into the
  // same generic "Offline". See ConnectivityStatus doc comments for what
  // each value means and _classifyConnectivity for how a poll result
  // becomes one of them.
  ConnectivityStatus _connectivityStatus = ConnectivityStatus.connecting;
  String? _connectivityDebugDetail; // raw exception text, diagnostics only — never shown in UI

  bool              get connected       => _connected;
  bool              get connecting      => _connecting;
  int               get failStreak      => _failStreak;
  int?              get lastLatencyMs   => _lastLatencyMs;
  ConnectivityStatus get connectivityStatus => _connectivityStatus;
  String?           get connectivityDebugDetail => _connectivityDebugDetail;
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
  List<ToggleDevice>    _toggleDevices    = [];
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
  List<ToggleDevice>    get toggleDevices    => _toggleDevices;
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

  // Was 2s. Tightened to 1s — as fast as this specific PLC's ADS layer can
  // safely sustain. Went deep on this 2026-08-19: the CX8190 here is
  // Windows CE, has repeatedly proven unable to hold a stable ADS session
  // under load (hours of live debugging, documented in project memory),
  // and every read still crosses phone → internet → tunnel → server → LAN
  // → PLC and back. Sub-100ms polling would multiply load on hardware
  // that's already the bottleneck and risk the exact instability this
  // session spent hours fixing, for no perceptible UI benefit (human
  // reaction time is ~100-200ms; nothing below that is felt). Real
  // responsiveness for user actions comes from optimistic UI (every
  // setXxx() below updates state and notifies before the network call
  // even returns), not poll frequency.
  static const _fastInterval = Duration(seconds: 1);

  // ── Optimistic / pending updates ───────────────────────────────────────────
  // Deliberately in-memory only — never persisted to disk. These represent
  // "requested state" (the user tapped a switch, the write may or may not
  // have reached the PLC yet), not "confirmed state" (what _state holds,
  // straight from the server's own read of the hardware). If the app is
  // killed mid-write, the process dies with these maps — there is nothing
  // on disk claiming "the light is on" that could outlive the request that
  // would have made it true. A fresh process starts with empty maps and a
  // DeviceState.unknown/unavailable render for everything until the first
  // real _poll() confirms actual state. Do NOT add persistence here: that
  // would let a killed app resurrect an unconfirmed optimistic value as if
  // it were physical truth on relaunch — exactly the failure mode kill-
  // during-write testing (2026-08-20) exists to catch.
  final Map<int, int>    _pendingBrightness = {};  // channel → pct
  final Map<int, bool>   _pendingRelay      = {};  // channel → on
  final Map<int, int>    _pendingCurtain    = {};  // index   → 0/1/2 cmd
  final Map<String, bool> _pendingAppliance = {};  // gvl_name → on
  final Map<String, bool> _pendingToggle    = {};  // var_name → on
  bool?   _pendingAlarm;     // null = not pending
  bool?   _pendingLockdown;

  Map<int, int>    get pendingBrightness => _pendingBrightness;
  Map<int, bool>   get pendingRelay      => _pendingRelay;
  Map<int, int>    get pendingCurtain    => _pendingCurtain;
  Map<String, bool> get pendingAppliance => _pendingAppliance;
  Map<String, bool> get pendingToggle    => _pendingToggle;

  // ── Constructor ────────────────────────────────────────────────────────────

  AppState(this._config, {
    Future<String?> Function()? getAuthToken,
    Future<String?> Function()? refreshAuthToken,
  }) : _getAuthToken = getAuthToken, _refreshAuthToken = refreshAuthToken {
    _rebuildForConfig(logConnecting: true);
    WidgetsBinding.instance.addObserver(this);
    // The one and only place AppState learns the URL changed. Nothing else
    // — not login, not Settings, not the recovery sheet — talks to AppState
    // directly about the server URL anymore; they all just call
    // RuntimeConfig.setServerUrl() and this fires as a consequence. That is
    // the actual fix for "AppState kept polling the old URL": it is no
    // longer possible for a URL change to happen without AppState hearing
    // about it, because AppState is the one subscribing, not the one being
    // remembered-to-be-told.
    _config.addListener(_onConfigChanged);
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
    _config.removeListener(_onConfigChanged);
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
  //
  // RuntimeConfig is the only writer of the server URL. AppState only ever
  // reacts — see the constructor's _config.addListener(_onConfigChanged).

  void _onConfigChanged() {
    final wasUrl = _api.baseUrl;
    _rebuildForConfig(logConnecting: false);
    _addLog('Server changed → ${_config.serverUrl}  (config v${_config.version}, was $wasUrl)');
    notifyListeners();
    _poll();
  }

  /// (Re)builds the ApiService for the current RuntimeConfig value and
  /// resets every piece of state that belongs to "the old server" — device
  /// lists, pending optimistic writes, connectivity status. Called once
  /// from the constructor and again every time [_onConfigChanged] fires.
  ///
  /// Also resets [_polling] to false: a request against the *old* API
  /// instance may still be in flight when this runs. That request is not
  /// cancelled (Dart's http package has no cheap cancellation here), but
  /// _poll()'s own version check discards its result when it eventually
  /// resolves, and resetting the gate here means the discard doesn't also
  /// block the fresh poll this method triggers from ever starting.
  void _rebuildForConfig({required bool logConnecting}) {
    _api = ApiService(_config.serverUrl, tokenProvider: _getAuthToken, tokenRefresher: _refreshAuthToken);
    _polling            = false;
    _connected          = false;
    _connecting         = true;
    _connectivityStatus = ConnectivityStatus.connecting;
    _connectivityDebugDetail = null;
    _failStreak         = 0;
    _lastLatencyMs      = null;
    _state              = SystemState.empty;
    _initializedDevices = false;
    _daliDevices        = [];
    _relayDevices       = [];
    _curtainDevices     = [];
    _applianceDevices   = [];
    _toggleDevices      = [];
    _doorSensors        = [];
    _windowSensors      = [];
    _motionSensors      = [];
    _switchDevices      = [];
    _rooms              = [];
    _pendingBrightness.clear();
    _pendingRelay.clear();
    _pendingCurtain.clear();
    _pendingAppliance.clear();
    _pendingToggle.clear();
    _pendingAlarm    = null;
    _pendingLockdown = null;
    _activeSceneIndex = null;
    if (logConnecting) _addLog('Connecting to ${_config.serverUrl}');
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
    // Captured before the await — if RuntimeConfig changes while this
    // request is in flight, _config.version will have moved on by the time
    // it resolves. That response belongs to a server the user has already
    // switched away from and must never be applied, or a slow response
    // from the OLD server could silently overwrite state the NEW server
    // already reported. See RuntimeConfig's doc comment and Scenario C/F
    // in the 2026-08-20 hardening pass.
    final requestVersion = _config.version;
    try {
      final result       = await _api.getState();
      if (requestVersion != _config.version) {
        // Stale — a newer config change superseded this request while it
        // was in flight. _rebuildForConfig() already reset _polling and
        // kicked off a fresh, current poll; this one has nothing left to
        // do and must not touch _connected/_state/_polling.
        return;
      }
      final wasConnected = _connected;
      final prevStatus    = _connectivityStatus;
      _connecting        = false;
      _lastLatencyMs     = result.latencyMs;

      final serverReachable = result.success && result.data != null;
      if (serverReachable) {
        _state = SystemState.fromJson(result.data!);

        // Clear optimistic updates that the server has confirmed
        _pendingBrightness.removeWhere((ch, pct) => _state.dali[ch] == pct);
        _pendingRelay.removeWhere((ch, on) => _state.relays[ch] == on);
        _pendingCurtain.removeWhere((idx, cmd) => _state.curtains[idx] == cmd);
        _pendingAppliance.removeWhere((name, on) => _state.appliances[name] == on);
        _pendingToggle.removeWhere((name, on) => _state.toggles[name] == on);
        if (_pendingAlarm    != null && _state.security.armed    == _pendingAlarm!)    _pendingAlarm    = null;
        if (_pendingLockdown != null && _state.security.lockdown == _pendingLockdown!) _pendingLockdown = null;
      }

      // "Connected" must mean the PLC itself is reachable, not just that the
      // HTTP round trip to Django succeeded — a healthy server can still
      // return plc_connected:false (every device value null) while this
      // app happily reported "Connected" and silently rendered every null
      // device state as OFF (?? false), which is actively misleading during
      // a real outage. Found live 2026-08-20 during QA: the PLC dropped
      // mid-session and the dashboard kept showing a green "Connected"
      // badge with stale/false states the whole time.
      _connected = serverReachable && _state.plcConnected;
      _connectivityStatus = _classifyConnectivity(result, serverReachable);
      _connectivityDebugDetail = result.debugDetail;

      if (!wasConnected && _connected) {
        _failStreak = 0;
        _addLog('Connected  (${result.latencyMs}ms)');
      }
      if (prevStatus != _connectivityStatus) {
        if (_connectivityStatus != ConnectivityStatus.ok) {
          final detail = result.debugDetail;
          _addLog(
            _connectivityStatus.shortLabel +
                (detail != null ? ' ($detail)' : ''),
            isError: true,
          );
        }
      }

      _failStreak = _connected ? 0 : _failStreak + 1;

      // Device list/config comes from the DB, not live PLC data — load it
      // as soon as the server itself is reachable so the room/device grid
      // still renders during a PLC outage instead of staying empty.
      if (serverReachable && !_initializedDevices) await _loadDevices();

      notifyListeners();
    } finally {
      // Only release the gate if this is still the current config
      // generation. If a config change happened mid-request, _rebuildForConfig
      // already reset _polling (and a fresh poll may already be running
      // under it) — this stale request must not stomp on that.
      if (requestVersion == _config.version) _polling = false;
    }
  }

  /// Maps one getState() result onto a specific reason, instead of the
  /// generic "server reachable or not" the UI used to be limited to. Order
  /// matters: check the more specific backend `code` before falling back
  /// to a generic bucket keyed only on HTTP status.
  ConnectivityStatus _classifyConnectivity(
    ApiResult<Map<String, dynamic>> result, bool serverReachable,
  ) {
    if (serverReachable) {
      return _state.plcConnected ? ConnectivityStatus.ok : ConnectivityStatus.plcDown;
    }
    switch (result.errorCode) {
      case ApiErrorCode.network:
      case ApiErrorCode.timeout:
        return ConnectivityStatus.serverUnreachable;
      case ApiErrorCode.parseError:
        return ConnectivityStatus.invalidResponse;
      case ApiErrorCode.serverError:
        return ConnectivityStatus.serverError;
      case ApiErrorCode.clientError:
        switch (result.backendCode) {
          case 'UNAUTHORIZED':
            return ConnectivityStatus.authFailure;
          case 'NO_APARTMENT':
            return ConnectivityStatus.noApartment;
          case 'FORBIDDEN':
            return ConnectivityStatus.forbidden;
          case 'RATE_LIMITED':
            return ConnectivityStatus.rateLimited;
          default:
            return result.statusCode == 401
                ? ConnectivityStatus.authFailure
                : ConnectivityStatus.serverUnreachable;
        }
      case ApiErrorCode.unknown:
      case null:
        return ConnectivityStatus.serverUnreachable;
    }
  }

  Future<void> _loadDevices() async {
    final requestVersion = _config.version;
    final result = await _api.getDevices();
    // Same stale-response guard as _poll() — a slow device-list fetch
    // against the old server must not populate the room grid with the old
    // apartment's devices after the user has already switched servers.
    if (requestVersion != _config.version) return;
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
    _toggleDevices = (data['toggles'] as List<dynamic>? ?? [])
        .map((e) => ToggleDevice.fromJson(e as Map<String, dynamic>))
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
      '${_curtainDevices.length} curtains, ${_applianceDevices.length} appliances, '
      '${_toggleDevices.length} toggles',
    );
  }

  // ── DALI actions ───────────────────────────────────────────────────────────

  /// durationMs fades server-side instead of jumping instantly — caller
  /// picks dim vs. undim duration (they know the direction; AppState only
  /// tracks brightness, not the user's speed preferences, which live on
  /// AuthUser). Optimistic UI still updates immediately either way — the
  /// fade is a hardware-visible transition, not something worth delaying
  /// the on-screen slider position for.
  Future<void> setDaliBrightness(int channel, int pct, {int durationMs = 0}) async {
    _pendingBrightness[channel] = pct;
    _activeSceneIndex           = null;
    notifyListeners();

    final result = await _api.setDaliBrightness(channel, pct, durationMs: durationMs);
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

  // ── Toggle (named relay/light) actions ──────────────────────────────────────

  Future<void> setToggle(String varName, bool on) async {
    _pendingToggle[varName] = on;
    notifyListeners();

    final result = await _api.setToggle(varName, on);
    if (!result.success) {
      final msg = result.errorMessage ?? 'Command failed';
      _addLog('$varName: $msg', isError: true);
      _snackCtrl.add(SnackMsg.err(msg));
      _pendingToggle.remove(varName);
      notifyListeners();
    } else {
      _addLog('$varName → ${on ? "ON" : "OFF"}');
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
  //
  // effectiveXxx() below return a plain bool/int — kept for call sites that
  // need *some* value regardless (an onChanged handler's current position,
  // a count of lights on, fade-direction comparisons). They still resolve
  // through `?? false`/`?? 0`, which is fine for those uses, but must NEVER
  // be used to decide what a device tile visually renders — that's exactly
  // the "unknown/unavailable silently became a confident OFF" bug found
  // live 2026-08-20. For anything the user LOOKS AT, use the xxxState()
  // methods below instead, which return a DeviceState that can say
  // "unknown" or "unavailable" instead of lying with a bool.

  int effectiveBrightness(int channel) =>
      _pendingBrightness[channel] ?? _state.dali[channel] ?? 0;

  bool effectiveRelay(int channel) =>
      _pendingRelay[channel] ?? _state.relays[channel] ?? false;

  int effectiveCurtain(int index) =>
      _pendingCurtain[index] ?? _state.curtains[index] ?? 0;

  bool effectiveAppliance(String gvlName) =>
      _pendingAppliance[gvlName] ?? _state.appliances[gvlName] ?? false;

  bool effectiveToggle(String varName) =>
      _pendingToggle[varName] ?? _state.toggles[varName] ?? false;

  // ── Device state (tri/quad-state, for anything the UI RENDERS) ────────────

  DeviceState relayDeviceState(int channel) => resolveDeviceState(
        pending: _pendingRelay[channel], raw: _state.relays[channel], systemConnected: _connected,
      );

  DeviceState toggleDeviceState(String varName) => resolveDeviceState(
        pending: _pendingToggle[varName], raw: _state.toggles[varName], systemConnected: _connected,
      );

  DeviceState applianceDeviceState(String gvlName) => resolveDeviceState(
        pending: _pendingAppliance[gvlName], raw: _state.appliances[gvlName], systemConnected: _connected,
      );

  BrightnessReading daliDeviceState(int channel) => resolveBrightnessState(
        pending: _pendingBrightness[channel], raw: _state.dali[channel], systemConnected: _connected,
      );

  /// Curtains don't have a simple on/off — this only answers "do we have a
  /// trustworthy reading at all" so the curtain control can show a neutral
  /// state instead of assuming STOP when the truth is "unknown".
  DeviceState curtainDeviceState(int index) {
    if (_pendingCurtain.containsKey(index)) return DeviceState.on;
    if (!_connected) return DeviceState.unavailable;
    return _state.curtains[index] == null ? DeviceState.unknown : DeviceState.on;
  }

  /// Sensors (door/window/motion) are read-only inputs with no pending/
  /// optimistic value — same resolution, just without a pending map.
  DeviceState sensorDeviceState(bool? raw) =>
      resolveDeviceState(pending: null, raw: raw, systemConnected: _connected);

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
