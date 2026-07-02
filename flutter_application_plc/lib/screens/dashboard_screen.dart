import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../auth/auth_state.dart';
import '../widgets/common_widgets.dart';
import '../state/favorites_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Dashboard Screen — the heart of the app
// Design philosophy:
//   • No uppercase section labels — visual grouping does the work
//   • Every touch target ≥48px
//   • Ambient glow on active rooms (warm, alive, inviting)
//   • Scene cards large enough to feel like real choices, not chips
//   • Light sliders colored to match brightness level
//   • Everything breathes — spacing is generous and intentional
// ─────────────────────────────────────────────────────────────────────────────

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

  final Map<String, bool> _roomCollapsed = {};
  Set<int> _favoriteChannels = {};

  AppState get _s => widget.appState;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(vsync: this, duration: Dur.enter);
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Cur.enter);
    _fadeCtrl.forward();
    _snackSub = _s.snackStream.listen(_showSnack);
    _loadFavorites();
  }

  @override
  void dispose() {
    _snackSub.cancel();
    _fadeCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadFavorites() async {
    final favs = await FavoritesService.load();
    if (mounted) setState(() => _favoriteChannels = favs);
  }

  Future<void> _toggleFavorite(int ch) async {
    HapticFeedback.mediumImpact();
    final next = Set<int>.from(_favoriteChannels);
    next.contains(ch) ? next.remove(ch) : next.add(ch);
    setState(() => _favoriteChannels = next);
    await FavoritesService.save(next);
  }

  void _showSnack(SnackMsg msg) {
    if (!mounted) return;
    AppToast.show(context, msg.text, kind: switch (msg.severity) {
      SnackSeverity.success => ToastKind.success,
      SnackSeverity.warning => ToastKind.warning,
      SnackSeverity.error   => ToastKind.error,
      SnackSeverity.info    => ToastKind.info,
    });
  }

  bool _isCollapsed(String room) => _roomCollapsed[room] ?? false;

  void _toggleRoom(String room) {
    HapticFeedback.selectionClick();
    setState(() => _roomCollapsed[room] = !_isCollapsed(room));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _s,
    builder: (_, _) => FadeTransition(
      opacity: _fadeAnim,
      child: Scaffold(
        backgroundColor: C.bg,
        body: SafeArea(
          bottom: false,
          child: Column(children: [
            _DashHeader(appState: _s, authState: widget.authState),
            if (!_s.connected && !_s.connecting) OfflineBanner(serverUrl: _s.baseUrl),
            Expanded(child: _buildBody()),
          ]),
        ),
      ),
    ),
  );

  Widget _buildBody() {
    if (_s.connected && _s.daliDevices.isEmpty) return _LoadingContent();
    if (!_s.connected && _s.daliDevices.isEmpty) return _offlineBody();

    final rooms = _s.rooms.isNotEmpty ? _s.rooms : <String>['All Lights'];

    return RefreshIndicator(
      onRefresh: _s.refresh, color: C.accent,
      backgroundColor: C.card, strokeWidth: 2,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        slivers: [
          // ── Greeting ────────────────────────────────────────────────────
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(Sp.x5, Sp.x4, Sp.x5, 0),
            sliver: SliverToBoxAdapter(
              child: _Greeting(appState: _s, authState: widget.authState),
            ),
          ),

          // ── Favourites row (conditional) ────────────────────────────────
          if (_favoriteChannels.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(Sp.x5, Sp.x6, Sp.x5, 0),
              sliver: SliverToBoxAdapter(
                child: _FavouritesRow(
                  appState: _s,
                  channels: _favoriteChannels,
                  onToggle: _toggleFavorite,
                ),
              ),
            ),

          // ── Summary stats ───────────────────────────────────────────────
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(Sp.x5, Sp.x6, Sp.x5, 0),
            sliver: SliverToBoxAdapter(child: _SummaryCard(appState: _s)),
          ),

          // ── Scenes ──────────────────────────────────────────────────────
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(Sp.x5, Sp.x8, Sp.x5, 0),
            sliver: SliverToBoxAdapter(child: _SceneStrip(appState: _s)),
          ),

          // ── Quick controls ──────────────────────────────────────────────
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(Sp.x5, Sp.x5, Sp.x5, 0),
            sliver: SliverToBoxAdapter(child: _QuickControls(appState: _s)),
          ),

          // ── Relays ──────────────────────────────────────────────────────
          if (_s.relayDevices.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(Sp.x5, Sp.x6, Sp.x5, 0),
              sliver: SliverToBoxAdapter(child: _RelaysGrid(appState: _s)),
            ),

          // ── Curtains ────────────────────────────────────────────────────
          if (_s.curtainDevices.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(Sp.x5, Sp.x6, Sp.x5, 0),
              sliver: SliverToBoxAdapter(child: _CurtainsPanel(appState: _s)),
            ),

          // ── Appliances ──────────────────────────────────────────────────
          if (_s.applianceDevices.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(Sp.x5, Sp.x6, Sp.x5, 0),
              sliver: SliverToBoxAdapter(child: _AppliancesGrid(appState: _s)),
            ),

          // ── Security ────────────────────────────────────────────────────
          if (_s.securityAvailable)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(Sp.x5, Sp.x6, Sp.x5, 0),
              sliver: SliverToBoxAdapter(child: _SecurityPanel(appState: _s)),
            ),

          // ── Sensors ─────────────────────────────────────────────────────
          if (_s.doorSensors.isNotEmpty || _s.windowSensors.isNotEmpty || _s.motionSensors.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(Sp.x5, Sp.x6, Sp.x5, 0),
              sliver: SliverToBoxAdapter(child: _SensorsPanel(appState: _s)),
            ),

          // ── Room cards ──────────────────────────────────────────────────
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (_, i) => Padding(
                padding: EdgeInsets.fromLTRB(Sp.x5, i == 0 ? Sp.x8 : Sp.x3, Sp.x5, 0),
                child: _RoomCard(
                  room:     rooms[i],
                  appState: _s,
                  collapsed:        _isCollapsed(rooms[i]),
                  onToggle:         () => _toggleRoom(rooms[i]),
                  favoriteChannels: _favoriteChannels,
                  onToggleFavorite: _toggleFavorite,
                ),
              ),
              childCount: rooms.length,
            ),
          ),

          // ── Fallback (no device metadata) ────────────────────────────────
          if (_s.daliDevices.isEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(Sp.x5, Sp.x6, Sp.x5, 0),
              sliver: SliverToBoxAdapter(child: _RawChannelsFallback(appState: _s)),
            ),

          // ── Recent activity ─────────────────────────────────────────────
          if (_s.log.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(Sp.x5, Sp.x6, Sp.x5, 0),
              sliver: SliverToBoxAdapter(child: _RecentActivity(appState: _s)),
            ),

          const SliverPadding(padding: EdgeInsets.only(bottom: Sp.x12)),
        ],
      ),
    );
  }

  Widget _offlineBody() => SingleChildScrollView(
    physics: const BouncingScrollPhysics(),
    padding: const EdgeInsets.all(Sp.x6),
    child: Column(children: [
      const SizedBox(height: Sp.x10),
      Container(
        width: 88, height: 88,
        decoration: BoxDecoration(
          color: C.red.withAlpha(14),
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: C.red.withAlpha(40), width: 0.5),
        ),
        child: const Icon(Icons.wifi_off_rounded, color: C.red, size: 40),
      ),
      const SizedBox(height: Sp.x6),
      Text('No Connection', style: AppText.h1),
      const SizedBox(height: Sp.x2),
      Text('Check your server settings', style: AppText.body.copyWith(color: C.textSec)),
    ]),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Header — minimal, breathable. No latency chip (technical jargon).
