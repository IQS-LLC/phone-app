import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../auth/auth_state.dart';
import '../widgets/common_widgets.dart';
import 'log_screen.dart';
import 'settings_screen.dart';

class DashboardScreen extends StatefulWidget {
  final AppState  appState;
  final AuthState authState;
  const DashboardScreen({super.key, required this.appState, required this.authState});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with TickerProviderStateMixin {

  late final AnimationController _fadeCtrl;
  late final Animation<double>   _fadeAnim;
  late final StreamSubscription<SnackMsg> _snackSub;

  // Collapsed state per room  (room name → isCollapsed)
  final Map<String, bool> _roomCollapsed = {};

  AppState get _s => widget.appState;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 500),
    )..forward();
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);

    // Subscribe to snackbar events from state
    _snackSub = _s.snackStream.listen(_showSnack);
  }

  @override
  void dispose() {
    _snackSub.cancel();
    _fadeCtrl.dispose();
    super.dispose();
  }

  void _showSnack(SnackMsg msg) {
    if (!mounted) return;
    final isErr = msg.severity == SnackSeverity.error;
    final color = switch (msg.severity) {
      SnackSeverity.error   => C.red,
      SnackSeverity.warning => C.orange,
      SnackSeverity.info    => C.blue,
      SnackSeverity.success => C.green,
    };
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Row(children: [
            Icon(
              isErr ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
              color: color, size: 16,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                msg.text,
                style: GoogleFonts.inter(
                  fontSize: 13, fontWeight: FontWeight.w500, color: C.textPri,
                ),
              ),
            ),
          ]),
          backgroundColor: C.card2,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: color.withAlpha(60)),
          ),
          duration: Duration(seconds: isErr ? 4 : 2),
          elevation: 0,
        ),
      );
  }

  bool _isCollapsed(String room) => _roomCollapsed[room] ?? false;

  void _toggleRoom(String room) {
    HapticFeedback.selectionClick();
    setState(() => _roomCollapsed[room] = !_isCollapsed(room));
  }

  // ── Page route helper ──────────────────────────────────────────────────────

  Route<T> _slideRoute<T>(Widget page) => PageRouteBuilder<T>(
    pageBuilder: (ctx, anim, secondary) => page,
    transitionsBuilder: (ctx, anim, secondary, child) => SlideTransition(
      position: Tween(begin: const Offset(1.0, 0.0), end: Offset.zero)
          .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
      child: child,
    ),
    transitionDuration: const Duration(milliseconds: 300),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _s,
    builder: (ctx, child) => FadeTransition(
      opacity: _fadeAnim,
      child: Scaffold(
        backgroundColor: C.bg,
        body: SafeArea(
          child: Column(
            children: [
              _Header(appState: _s, onLog: _goLog, onSettings: _goSettings),
              if (!_s.connected && !_s.connecting)
                OfflineBanner(serverUrl: _s.baseUrl),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    ),
  );

  void _goLog() =>
      Navigator.push(context, _slideRoute(LogScreen(appState: _s)));

  void _goSettings() => Navigator.push(
      context, _slideRoute(SettingsScreen(appState: _s, authState: widget.authState)));

  // ── Body ───────────────────────────────────────────────────────────────────

  Widget _buildBody() {
    // Loading state: connected but no devices yet
    if (_s.connected && !_s.daliDevices.isNotEmpty) {
      return _LoadingContent();
    }

    // Offline + no device metadata at all
    if (!_s.connected && _s.daliDevices.isEmpty) {
      return _buildOfflineBody();
    }

    final rooms = _s.rooms.isNotEmpty ? _s.rooms : <String>['All Lights'];

    return RefreshIndicator(
      onRefresh:       _s.refresh,
      color:           C.accent,
      strokeWidth:     2,
      backgroundColor: C.card,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics()),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SummaryBar(appState: _s),
            const SizedBox(height: 16),
            _SceneBar(appState: _s),
            const SizedBox(height: 20),
            _GlobalControls(appState: _s),
            if (_s.relayDevices.isNotEmpty) ...[
              const SizedBox(height: 20),
              _RelaysSection(appState: _s),
            ],
            if (_s.curtainDevices.isNotEmpty) ...[
              const SizedBox(height: 20),
              _CurtainsSection(appState: _s),
            ],
            if (_s.applianceDevices.isNotEmpty) ...[
              const SizedBox(height: 20),
              _AppliancesSection(appState: _s),
            ],
            if (_s.securityAvailable) ...[
              const SizedBox(height: 20),
              _SecuritySection(appState: _s),
            ],
            if (_s.doorSensors.isNotEmpty ||
                _s.windowSensors.isNotEmpty ||
                _s.motionSensors.isNotEmpty) ...[
              const SizedBox(height: 20),
              _SensorsSection(appState: _s),
            ],
            const SizedBox(height: 20),
            for (final room in rooms) ...[
              _RoomCard(
                room:      room,
                appState:  _s,
                collapsed: _isCollapsed(room),
                onToggle:  () => _toggleRoom(room),
              ),
              const SizedBox(height: 12),
            ],
            if (_s.daliDevices.isEmpty)
              _RawChannelsFallback(appState: _s),
          ],
        ),
      ),
    );
  }

  Widget _buildOfflineBody() => SingleChildScrollView(
    physics: const BouncingScrollPhysics(),
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
    child: Column(children: [
      const SizedBox(height: 40),
      EmptyState(
        icon: Icons.wifi_off_rounded,
        title: 'No connection',
        subtitle: 'Check your network and server address in Settings.',
        action: TapScale(
          onTap: _goSettings,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
            decoration: BoxDecoration(
              color:        C.accent.withAlpha(18),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: C.accent.withAlpha(60)),
            ),
            child: Text('Open Settings',
                style: GoogleFonts.inter(
                  fontSize: 13, fontWeight: FontWeight.w600, color: C.accent,
                )),
          ),
        ),
      ),
    ]),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Header
