import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../auth/auth_state.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common_widgets.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// Dashboard — Your home, at a glance
// Architecture: Hero → Room Carousel → Atmosphere Grid → Quick Switches
// Rooms open as a detail sheet — no engineering lists on the main screen
// ═══════════════════════════════════════════════════════════════════════════════

class DashboardScreen extends StatefulWidget {
  final AppState  appState;
  final AuthState authState;
  const DashboardScreen({super.key, required this.appState, required this.authState});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  AppState get _st => widget.appState;

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
    if (h >= 5  && h < 9)  return [const Color(0xFF2A1200), const Color(0xFF0A0400)];
    if (h >= 9  && h < 17) return [const Color(0xFF030820), const Color(0xFF010412)];
    if (h >= 17 && h < 21) return [const Color(0xFF200700), const Color(0xFF0A0300)];
    return [const Color(0xFF00051A), const Color(0xFF010310)];
  }

  static IconData _timeIcon() {
    final h = DateTime.now().hour;
    if (h >= 5  && h < 9)  return Icons.wb_sunny_rounded;
    if (h >= 9  && h < 17) return Icons.light_mode_rounded;
    if (h >= 17 && h < 21) return Icons.wb_twilight_rounded;
    return Icons.bedtime_rounded;
  }

  // ── Room visual palette ───────────────────────────────────────────────────

  static Color _roomColor(String r) {
    final n = r.toLowerCase();
    if (n.contains('living'))                       return const Color(0xFF5BA8FF);
    if (n.contains('kitchen'))                      return const Color(0xFFFD9A3E);
    if (n.contains('bedroom') || n.contains('bed')) return const Color(0xFF9F7BFA);
    if (n.contains('bath'))                         return const Color(0xFF26D4BE);
    if (n.contains('dining'))                       return const Color(0xFFFD6A3E);
    if (n.contains('garden') || n.contains('yard')) return const Color(0xFF66BB6A);
    if (n.contains('hall'))                         return const Color(0xFF7CB0E8);
    if (n.contains('cinema') || n.contains('media'))return const Color(0xFFCE93D8);
    if (n.contains('office') || n.contains('study'))return const Color(0xFF64B5F6);
    if (n.contains('kids')   || n.contains('child'))return const Color(0xFFFF8A65);
    if (n.contains('garage'))                       return const Color(0xFF90A4AE);
    return C.accent;
  }

  static IconData _roomIcon(String r) {
    final n = r.toLowerCase();
    if (n.contains('living'))                       return Icons.weekend_rounded;
    if (n.contains('kitchen'))                      return Icons.soup_kitchen_rounded;
    if (n.contains('bedroom') || n.contains('bed')) return Icons.king_bed_rounded;
    if (n.contains('bath'))                         return Icons.bathtub_rounded;
    if (n.contains('dining'))                       return Icons.restaurant_rounded;
    if (n.contains('garden') || n.contains('yard')) return Icons.yard_rounded;
    if (n.contains('hall'))                         return Icons.meeting_room_rounded;
    if (n.contains('cinema') || n.contains('media'))return Icons.movie_rounded;
    if (n.contains('office') || n.contains('study'))return Icons.computer_rounded;
    if (n.contains('kids')   || n.contains('child'))return Icons.child_care_rounded;
    if (n.contains('garage'))                       return Icons.garage_rounded;
    return Icons.room_rounded;
  }

  static Color _brightnessToColor(int pct) {
    if (pct == 0)  return C.textTri;
    if (pct < 20)  return C.purple;
    if (pct < 45)  return C.blue;
    if (pct < 70)  return C.orange;
    return C.accent;
  }

  // ── Live state helpers ────────────────────────────────────────────────────

  int  _brightness(int ch) => _st.pendingBrightness[ch] ?? _st.state.dali[ch]  ?? 0;
  bool _relayOn(int ch)    => _st.pendingRelay[ch]      ?? _st.state.relays[ch] ?? false;

  List<DaliDevice>  _lights(String room) => _st.daliDevices .where((d) => d.room == room).toList();
  List<RelayDevice> _relays(String room) => _st.relayDevices.where((d) => d.room == room).toList();
  int _onCount(String room) => _lights(room).where((d) => _brightness(d.channel) > 0).length;

  // ── Room sheet ────────────────────────────────────────────────────────────

  void _openRoom(String room) {
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context:            context,
      isScrollControlled: true,
      backgroundColor:    Colors.transparent,
      builder: (_) => ListenableBuilder(
        listenable: _st,
        builder: (_, __) => _RoomSheet(
          room:       room,
          color:      _roomColor(room),
          icon:       _roomIcon(room),
          lights:     _lights(room),
          relays:     _relays(room),
          brightness: _brightness,
          relayOn:    _relayOn,
          bColor:     _brightnessToColor,
          onSetLight: (ch, v) => _st.setDaliBrightness(ch, v),
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
      listenable: _st,
      builder: (_, __) {
        final rooms   = _st.rooms;
        final totalOn = _st.daliDevices.where((d) => _brightness(d.channel) > 0).length;

        return Scaffold(
          backgroundColor: C.bg,
          body: CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [

              // ── Collapsing hero ──────────────────────────────────────────
              SliverAppBar(
                expandedHeight: 226,
                pinned:    true,
                stretch:   true,
                backgroundColor: C.surface,
                surfaceTintColor: Colors.transparent,
                elevation: 0,
                scrolledUnderElevation: 0,
                title: _PinnedHeader(appState: _st),
                titleSpacing: 0,
                flexibleSpace: FlexibleSpaceBar(
                  collapseMode: CollapseMode.parallax,
                  stretchModes: const [StretchMode.zoomBackground],
                  background: _HeroBanner(
                    greeting: _greeting(),
                    bgColors: _timeColors(),
                    timeIcon: _timeIcon(),
                    totalOn:  totalOn,
                    aptId:    _st.state.apartmentId,
                    appState: _st,
                  ),
                ),
              ),

              // ── Scrollable body ──────────────────────────────────────────
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [

                    // ── Room carousel ──────────────────────────────────────
                    if (rooms.isNotEmpty) ...[
                      _SectionLabel('your spaces', badge: '${rooms.length}', top: 28),
                      const SizedBox(height: 14),
                      SizedBox(
                        height: 186,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          physics: const BouncingScrollPhysics(),
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          itemCount: rooms.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 12),
                          itemBuilder: (_, i) {
                            final room    = rooms[i];
                            final onCount = _onCount(room);
                            final total   = _lights(room).length;
                            return _RoomCard(
                              room:    room,
                              icon:    _roomIcon(room),
                              color:   _roomColor(room),
                              onCount: onCount,
                              total:   total,
                              onTap:   () => _openRoom(room),
                            );
                          },
                        ),
                      ),
                    ],

                    // ── Atmosphere / scenes ────────────────────────────────
                    _SectionLabel('atmosphere', top: 28),
                    const SizedBox(height: 14),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: _SceneGrid(appState: _st),
                    ),

                    // ── Relay switches ─────────────────────────────────────
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

                    const SizedBox(height: 36),
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
// Pinned header (collapsed)
// ═══════════════════════════════════════════════════════════════════════════════

class _PinnedHeader extends StatelessWidget {
  final AppState appState;
  const _PinnedHeader({required this.appState});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Row(children: [
      Container(
        width: 28, height: 28,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          gradient: G.accent,
        ),
        child: const Icon(Icons.bolt_rounded, size: 16, color: Colors.black),
      ),
      const SizedBox(width: 8),
      Expanded(child: Text('Lugh',
          style: AppText.title.copyWith(letterSpacing: -0.5))),
      _LiveBadge(appState: appState),
    ]),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// Live / Offline badge
// ═══════════════════════════════════════════════════════════════════════════════

class _LiveBadge extends StatelessWidget {
  final AppState appState;
  const _LiveBadge({required this.appState});

  @override
  Widget build(BuildContext context) {
    final live  = appState.connected;
    final color = live ? C.green : C.red;
    final label = live ? 'Live'
        : appState.connecting ? 'Connecting' : 'Offline';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color:        color.withAlpha(20),
        borderRadius: BorderRadius.circular(20),
        border:       Border.all(color: color.withAlpha(60), width: 0.5),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 6, height: 6,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        const SizedBox(width: 5),
        Text(label,
          style: AppText.small.copyWith(
            color: color, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Hero banner (expanded)
// ═══════════════════════════════════════════════════════════════════════════════

class _HeroBanner extends StatelessWidget {
  final String      greeting;
  final List<Color> bgColors;
  final IconData    timeIcon;
  final int         totalOn;
  final int         aptId;
  final AppState    appState;

  const _HeroBanner({
    required this.greeting,
    required this.bgColors,
    required this.timeIcon,
    required this.totalOn,
    required this.aptId,
    required this.appState,
  });

  @override
  Widget build(BuildContext context) {
    final isActive   = totalOn > 0;
    final statusText = isActive
        ? '$totalOn ${totalOn == 1 ? 'light' : 'lights'} on'
        : 'All lights off';

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end:   Alignment.bottomRight,
          colors: bgColors,
        ),
      ),
      child: Stack(children: [
        // Accent orb
        Positioned(
          top: -50, right: -30,
          child: Container(
            width: 200, height: 200,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [
                C.accent.withAlpha(14), Colors.transparent,
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
                // Apartment label
                Row(children: [
                  Icon(timeIcon, color: C.accent.withAlpha(150), size: 12),
                  const SizedBox(width: 6),
                  Text('Apartment $aptId',
                    style: AppText.small.copyWith(color: C.textSec)),
                ]),
                const SizedBox(height: 8),
                Text(greeting,
                  style: GoogleFonts.inter(
                    fontSize: 26, fontWeight: FontWeight.w700,
                    color: C.textPri, letterSpacing: -1.0, height: 1.1,
                  ),
                ),
                const Spacer(),
                // Status + quick actions
                Row(children: [
                  // Status pill
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: isActive ? C.accent.withAlpha(18) : Colors.white.withAlpha(7),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isActive ? C.accent.withAlpha(50) : C.border,
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
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                        color: Colors.white.withAlpha(8),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: C.border, width: 0.5),
                      ),
                      child: Text('All off',
                        style: AppText.small.copyWith(
                          color: C.textSec, fontWeight: FontWeight.w600)),
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
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                        gradient: G.accent,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(color: C.accent.withAlpha(50), blurRadius: 12),
                        ],
                      ),
                      child: Text('All on',
                        style: AppText.small.copyWith(
                          color: Colors.black, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ]),
    );
  }
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
          letterSpacing: 1.4, fontSize: 10,
        ),
      ),
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
// Room card — horizontal carousel item
// ═══════════════════════════════════════════════════════════════════════════════

class _RoomCard extends StatelessWidget {
  final String     room;
  final IconData   icon;
  final Color      color;
  final int        onCount;
  final int        total;
  final VoidCallback onTap;

  const _RoomCard({
    required this.room, required this.icon, required this.color,
    required this.onCount, required this.total, required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final active = onCount > 0;
    final status = total == 0  ? 'No lights'
        : onCount == 0         ? 'Off'
        : onCount == total     ? 'All on'
        : '$onCount of $total on';

    return TapScale(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Dur.normal, curve: Cur.snap,
        width: 148,
        decoration: BoxDecoration(
          color: C.card,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active ? color.withAlpha(55) : C.border, width: 0.5),
          boxShadow: active
              ? [
                  BoxShadow(color: color.withAlpha(30), blurRadius: 24),
                  BoxShadow(color: Colors.black.withAlpha(60), blurRadius: 12,
                      offset: const Offset(0, 4)),
                ]
              : S.card,
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedContainer(
                duration: Dur.normal,
                width: 46, height: 46,
                decoration: BoxDecoration(
                  color: active ? color.withAlpha(25) : C.card2,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: active ? color : C.textTri, size: 22),
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
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: onCount / total,
                    backgroundColor: C.border,
                    valueColor: AlwaysStoppedAnimation(active ? color : C.textTri),
                    minHeight: 2,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Scene grid — 2-column atmosphere selector
// ═══════════════════════════════════════════════════════════════════════════════

class _SceneGrid extends StatelessWidget {
  final AppState appState;
  const _SceneGrid({required this.appState});

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
        mainAxisSpacing: 12, childAspectRatio: 1.55,
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
                    ? [scene.color.withAlpha(45), scene.color.withAlpha(15)]
                    : [C.card2, C.card],
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: active ? scene.color.withAlpha(110) : C.border,
                width: active ? 1.0 : 0.5,
              ),
              boxShadow: active
                  ? [BoxShadow(color: scene.color.withAlpha(35), blurRadius: 16)]
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
                      width: 32, height: 32,
                      decoration: BoxDecoration(
                        color: active
                            ? scene.color.withAlpha(35)
                            : Colors.white.withAlpha(8),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(scene.icon,
                        color: active ? scene.color : C.textSec, size: 17),
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
// Switch grid — relay controls
// ═══════════════════════════════════════════════════════════════════════════════

class _SwitchGrid extends StatelessWidget {
  final List<RelayDevice>        devices;
  final bool Function(int)       relayOn;
  final void Function(int, bool) onToggle;

  const _SwitchGrid({
    required this.devices, required this.relayOn, required this.onToggle,
  });

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
            color: on ? C.green.withAlpha(60) : C.border, width: 0.5),
        ),
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
                const SizedBox(height: 6),
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
// Room sheet — detail panel (modal bottom sheet)
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
    final status  = lights.isEmpty
        ? 'No lights configured'
        : onCount == 0
            ? 'All lights off'
            : onCount == lights.length
                ? 'All on'
                : '$onCount of ${lights.length} on';

    final initSize = lights.isEmpty ? 0.35
        : lights.length <= 3         ? 0.52
        : lights.length <= 6         ? 0.70
        : 0.85;

    return DraggableScrollableSheet(
      initialChildSize: initSize,
      minChildSize: 0.28,
      maxChildSize: 0.95,
      builder: (_, scrollCtrl) => Container(
        decoration: BoxDecoration(
          color: C.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: color.withAlpha(40), width: 0.5)),
        ),
        child: Column(children: [
          // Drag handle
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Container(
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: C.textTri.withAlpha(80),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // Room header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            child: Row(children: [
              Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                  color: color.withAlpha(25),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(room,
                    style: AppText.h2.copyWith(fontSize: 17, letterSpacing: -0.5)),
                  Text(status,
                    style: AppText.small.copyWith(
                      color: onCount > 0 ? color : C.textTri,
                      fontWeight: onCount > 0 ? FontWeight.w600 : FontWeight.w400,
                    )),
                ],
              )),
              if (lights.isNotEmpty) ...[
                _QuickBtn(
                  label: 'Off',
                  onTap: () { HapticFeedback.selectionClick(); onSetRoom(0); },
                ),
                const SizedBox(width: 8),
                _QuickBtn(
                  label: 'On', accent: true,
                  onTap: () { HapticFeedback.selectionClick(); onSetRoom(100); },
                ),
              ],
            ]),
          ),

          Container(height: 0.5, color: C.border),

          // Content
          Expanded(
            child: ListView(
              controller: scrollCtrl,
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
              children: [

                // Light sliders
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
                                  ? [BoxShadow(color: clr.withAlpha(120), blurRadius: 6)]
                                  : null,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(child: Text(d.name,
                            style: AppText.body.copyWith(
                              color: isOn ? C.textPri : C.textSec,
                              fontWeight: isOn ? FontWeight.w600 : FontWeight.w400,
                            ),
                          )),
                          Text('$pct%',
                            style: AppText.small.copyWith(
                              color: isOn ? clr : C.textTri,
                              fontWeight: FontWeight.w700,
                              fontFeatures: [const FontFeature.tabularFigures()],
                            ),
                          ),
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
                            min:       0,
                            max:       100,
                            divisions: 20,
                            onChanged: (v) => onSetLight(d.channel, v.round()),
                          ),
                        ),
                      ],
                    ),
                  );
                }),

                // Relay switches in this room
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
                              color: on ? C.green.withAlpha(80) : C.border,
                              width: 0.5),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Container(
                              width: 6, height: 6,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: on ? C.green : C.textTri,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(d.name,
                              style: AppText.small.copyWith(
                                color: on ? C.textPri : C.textSec,
                                fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                              )),
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

// ── Quick On/Off button ───────────────────────────────────────────────────────

class _QuickBtn extends StatelessWidget {
  final String     label;
  final bool       accent;
  final VoidCallback onTap;
  const _QuickBtn({required this.label, required this.onTap, this.accent = false});

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
          fontWeight: FontWeight.w700,
        )),
    ),
  );
}