// ─────────────────────────────────────────────────────────────────────────────

class _DashHeader extends StatelessWidget {
  final AppState  appState;
  final AuthState authState;
  const _DashHeader({required this.appState, required this.authState});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Sp.x5, Sp.x4, Sp.x5, Sp.x2),
    child: Row(children: [
      // Brand mark
      Container(
        width: 36, height: 36,
        decoration: BoxDecoration(
          gradient: G.accent,
          borderRadius: BorderRadius.circular(11),
          boxShadow: S.accentGlow,
        ),
        child: const Icon(Icons.bolt_rounded, size: 20, color: Colors.black),
      ),
      const SizedBox(width: Sp.x3),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Lugh', style: GoogleFonts.inter(
          fontSize: 15, fontWeight: FontWeight.w800,
          color: C.textPri, letterSpacing: -0.5,
        )),
        Text('by IQS', style: AppText.small.copyWith(
          color: C.textTri, letterSpacing: 1.2, fontSize: 10,
        )),
      ]),
      const Spacer(),
      StatusPill(connected: appState.connected),
    ]),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Greeting — large, warm, personal
// ─────────────────────────────────────────────────────────────────────────────

class _Greeting extends StatelessWidget {
  final AppState  appState;
  final AuthState authState;
  const _Greeting({required this.appState, required this.authState});

  String get _time {
    final h = DateTime.now().hour;
    if (h < 5)  return 'Good Night';
    if (h < 12) return 'Good Morning';
    if (h < 17) return 'Good Afternoon';
    return 'Good Evening';
  }

  @override
  Widget build(BuildContext context) {
    final name  = authState.user?.firstName.trim();
    final house = authState.apartmentName;
    final armed     = appState.securityAvailable && appState.effectiveAlarmArmed;
    final triggered = appState.securityAvailable && appState.alarmTriggered;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(
        name?.isNotEmpty == true ? '$_time, $name' : _time,
        style: AppText.hero.copyWith(fontSize: 30),
      ),
      const SizedBox(height: Sp.x2),
      Row(children: [
        Icon(Icons.home_rounded, size: 14, color: C.textTri),
        const SizedBox(width: 5),
        Flexible(child: Text(house ?? 'Welcome home', style: AppText.small)),
        if (appState.securityAvailable) ...[
          const SizedBox(width: Sp.x3),
          _SecurityPill(armed: armed, triggered: triggered),
        ],
      ]),
    ]);
  }
}

class _SecurityPill extends StatelessWidget {
  final bool armed;
  final bool triggered;
  const _SecurityPill({required this.armed, required this.triggered});

  @override
  Widget build(BuildContext context) {
    final color = triggered ? C.red : (armed ? C.orange : C.green);
    final icon  = triggered ? Icons.warning_rounded
        : (armed ? Icons.lock_rounded : Icons.home_rounded);
    final label = triggered ? 'Alert' : (armed ? 'Secured' : 'Home');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(18),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withAlpha(55), width: 0.5),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 10, color: color),
        const SizedBox(width: 4),
        Text(label, style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w700, color: color)),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Favourites — compact horizontal quick-access row
// ─────────────────────────────────────────────────────────────────────────────

class _FavouritesRow extends StatelessWidget {
  final AppState      appState;
  final Set<int>      channels;
  final void Function(int) onToggle;
  const _FavouritesRow({required this.appState, required this.channels, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final devices = channels
        .map((ch) => appState.daliDevices.where((d) => d.channel == ch).firstOrNull)
        .whereType<DaliDevice>()
        .toList();
    if (devices.isEmpty) return const SizedBox.shrink();

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Favourites', style: AppText.small.copyWith(
        color: C.textTri, fontWeight: FontWeight.w700, letterSpacing: 1.2, fontSize: 10,
      )),
      const SizedBox(height: Sp.x3),
      SizedBox(
        height: 88,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          itemCount: devices.length,
          separatorBuilder: (_, _) => const SizedBox(width: Sp.x3),
          itemBuilder: (_, i) => _FavTile(
            device: devices[i], appState: appState,
            onLongPress: () => onToggle(devices[i].channel),
          ),
        ),
      ),
    ]);
  }
}