// ─────────────────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final AppState     appState;
  final VoidCallback onLog;
  final VoidCallback onSettings;
  const _Header({
    required this.appState,
    required this.onLog,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
    child: Row(
      children: [
        // Logo
        Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end:   Alignment.bottomRight,
              colors: [
                C.accent.withAlpha(30),
                C.accent.withAlpha(12),
              ],
            ),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: C.accent.withAlpha(60)),
          ),
          child: const Icon(Icons.lightbulb_outline_rounded,
              color: C.accent, size: 18),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Lugh', style: AppText.h3),
            Text('by IQS',
                style: AppText.bodySm.copyWith(fontSize: 10)),
          ],
        ),
        const Spacer(),
        // Latency chip — only shown when connected
        if (appState.connected && appState.lastLatencyMs != null)
          _LatencyChip(latencyMs: appState.lastLatencyMs!),
        if (appState.connected && appState.lastLatencyMs != null)
          const SizedBox(width: 6),
        IconBtn(icon: Icons.history_rounded,   onTap: onLog),
        const SizedBox(width: 8),
        IconBtn(icon: Icons.settings_outlined, onTap: onSettings),
        const SizedBox(width: 10),
        StatusPill(connected: appState.connected),
      ],
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Latency chip
// ─────────────────────────────────────────────────────────────────────────────

class _LatencyChip extends StatelessWidget {
  final int latencyMs;
  const _LatencyChip({required this.latencyMs});

  Color get _color {
    if (latencyMs > 1500) return C.red;
    if (latencyMs > 500)  return C.orange;
    if (latencyMs > 150)  return C.blue;
    return C.green;
  }

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 400),
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color:        _color.withAlpha(16),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: _color.withAlpha(45)),
    ),
    child: Text(
      '${latencyMs}ms',
      style: GoogleFonts.jetBrainsMono(
        fontSize: 9, fontWeight: FontWeight.w600, color: _color,
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Summary bar — "8 of 12 on · avg 65%"
// ─────────────────────────────────────────────────────────────────────────────

class _SummaryBar extends StatelessWidget {
  final AppState appState;
  const _SummaryBar({required this.appState});

  @override
  Widget build(BuildContext context) {
    final total  = appState.daliDevices.length;
    final on     = appState.lightsOnCount;
    final avg    = appState.avgBrightness;
    final mock   = appState.state.mock;

    if (total == 0) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color:        C.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: C.border),
      ),
      child: Row(children: [
        // Lights on stat
        _Stat(
          value: '$on',
          label: 'of $total on',
          color: on > 0 ? C.green : C.textTri,
        ),
        _divider(),
        // Avg brightness
        _Stat(
          value: '$avg%',
          label: 'avg brightness',
          color: on > 0 ? C.accent : C.textTri,
        ),
        _divider(),
        // Mode badge
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color:        mock ? C.orange.withAlpha(18) : C.green.withAlpha(18),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: mock ? C.orange.withAlpha(60) : C.green.withAlpha(60),
            ),
          ),
          child: Text(
            mock ? 'MOCK' : 'LIVE',
            style: GoogleFonts.inter(
              fontSize: 9, fontWeight: FontWeight.w700,
              color: mock ? C.orange : C.green,
              letterSpacing: 0.8,
            ),
          ),
        ),
      ]),
    );
  }

  Widget _divider() => Container(
    width: 1, height: 24,
    margin: const EdgeInsets.symmetric(horizontal: 12),
    color: C.border,
  );
}

