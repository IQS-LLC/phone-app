import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
import '../state/app_state.dart';
import '../auth/auth_state.dart';
import 'dashboard_screen.dart';
import 'log_screen.dart';
import 'map_editor_screen.dart';
import 'map_mode_screen.dart';
import 'settings_screen.dart';
import 'commissioning_wizard_screen.dart';

/// Persistent shell with animated bottom nav.
/// Map Mode is a full-screen overlay that hides everything else.
class MainShell extends StatefulWidget {
  final AppState  appState;
  final AuthState authState;
  const MainShell({super.key, required this.appState, required this.authState});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int  _index        = 0;
  bool _mapMode      = false;
  bool _editorMode   = false;
  bool _wizardMode   = false;

  void _onTap(int i) {
    if (i == _index) return;
    HapticFeedback.selectionClick();
    setState(() => _index = i);
  }

  void _openMap()     => setState(() => _mapMode    = true);
  void _closeMap()    => setState(() => _mapMode    = false);
  void _openEditor()  => setState(() => _editorMode = true);
  void _closeEditor() => setState(() => _editorMode = false);
  void _openWizard()  => setState(() => _wizardMode = true);
  void _closeWizard() => setState(() => _wizardMode = false);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.authState,
      builder: (ctx, _) => _buildShell(ctx),
    );
  }

  Widget _buildShell(BuildContext context) {
    return Stack(children: [

      // ── Regular shell ────────────────────────────────────────────────────
      Scaffold(
        backgroundColor: C.bg,
        body: IndexedStack(
          index: _index,
          children: [
            DashboardScreen(
              appState:        widget.appState,
              authState:       widget.authState,
              onOpenMap:       _openMap,
              onOpenCommission: _openWizard,
              onOpenMapEditor: _openEditor,
            ),
            LogScreen(appState: widget.appState),
            SettingsScreen(
              appState:        widget.appState,
              authState:       widget.authState,
              onOpenMapEditor: _openEditor,
            ),
          ],
        ),
        bottomNavigationBar: _NavBar(index: _index, onTap: _onTap),
      ),

      // ── Map Mode full-screen overlay ──────────────────────────────────────
      if (_mapMode)
        Positioned.fill(
          child: MapModeScreen(
            appState:       widget.appState,
            authState:      widget.authState,
            onClose:        _closeMap,
            // authState.apartmentName is already the full display name
            // (e.g. "Apartment 16") — found live 2026-08-20 that prepending
            // "Apartment " here produced "Apartment Apartment 16" on the
            // Map Mode top badge.
            apartmentLabel: widget.authState.apartmentName,
          ),
        ),

      // ── Map Editor overlay (staff only — residents never see this) ─────────
      if (_editorMode)
        Positioned.fill(
          child: MapEditorScreen(
            authState: widget.authState,
            onClose:   _closeEditor,
          ),
        ),

      // ── Commissioning Wizard overlay (staff only) ─────────────────────────
      if (_wizardMode)
        Positioned.fill(
          child: CommissioningWizardScreen(
            authState: widget.authState,
            onClose:   _closeWizard,
          ),
        ),

    ]);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Animated bottom nav with sliding pill
// ─────────────────────────────────────────────────────────────────────────────

class _NavBar extends StatefulWidget {
  final int index;
  final void Function(int) onTap;
  const _NavBar({required this.index, required this.onTap});

  @override
  State<_NavBar> createState() => _NavBarState();
}

class _NavBarState extends State<_NavBar> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late Animation<double> _position;

  static const _tabs = [
    _Tab(icon: Icons.home_rounded,         iconOff: Icons.home_outlined,         label: 'Home'),
    _Tab(icon: Icons.receipt_long_rounded, iconOff: Icons.receipt_long_outlined, label: 'Activity'),
    _Tab(icon: Icons.settings_rounded,     iconOff: Icons.settings_outlined,     label: 'Settings'),
  ];

  @override
  void initState() {
    super.initState();
    _ctrl     = AnimationController(vsync: this, duration: Dur.normal);
    _position = Tween<double>(
      begin: widget.index.toDouble(),
      end:   widget.index.toDouble(),
    ).animate(CurvedAnimation(parent: _ctrl, curve: Cur.overshoot));
  }

  @override
  void didUpdateWidget(_NavBar old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) {
      _position = Tween<double>(
        begin: old.index.toDouble(),
        end:   widget.index.toDouble(),
      ).animate(CurvedAnimation(parent: _ctrl, curve: Cur.overshoot));
      _ctrl..reset()..forward();
    }
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom;
    return Container(
      decoration: BoxDecoration(
        color: C.surface,
        border: const Border(top: BorderSide(color: C.border, width: 0.5)),
        boxShadow: [
          BoxShadow(color: Colors.black.withAlpha(80),
              blurRadius: 24, offset: const Offset(0, -6)),
        ],
      ),
      child: SizedBox(
        height: 68 + bottom,
        child: Stack(children: [
          // Sliding pill
          AnimatedBuilder(
            animation: _position,
            builder: (_, _) {
              final iw = MediaQuery.of(context).size.width / _tabs.length;
              return Positioned(
                left:   iw * _position.value + 16,
                top:    12,
                width:  iw - 32,
                height: 40,
                child: Container(
                  decoration: BoxDecoration(
                    color:        C.accent.withAlpha(18),
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              );
            },
          ),
          // Tab items
          Row(
            children: List.generate(_tabs.length, (i) => Expanded(
              child: GestureDetector(
                onTap: () => widget.onTap(i),
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  height: 68 + bottom,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      AnimatedSwitcher(
                        duration: Dur.fast,
                        child: Icon(
                          widget.index == i ? _tabs[i].icon : _tabs[i].iconOff,
                          key:   ValueKey('${i}_${widget.index == i}'),
                          color: widget.index == i ? C.accent : C.textTri,
                          size:  widget.index == i ? 27 : 24,
                        ),
                        transitionBuilder: (child, anim) => ScaleTransition(
                          scale: Tween<double>(begin: 0.7, end: 1.0).animate(
                              CurvedAnimation(parent: anim, curve: Cur.snap)),
                          child: FadeTransition(opacity: anim, child: child),
                        ),
                      ),
                      const SizedBox(height: 4),
                      AnimatedDefaultTextStyle(
                        duration: Dur.fast,
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize:   11,
                          fontWeight: widget.index == i
                              ? FontWeight.w700 : FontWeight.w400,
                          color: widget.index == i ? C.accent : C.textTri,
                        ),
                        child: Text(_tabs[i].label),
                      ),
                      SizedBox(height: bottom),
                    ],
                  ),
                ),
              ),
            )),
          ),
        ]),
      ),
    );
  }
}

class _Tab {
  final IconData icon, iconOff;
  final String   label;
  const _Tab({required this.icon, required this.iconOff, required this.label});
}