class _FavTile extends StatelessWidget {
  final DaliDevice device;
  final AppState   appState;
  final VoidCallback onLongPress;
  const _FavTile({required this.device, required this.appState, required this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final pct   = appState.effectiveBrightness(device.channel);
    final on    = pct > 0;
    final color = _brightness2color(pct);
    return TapScale(
      onTap: () => appState.setDaliBrightness(device.channel, on ? 0 : 100),
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: Dur.normal,
        width: 88,
        decoration: BoxDecoration(
          gradient: on ? G.room(color) : null,
          color:    on ? null : C.card,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: on ? color.withAlpha(60) : C.border, width: 0.5),
          boxShadow: on ? S.ambientGlow(color) : S.card,
        ),
        padding: const EdgeInsets.all(Sp.x3),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(on ? Icons.lightbulb_rounded : Icons.lightbulb_outline_rounded,
              color: on ? color : C.textTri, size: 22),
          const Spacer(),
          Text(device.name, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: AppText.bodyMed.copyWith(fontSize: 12, color: C.textPri)),
          Text('$pct%', style: GoogleFonts.inter(
            fontSize: 11, fontWeight: FontWeight.w700, color: color,
            fontFeatures: [const FontFeature.tabularFigures()],
          )),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Home Status Card — what users actually care about right now
// ─────────────────────────────────────────────────────────────────────────────

class _SummaryCard extends StatelessWidget {
  final AppState appState;
  const _SummaryCard({required this.appState});

  @override
  Widget build(BuildContext context) {
    final on    = appState.lightsOnCount;
    final total = appState.daliDevices.length;
    if (total == 0) return const SizedBox.shrink();

    final activeScene = appState.activeSceneIndex != null
        ? LightScene.presets[appState.activeSceneIndex!] : null;
    final armed     = appState.securityAvailable && appState.effectiveAlarmArmed;
    final triggered = appState.securityAvailable && appState.alarmTriggered;

    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(Sp.x5),
        child: Row(children: [
          // Left — lights status
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                on == 0 ? 'All lights off' : '$on light${on == 1 ? '' : 's'} on',
                style: AppText.title.copyWith(
                  color: on > 0 ? C.textPri : C.textSec,
                  fontSize: 15,
                ),
              ),
              if (activeScene != null) ...[
                const SizedBox(height: Sp.x1),
                Row(children: [
                  Icon(activeScene.icon, size: 12, color: activeScene.color),
                  const SizedBox(width: 5),
                  Text(activeScene.name, style: AppText.small.copyWith(
                    color: activeScene.color, fontWeight: FontWeight.w600,
                  )),
                ]),
              ] else if (on > 0) ...[
                const SizedBox(height: Sp.x1),
                Text('Manual control', style: AppText.small),
              ],
            ]),
          ),
          // Right — security status (if available)
          if (appState.securityAvailable) ...[
            Container(width: 0.5, height: 36, color: C.border),
            const SizedBox(width: Sp.x4),
            Column(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: triggered ? C.red.withAlpha(20)
                      : (armed ? C.orange.withAlpha(18) : C.green.withAlpha(16)),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color: triggered ? C.red.withAlpha(60)
                        : (armed ? C.orange.withAlpha(55) : C.green.withAlpha(45)),
                    width: 0.5,
                  ),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(
                    triggered ? Icons.warning_rounded
                        : (armed ? Icons.lock_rounded : Icons.home_rounded),
                    size: 11,
                    color: triggered ? C.red : (armed ? C.orange : C.green),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    triggered ? 'Alert' : (armed ? 'Secured' : 'Home'),
                    style: GoogleFonts.inter(
                      fontSize: 11, fontWeight: FontWeight.w700,
                      color: triggered ? C.red : (armed ? C.orange : C.green),
                    ),
                  ),
                ]),
              ),
            ]),
          ],
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Scene strip — large cards, not chips. Each scene has its own visual identity.
// ─────────────────────────────────────────────────────────────────────────────

class _SceneStrip extends StatelessWidget {
  final AppState appState;
  const _SceneStrip({required this.appState});

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 84,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      itemCount: LightScene.presets.length,
      separatorBuilder: (_, _) => const SizedBox(width: Sp.x3),
      itemBuilder: (_, i) {
        final scene    = LightScene.presets[i];
        final selected = appState.activeSceneIndex == i;
        return TapScale(
          onTap: () => appState.applyScene(scene, i),
          child: AnimatedContainer(
            duration: Dur.normal, curve: Cur.snap,
            width: 110,
            decoration: BoxDecoration(
              gradient: selected ? scene.gradient : null,
              color:    selected ? null : C.card,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: selected ? scene.color.withAlpha(100) : C.border,
                width: selected ? 1.0 : 0.5,
              ),
              boxShadow: selected ? S.colorGlow(scene.color, alpha: 70) : S.card,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Sp.x4, Sp.x4, Sp.x4, Sp.x3),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(scene.icon,
                    color: selected ? scene.color : C.textTri, size: 22),
                const Spacer(),
                Text(scene.name, style: GoogleFonts.inter(
                  fontSize: 13, fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? scene.color : C.textSec,
                )),
              ]),
            ),
          ),
        );
      },
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Quick controls — three prominent buttons
// ─────────────────────────────────────────────────────────────────────────────

class _QuickControls extends StatelessWidget {
  final AppState appState;
  const _QuickControls({required this.appState});