class _Stat extends StatelessWidget {
  final String value;
  final String label;
  final Color  color;
  const _Stat({required this.value, required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.baseline,
    textBaseline: TextBaseline.alphabetic,
    children: [
      Text(value,
          style: GoogleFonts.inter(
            fontSize: 16, fontWeight: FontWeight.w700, color: color,
            fontFeatures: [const FontFeature.tabularFigures()],
          )),
      const SizedBox(width: 4),
      Text(label, style: AppText.bodySm.copyWith(fontSize: 10)),
    ],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Scene bar — horizontal scroll
// ─────────────────────────────────────────────────────────────────────────────

class _SceneBar extends StatelessWidget {
  final AppState appState;
  const _SceneBar({required this.appState});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SectionHeader('Scenes'),
      const SizedBox(height: 10),
      SizedBox(
        height: 40,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          itemCount: LightScene.presets.length,
          separatorBuilder: (ctx, idx) => const SizedBox(width: 8),
          itemBuilder: (_, i) {
            final scene    = LightScene.presets[i];
            final selected = appState.activeSceneIndex == i;
            return SceneChip(
              scene:    scene,
              selected: selected,
              onTap:    () => appState.applyScene(scene, i),
            );
          },
        ),
      ),
    ],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Global controls
// ─────────────────────────────────────────────────────────────────────────────

class _GlobalControls extends StatelessWidget {
  final AppState appState;
  const _GlobalControls({required this.appState});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SectionHeader('Quick Control'),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: _QuickBtn(
          label: 'All On',
          icon:  Icons.wb_sunny_rounded,
          color: C.accent,
          onTap: () => appState.setAllDaliBrightness(100),
        )),
        const SizedBox(width: 8),
        Expanded(child: _QuickBtn(
          label: 'All Off',
          icon:  Icons.nightlight_round,
          color: C.textSec,
          onTap: () => appState.setAllDaliBrightness(0),
        )),
        const SizedBox(width: 8),
        Expanded(child: _QuickBtn(
          label: '50%',
          icon:  Icons.brightness_medium_rounded,
          color: C.blue,
          onTap: () => appState.setAllDaliBrightness(50),
        )),
      ]),
    ],
  );
}

class _QuickBtn extends StatelessWidget {
  final String    label;
  final IconData  icon;
  final Color     color;
  final VoidCallback onTap;
  const _QuickBtn({
    required this.label, required this.icon,
    required this.color, required this.onTap,
  });

  @override
  Widget build(BuildContext context) => TapScale(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color:        color.withAlpha(14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(50)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(height: 5),
        Text(label,
            style: GoogleFonts.inter(
              fontSize: 11, fontWeight: FontWeight.w600, color: color,
            )),
      ]),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Relays section
// ─────────────────────────────────────────────────────────────────────────────

class _RelaysSection extends StatelessWidget {
  final AppState appState;
  const _RelaysSection({required this.appState});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SectionHeader('Wall Switches'),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8, runSpacing: 8,
        children: appState.relayDevices.map((relay) {
          final on = appState.effectiveRelay(relay.channel);
          return TapScale(
            onTap: () => appState.setRelay(relay.channel, !on),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color:        on ? C.green.withAlpha(20) : C.card,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: on ? C.green.withAlpha(100) : C.border,
                  width: on ? 1.5 : 1.0,
                ),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 8, height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: on ? C.green : C.textTri,
                    boxShadow: on ? [
                      BoxShadow(color: C.green.withAlpha(80), blurRadius: 6),
                    ] : null,
                  ),
                ),
                const SizedBox(width: 8),
                Text(relay.name,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                      color:     on ? C.green : C.textSec,
                    )),
              ]),
            ),
          );
        }).toList(),
      ),
    ],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Room card — collapsible
// ─────────────────────────────────────────────────────────────────────────────

