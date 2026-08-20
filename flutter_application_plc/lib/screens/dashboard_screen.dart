import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../auth/auth_state.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common_widgets.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// Lugh — Digital Home
//
// This is not a control panel. This is your home.
// Architecture: Immersive Hero → Home Insights → Spatial Rooms → Atmosphere
// Every room is a living space. Every light glows. Everything breathes.
// ═══════════════════════════════════════════════════════════════════════════════

class DashboardScreen extends StatefulWidget {
  final AppState     appState;
  final AuthState    authState;
  final VoidCallback onOpenMap;
  final VoidCallback onOpenCommission;
  final VoidCallback onOpenMapEditor;

  const DashboardScreen({
    super.key,
    required this.appState,
    required this.authState,
    required this.onOpenMap,
    required this.onOpenCommission,
    required this.onOpenMapEditor,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with TickerProviderStateMixin {
  AppState get _st => widget.appState;

  late final AnimationController _breatheCtrl;
  late final Animation<double>   _breatheAnim;

  @override
  void initState() {
    super.initState();
    _breatheCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat(reverse: true);
    _breatheAnim = CurvedAnimation(parent: _breatheCtrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _breatheCtrl.dispose();
    super.dispose();
  }

  // ── Time context ──────────────────────────────────────────────────────────
  static String _greeting() {
    final h = DateTime.now().hour;
    if (h >= 5  && h < 12) return 'Good morning';
    if (h >= 12 && h < 17) return 'Good afternoon';
    if (h >= 17 && h < 21) return 'Good evening';
    return 'Good night';
  }

  static List<Color> _timeColors() {
    final h = DateTime.now().hour;
    if (h >= 5  && h < 9)  return [const Color(0xFF2A1200), const Color(0xFF140800)];
    if (h >= 9  && h < 17) return [const Color(0xFF030B26), const Color(0xFF010618)];
    if (h >= 17 && h < 21) return [const Color(0xFF1E0700), const Color(0xFF0E0300)];
    return [const Color(0xFF00041A), const Color(0xFF00020E)];
  }

  static IconData _timeIcon() {
    final h = DateTime.now().hour;
    if (h >= 5  && h < 9)  return Icons.wb_sunny_rounded;
    if (h >= 9  && h < 17) return Icons.light_mode_rounded;
    if (h >= 17 && h < 21) return Icons.wb_twilight_rounded;
    return Icons.bedtime_rounded;
  }

  // ── Room visual identity ──────────────────────────────────────────────────
  static Color _roomColor(String r) {
    final n = r.toLowerCase();
    if (n.contains('living'))                        return const Color(0xFF5BA8FF);
    if (n.contains('kitchen'))                       return const Color(0xFFFD9A3E);
    if (n.contains('bedroom') || n.contains('bed'))  return const Color(0xFF9F7BFA);
    if (n.contains('bath'))                          return const Color(0xFF26D4BE);
    if (n.contains('dining'))                        return const Color(0xFFFD6A3E);
    if (n.contains('garden') || n.contains('yard'))  return const Color(0xFF66BB6A);
    if (n.contains('hall'))                          return const Color(0xFF7CB0E8);
    if (n.contains('cinema') || n.contains('media')) return const Color(0xFFCE93D8);
    if (n.contains('office') || n.contains('study')) return const Color(0xFF64B5F6);
    if (n.contains('kids')   || n.contains('child')) return const Color(0xFFFF8A65);
    if (n.contains('garage'))                        return const Color(0xFF90A4AE);
    return C.accent;
  }

  static IconData _roomIcon(String r) {
    final n = r.toLowerCase();
    if (n.contains('living'))                        return Icons.weekend_rounded;
    if (n.contains('kitchen'))                       return Icons.soup_kitchen_rounded;
    if (n.contains('bedroom') || n.contains('bed'))  return Icons.king_bed_rounded;
    if (n.contains('bath'))                          return Icons.bathtub_rounded;
    if (n.contains('dining'))                        return Icons.restaurant_rounded;
    if (n.contains('garden') || n.contains('yard'))  return Icons.yard_rounded;
    if (n.contains('hall'))                          return Icons.meeting_room_rounded;
    if (n.contains('cinema') || n.contains('media')) return Icons.movie_rounded;
    if (n.contains('office') || n.contains('study')) return Icons.computer_rounded;
    if (n.contains('kids')   || n.contains('child')) return Icons.child_care_rounded;
    if (n.contains('garage'))                        return Icons.garage_rounded;
    return Icons.room_rounded;
  }

  static Color _brightnessToColor(int pct) {
    if (pct == 0)  return C.textTri;
    if (pct < 20)  return C.purple;
    if (pct < 45)  return C.blue;
    if (pct < 70)  return C.orange;
    return C.accent;
  }

  // ── State helpers ─────────────────────────────────────────────────────────
  int  _brightness(int ch) => _st.pendingBrightness[ch] ?? _st.state.dali[ch]  ?? 0;

  /// Raising brightness uses undimDurationMs, lowering uses dimDurationMs —
  /// matches how a real dimmer switch feels (snapping on faster than fading
  /// off is the more natural default, hence the different defaults server-
  /// side too). No change (v == current) skips the fade entirely.
  int _fadeDurationFor(int channel, int target) {
    final current = _brightness(channel);
    if (target == current) return 0;
    final user = widget.authState.user;
    return target > current
        ? (user?.undimDurationMs ?? 500)
        : (user?.dimDurationMs   ?? 800);
  }
  bool _relayOn(int ch)    => _st.pendingRelay[ch]      ?? _st.state.relays[ch] ?? false;

  List<DaliDevice>  _lights(String r) => _st.daliDevices .where((d) => d.room == r).toList();
  List<RelayDevice> _relays(String r) => _st.relayDevices.where((d) => d.room == r).toList();
  int _onCount(String r) => _lights(r).where((d) => _brightness(d.channel) > 0).length;

  int get _totalLightsOn => _st.daliDevices.where((d) => _brightness(d.channel) > 0).length;
  int get _activeRooms   => _st.rooms.where((r) => _onCount(r) > 0).length;

  // ── Room sheet ────────────────────────────────────────────────────────────
  void _openRoom(String room) {
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context:            context,
      isScrollControlled: true,
      backgroundColor:    Colors.transparent,
      builder: (_) => ListenableBuilder(
        listenable: _st,
        builder: (_, _) => _RoomSheet(
          room:       room,
          color:      _roomColor(room),
          icon:       _roomIcon(room),
          lights:     _lights(room),
          relays:     _relays(room),
          brightness: _brightness,
          relayOn:    _relayOn,
          bColor:     _brightnessToColor,
          onSetLight: (ch, v) => _st.setDaliBrightness(ch, v, durationMs: _fadeDurationFor(ch, v)),
          onSetRoom:  (pct)   => _st.setRoomBrightness(room, pct),
          onSetRelay: (ch, v) => _st.setRelay(ch, v),
        ),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // Merged with authState: the hero banner reads widget.authState.apartmentName
      // below, which arrives asynchronously after login (_loadPermissions()) —
      // listening to _st alone left it stuck on the "Apartment {id}" fallback
      // until AppState happened to notify for an unrelated reason.
      listenable: Listenable.merge([_st, widget.authState]),
      builder: (_, _) {
        final rooms      = _st.rooms;
        final totalOn    = _totalLightsOn;
        final activeRms  = _activeRooms;
        final sceneName  = _st.activeSceneIndex != null
            ? LightScene.presets[_st.activeSceneIndex!].name
            : null;

        return Scaffold(
          backgroundColor: C.bg,
          body: CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [

              // ── Immersive hero ───────────────────────────────────────────
              SliverAppBar(
                expandedHeight: 252,
                pinned:    true,
                stretch:   true,
                backgroundColor: C.surface,
                surfaceTintColor: Colors.transparent,
                elevation: 0,
                scrolledUnderElevation: 0,
                title: _PinnedHeader(appState: _st),
                titleSpacing: 0,
                actions: [
                  // Map mode — full-screen digital twin (handled by MainShell)
                  IconButton(
                    icon: const Icon(Icons.map_rounded,
                        color: C.textSec, size: 20),
                    onPressed: widget.onOpenMap,
                    tooltip: 'Floor plan',
                  ),
                  const SizedBox(width: 4),
                ],
                flexibleSpace: FlexibleSpaceBar(
                  collapseMode: CollapseMode.parallax,
                  stretchModes: const [StretchMode.zoomBackground],
                  background: _HeroBanner(
                    greeting:    _greeting(),
                    bgColors:    _timeColors(),
                    timeIcon:    _timeIcon(),
                    totalOn:     totalOn,
                    aptId:       _st.state.apartmentId,
                    apartmentName: widget.authState.apartmentName,
                    breatheAnim: _breatheAnim,
                    appState:    _st,
                  ),
                ),
              ),

              // ── Body ─────────────────────────────────────────────────────
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [

                    // ── Tech Team quick actions ──────────────────────────
                    if (widget.authState.user?.isStaff ?? false) ...[
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Row(children: [
                          Expanded(
                            child: _StaffActionButton(
                              icon:  Icons.checklist_rounded,
                              label: 'Commission',
                              onTap: widget.onOpenCommission,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _StaffActionButton(
                              icon:  Icons.edit_square,
                              label: 'Map Editor',
                              onTap: widget.onOpenMapEditor,
                            ),
                          ),
                        ]),
                      ),
                    ],

                    // ── Home insights row ────────────────────────────────
                    const SizedBox(height: 20),
                    SizedBox(
                      height: 76,
                      child: _HomeInsightsRow(
                        activeRooms: activeRms,
                        totalRooms:  rooms.length,
                        totalOn:     totalOn,
                        sceneName:   sceneName,
                        appState:    _st,
                      ),
                    ),

                    // ── Spatial room grid ──────────────────────────────
                    if (rooms.isNotEmpty) ...[
                      _SectionLabel('your home', badge: '${rooms.length}', top: 24),
                      const SizedBox(height: 14),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: _SpatialRoomGrid(
                          rooms:     rooms,
                          onCount:   _onCount,
                          lights:    _lights,
                          roomColor: _roomColor,
                          roomIcon:  _roomIcon,
                          onTap:     _openRoom,
                        ),
                      ),
                    ],

                    // ── Atmosphere ───────────────────────────────────────
                    _SectionLabel('atmosphere', top: 28),
                    const SizedBox(height: 14),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: _AtmosphereGrid(appState: _st),
                    ),

                    // ── Switches ─────────────────────────────────────────
                    if (_st.relayDevices.isNotEmpty) ...[
                      _SectionLabel('switches', top: 28),
                      const SizedBox(height: 14),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: _SwitchGrid(
                          devices:  _st.relayDevices,
                          relayOn:  _relayOn,
                          onToggle: (ch, v) => _st.setRelay(ch, v),
                        ),
                      ),
                    ],

                    // ── Ventilators & Extra Lights ────────────────────────
                    if ((widget.authState.user?.showVentilatorsHome ?? true) &&
                        _st.toggleDevices.isNotEmpty) ...[
                      _SectionLabel('ventilators & extra lights', top: 28),
                      const SizedBox(height: 14),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: _VentilatorGrid(
                          devices: _st.toggleDevices,
                          isOn:    _st.effectiveToggle,
                          onToggle: (varName, v) => _st.setToggle(varName, v),
                        ),
                      ),
                    ],

                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Pinned header
// ═══════════════════════════════════════════════════════════════════════════════

class _PinnedHeader extends StatelessWidget {
  final AppState appState;
  const _PinnedHeader({required this.appState});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 16),
    child: Row(children: [
      Container(
        width: 28, height: 28,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8), gradient: G.accent),
        child: const Icon(Icons.bolt_rounded, size: 16, color: Colors.black),
      ),
      const SizedBox(width: 8),
      Text('Lugh', style: AppText.title.copyWith(letterSpacing: -0.5)),
    ]),
  );
}


// ═══════════════════════════════════════════════════════════════════════════════
// Immersive hero banner
// ═══════════════════════════════════════════════════════════════════════════════

class _HeroBanner extends StatelessWidget {
  final String      greeting;
  final List<Color> bgColors;
  final IconData    timeIcon;
  final int         totalOn;
  final int         aptId;
  final String?     apartmentName;
  final Animation<double> breatheAnim;
  final AppState    appState;

  const _HeroBanner({
    required this.greeting, required this.bgColors, required this.timeIcon,
    required this.totalOn,  required this.aptId,    required this.breatheAnim,
    required this.appState, this.apartmentName,
  });

  @override
  Widget build(BuildContext context) {
    final isActive   = totalOn > 0;
    final statusText = isActive
        ? '$totalOn ${totalOn == 1 ? 'light' : 'lights'} on'
        : 'Everything calm';

    return AnimatedBuilder(
      animation: breatheAnim,
      builder: (_, _) => Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: bgColors,
          ),
        ),
        child: Stack(children: [
          // Breathing ambient orb — shifts subtly with breatheAnim
          Positioned(
            top: -60 + breatheAnim.value * 20,
            right: -40 + breatheAnim.value * 15,
            child: Container(
              width: 240, height: 240,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(colors: [
                  C.accent.withAlpha((12 + (breatheAnim.value * 8)).round()),
                  Colors.transparent,
                ]),
              ),
            ),
          ),
          // Second ambient orb (bottom-left, opposite phase)
          Positioned(
            bottom: -30 - breatheAnim.value * 10,
            left: -20,
            child: Container(
              width: 160, height: 160,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(colors: [
                  (isActive ? C.orange : C.blue).withAlpha(
                      (8 + ((1 - breatheAnim.value) * 6)).round()),
                  Colors.transparent,
                ]),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 52, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Location label
                  Row(children: [
                    Icon(timeIcon, color: C.accent.withAlpha(150), size: 12),
                    const SizedBox(width: 6),
                    Text(apartmentName ?? 'Apartment $aptId',
                        style: AppText.small.copyWith(color: C.textSec)),
                  ]),
                  const SizedBox(height: 10),
                  // Greeting
                  Text(greeting,
                    style: GoogleFonts.inter(
                      fontSize: 28, fontWeight: FontWeight.w700,
                      color: C.textPri, letterSpacing: -1.2, height: 1.0,
                    ),
                  ),
                  const Spacer(),
                  // Status + quick actions
                  Row(children: [
                    // Animated status pill
                    AnimatedContainer(
                      duration: Dur.normal,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                        color: isActive
                            ? C.accent.withAlpha(20)
                            : Colors.white.withAlpha(7),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: isActive
                              ? C.accent.withAlpha(55)
                              : C.border,
                          width: 0.5,
                        ),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        AnimatedContainer(
                          duration: Dur.normal,
                          width: 6, height: 6,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isActive ? C.accent : C.textTri,
                          ),
                        ),
                        const SizedBox(width: 7),
                        Text(statusText,
                          style: AppText.small.copyWith(
                            color: isActive ? C.accent : C.textSec,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ]),
                    ),
                    const Spacer(),
                    // All off
                    TapScale(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        appState.setAllDaliBrightness(0);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.white.withAlpha(8),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: C.border, width: 0.5),
                        ),
                        child: Text('All off',
                            style: AppText.small.copyWith(
                                color: C.textSec,
                                fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // All on
                    TapScale(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        appState.setAllDaliBrightness(100);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          gradient: G.accent,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                                color: C.accent.withAlpha(55),
                                blurRadius: 12)
                          ],
                        ),
                        child: Text('All on',
                            style: AppText.small.copyWith(
                                color: Colors.black,
                                fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ]),
                ],
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Home Insights — horizontal cards that tell the story of the home
// ═══════════════════════════════════════════════════════════════════════════════

class _HomeInsightsRow extends StatelessWidget {
  final int     activeRooms;
  final int     totalRooms;
  final int     totalOn;
  final String? sceneName;
  final AppState appState;

  const _HomeInsightsRow({
    required this.activeRooms, required this.totalRooms,
    required this.totalOn,     required this.appState,
    this.sceneName,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      children: [
        // Active rooms card
        _InsightCard(
          icon:  Icons.home_rounded,
          color: activeRooms > 0 ? C.accent : C.textTri,
          label: activeRooms > 0
              ? '$activeRooms of $totalRooms rooms active'
              : 'All rooms off',
          sub: activeRooms > 0
              ? '$totalOn lights on'
              : 'Everything calm',
          active: activeRooms > 0,
        ),
        const SizedBox(width: 10),
        // Scene card
        if (sceneName != null) ...[
          _InsightCard(
            icon:  Icons.auto_awesome_rounded,
            color: C.purple,
            label: sceneName!,
            sub:   'Active scene',
            active: true,
          ),
          const SizedBox(width: 10),
        ],
        // Connection card
        _InsightCard(
          icon:  appState.connected
              ? Icons.wifi_rounded
              : Icons.wifi_off_rounded,
          color: appState.connected ? C.green : C.red,
          label: appState.connected ? 'Connected' : 'Offline',
          sub: appState.connected
              ? '${appState.lastLatencyMs ?? '–'}ms'
              : 'Check settings',
          active: appState.connected,
        ),
        const SizedBox(width: 10),
        // Security stub card
        _InsightCard(
          icon:  Icons.shield_rounded,
          color: C.green,
          label: 'All secure',
          sub:   'No alerts',
          active: false,
        ),
      ],
    );
  }
}

class _InsightCard extends StatelessWidget {
  final IconData icon;
  final Color    color;
  final String   label;
  final String   sub;
  final bool     active;

  const _InsightCard({
    required this.icon, required this.color,
    required this.label, required this.sub, required this.active,
  });

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: Dur.normal,
    width: 162,
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: active ? color.withAlpha(14) : C.card,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(
        color: active ? color.withAlpha(50) : C.border, width: 0.5),
    ),
    child: Row(children: [
      Container(
        width: 34, height: 34,
        decoration: BoxDecoration(
          color: active ? color.withAlpha(22) : C.card2,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: active ? color : C.textTri, size: 17),
      ),
      const SizedBox(width: 10),
      Expanded(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label,
            style: AppText.small.copyWith(
              color: active ? C.textPri : C.textSec,
              fontWeight: FontWeight.w600, fontSize: 11,
            ),
            maxLines: 1, overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(sub,
            style: AppText.small.copyWith(
              color: active ? color : C.textTri, fontSize: 10),
            maxLines: 1,
          ),
        ],
      )),
    ]),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// Spatial Room Grid — your home, not a list
// Featured first room + 2-column grid for the rest
// ═══════════════════════════════════════════════════════════════════════════════

class _SpatialRoomGrid extends StatelessWidget {
  final List<String>             rooms;
  final int Function(String)     onCount;
  final List<DaliDevice> Function(String) lights;
  final Color Function(String)   roomColor;
  final IconData Function(String) roomIcon;
  final void Function(String)    onTap;

  const _SpatialRoomGrid({
    required this.rooms,    required this.onCount,  required this.lights,
    required this.roomColor, required this.roomIcon, required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (rooms.isEmpty) return const SizedBox.shrink();

    final featured = rooms.first;
    final rest     = rooms.length > 1 ? rooms.sublist(1) : <String>[];

    return Column(children: [
      // Featured room — full width, prominent
      _FeaturedRoomCard(
        room:    featured,
        icon:    roomIcon(featured),
        color:   roomColor(featured),
        on:      onCount(featured),
        total:   lights(featured).length,
        onTap:   () => onTap(featured),
      ),

      if (rest.isNotEmpty) ...[
        const SizedBox(height: 12),
        // Grid for remaining rooms
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: rest.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2, crossAxisSpacing: 12,
            mainAxisSpacing: 12, childAspectRatio: 0.88,
          ),
          itemBuilder: (_, i) {
            final room  = rest[i];
            final color = roomColor(room);
            final icon  = roomIcon(room);
            final on    = onCount(room);
            final total = lights(room).length;
            return _RoomGridCell(
              room:  room,  icon:  icon, color: color,
              on:    on,    total: total,
              onTap: () => onTap(room),
            );
          },
        ),
      ],
    ]);
  }
}

// ── Featured room (full-width, large) ─────────────────────────────────────────

class _FeaturedRoomCard extends StatelessWidget {
  final String   room;
  final IconData icon;
  final Color    color;
  final int      on;
  final int      total;
  final VoidCallback onTap;

  const _FeaturedRoomCard({
    required this.room, required this.icon, required this.color,
    required this.on,   required this.total, required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final active = on > 0;
    final status = total == 0 ? 'No lights'
        : on == 0   ? 'Off'
        : on == total ? 'All on'
        : '$on of $total lights on';

    return TapScale(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Dur.normal, curve: Cur.snap,
        height: 128,
        decoration: BoxDecoration(
          color: C.card,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active ? color.withAlpha(60) : C.border, width: 0.5),
          boxShadow: active
              ? [
                  BoxShadow(color: color.withAlpha(35), blurRadius: 30, spreadRadius: 0),
                  BoxShadow(color: Colors.black.withAlpha(70),
                      blurRadius: 16, offset: const Offset(0, 4)),
                ]
              : S.card,
        ),
        child: Stack(children: [
          // Ambient gradient overlay
          Positioned.fill(
            child: AnimatedContainer(
              duration: Dur.normal,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end:   Alignment.centerRight,
                  colors: active
                      ? [color.withAlpha(22), Colors.transparent]
                      : [Colors.transparent, Colors.transparent],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(children: [
              // Icon
              AnimatedContainer(
                duration: Dur.normal,
                width: 64, height: 64,
                decoration: BoxDecoration(
                  color: active ? color.withAlpha(28) : C.card2,
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: active
                      ? [BoxShadow(color: color.withAlpha(50), blurRadius: 20)]
                      : null,
                ),
                child: Icon(icon,
                    color: active ? color : C.textTri, size: 30),
              ),
              const SizedBox(width: 20),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(room,
                    style: AppText.h2.copyWith(
                      fontSize: 18, letterSpacing: -0.5),
                  ),
                  const SizedBox(height: 4),
                  Text(status,
                    style: AppText.body.copyWith(
                      color: active ? color : C.textTri,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  if (total > 0) ...[
                    const SizedBox(height: 12),
                    // Light dot indicators
                    Row(children: List.generate(total, (i) {
                      final isOn = i < on;
                      return Container(
                        width: 6, height: 6,
                        margin: const EdgeInsets.only(right: 5),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isOn ? color : C.border,
                          boxShadow: isOn
                              ? [BoxShadow(
                                  color: color.withAlpha(100),
                                  blurRadius: 4)]
                              : null,
                        ),
                      );
                    })),
                  ],
                ],
              )),
              // Arrow
              Icon(Icons.chevron_right_rounded,
                  color: active ? color.withAlpha(150) : C.textTri,
                  size: 22),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ── Room grid cell (2-column) ─────────────────────────────────────────────────

class _RoomGridCell extends StatelessWidget {
  final String   room;
  final IconData icon;
  final Color    color;
  final int      on;
  final int      total;
  final VoidCallback onTap;

  const _RoomGridCell({
    required this.room, required this.icon, required this.color,
    required this.on,   required this.total, required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final active = on > 0;
    final status = total == 0 ? 'No lights'
        : on == 0   ? 'Off'
        : on == total ? 'All on'
        : '$on/$total on';

    return TapScale(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Dur.normal, curve: Cur.snap,
        decoration: BoxDecoration(
          color: C.card,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: active ? color.withAlpha(55) : C.border, width: 0.5),
          boxShadow: active
              ? [
                  BoxShadow(color: color.withAlpha(28), blurRadius: 24),
                  BoxShadow(color: Colors.black.withAlpha(60), blurRadius: 10,
                      offset: const Offset(0, 3)),
                ]
              : S.card,
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Icon with ambient background
              AnimatedContainer(
                duration: Dur.normal,
                width: 48, height: 48,
                decoration: BoxDecoration(
                  color: active ? color.withAlpha(25) : C.card2,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon,
                    color: active ? color : C.textTri, size: 24),
              ),
              const Spacer(),
              Text(room,
                style: AppText.bodyMed.copyWith(
                  fontSize: 13, letterSpacing: -0.3, color: C.textPri),
                maxLines: 2, overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 3),
              Text(status,
                style: AppText.small.copyWith(
                  color: active ? color : C.textTri, fontSize: 11,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400),
              ),
              if (total > 0) ...[
                const SizedBox(height: 10),
                // Mini light dots
                Row(children: List.generate(total, (i) {
                  final isOn = i < on;
                  return Container(
                    width: 5, height: 5,
                    margin: const EdgeInsets.only(right: 4),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isOn ? color : C.border,
                      boxShadow: isOn
                          ? [BoxShadow(color: color.withAlpha(80), blurRadius: 3)]
                          : null,
                    ),
                  );
                })),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Atmosphere grid — 2-col scene selector
// ═══════════════════════════════════════════════════════════════════════════════

class _AtmosphereGrid extends StatelessWidget {
  final AppState appState;
  const _AtmosphereGrid({required this.appState});

  @override
  Widget build(BuildContext context) {
    final scenes   = LightScene.presets;
    final selected = appState.activeSceneIndex;

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: scenes.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2, crossAxisSpacing: 12,
        mainAxisSpacing: 12, childAspectRatio: 1.5,
      ),
      itemBuilder: (_, i) {
        final scene  = scenes[i];
        final active = selected == i;
        return TapScale(
          onTap: () {
            HapticFeedback.selectionClick();
            appState.applyScene(scene, i);
          },
          child: AnimatedContainer(
            duration: Dur.normal, curve: Cur.snap,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft, end: Alignment.bottomRight,
                colors: active
                    ? [scene.color.withAlpha(48), scene.color.withAlpha(16)]
                    : [C.card2, C.card],
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: active ? scene.color.withAlpha(100) : C.border,
                width: active ? 1.0 : 0.5,
              ),
              boxShadow: active
                  ? [BoxShadow(color: scene.color.withAlpha(38), blurRadius: 18)]
                  : S.card,
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    AnimatedContainer(
                      duration: Dur.normal,
                      width: 34, height: 34,
                      decoration: BoxDecoration(
                        color: active
                            ? scene.color.withAlpha(35)
                            : Colors.white.withAlpha(8),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(scene.icon,
                          color: active ? scene.color : C.textSec, size: 18),
                    ),
                    if (active) ...[
                      const Spacer(),
                      Container(
                        width: 6, height: 6,
                        decoration: BoxDecoration(
                            shape: BoxShape.circle, color: scene.color),
                      ),
                    ],
                  ]),
                  const Spacer(),
                  Text(scene.name,
                    style: AppText.bodyMed.copyWith(
                      fontSize: 13,
                      color: active ? scene.color : C.textSec),
                  ),
                  Text('${scene.brightness}% brightness',
                    style: AppText.small.copyWith(
                      fontSize: 10,
                      color: active ? scene.color.withAlpha(160) : C.textTri),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Switch grid
// ═══════════════════════════════════════════════════════════════════════════════

class _StaffActionButton extends StatelessWidget {
  final IconData icon;
  final String   label;
  final VoidCallback onTap;

  const _StaffActionButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color:        C.surface,
        borderRadius: BorderRadius.circular(14),
        border:       Border.all(color: C.border, width: 0.5),
      ),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 15, color: C.accent),
        const SizedBox(width: 7),
        Text(label,
            style: const TextStyle(
              fontFamily: 'Inter', fontSize: 12,
              fontWeight: FontWeight.w700, color: C.accent,
            )),
      ]),
    ),
  );
}

class _VentilatorGrid extends StatelessWidget {
  final List<ToggleDevice> devices;
  final bool Function(String) isOn;
  final void Function(String, bool) onToggle;

  const _VentilatorGrid({
    required this.devices, required this.isOn, required this.onToggle});

  IconData _iconFor(String name) {
    final n = name.toLowerCase();
    if (n.contains('ventilator')) return Icons.air_rounded;
    if (n.contains('balcony')) return Icons.balcony_rounded;
    if (n.contains('mirror')) return Icons.wb_incandescent_rounded;
    return Icons.lightbulb_outline_rounded;
  }

  @override
  Widget build(BuildContext context) => GridView.builder(
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    itemCount: devices.length,
    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 2, crossAxisSpacing: 12,
      mainAxisSpacing: 12, childAspectRatio: 2.0,
    ),
    itemBuilder: (_, i) {
      final d  = devices[i];
      final on = isOn(d.varName);
      return AnimatedContainer(
        duration: Dur.normal,
        decoration: BoxDecoration(
          color: on ? C.green.withAlpha(15) : C.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: on ? C.green.withAlpha(60) : C.border, width: 0.5)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(children: [
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(_iconFor(d.name), color: on ? C.green : C.textTri, size: 18),
                const SizedBox(height: 5),
                Text(d.name,
                  style: AppText.small.copyWith(
                    color: on ? C.textPri : C.textSec,
                    fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                    fontSize: 10.5, height: 1.15),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
            )),
            if (d.writable)
              Switch(
                value: on,
                onChanged: (v) {
                  HapticFeedback.selectionClick();
                  onToggle(d.varName, v);
                },
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              )
            else
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: (on ? C.green : C.textTri).withAlpha(18),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(on ? 'ON' : 'OFF', style: AppText.small.copyWith(
                  color: on ? C.green : C.textTri, fontWeight: FontWeight.w600, fontSize: 10,
                )),
              ),
          ]),
        ),
      );
    },
  );
}

class _SwitchGrid extends StatelessWidget {
  final List<RelayDevice>        devices;
  final bool Function(int)       relayOn;
  final void Function(int, bool) onToggle;

  const _SwitchGrid({
    required this.devices, required this.relayOn, required this.onToggle});

  @override
  Widget build(BuildContext context) => GridView.builder(
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    itemCount: devices.length,
    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 2, crossAxisSpacing: 12,
      mainAxisSpacing: 12, childAspectRatio: 2.0,
    ),
    itemBuilder: (_, i) {
      final d  = devices[i];
      final on = relayOn(d.channel);
      return AnimatedContainer(
        duration: Dur.normal,
        decoration: BoxDecoration(
          color: on ? C.green.withAlpha(15) : C.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: on ? C.green.withAlpha(60) : C.border, width: 0.5)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(children: [
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  on ? Icons.lightbulb_rounded : Icons.lightbulb_outline_rounded,
                  color: on ? C.green : C.textTri, size: 18),
                const SizedBox(height: 5),
                Text(d.name,
                  style: AppText.small.copyWith(
                    color: on ? C.textPri : C.textSec,
                    fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                    fontSize: 11),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            )),
            Switch(
              value: on,
              onChanged: (v) {
                HapticFeedback.selectionClick();
                onToggle(d.channel, v);
              },
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ]),
        ),
      );
    },
  );
}


// ═══════════════════════════════════════════════════════════════════════════════
// Section label
// ═══════════════════════════════════════════════════════════════════════════════

class _SectionLabel extends StatelessWidget {
  final String  label;
  final String? badge;
  final double  top;
  const _SectionLabel(this.label, {this.badge, this.top = 0});

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(20, top, 20, 0),
    child: Row(children: [
      Text(label.toUpperCase(),
        style: AppText.small.copyWith(
          color: C.textTri, fontWeight: FontWeight.w700,
          letterSpacing: 1.4, fontSize: 10)),
      if (badge != null) ...[
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: C.card2, borderRadius: BorderRadius.circular(6)),
          child: Text(badge!,
            style: AppText.small.copyWith(
              color: C.textSec, fontSize: 9, fontWeight: FontWeight.w700)),
        ),
      ],
    ]),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// Room Sheet — full room experience
// ═══════════════════════════════════════════════════════════════════════════════

class _RoomSheet extends StatelessWidget {
  final String             room;
  final Color              color;
  final IconData           icon;
  final List<DaliDevice>   lights;
  final List<RelayDevice>  relays;
  final int  Function(int)  brightness;
  final bool Function(int)  relayOn;
  final Color Function(int) bColor;
  final void Function(int, int)  onSetLight;
  final void Function(int)       onSetRoom;
  final void Function(int, bool) onSetRelay;

  const _RoomSheet({
    required this.room,   required this.color,  required this.icon,
    required this.lights, required this.relays,
    required this.brightness, required this.relayOn, required this.bColor,
    required this.onSetLight, required this.onSetRoom, required this.onSetRelay,
  });

  int get _onCount => lights.where((d) => brightness(d.channel) > 0).length;

  @override
  Widget build(BuildContext context) {
    final onCount = _onCount;
    final status  = lights.isEmpty   ? 'No lights'
        : onCount == 0               ? 'All lights off'
        : onCount == lights.length   ? 'All on'
        : '$onCount of ${lights.length} on';

    final sz = lights.isEmpty ? 0.35
        : lights.length <= 3  ? 0.55
        : lights.length <= 6  ? 0.72
        : 0.88;

    return DraggableScrollableSheet(
      initialChildSize: sz,
      minChildSize: 0.28,
      maxChildSize: 0.95,
      builder: (_, ctrl) => Container(
        decoration: BoxDecoration(
          color: C.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(
              top: BorderSide(color: color.withAlpha(40), width: 0.5)),
        ),
        child: Column(children: [
          // Handle
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Container(
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: C.textTri.withAlpha(80),
                borderRadius: BorderRadius.circular(2)),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
            child: Row(children: [
              // Room icon with ambient glow
              AnimatedContainer(
                duration: Dur.normal,
                width: 48, height: 48,
                decoration: BoxDecoration(
                  color: color.withAlpha(25),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: onCount > 0
                      ? [BoxShadow(
                          color: color.withAlpha(60), blurRadius: 16)]
                      : null,
                ),
                child: Icon(icon, color: color, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(room,
                    style: AppText.h2.copyWith(
                      fontSize: 18, letterSpacing: -0.5)),
                  Text(status,
                    style: AppText.small.copyWith(
                      color: onCount > 0 ? color : C.textTri,
                      fontWeight: onCount > 0
                          ? FontWeight.w600
                          : FontWeight.w400,
                    )),
                ],
              )),
              if (lights.isNotEmpty) ...[
                _Btn(label: 'Off',
                    onTap: () {
                      HapticFeedback.selectionClick();
                      onSetRoom(0);
                    }),
                const SizedBox(width: 8),
                _Btn(label: 'On', accent: true,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      onSetRoom(100);
                    }),
              ],
            ]),
          ),

          Container(height: 0.5, color: C.border),

          // Content
          Expanded(
            child: ListView(
              controller: ctrl,
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
              children: [

                // ── Light fixtures ─────────────────────────────────────
                if (lights.isNotEmpty) ...[
                  // At-a-glance light overview
                  Wrap(
                    spacing: 10, runSpacing: 10,
                    children: lights.map((d) {
                      final pct  = brightness(d.channel);
                      final clr  = bColor(pct);
                      final isOn = pct > 0;
                      return TapScale(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          onSetLight(d.channel, isOn ? 0 : 100);
                        },
                        child: AnimatedContainer(
                          duration: Dur.fast,
                          width: 64, height: 64,
                          decoration: BoxDecoration(
                            color: isOn ? clr.withAlpha(22) : C.card2,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: isOn ? clr.withAlpha(80) : C.border,
                              width: 0.5),
                            boxShadow: isOn
                                ? [BoxShadow(color: clr.withAlpha(60),
                                    blurRadius: 10)]
                                : null,
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                isOn
                                    ? Icons.lightbulb_rounded
                                    : Icons.lightbulb_outline_rounded,
                                color: isOn ? clr : C.textTri, size: 22),
                              if (isOn) ...[
                                const SizedBox(height: 2),
                                Text('$pct%',
                                  style: AppText.small.copyWith(
                                    color: clr, fontSize: 9,
                                    fontWeight: FontWeight.w700)),
                              ],
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 20),
                  Container(height: 0.5, color: C.border),
                  const SizedBox(height: 20),

                  // Individual sliders
                  ...lights.map((d) {
                    final pct  = brightness(d.channel);
                    final clr  = bColor(pct);
                    final isOn = pct > 0;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            AnimatedContainer(
                              duration: Dur.fast,
                              width: 8, height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isOn ? clr : C.border,
                                boxShadow: isOn
                                    ? [BoxShadow(
                                        color: clr.withAlpha(130),
                                        blurRadius: 6)]
                                    : null,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(child: Text(d.name,
                              style: AppText.body.copyWith(
                                color: isOn ? C.textPri : C.textSec,
                                fontWeight: isOn
                                    ? FontWeight.w600
                                    : FontWeight.w400),
                            )),
                            Text('$pct%',
                              style: AppText.small.copyWith(
                                color: isOn ? clr : C.textTri,
                                fontWeight: FontWeight.w700,
                                fontFeatures: [
                                  const FontFeature.tabularFigures()],
                              )),
                          ]),
                          const SizedBox(height: 4),
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              activeTrackColor:   clr,
                              thumbColor:         clr,
                              inactiveTrackColor: C.border2,
                              overlayColor:       clr.withAlpha(20),
                              trackHeight:        5,
                            ),
                            child: Slider(
                              value:     pct.toDouble(),
                              min:       0, max: 100, divisions: 20,
                              onChanged: (v) =>
                                  onSetLight(d.channel, v.round()),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ],

                // ── Relay switches ─────────────────────────────────────
                if (relays.isNotEmpty) ...[
                  if (lights.isNotEmpty)
                    Container(height: 0.5, color: C.border,
                        margin: const EdgeInsets.only(bottom: 16)),
                  Wrap(
                    spacing: 10, runSpacing: 10,
                    children: relays.map((d) {
                      final on = relayOn(d.channel);
                      return TapScale(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          onSetRelay(d.channel, !on);
                        },
                        child: AnimatedContainer(
                          duration: Dur.fast,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: on ? C.green.withAlpha(20) : C.card,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: on
                                  ? C.green.withAlpha(80)
                                  : C.border,
                              width: 0.5),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 6, height: 6,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: on ? C.green : C.textTri)),
                              const SizedBox(width: 8),
                              Text(d.name,
                                style: AppText.small.copyWith(
                                  color: on ? C.textPri : C.textSec,
                                  fontWeight: on
                                      ? FontWeight.w600
                                      : FontWeight.w400)),
                            ]),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

// ── Quick action button ───────────────────────────────────────────────────────

class _Btn extends StatelessWidget {
  final String label;
  final bool   accent;
  final VoidCallback onTap;
  const _Btn({required this.label, required this.onTap, this.accent = false});

  @override
  Widget build(BuildContext context) => TapScale(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        gradient: accent ? G.accent : null,
        color:    accent ? null : C.card2,
        borderRadius: BorderRadius.circular(20),
        boxShadow: accent
            ? [BoxShadow(color: C.accent.withAlpha(50), blurRadius: 10)]
            : null,
        border: accent ? null : Border.all(color: C.border, width: 0.5),
      ),
      child: Text(label,
        style: AppText.small.copyWith(
          color: accent ? Colors.black : C.textSec,
          fontWeight: FontWeight.w700)),
    ),
  );
}