  @override
  Widget build(BuildContext context) => Row(children: [
    Expanded(child: _ControlBtn(
      label: 'All On', icon: Icons.wb_sunny_rounded, color: C.accent,
      onTap: () => appState.setAllDaliBrightness(100),
    )),
    const SizedBox(width: Sp.x3),
    Expanded(child: _ControlBtn(
      label: 'All Off', icon: Icons.nightlight_rounded, color: C.textSec,
      onTap: () => appState.setAllDaliBrightness(0),
    )),
    const SizedBox(width: Sp.x3),
    Expanded(child: _ControlBtn(
      label: '50%', icon: Icons.brightness_medium_rounded, color: C.blue,
      onTap: () => appState.setAllDaliBrightness(50),
    )),
  ]);
}

class _ControlBtn extends StatelessWidget {
  final String    label;
  final IconData  icon;
  final Color     color;
  final VoidCallback onTap;
  const _ControlBtn({required this.label, required this.icon, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) => TapScale(
    onTap: onTap,
    child: Container(
      height: 64,
      decoration: BoxDecoration(
        color: color.withAlpha(14),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withAlpha(40), width: 0.5),
        boxShadow: S.card,
      ),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, color: color, size: 24),
        const SizedBox(height: 5),
        Text(label, style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
      ]),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Relays — card-based rows, not a tag cloud
// ─────────────────────────────────────────────────────────────────────────────

class _RelaysGrid extends StatelessWidget {
  final AppState appState;
  const _RelaysGrid({required this.appState});

  @override
  Widget build(BuildContext context) => AppCard(
        child: Column(
          children: List.generate(appState.relayDevices.length, (i) {
            final relay = appState.relayDevices[i];
            final on    = appState.effectiveRelay(relay.channel);
            return Column(children: [
              if (i > 0) const AppDivider(indent: EdgeInsets.only(left: 68)),
              InkWell(
                onTap: () => appState.setRelay(relay.channel, !on),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x4),
                  child: Row(children: [
                    AnimatedContainer(
                      duration: Dur.normal,
                      width: 44, height: 44,
                      decoration: BoxDecoration(
                        color: on ? C.green.withAlpha(22) : C.elevated,
                        borderRadius: BorderRadius.circular(13),
                        boxShadow: on ? S.colorGlow(C.green, alpha: 50) : null,
                      ),
                      child: Icon(Icons.toggle_on_rounded,
                          color: on ? C.green : C.textTri, size: 22),
                    ),
                    const SizedBox(width: Sp.x3),
                    Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(relay.name, style: AppText.title.copyWith(fontSize: 14)),
                        Text(on ? 'On' : 'Off',
                            style: AppText.small.copyWith(color: on ? C.green : C.textTri)),
                      ],
                    )),
                    DeviceIndicator(on: on, onColor: C.green),
                  ]),
                ),
              ),
            ]);
          }),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Curtains
// ─────────────────────────────────────────────────────────────────────────────

class _CurtainsPanel extends StatelessWidget {
  final AppState appState;
  const _CurtainsPanel({required this.appState});

  static const _labels = {0: 'Stopped', 1: 'Opening', 2: 'Closing'};
  static const _colors = {0: C.textTri, 1: C.blue, 2: C.orange};

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(children: [
        const Spacer(),
        _CurtainQuick(icon: Icons.arrow_upward_rounded, label: 'Up',   color: C.blue,    onTap: () => appState.setCurtainAll(1)),
        const SizedBox(width: Sp.x2),
        _CurtainQuick(icon: Icons.stop_rounded,         label: 'Stop', color: C.textSec, onTap: () => appState.setCurtainAll(0)),
        const SizedBox(width: Sp.x2),
        _CurtainQuick(icon: Icons.arrow_downward_rounded, label: 'Down', color: C.orange, onTap: () => appState.setCurtainAll(2)),
      ]),
      const SizedBox(height: Sp.x3),
      AppCard(
        child: Column(children: List.generate(appState.curtainDevices.length, (i) {
          final c = appState.curtainDevices[i];
          final state = appState.effectiveCurtain(c.index);
          final color = _colors[state] ?? C.textTri;
          return Column(children: [
            if (i > 0) const AppDivider(indent: EdgeInsets.only(left: Sp.x4)),
            Padding(
              padding: const EdgeInsets.fromLTRB(Sp.x4, Sp.x4, Sp.x4, Sp.x4),
              child: Row(children: [
                DeviceIndicator(on: state != 0, onColor: color, size: 10),
                const SizedBox(width: Sp.x3),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(c.name, style: AppText.title.copyWith(fontSize: 14)),
                  Text('${c.room} · ${_labels[state] ?? ''}', style: AppText.small.copyWith(fontSize: 10)),
                ])),
                Row(children: [
                  _CurtainBtn(icon: Icons.arrow_upward_rounded,   color: C.blue,    active: state == 1, onTap: () => appState.setCurtain(c.index, state == 1 ? 0 : 1)),
                  const SizedBox(width: Sp.x1),
                  _CurtainBtn(icon: Icons.stop_rounded,           color: C.textSec, active: state == 0, onTap: () => appState.setCurtain(c.index, 0)),
                  const SizedBox(width: Sp.x1),
                  _CurtainBtn(icon: Icons.arrow_downward_rounded, color: C.orange,  active: state == 2, onTap: () => appState.setCurtain(c.index, state == 2 ? 0 : 2)),
                ]),
              ]),
            ),
          ]);
        })),
      ),
    ],
  );
}

class _CurtainQuick extends StatelessWidget {
  final IconData icon; final String label; final Color color; final VoidCallback onTap;
  const _CurtainQuick({required this.icon, required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) => TapScale(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withAlpha(14), borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withAlpha(40), width: 0.5),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: color, size: 13),
        const SizedBox(width: 4),
        Text(label, style: AppText.small.copyWith(color: color, fontWeight: FontWeight.w700, fontSize: 11)),
      ]),
    ),
  );
}