class _RoomCard extends StatelessWidget {
  final String   room;
  final AppState appState;
  final bool     collapsed;
  final VoidCallback onToggle;
  const _RoomCard({
    required this.room, required this.appState,
    required this.collapsed, required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final devices  = appState.daliDevices.where((d) => d.room == room).toList();
    if (devices.isEmpty) return const SizedBox.shrink();

    final onCount  = appState.roomLightsOn(room);
    final total    = devices.length;

    return AppCard(
      child: Column(
        children: [
          // ── Room header ──
          GestureDetector(
            onTap: onToggle,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 13, 10, 13),
              child: Row(children: [
                // Expand/collapse chevron
                AnimatedRotation(
                  turns:    collapsed ? -0.25 : 0,
                  duration: const Duration(milliseconds: 220),
                  curve:    Curves.easeInOut,
                  child: const Icon(Icons.expand_more_rounded,
                      color: C.textSec, size: 18),
                ),
                const SizedBox(width: 8),
                Text(room, style: AppText.h3),
                const Spacer(),
                // Room-level controls (only when expanded)
                if (!collapsed) ...[
                  _RoomQuickBtn(
                    label: 'On',
                    color: C.green,
                    onTap: () => appState.setRoomBrightness(room, 100),
                  ),
                  const SizedBox(width: 6),
                  _RoomQuickBtn(
                    label: 'Off',
                    color: C.textSec,
                    onTap: () => appState.setRoomBrightness(room, 0),
                  ),
                  const SizedBox(width: 10),
                ],
                // On-count badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: onCount > 0
                        ? C.accent.withAlpha(20)
                        : C.surface,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: onCount > 0
                          ? C.accent.withAlpha(70)
                          : C.border,
                    ),
                  ),
                  child: Text('$onCount/$total',
                      style: GoogleFonts.inter(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: onCount > 0 ? C.accent : C.textSec,
                      )),
                ),
              ]),
            ),
          ),
          // ── Room body (animated) ──
          AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve:    Curves.easeInOut,
            child: collapsed
                ? const SizedBox.shrink()
                : Column(
                    children: [
                      const Divider(height: 1, color: C.border),
                      for (int i = 0; i < devices.length; i++) ...[
                        if (i > 0) const Divider(
                          height: 1, color: C.border,
                          indent: 62, endIndent: 16,
                        ),
                        _LightRow(device: devices[i], appState: appState),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _RoomQuickBtn extends StatelessWidget {
  final String       label;
  final Color        color;
  final VoidCallback onTap;
  const _RoomQuickBtn({
    required this.label, required this.color, required this.onTap,
  });

  @override
  Widget build(BuildContext context) => TapScale(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color:        color.withAlpha(16),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: color.withAlpha(55)),
      ),
      child: Text(label,
          style: GoogleFonts.inter(
            fontSize: 11, fontWeight: FontWeight.w600, color: color,
          )),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Light row — the core control element
// ─────────────────────────────────────────────────────────────────────────────

class _LightRow extends StatefulWidget {
  final DaliDevice device;
  final AppState   appState;
  const _LightRow({required this.device, required this.appState});

  @override
  State<_LightRow> createState() => _LightRowState();
}

class _LightRowState extends State<_LightRow> {
  double? _dragging;

  int get _pct =>
      _dragging?.toInt()
      ?? widget.appState.effectiveBrightness(widget.device.channel);

  Color _levelColor(int pct) {
    if (pct == 0)  return C.textTri;
    if (pct < 20)  return C.purple;
    if (pct < 40)  return C.orange;
    if (pct < 70)  return C.blue;
    return C.accent;
  }

  void _toggle() {
    HapticFeedback.lightImpact();
    final target = _pct > 0 ? 0 : 100;
    widget.appState.setDaliBrightness(widget.device.channel, target);
  }

  void _showQuickPresets() {
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: C.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _BrightnessSheet(
        device:   widget.device,
        current:  _pct,
        appState: widget.appState,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pct   = _pct;
    final color = _levelColor(pct);
    final on    = pct > 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 14, 6),
      child: Row(
        children: [
          // ── Light icon (tap = toggle, long = sheet) ──
          TapScale(
            onTap:       _toggle,
            onLongPress: _showQuickPresets,
            scale: 0.88,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: 40, height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: on ? color.withAlpha(22) : C.surface,
                border: Border.all(
                  color: on ? color.withAlpha(90) : C.border,
                  width: on ? 1.5 : 1.0,
                ),
                boxShadow: on ? [
                  BoxShadow(
                    color:      color.withAlpha((pct / 100 * 70).toInt()),
                    blurRadius: 12,
                    spreadRadius: 1,
                  ),
                ] : null,
              ),
              child: Icon(
                on ? Icons.lightbulb_rounded : Icons.lightbulb_outline_rounded,
                color: on ? color : C.textTri,
                size:  17,
              ),
            ),
          ),
          const SizedBox(width: 12),
          // ── Name + slider ──
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Text(widget.device.name,
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: on ? FontWeight.w500 : FontWeight.w400,
                          color: on ? C.textPri : C.textSec,
                        )),
                  ),
                  AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 200),
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: color,
                      fontFeatures: [const FontFeature.tabularFigures()],
                    ),
                    child: Text('$pct%'),
                  ),
                ]),
                const SizedBox(height: 2),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight:        2.5,
                    thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6),
                    activeTrackColor:   color,
                    inactiveTrackColor: on ? color.withAlpha(30) : C.border,
                    thumbColor:         color,
                    overlayColor:       color.withAlpha(18),
                    overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 16),
                  ),
                  child: Slider(
                    value:     pct.toDouble(),
                    min: 0, max: 100, divisions: 100,
                    onChanged: (v) {
                      HapticFeedback.selectionClick();
                      setState(() => _dragging = v);
                    },
                    onChangeEnd: (v) {
                      setState(() => _dragging = null);
                      widget.appState.setDaliBrightness(
                          widget.device.channel, v.toInt());
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Quick presets bottom sheet
// ─────────────────────────────────────────────────────────────────────────────

class _BrightnessSheet extends StatelessWidget {
  final DaliDevice device;
  final int        current;
  final AppState   appState;
  const _BrightnessSheet({
    required this.device,
    required this.current,
    required this.appState,
  });

  void _set(BuildContext ctx, int pct) {
    HapticFeedback.lightImpact();
    appState.setDaliBrightness(device.channel, pct);
    Navigator.pop(ctx);
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle
          Center(
            child: Container(
              width: 36, height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: C.border2, borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Row(children: [
            const Icon(Icons.lightbulb_outline_rounded,
                color: C.accent, size: 18),
            const SizedBox(width: 8),
            Text(device.name, style: AppText.h3),
            const Spacer(),
            Text('Current: $current%', style: AppText.bodySm),
          ]),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(child: _PresetTile(label: 'Off',    pct: 0,   color: C.textSec, onTap: (p) => _set(context, p))),
            const SizedBox(width: 8),
            Expanded(child: _PresetTile(label: '25%',   pct: 25,  color: C.purple,  onTap: (p) => _set(context, p))),
            const SizedBox(width: 8),
            Expanded(child: _PresetTile(label: '50%',   pct: 50,  color: C.blue,    onTap: (p) => _set(context, p))),
            const SizedBox(width: 8),
            Expanded(child: _PresetTile(label: '75%',   pct: 75,  color: C.orange,  onTap: (p) => _set(context, p))),
            const SizedBox(width: 8),
            Expanded(child: _PresetTile(label: 'Full',  pct: 100, color: C.accent,  onTap: (p) => _set(context, p))),
          ]),
        ],
      ),
    ),
  );
}