class _CurtainBtn extends StatelessWidget {
  final IconData icon; final Color color; final bool active; final VoidCallback onTap;
  const _CurtainBtn({required this.icon, required this.color, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) => TapScale(
    onTap: onTap,
    child: AnimatedContainer(
      duration: Dur.fast, width: 38, height: 38,
      decoration: BoxDecoration(
        color: active ? color.withAlpha(24) : C.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: active ? color.withAlpha(80) : C.border, width: 0.5),
      ),
      child: Icon(icon, color: active ? color : C.textTri, size: 16),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Appliances — card rows, not tag cloud
// ─────────────────────────────────────────────────────────────────────────────

class _AppliancesGrid extends StatelessWidget {
  final AppState appState;
  const _AppliancesGrid({required this.appState});

  static IconData _icon(String gvl) => switch (gvl) {
    'Fridge'        => Icons.kitchen_rounded,
    'CoffeeMachine' => Icons.coffee_rounded,
    'Microwave'     => Icons.microwave_rounded,
    _               => Icons.power_rounded,
  };

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      AppCard(
        child: Column(children: List.generate(appState.applianceDevices.length, (i) {
          final ap = appState.applianceDevices[i];
          final on = appState.effectiveAppliance(ap.gvlName);
          return Column(children: [
            if (i > 0) const AppDivider(indent: EdgeInsets.only(left: 68)),
            InkWell(
              onTap: () => appState.setAppliance(ap.gvlName, !on),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x4),
                child: Row(children: [
                  AnimatedContainer(
                    duration: Dur.normal,
                    width: 44, height: 44,
                    decoration: BoxDecoration(
                      color: on ? C.green.withAlpha(20) : C.elevated,
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Icon(_icon(ap.gvlName), color: on ? C.green : C.textTri, size: 20),
                  ),
                  const SizedBox(width: Sp.x3),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(ap.name, style: AppText.title.copyWith(fontSize: 14)),
                    Text(on ? 'On' : 'Off', style: AppText.small.copyWith(color: on ? C.green : C.textTri)),
                  ])),
                  DeviceIndicator(on: on, onColor: C.green),
                ]),
              ),
            ),
          ]);
        })),
      ),
    ],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Security — bold, immediately readable
// ─────────────────────────────────────────────────────────────────────────────

class _SecurityPanel extends StatelessWidget {
  final AppState appState;
  const _SecurityPanel({required this.appState});

  @override
  Widget build(BuildContext context) {
    final armed     = appState.effectiveAlarmArmed;
    final lockdown  = appState.effectiveLockdown;
    final triggered = appState.alarmTriggered;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      
      if (triggered)
        Container(
          margin: const EdgeInsets.only(bottom: Sp.x3),
          padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x3),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [C.red.withAlpha(22), C.red.withAlpha(8)]),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: C.red.withAlpha(70), width: 0.5),
          ),
          child: Row(children: [
            const Icon(Icons.warning_rounded, color: C.red, size: 18),
            const SizedBox(width: Sp.x3),
            Text('Intrusion detected!', style: AppText.bodyMed.copyWith(color: C.red)),
          ]),
        ),
      Row(children: [
        Expanded(child: _SecurityTile(
          icon: armed ? Icons.lock_rounded : Icons.lock_open_rounded,
          label: armed ? 'Armed'   : 'Disarmed',
          sub:   armed ? 'Tap to disarm' : 'Tap to arm',
          color: armed ? C.orange : C.textSec,
          onTap: () => appState.setAlarm(!armed),
        )),
        const SizedBox(width: Sp.x3),
        Expanded(child: _SecurityTile(
          icon: lockdown ? Icons.shield_rounded : Icons.shield_outlined,
          label: lockdown ? 'Lockdown' : 'Normal',
          sub:   lockdown ? 'Tap to cancel'    : 'Tap to activate',
          color: lockdown ? C.red : C.textSec,
          onTap: () => appState.setLockdown(!lockdown),
        )),
      ]),
    ]);
  }
}

class _SecurityTile extends StatelessWidget {
  final IconData icon; final String label; final String sub;
  final Color color; final VoidCallback onTap;
  const _SecurityTile({required this.icon, required this.label, required this.sub, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) => TapScale(
    onTap: onTap,
    child: AnimatedContainer(
      duration: Dur.normal,
      height: 88,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [color.withAlpha(20), color.withAlpha(8)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withAlpha(55), width: 0.5),
        boxShadow: S.colorGlow(color, alpha: 30),
      ),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, color: color, size: 28),
        const SizedBox(height: 6),
        Text(label, style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w800, color: color, letterSpacing: 0.5)),
        const SizedBox(height: 2),
        Text(sub, style: AppText.small.copyWith(fontSize: 10)),
      ]),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Sensors — clean status chips in a proper grid
// ─────────────────────────────────────────────────────────────────────────────

class _SensorsPanel extends StatelessWidget {
  final AppState appState;
  const _SensorsPanel({required this.appState});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      
      Wrap(spacing: Sp.x3, runSpacing: Sp.x3, children: [
        for (final s in appState.doorSensors)
          _SensorChip(name: s.name, open: appState.state.doorSensors[s.index] ?? false,   icon: Icons.door_front_door_rounded),
        for (final s in appState.windowSensors)
          _SensorChip(name: s.name, open: appState.state.windowSensors[s.index] ?? false, icon: Icons.window_rounded),
        for (final s in appState.motionSensors)
          _SensorChip(name: s.name, open: appState.state.motionSensors[s.index] ?? false, icon: Icons.sensors_rounded, openLabel: 'Motion', closedLabel: 'Clear'),
      ]),
    ],
  );
}

class _SensorChip extends StatelessWidget {
  final String name; final bool open; final IconData icon;
  final String openLabel; final String closedLabel;
  const _SensorChip({required this.name, required this.open, required this.icon, this.openLabel = 'Open', this.closedLabel = 'Closed'});

  @override
  Widget build(BuildContext context) {
    final color = open ? C.orange : C.green;
    return AnimatedContainer(
      duration: Dur.normal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: color.withAlpha(14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(open ? 65 : 35), width: 0.5),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: color, size: 15),
        const SizedBox(width: 7),
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(name, style: AppText.bodyMed.copyWith(fontSize: 12)),
          Text(open ? openLabel : closedLabel,
              style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w700, color: color)),
        ]),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Room icon / colour helpers — each room has its own visual identity
// ─────────────────────────────────────────────────────────────────────────────

IconData _roomIcon(String name) {
  final n = name.toLowerCase();
  if (n.contains('living') || n.contains('lounge') || n.contains('sitting')) {
    return Icons.weekend_rounded;
  }
  if (n.contains('kitchen')) return Icons.soup_kitchen_rounded;
  if (n.contains('bedroom') || n.contains('master') || n.contains('sleep') || n.contains('guest')) {
    return Icons.king_bed_rounded;
  }
  if (n.contains('bathroom') || n.contains('bath') || n.contains('toilet') || n.contains('wc')) {
    return Icons.bathtub_rounded;
  }
  if (n.contains('office') || n.contains('study') || n.contains('work')) {
    return Icons.computer_rounded;
  }
  if (n.contains('dining')) return Icons.restaurant_rounded;
  if (n.contains('garage')) return Icons.garage_rounded;
  if (n.contains('garden') || n.contains('outdoor') || n.contains('yard') || n.contains('patio')) {
    return Icons.yard_rounded;
  }
  if (n.contains('hall') || n.contains('entry') || n.contains('corridor')) {
    return Icons.meeting_room_rounded;
  }
  if (n.contains('gym') || n.contains('fitness')) { return Icons.fitness_center_rounded; }
  if (n.contains('cinema') || n.contains('media') || n.contains('theater')) {
    return Icons.movie_rounded;
  }
  if (n.contains('kids') || n.contains('child') || n.contains('nursery')) {
    return Icons.child_care_rounded;
  }
  return Icons.lightbulb_outline_rounded;
}

Color _roomColor(String name) {
  final n = name.toLowerCase();
  if (n.contains('living') || n.contains('lounge')) return C.blue;
  if (n.contains('kitchen')) return C.orange;
  if (n.contains('bedroom') || n.contains('sleep') || n.contains('master')) return C.purple;
  if (n.contains('bathroom') || n.contains('bath')) return C.teal;
  if (n.contains('office') || n.contains('study')) return C.blue;
  if (n.contains('dining')) return C.orange;
  if (n.contains('garden') || n.contains('outdoor')) return C.green;
  if (n.contains('cinema') || n.contains('media')) return C.purple;
  if (n.contains('kids') || n.contains('child')) return C.green;
  return C.accent;
}

// ─────────────────────────────────────────────────────────────────────────────
// Room card — the centrepiece. Glows warmly when lights are on.
// ─────────────────────────────────────────────────────────────────────────────

class _RoomCard extends StatelessWidget {
  final String   room;
  final AppState appState;
  final bool     collapsed;
  final VoidCallback onToggle;
  final Set<int> favoriteChannels;
  final void Function(int) onToggleFavorite;

  const _RoomCard({
    required this.room, required this.appState,
    required this.collapsed, required this.onToggle,
    required this.favoriteChannels, required this.onToggleFavorite,
  });

  @override
  Widget build(BuildContext context) {
    final devices  = appState.daliDevices.where((d) => d.room == room).toList();
    if (devices.isEmpty) return const SizedBox.shrink();

    final onCount  = appState.roomLightsOn(room);
    final total    = devices.length;
    final isLit    = onCount > 0;
    final roomColor = _roomColor(room);
    final roomIcon  = _roomIcon(room);
    final glowColor = isLit ? roomColor : C.accent;

    return AnimatedContainer(
      duration: Dur.normal, curve: Cur.smooth,
      decoration: BoxDecoration(
        color: C.card,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: isLit ? roomColor.withAlpha(60) : C.border, width: 0.5,
        ),
        boxShadow: isLit ? S.ambientGlow(glowColor) : S.card,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Column(children: [
          // ── Room header ─────────────────────────────────────────────────
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Sp.x4, Sp.x4, Sp.x4, Sp.x4),
              child: Row(children: [
                // Room icon — each room has its own visual identity
                AnimatedContainer(
                  duration: Dur.normal,
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: isLit ? roomColor.withAlpha(22) : C.elevated,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: isLit ? S.colorGlow(roomColor, alpha: 50) : null,
                  ),
                  child: Icon(roomIcon,
                      color: isLit ? roomColor : C.textTri, size: 19),
                ),
                const SizedBox(width: Sp.x3),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(room, style: AppText.title),
                    Text(
                      onCount == 0 ? 'All off'
                          : onCount == total ? 'All on'
                          : '$onCount of $total on',
                      style: AppText.small.copyWith(
                        color: isLit ? roomColor : C.textTri,
                        fontWeight: isLit ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ]),
                ),
                if (!collapsed) ...[
                  _RoomBtn(label: 'On',  color: roomColor, onTap: () => appState.setRoomBrightness(room, 100)),
                  const SizedBox(width: Sp.x2),
                  _RoomBtn(label: 'Off', color: C.textSec, onTap: () => appState.setRoomBrightness(room, 0)),
                  const SizedBox(width: Sp.x3),
                ] else const SizedBox(width: Sp.x2),
                AnimatedRotation(
                  turns: collapsed ? -0.25 : 0, duration: Dur.fast,
                  child: Icon(Icons.expand_more_rounded,
                      color: isLit ? roomColor.withAlpha(180) : C.textSec, size: 20),
                ),
              ]),
            ),
          ),
          // ── Light list ──────────────────────────────────────────────────
          AnimatedSize(
            duration: Dur.fast, curve: Cur.snap,
            child: collapsed
                ? const SizedBox(width: double.infinity)
                : Column(children: [
                    Divider(height: 0.5, thickness: 0.5, color: C.border),
                    for (int i = 0; i < devices.length; i++) ...[
                      if (i > 0) Divider(
                        height: 0.5, thickness: 0.5,
                        color: C.border, indent: 72, endIndent: Sp.x4,
                      ),
                      _LightRow(
                        device:           devices[i],
                        appState:         appState,
                        isFav:            favoriteChannels.contains(devices[i].channel),
                        onToggleFav:      () => onToggleFavorite(devices[i].channel),
                      ),
                    ],
                  ]),
          ),
        ]),
      ),
    );
  }
}