class _PresetTile extends StatelessWidget {
  final String      label;
  final int         pct;
  final Color       color;
  final void Function(int) onTap;
  const _PresetTile({
    required this.label, required this.pct,
    required this.color, required this.onTap,
  });

  @override
  Widget build(BuildContext context) => TapScale(
    onTap: () => onTap(pct),
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color:        color.withAlpha(16),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withAlpha(55)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.lightbulb_rounded, color: color, size: 16),
        const SizedBox(height: 5),
        Text(label,
            style: GoogleFonts.inter(
              fontSize: 10, fontWeight: FontWeight.w600, color: color,
            )),
      ]),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Raw channels fallback (no device metadata yet)
// ─────────────────────────────────────────────────────────────────────────────

class _RawChannelsFallback extends StatelessWidget {
  final AppState appState;
  const _RawChannelsFallback({required this.appState});

  // Last-resort degraded-mode control surface for when /plc/devices/ has
  // failed to load (so the real, backend-driven device list below is
  // empty) — not a substitute for it. 28 matches the DALI bus's actual
  // address capacity (devices.py / POU.TcPOU), not an arbitrary guess.
  static const _maxRawDaliChannels = 28;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SectionHeader('DALI Channels (raw — device list unavailable)'),
      const SizedBox(height: 10),
      AppCard(
        child: Column(
          children: List.generate(_maxRawDaliChannels, (i) {
            final ch = i + 1;
            return Column(children: [
              if (i > 0) const Divider(height: 1, color: C.border),
              _RawChannelRow(channel: ch, appState: appState),
            ]);
          }),
        ),
      ),
    ],
  );
}