class _RoomBtn extends StatelessWidget {
  final String label; final Color color; final VoidCallback onTap;
  const _RoomBtn({required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) => TapScale(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: color.withAlpha(16), borderRadius: BorderRadius.circular(9),
        border: Border.all(color: color.withAlpha(50), width: 0.5),
      ),
      child: Text(label, style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Light row — 48px+ touch target, colored slider matching brightness
// ─────────────────────────────────────────────────────────────────────────────

class _LightRow extends StatefulWidget {
  final DaliDevice device;
  final AppState   appState;
  final bool       isFav;
  final VoidCallback onToggleFav;
  const _LightRow({required this.device, required this.appState, required this.isFav, required this.onToggleFav});

  @override
  State<_LightRow> createState() => _LightRowState();
}

class _LightRowState extends State<_LightRow> {
  double? _dragging;

  int get _pct => _dragging?.toInt() ?? widget.appState.effectiveBrightness(widget.device.channel);

  void _toggle() {
    HapticFeedback.lightImpact();
    widget.appState.setDaliBrightness(widget.device.channel, _pct > 0 ? 0 : 100);
  }

  void _showSheet() {
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: C.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (_) => _LightSheet(
        device: widget.device, current: _pct,
        appState: widget.appState, isFav: widget.isFav,
        onToggleFav: widget.onToggleFav,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pct   = _pct;
    final color = _brightness2color(pct);
    final on    = pct > 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.x3, Sp.x3, Sp.x4, Sp.x3),
      child: Row(children: [
        // Toggle button — 48px touch target
        TapScale(
          onTap: _toggle, onLongPress: _showSheet, scale: 0.86,
          child: AnimatedContainer(
            duration: Dur.normal,
            width: 48, height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: on ? color.withAlpha(22) : C.elevated,
              border: Border.all(color: on ? color.withAlpha(80) : C.border, width: 0.5),
              boxShadow: on ? S.colorGlow(color, alpha: 60) : null,
            ),
            child: Icon(
              on ? Icons.lightbulb_rounded : Icons.lightbulb_outline_rounded,
              color: on ? color : C.textTri, size: 20,
            ),
          ),
        ),
        const SizedBox(width: Sp.x3),
        // Name + slider
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(widget.device.name, style: AppText.bodyMed.copyWith(
              fontWeight: on ? FontWeight.w600 : FontWeight.w400,
              color: on ? C.textPri : C.textSec, fontSize: 13,
            ))),
            AnimatedDefaultTextStyle(
              duration: Dur.fast,
              style: GoogleFonts.inter(
                fontSize: 13, fontWeight: FontWeight.w700, color: color,
                fontFeatures: [const FontFeature.tabularFigures()],
              ),
              child: Text('$pct%'),
            ),
          ]),
          const SizedBox(height: 4),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 6,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
              activeTrackColor:   color,
              inactiveTrackColor: on ? color.withAlpha(25) : C.border,
              thumbColor:         color,
              overlayColor:       color.withAlpha(22),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 22),
            ),
            child: Slider(
              value: pct.toDouble(), min: 0, max: 100, divisions: 100,
              onChanged: (v) { HapticFeedback.selectionClick(); setState(() => _dragging = v); },
              onChangeEnd: (v) {
                setState(() => _dragging = null);
                widget.appState.setDaliBrightness(widget.device.channel, v.toInt());
              },
            ),
          ),
        ])),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Light bottom sheet — presets + favourite toggle
// ─────────────────────────────────────────────────────────────────────────────

class _LightSheet extends StatelessWidget {
  final DaliDevice device;
  final int current;
  final AppState appState;
  final bool isFav;
  final VoidCallback onToggleFav;
  const _LightSheet({required this.device, required this.current, required this.appState, required this.isFav, required this.onToggleFav});

  void _set(BuildContext ctx, int pct) {
    HapticFeedback.lightImpact();
    appState.setDaliBrightness(device.channel, pct);
    Navigator.pop(ctx);
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(Sp.x5, Sp.x4, Sp.x5, Sp.x6),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const BottomSheetHandle(),
        const SizedBox(height: Sp.x5),
        Row(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: C.accent.withAlpha(20), borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.lightbulb_rounded, color: C.accent, size: 20),
          ),
          const SizedBox(width: Sp.x3),
          Expanded(child: Text(device.name, style: AppText.title)),
          Text('$current%', style: AppText.body.copyWith(color: C.textSec)),
        ]),
        const SizedBox(height: Sp.x4),
        // Favourite toggle
        TapScale(
          onTap: () { onToggleFav(); Navigator.pop(context); },
          child: Container(
            width: double.infinity, height: 48,
            decoration: BoxDecoration(
              color: (isFav ? C.accent : C.textTri).withAlpha(14),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: isFav ? C.accent : C.border, width: 0.5),
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(isFav ? Icons.star_rounded : Icons.star_outline_rounded,
                  color: isFav ? C.accent : C.textSec, size: 17),
              const SizedBox(width: Sp.x2),
              Text(
                isFav ? 'Remove from Favourites' : 'Add to Favourites',
                style: AppText.bodyMed.copyWith(color: isFav ? C.accent : C.textSec, fontSize: 13),
              ),
            ]),
          ),
        ),
        const SizedBox(height: Sp.x5),
        // Presets
        Row(children: [
          _Preset(label: 'Off',   pct: 0,   color: C.textSec, onTap: (p) => _set(context, p)),
          const SizedBox(width: Sp.x2),
          _Preset(label: '25%',  pct: 25,  color: C.purple,  onTap: (p) => _set(context, p)),
          const SizedBox(width: Sp.x2),
          _Preset(label: '50%',  pct: 50,  color: C.blue,    onTap: (p) => _set(context, p)),
          const SizedBox(width: Sp.x2),
          _Preset(label: '75%',  pct: 75,  color: C.orange,  onTap: (p) => _set(context, p)),
          const SizedBox(width: Sp.x2),
          _Preset(label: 'Full', pct: 100, color: C.accent,  onTap: (p) => _set(context, p)),
        ]),
      ]),
    ),
  );
}