class _RawChannelRow extends StatefulWidget {
  final int      channel;
  final AppState appState;
  const _RawChannelRow({required this.channel, required this.appState});

  @override
  State<_RawChannelRow> createState() => _RawChannelRowState();
}

class _RawChannelRowState extends State<_RawChannelRow> {
  double? _dragging;
  int get _pct =>
      _dragging?.toInt()
      ?? widget.appState.effectiveBrightness(widget.channel);

  @override
  Widget build(BuildContext context) {
    final pct   = _pct;
    final color = pct > 0 ? C.accent : C.textTri;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
      child: Row(children: [
        SizedBox(
          width: 40,
          child: Text('Ch ${ widget.channel}',
              style: AppText.bodySm.copyWith(fontSize: 11)),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight:      2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              activeTrackColor:   color,
              inactiveTrackColor: C.border,
              thumbColor:         color,
            ),
            child: Slider(
              value: pct.toDouble(), min: 0, max: 100, divisions: 100,
              onChanged:    (v) => setState(() => _dragging = v),
              onChangeEnd:  (v) {
                setState(() => _dragging = null);
                widget.appState.setDaliBrightness(widget.channel, v.toInt());
              },
            ),
          ),
        ),
        SizedBox(
          width: 34,
          child: Text('$pct%',
              textAlign: TextAlign.end,
              style: GoogleFonts.inter(
                fontSize: 11, fontWeight: FontWeight.w700, color: color,
                fontFeatures: [const FontFeature.tabularFigures()],
              )),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Loading skeleton
// ─────────────────────────────────────────────────────────────────────────────

class _LoadingContent extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Summary bar skeleton
        ShimmerBox(width: double.infinity, height: 54, radius: 12),
        const SizedBox(height: 16),
        // Scene bar skeleton
        const ShimmerBox(width: 80, height: 12, radius: 4),
        const SizedBox(height: 10),
        Row(children: [
          for (int i = 0; i < 4; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            ShimmerBox(width: 88, height: 40, radius: 12),
          ],
        ]),
        const SizedBox(height: 20),
        // Room card skeletons
        for (int r = 0; r < 2; r++) ...[
          ShimmerBox(width: double.infinity, height: 160, radius: 16),
          const SizedBox(height: 12),
        ],
      ],
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Curtains section
// ─────────────────────────────────────────────────────────────────────────────

class _CurtainsSection extends StatelessWidget {
  final AppState appState;
  const _CurtainsSection({required this.appState});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      // Header row with All Up / All Down / All Stop
      Row(children: [
        Expanded(child: SectionHeader('Curtains')),
        _CurtainQuickBtn(
          icon: Icons.arrow_upward_rounded, label: 'All Up',
          color: C.blue,
          onTap: () => appState.setCurtainAll(1),
        ),
        const SizedBox(width: 6),
        _CurtainQuickBtn(
          icon: Icons.stop_rounded, label: 'Stop',
          color: C.textSec,
          onTap: () => appState.setCurtainAll(0),
        ),
        const SizedBox(width: 6),
        _CurtainQuickBtn(
          icon: Icons.arrow_downward_rounded, label: 'All Down',
          color: C.orange,
          onTap: () => appState.setCurtainAll(2),
        ),
      ]),
      const SizedBox(height: 10),
      AppCard(
        child: Column(
          children: List.generate(appState.curtainDevices.length, (i) {
            final curtain = appState.curtainDevices[i];
            return Column(children: [
              if (i > 0) const Divider(
                height: 1, color: C.border, indent: 14, endIndent: 14),
              _CurtainRow(device: curtain, appState: appState),
            ]);
          }),
        ),
      ),
    ],
  );
}

class _CurtainQuickBtn extends StatelessWidget {
  final IconData     icon;
  final String       label;
  final Color        color;
  final VoidCallback onTap;
  const _CurtainQuickBtn({
    required this.icon, required this.label,
    required this.color, required this.onTap,
  });

  @override
  Widget build(BuildContext context) => TapScale(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color:        color.withAlpha(16),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withAlpha(55)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: color, size: 12),
        const SizedBox(width: 4),
        Text(label,
            style: GoogleFonts.inter(
              fontSize: 10, fontWeight: FontWeight.w600, color: color,
            )),
      ]),
    ),
  );
}