class _Preset extends StatelessWidget {
  final String label; final int pct; final Color color;
  final void Function(int) onTap;
  const _Preset({required this.label, required this.pct, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) => Expanded(
    child: TapScale(
      onTap: () => onTap(pct),
      child: Container(
        height: 60,
        decoration: BoxDecoration(
          color: color.withAlpha(16), borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withAlpha(50), width: 0.5),
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.lightbulb_rounded, color: color, size: 18),
          const SizedBox(height: 5),
          Text(label, style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
        ]),
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Recent activity
// ─────────────────────────────────────────────────────────────────────────────

class _RecentActivity extends StatelessWidget {
  final AppState appState;
  const _RecentActivity({required this.appState});

  String _rel(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24)   return '${d.inHours}h';
    return '${d.inDays}d';
  }

  @override
  Widget build(BuildContext context) {
    final recent = appState.log.reversed.take(3).toList();
    if (recent.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      
      AppCard(
        child: Column(children: [
          for (int i = 0; i < recent.length; i++) ...[
            if (i > 0) const AppDivider(indent: EdgeInsets.only(left: 48)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x3),
              child: Row(children: [
                Container(
                  width: 24, height: 24,
                  decoration: BoxDecoration(
                    color: (recent[i].isError ? C.red : C.green).withAlpha(18),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    recent[i].isError ? Icons.error_rounded : Icons.check_rounded,
                    size: 13, color: recent[i].isError ? C.red : C.green,
                  ),
                ),
                const SizedBox(width: Sp.x3),
                Expanded(child: Text(recent[i].message,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: AppText.body.copyWith(fontSize: 12))),
                const SizedBox(width: Sp.x2),
                Text(_rel(recent[i].time), style: AppText.small.copyWith(fontSize: 10)),
              ]),
            ),
          ],
        ]),
      ),
    ]);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Raw channels fallback
// ─────────────────────────────────────────────────────────────────────────────

class _RawChannelsFallback extends StatelessWidget {
  final AppState appState;
  const _RawChannelsFallback({required this.appState});
  static const _max = 28;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('DALI channels', style: AppText.small.copyWith(
        color: C.textTri, fontWeight: FontWeight.w700, letterSpacing: 1.2, fontSize: 10,
      )),
      const SizedBox(height: Sp.x3),
      AppCard(
        child: Column(children: List.generate(_max, (i) {
          final ch = i + 1;
          return Column(children: [
            if (i > 0) const AppDivider(indent: EdgeInsets.only(left: Sp.x4)),
            _RawRow(channel: ch, appState: appState),
          ]);
        })),
      ),
    ],
  );
}

class _RawRow extends StatefulWidget {
  final int channel; final AppState appState;
  const _RawRow({required this.channel, required this.appState});
  @override State<_RawRow> createState() => _RawRowState();
}

class _RawRowState extends State<_RawRow> {
  double? _drag;
  int get _pct => _drag?.toInt() ?? widget.appState.effectiveBrightness(widget.channel);

  @override
  Widget build(BuildContext context) {
    final pct = _pct; final color = pct > 0 ? C.accent : C.textTri;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.x4, Sp.x2, Sp.x4, Sp.x2),
      child: Row(children: [
        SizedBox(width: 44, child: Text('Ch ${ widget.channel}', style: AppText.small.copyWith(fontSize: 11))),
        Expanded(child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            activeTrackColor: color, inactiveTrackColor: C.border, thumbColor: color,
          ),
          child: Slider(
            value: pct.toDouble(), min: 0, max: 100, divisions: 100,
            onChanged: (v) => setState(() => _drag = v),
            onChangeEnd: (v) { setState(() => _drag = null); widget.appState.setDaliBrightness(widget.channel, v.toInt()); },
          ),
        )),
        SizedBox(width: 38, child: Text('$pct%', textAlign: TextAlign.end,
            style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w700, color: color,
                fontFeatures: [const FontFeature.tabularFigures()]))),
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
    padding: const EdgeInsets.fromLTRB(Sp.x5, Sp.x5, Sp.x5, 0),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ShimmerBox(width: 240, height: 40, radius: 12),
      const SizedBox(height: Sp.x2),
      ShimmerBox(width: 140, height: 16, radius: 8),
      const SizedBox(height: Sp.x8),
      ShimmerBox(width: double.infinity, height: 76, radius: 20),
      const SizedBox(height: Sp.x8),
      SizedBox(height: 84, child: Row(children: [
        for (int i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(width: Sp.x3),
          Expanded(child: ShimmerBox(width: double.infinity, height: 84, radius: 18)),
        ],
      ])),
      const SizedBox(height: Sp.x8),
      for (int r = 0; r < 2; r++) ...[
        ShimmerBox(width: double.infinity, height: 180, radius: 22),
        const SizedBox(height: Sp.x3),
      ],
    ]),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

Color _brightness2color(int pct) {
  if (pct == 0)  return C.textTri;
  if (pct < 15)  return C.purple;
  if (pct < 35)  return C.blue;
  if (pct < 65)  return C.orange;
  return C.accent;
}