class _CurtainRow extends StatelessWidget {
  final CurtainDevice device;
  final AppState      appState;
  const _CurtainRow({required this.device, required this.appState});

  static const _stateLabels = {0: 'Stopped', 1: 'Opening', 2: 'Closing'};
  static const _stateColors = {0: C.textTri, 1: C.blue, 2: C.orange};

  @override
  Widget build(BuildContext context) {
    final state = appState.effectiveCurtain(device.index);
    final color = _stateColors[state] ?? C.textTri;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Row(children: [
        // Status dot
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 8, height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            boxShadow: state != 0
                ? [BoxShadow(color: color.withAlpha(80), blurRadius: 6)]
                : null,
          ),
        ),
        const SizedBox(width: 10),
        // Name + state
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(device.name,
                  style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w500, color: C.textPri)),
              Text('${device.room}  ·  ${_stateLabels[state] ?? ''}',
                  style: AppText.bodySm.copyWith(fontSize: 10)),
            ],
          ),
        ),
        // Up / Stop / Down buttons
        _CurtainBtn(
          icon: Icons.arrow_upward_rounded,
          color: C.blue,
          active: state == 1,
          onTap: () => appState.setCurtain(device.index, state == 1 ? 0 : 1),
        ),
        const SizedBox(width: 6),
        _CurtainBtn(
          icon: Icons.stop_rounded,
          color: C.textSec,
          active: state == 0,
          onTap: () => appState.setCurtain(device.index, 0),
        ),
        const SizedBox(width: 6),
        _CurtainBtn(
          icon: Icons.arrow_downward_rounded,
          color: C.orange,
          active: state == 2,
          onTap: () => appState.setCurtain(device.index, state == 2 ? 0 : 2),
        ),
      ]),
    );
  }
}

class _CurtainBtn extends StatelessWidget {
  final IconData     icon;
  final Color        color;
  final bool         active;
  final VoidCallback onTap;
  const _CurtainBtn({
    required this.icon, required this.color,
    required this.active, required this.onTap,
  });

  @override
  Widget build(BuildContext context) => TapScale(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 34, height: 34,
      decoration: BoxDecoration(
        color:        active ? color.withAlpha(26) : C.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: active ? color.withAlpha(100) : C.border,
          width: active ? 1.5 : 1.0,
        ),
      ),
      child: Icon(icon, color: active ? color : C.textTri, size: 16),
    ),
  );
}


// ─────────────────────────────────────────────────────────────────────────────
// Appliances section
// ─────────────────────────────────────────────────────────────────────────────

class _AppliancesSection extends StatelessWidget {
  final AppState appState;
  const _AppliancesSection({required this.appState});

  static IconData _iconFor(String gvlName) {
    return switch (gvlName) {
      'Fridge'        => Icons.kitchen_rounded,
      'CoffeeMachine' => Icons.coffee_rounded,
      'Microwave'     => Icons.microwave_rounded,
      _               => Icons.power_rounded,
    };
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SectionHeader('Appliances'),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8, runSpacing: 8,
        children: appState.applianceDevices.map((ap) {
          final on   = appState.effectiveAppliance(ap.gvlName);
          final icon = _iconFor(ap.gvlName);
          return TapScale(
            onTap: () => appState.setAppliance(ap.gvlName, !on),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color:        on ? C.green.withAlpha(20) : C.card,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: on ? C.green.withAlpha(100) : C.border,
                  width: on ? 1.5 : 1.0,
                ),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, color: on ? C.green : C.textTri, size: 16),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(ap.name,
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                          color: on ? C.green : C.textSec,
                        )),
                    Text(on ? 'On' : 'Off',
                        style: AppText.bodySm.copyWith(fontSize: 9)),
                  ],
                ),
              ]),
            ),
          );
        }).toList(),
      ),
    ],
  );
}


// ─────────────────────────────────────────────────────────────────────────────
// Security section — alarm + lockdown
// ─────────────────────────────────────────────────────────────────────────────

class _SecuritySection extends StatelessWidget {
  final AppState appState;
  const _SecuritySection({required this.appState});

  @override
  Widget build(BuildContext context) {
    final armed     = appState.effectiveAlarmArmed;
    final lockdown  = appState.effectiveLockdown;
    final triggered = appState.alarmTriggered;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader('Security'),
        const SizedBox(height: 10),

        // Alarm triggered banner
        if (triggered)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color:        C.red.withAlpha(22),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: C.red.withAlpha(100)),
            ),
            child: Row(children: [
              const Icon(Icons.warning_amber_rounded, color: C.red, size: 16),
              const SizedBox(width: 8),
              Text('Intrusion detected!',
                  style: GoogleFonts.inter(
                    fontSize: 13, fontWeight: FontWeight.w700, color: C.red,
                  )),
            ]),
          ),

        Row(children: [
          // Alarm arm/disarm
          Expanded(
            child: TapScale(
              onTap: () => appState.setAlarm(!armed),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  color: armed
                      ? C.orange.withAlpha(22)
                      : C.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: armed ? C.orange.withAlpha(120) : C.border,
                    width: armed ? 1.5 : 1.0,
                  ),
                ),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(
                    armed
                        ? Icons.lock_rounded
                        : Icons.lock_open_rounded,
                    color: armed ? C.orange : C.textSec,
                    size: 22,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    armed ? 'ARMED' : 'DISARMED',
                    style: GoogleFonts.inter(
                      fontSize: 11, fontWeight: FontWeight.w700,
                      color: armed ? C.orange : C.textSec,
                      letterSpacing: 0.8,
                    ),
                  ),
                  Text(
                    armed ? 'Tap to disarm' : 'Tap to arm',
                    style: AppText.bodySm.copyWith(fontSize: 9),
                  ),
                ]),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Lockdown
          Expanded(
            child: TapScale(
              onTap: () => appState.setLockdown(!lockdown),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  color: lockdown
                      ? C.red.withAlpha(22)
                      : C.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: lockdown ? C.red.withAlpha(120) : C.border,
                    width: lockdown ? 1.5 : 1.0,
                  ),
                ),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(
                    lockdown
                        ? Icons.shield_rounded
                        : Icons.shield_outlined,
                    color: lockdown ? C.red : C.textSec,
                    size: 22,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    lockdown ? 'LOCKDOWN' : 'NORMAL',
                    style: GoogleFonts.inter(
                      fontSize: 11, fontWeight: FontWeight.w700,
                      color: lockdown ? C.red : C.textSec,
                      letterSpacing: 0.8,
                    ),
                  ),
                  Text(
                    lockdown ? 'Tap to cancel' : 'Tap to activate',
                    style: AppText.bodySm.copyWith(fontSize: 9),
                  ),
                ]),
              ),
            ),
          ),
        ]),
      ],
    );
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// Sensors section — read-only door/window/motion display
// ─────────────────────────────────────────────────────────────────────────────

class _SensorsSection extends StatelessWidget {
  final AppState appState;
  const _SensorsSection({required this.appState});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SectionHeader('Sensors'),
      const SizedBox(height: 10),
      AppCard(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 8, runSpacing: 8,
            children: [
              for (final s in appState.doorSensors)
                _SensorChip(
                  name: s.name,
                  open: appState.state.doorSensors[s.index] ?? false,
                  icon: Icons.door_front_door_rounded,
                ),
              for (final s in appState.windowSensors)
                _SensorChip(
                  name: s.name,
                  open: appState.state.windowSensors[s.index] ?? false,
                  icon: Icons.window_rounded,
                ),
              for (final s in appState.motionSensors)
                _SensorChip(
                  name: s.name,
                  open: appState.state.motionSensors[s.index] ?? false,
                  icon: Icons.sensors_rounded,
                  openLabel: 'Motion',
                  closedLabel: 'Clear',
                ),
            ],
          ),
        ),
      ),
    ],
  );
}

class _SensorChip extends StatelessWidget {
  final String   name;
  final bool     open;
  final IconData icon;
  final String   openLabel;
  final String   closedLabel;
  const _SensorChip({
    required this.name,
    required this.open,
    required this.icon,
    this.openLabel   = 'Open',
    this.closedLabel = 'Closed',
  });

  @override
  Widget build(BuildContext context) {
    final color = open ? C.orange : C.green;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color:        color.withAlpha(14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withAlpha(open ? 80 : 40)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: color, size: 13),
        const SizedBox(width: 6),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(name,
                style: GoogleFonts.inter(
                  fontSize: 11, fontWeight: FontWeight.w500,
                  color: C.textPri,
                )),
            Text(open ? openLabel : closedLabel,
                style: GoogleFonts.inter(
                  fontSize: 9, fontWeight: FontWeight.w600,
                  color: color,
                )),
          ],
        ),
      ]),
    );
  }
}
