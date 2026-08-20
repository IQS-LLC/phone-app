import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme.dart';
import '../config/runtime_config.dart';
import '../models/connectivity_status.dart';
import '../state/app_state.dart';
import '../auth/auth_state.dart';
import '../utils/apartment_display.dart';
import '../widgets/common_widgets.dart';
import 'connection_screen.dart';
import 'dynamic_dashboard_screen.dart';
import 'user_management_screen.dart';
import 'apartment_management_screen.dart';
import 'light_reconfigure_screen.dart';
import 'input_identify_screen.dart';
import 'automations_screen.dart';
import 'utilities_screen.dart';
import 'superscan_screen.dart';

class SettingsScreen extends StatefulWidget {
  final AppState    appState;
  final AuthState?  authState;
  final VoidCallback? onOpenMapEditor;
  const SettingsScreen({super.key, required this.appState, this.authState, this.onOpenMapEditor});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _loggingOut  = false;
  bool _savingPush  = false;
  bool _savingVentilatorsHome = false;
  bool _savingUrl   = false;
  bool _testingConn = false;
  bool _renaming    = false;
  late final TextEditingController _urlCtrl;

  // Live-drag values, separate from the persisted authState.user values —
  // the slider needs to move smoothly on every pixel of drag without
  // firing a PATCH per pixel; onChangeEnd is what actually saves.
  late double _dimMs;
  late double _undimMs;

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController(text: widget.appState.baseUrl);
    _dimMs   = (widget.authState?.user?.dimDurationMs   ?? 800).toDouble();
    _undimMs = (widget.authState?.user?.undimDurationMs ?? 500).toDouble();
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _togglePush(bool v) async {
    if (widget.authState == null) return;
    setState(() => _savingPush = true);
    final ok = await widget.authState!.updatePushNotifications(v);
    if (!mounted) return;
    setState(() => _savingPush = false);
    if (!ok) AppToast.show(context, 'Could not update preference', error: true);
  }

  Future<void> _toggleVentilatorsHome(bool v) async {
    if (widget.authState == null) return;
    setState(() => _savingVentilatorsHome = true);
    final ok = await widget.authState!.updateShowVentilatorsHome(v);
    if (!mounted) return;
    setState(() => _savingVentilatorsHome = false);
    if (!ok) AppToast.show(context, 'Could not update preference', error: true);
  }

  Future<void> _saveUrl() async {
    setState(() => _savingUrl = true);
    // One call: validates, persists, updates the in-memory value, and
    // notifies AppState (which is subscribed directly) to rebuild its API
    // client and reconnect. Nothing else needs telling separately anymore —
    // AuthService reads RuntimeConfig fresh on every request too.
    final error = await RuntimeConfig.instance.setServerUrl(_urlCtrl.text);
    if (!mounted) return;
    if (error != null) {
      setState(() => _savingUrl = false);
      AppToast.show(context, error, error: true);
      return;
    }
    await widget.appState.refresh();
    if (!mounted) return;
    setState(() => _savingUrl = false);
    AppToast.show(context,
        widget.appState.connected
            ? 'Connected to ${RuntimeConfig.instance.serverUrl}'
            : 'Saved — couldn\'t reach the server',
        error: !widget.appState.connected);
  }

  Future<void> _testConn() async {
    setState(() => _testingConn = true);
    await widget.appState.refresh();
    if (!mounted) return;
    setState(() => _testingConn = false);
    AppToast.show(context,
        widget.appState.connected ? 'Connected' : 'Still unable to connect',
        error: !widget.appState.connected);
  }

  Future<void> _confirmLogout() async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: C.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const BottomSheetHandle(),
          const SizedBox(height: 20),
          Container(
            width: 52, height: 52,
            decoration: BoxDecoration(
              color: C.red.withAlpha(16), shape: BoxShape.circle,
            ),
            child: const Icon(Icons.logout_rounded, color: C.red, size: 24),
          ),
          const SizedBox(height: 16),
          Text('Sign out?', style: AppText.h2),
          const SizedBox(height: 8),
          Text(
            'You\'ll need to sign in again.\nThe PLC keeps running.',
            style: AppText.bodySm, textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          Row(children: [
            Expanded(child: PrimaryButton(label: 'Cancel', color: C.textSec,
                onTap: () => Navigator.pop(ctx, false))),
            const SizedBox(width: 12),
            Expanded(child: PrimaryButton(label: 'Sign Out', color: C.red,
                onTap: () => Navigator.pop(ctx, true))),
          ]),
        ]),
      ),
    );
    if (confirmed != true || widget.authState == null) return;
    setState(() => _loggingOut = true);
    await widget.authState!.logout();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: C.bg,
    body: SafeArea(
      child: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // ── App bar ──────────────────────────────────────────────────────
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            sliver: SliverToBoxAdapter(
              child: Text('Settings', style: AppText.display.copyWith(fontSize: 26)),
            ),
          ),
          // ── Account ──────────────────────────────────────────────────────
          if (widget.authState != null) ...[
            _sectionPad(_accountSection()),
          ],
          // ── Apartment ────────────────────────────────────────────────────
          if (widget.authState != null)
            _sectionPad(_apartmentSection()),
          // ── Preferences ──────────────────────────────────────────────────
          if (widget.authState != null)
            _sectionPad(_preferencesSection()),
          // ── Lighting (dim/undim fade speed) ─────────────────────────────
          if (widget.authState != null)
            _sectionPad(_lightingSection()),
          // ── Utilities (ventilators, balcony/mirror lights, etc.) ───────────
          if (widget.authState?.apartmentId != null)
            _sectionPad(_utilitiesSection()),
          // ── Device Management (installer / Tech Team) ─────────────────
          if (widget.authState?.hasInstallerAccess ?? false)
            _sectionPad(_deviceManagementSection()),
          // ── Tech Team ────────────────────────────────────────────────────
          if (widget.authState?.user?.isStaff ?? false)
            _sectionPad(_techTeamSection()),
          // ── System Status ────────────────────────────────────────────────
          _sectionPad(_statusSection()),
          // ── About ────────────────────────────────────────────────────────
          _sectionPad(_aboutSection()),
          const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
        ],
      ),
    ),
  );

  SliverPadding _sectionPad(Widget child) => SliverPadding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
    sliver: SliverToBoxAdapter(child: child),
  );

  // ── Account ──────────────────────────────────────────────────────────────

  Widget _accountSection() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    SectionHeader('Account'),
    const SizedBox(height: 12),
    GlassCard(
      padding: EdgeInsets.zero,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                gradient: G.accent,
                borderRadius: BorderRadius.circular(14),
                boxShadow: S.accentGlow,
              ),
              child: Center(
                child: Text(
                  (widget.authState?.user?.displayName ?? 'U')[0].toUpperCase(),
                  style: GoogleFonts.inter(
                    fontSize: 18, fontWeight: FontWeight.w800, color: Colors.black,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.authState?.user?.displayName ?? 'Signed in',
                    style: AppText.cardTitle),
                if (widget.authState?.user?.email.isNotEmpty == true)
                  Text(widget.authState!.user!.email, style: AppText.caption),
              ]),
            ),
            if (widget.authState?.user?.isStaff == true)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: C.purple.withAlpha(18),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: C.purple.withAlpha(50), width: 0.5),
                ),
                child: Text('TECH TEAM',
                    style: AppText.labelSm.copyWith(color: C.purple)),
              ),
          ]),
        ),
        const Divider(height: 0.5, thickness: 0.5, color: C.border),
        _SettingsRow(
          icon: Icons.logout_rounded, label: 'Sign Out',
          iconColor: C.red, labelColor: C.red,
          loading: _loggingOut,
          onTap: _loggingOut ? null : _confirmLogout,
        ),
      ]),
    ),
  ]);

  // ── Apartment ────────────────────────────────────────────────────────────

  Future<void> _showRenameSheet() async {
    final auth = widget.authState;
    final id   = auth?.apartmentId;
    if (auth == null || id == null) return;

    final ctrl = TextEditingController(text: auth.apartmentName ?? '');
    String? error;

    final saved = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: C.card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
            24, 20, 24,
            MediaQuery.of(ctx).viewInsets.bottom + 32,
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const BottomSheetHandle(),
            const SizedBox(height: 20),
            Container(
              width: 48, height: 48,
              decoration: BoxDecoration(
                color: C.accent.withAlpha(18), shape: BoxShape.circle,
              ),
              child: const Icon(Icons.edit_rounded, color: C.accent, size: 22),
            ),
            const SizedBox(height: 14),
            Text('Rename Apartment', style: AppText.h2),
            const SizedBox(height: 6),
            Text('All members will see the new name.',
                style: AppText.bodySm, textAlign: TextAlign.center),
            const SizedBox(height: 24),
            TextField(
              controller: ctrl,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              style: AppText.bodyMed,
              decoration: InputDecoration(
                hintText: 'e.g. Penthouse Suite',
                hintStyle: AppText.bodySm.copyWith(color: C.textTri),
                errorText: error,
                filled: true, fillColor: C.elevated,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: C.border, width: 0.5),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: C.border, width: 0.5),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: C.accent, width: 1.5),
                ),
              ),
              onSubmitted: (_) async {
                final name = ctrl.text.trim();
                if (name.isEmpty) {
                  setSheet(() => error = 'Name cannot be empty');
                  return;
                }
                setSheet(() => error = null);
                final err = await auth.renameApartment(id, name);
                if (err != null) {
                  setSheet(() => error = err);
                } else if (ctx.mounted) {
                  Navigator.pop(ctx, true);
                }
              },
            ),
            const SizedBox(height: 16),
            PrimaryButton(
              label: 'Save Name',
              onTap: () async {
                final name = ctrl.text.trim();
                if (name.isEmpty) {
                  setSheet(() => error = 'Name cannot be empty');
                  return;
                }
                setSheet(() => error = null);
                final err = await auth.renameApartment(id, name);
                if (err != null) {
                  setSheet(() => error = err);
                } else if (ctx.mounted) {
                  Navigator.pop(ctx, true);
                }
              },
            ),
          ]),
        ),
      ),
    );

    ctrl.dispose();
    if (saved == true && mounted) setState(() {});
  }

  Widget _apartmentSection() {
    final name = widget.authState?.apartmentName;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionHeader('Apartment'),
      const SizedBox(height: 12),
      AppCard(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: C.accent.withAlpha(18),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: C.accent.withAlpha(40), width: 0.5),
              ),
              child: const Icon(Icons.apartment_rounded, color: C.accent, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(ApartmentDisplay.label(name), style: AppText.cardTitle),
                Text('Your assigned residence', style: AppText.caption),
              ]),
            ),
            if (_renaming)
              const SizedBox(
                width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: C.accent),
              )
            else ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: C.green.withAlpha(18),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: C.green.withAlpha(50), width: 0.5),
                ),
                child: Text('ACTIVE', style: AppText.labelSm.copyWith(color: C.green)),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _showRenameSheet,
                child: Container(
                  width: 32, height: 32,
                  decoration: BoxDecoration(
                    color: C.elevated,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: C.border, width: 0.5),
                  ),
                  child: const Icon(Icons.edit_rounded, size: 15, color: C.textSec),
                ),
              ),
            ],
          ]),
        ),
      ),
    ]);
  }

  // ── Preferences ──────────────────────────────────────────────────────────

  Widget _preferencesSection() {
    final pushEnabled = widget.authState?.user?.pushNotifications ?? true;
    final ventilatorsOnHome = widget.authState?.user?.showVentilatorsHome ?? true;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionHeader('Preferences'),
      const SizedBox(height: 12),
      AppCard(
        child: Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(children: [
            Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                color: C.blue.withAlpha(18), borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.notifications_rounded, color: C.blue, size: 16),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text('Push Notifications', style: AppText.bodyMed)),
            if (_savingPush)
              const SizedBox(width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: C.accent))
            else
              Switch(value: pushEnabled, activeThumbColor: C.accent, onChanged: _togglePush),
          ]),
        ),
        const Divider(height: 0.5, thickness: 0.5, color: C.border),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(children: [
            Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                color: C.accent.withAlpha(18), borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.air_rounded, color: C.accent, size: 16),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text('Ventilators & Extra Lights on Home', style: AppText.bodyMed)),
            if (_savingVentilatorsHome)
              const SizedBox(width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: C.accent))
            else
              Switch(value: ventilatorsOnHome, activeThumbColor: C.accent, onChanged: _toggleVentilatorsHome),
          ]),
        ),
        ]),
      ),
    ]);
  }

  // ── Lighting ──────────────────────────────────────────────────────────────

  String _fadeLabel(double ms) {
    if (ms < 1000) return '${ms.round()}ms';
    return '${(ms / 1000).toStringAsFixed(1)}s';
  }

  Future<void> _commitDim(double ms) async {
    final ok = await widget.authState?.updateFadeDurations(dimMs: ms.round()) ?? false;
    if (!ok && mounted) AppToast.show(context, 'Could not save dim speed', error: true);
  }
  Future<void> _commitUndim(double ms) async {
    final ok = await widget.authState?.updateFadeDurations(undimMs: ms.round()) ?? false;
    if (!ok && mounted) AppToast.show(context, 'Could not save undim speed', error: true);
  }

  Widget _lightingSection() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    SectionHeader('Lighting'),
    const SizedBox(height: 4),
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        'How quickly lights fade when you dim them down vs. bring them back up. '
        'Separate from the app\'s own UI animations — this is the actual light transition.',
        style: AppText.bodySm.copyWith(color: C.textTri),
      ),
    ),
    const SizedBox(height: 12),
    AppCard(
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(children: [
            Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                color: C.blue.withAlpha(18), borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.trending_down_rounded, color: C.blue, size: 16),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text('Dim Speed', style: AppText.bodyMed)),
            Text(_fadeLabel(_dimMs), style: AppText.bodySm.copyWith(color: C.textSec)),
          ]),
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(activeTrackColor: C.blue, thumbColor: C.blue),
          child: Slider(
            value: _dimMs, min: 100, max: 5000, divisions: 49,
            onChanged: (v) => setState(() => _dimMs = v),
            onChangeEnd: _commitDim,
          ),
        ),
        const Divider(height: 0.5, thickness: 0.5, color: C.border),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(children: [
            Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                color: C.orange.withAlpha(18), borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.trending_up_rounded, color: C.orange, size: 16),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text('Undim Speed', style: AppText.bodyMed)),
            Text(_fadeLabel(_undimMs), style: AppText.bodySm.copyWith(color: C.textSec)),
          ]),
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(activeTrackColor: C.orange, thumbColor: C.orange),
          child: Slider(
            value: _undimMs, min: 100, max: 5000, divisions: 49,
            onChanged: (v) => setState(() => _undimMs = v),
            onChangeEnd: _commitUndim,
          ),
        ),
      ]),
    ),
  ]);

  // ── Utilities ─────────────────────────────────────────────────────────────

  Widget _utilitiesSection() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    SectionHeader('Utilities'),
    const SizedBox(height: 12),
    AppCard(
      child: _SettingsNavRow(
        icon: Icons.tune_rounded, iconColor: C.accent,
        label: 'Ventilators & Extra Lights',
        sub: 'Balcony, mirror, and bathroom ventilators',
        onTap: () => Navigator.push(context, MaterialPageRoute(
          builder: (_) => UtilitiesScreen(
            authState: widget.authState!,
            apartmentId: widget.authState!.apartmentId!,
          ),
        )),
      ),
    ),
  ]);

  // ── Device Management ────────────────────────────────────────────────────

  Widget _deviceManagementSection() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    SectionHeader('Device Management'),
    const SizedBox(height: 12),
    AppCard(
      child: Column(children: [
        _SettingsNavRow(
          icon: Icons.cable_rounded, iconColor: C.blue,
          label: 'Controllers', sub: 'Beckhoff CX devices — IP, AMS Net ID',
          onTap: () => Navigator.push(context, MaterialPageRoute(
            builder: (_) => ConnectionScreen(authState: widget.authState!),
          )),
        ),
        const Divider(height: 0.5, thickness: 0.5, color: C.border),
        _SettingsNavRow(
          icon: Icons.radar_rounded, iconColor: C.accent,
          label: 'Auto-Discovery', sub: 'Scan a controller and build a dynamic dashboard',
          onTap: () => Navigator.push(context, MaterialPageRoute(
            builder: (_) => DynamicDashboardScreen(authState: widget.authState!),
          )),
        ),
      ]),
    ),
    const SizedBox(height: 12),
    AppCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                color: C.teal.withAlpha(18), borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.dns_rounded, color: C.teal, size: 16),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text('Django Server URL', style: AppText.bodyMed)),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: _urlCtrl,
            style: AppText.mono.copyWith(fontSize: 12, color: C.textPri),
            decoration: InputDecoration(
              hintText: 'http://192.168.0.158:8000',
              hintStyle: AppText.mono.copyWith(color: C.textTri),
              filled: true, fillColor: C.elevated,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: C.border, width: 0.5)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: C.border, width: 0.5)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: C.accent, width: 1.5)),
            ),
          ),
          const SizedBox(height: 10),
          PrimaryButton(label: 'Save & Reconnect', loading: _savingUrl, onTap: _saveUrl),
        ]),
      ),
    ),
  ]);

  // ── Tech Team ────────────────────────────────────────────────────────────

  Widget _techTeamSection() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    SectionHeader('Tech Team'),
    const SizedBox(height: 12),
    AppCard(
      child: Column(children: [
        _SettingsNavRow(
          icon: Icons.admin_panel_settings_rounded, iconColor: C.purple,
          label: 'User Management', sub: 'Create, disable, reset, or delete accounts',
          onTap: () => Navigator.push(context, MaterialPageRoute(
            builder: (_) => UserManagementScreen(authState: widget.authState!),
          )),
        ),
        const Divider(height: 0.5, thickness: 0.5, color: C.border),
        _SettingsNavRow(
          icon: Icons.apartment_rounded, iconColor: C.blue,
          label: 'Apartment Management', sub: 'Owners, residents, rooms, controller status',
          onTap: () => Navigator.push(context, MaterialPageRoute(
            builder: (_) => ApartmentManagementScreen(authState: widget.authState!),
          )),
        ),
        // Map Editor — always shown inside Tech Team section (section already gated by isStaff)
        const Divider(height: 0.5, thickness: 0.5, color: C.border),
        _SettingsNavRow(
          icon: Icons.map_rounded, iconColor: C.teal,
          label: 'Map Editor', sub: 'Create and edit floor-plan zones for any apartment',
          onTap: widget.onOpenMapEditor ?? () {},
        ),
        // Reconfigure Lights / Identify Inputs — IT Team only, deliberately
        // not shown to Owner/Installer/Building Owner (see
        // has_relabel_access server-side).
        if (widget.authState?.apartmentId != null) ...[
          const Divider(height: 0.5, thickness: 0.5, color: C.border),
          _SettingsNavRow(
            icon: Icons.lightbulb_outline_rounded, iconColor: C.orange,
            label: 'Reconfigure Devices',
            sub: 'Flash each DALI/relay/curtain channel and fix its room + name',
            onTap: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => LightReconfigureScreen(
                authState: widget.authState!,
                apartmentId: widget.authState!.apartmentId!,
                apartmentName: ApartmentDisplay.label(widget.authState!.apartmentName),
              ),
            )),
          ),
          const Divider(height: 0.5, thickness: 0.5, color: C.border),
          _SettingsNavRow(
            icon: Icons.sensors_rounded, iconColor: C.orange,
            label: 'Identify Switches & Sensors',
            sub: 'Watch live input state and assign switches/motion/door/window sensors',
            onTap: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => InputIdentifyScreen(
                authState: widget.authState!,
                apartmentId: widget.authState!.apartmentId!,
                apartmentName: ApartmentDisplay.label(widget.authState!.apartmentName),
              ),
            )),
          ),
          const Divider(height: 0.5, thickness: 0.5, color: C.border),
          _SettingsNavRow(
            icon: Icons.bolt_rounded, iconColor: C.orange,
            label: 'Automations',
            sub: 'When this switch/sensor does X, do Y — no PLC code required',
            onTap: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => AutomationsScreen(
                authState: widget.authState!,
                apartmentId: widget.authState!.apartmentId!,
                apartmentName: ApartmentDisplay.label(widget.authState!.apartmentName),
              ),
            )),
          ),
          const Divider(height: 0.5, thickness: 0.5, color: C.border),
          _SettingsNavRow(
            icon: Icons.travel_explore_rounded, iconColor: C.purple,
            label: '🔍 SUPERSCAN',
            sub: 'Discover every device, sensor, and capability — safely test what\'s writable',
            onTap: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => SuperscanScreen(
                authState: widget.authState!,
                apartmentId: widget.authState!.apartmentId!,
                apartmentName: ApartmentDisplay.label(widget.authState!.apartmentName),
              ),
            )),
          ),
        ],
      ]),
    ),
  ]);

  // ── System Status ────────────────────────────────────────────────────────

  Widget _statusSection() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Row(children: [
      Expanded(child: SectionHeader('System Status')),
      TapScale(
        onTap: _testingConn ? null : _testConn,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (_testingConn)
            const SizedBox(width: 12, height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.5, color: C.accent))
          else
            const Icon(Icons.refresh_rounded, size: 13, color: C.accent),
          const SizedBox(width: 5),
          Text('Test Connection', style: AppText.bodySm.copyWith(
              color: C.accent, fontWeight: FontWeight.w600, fontSize: 11)),
        ]),
      ),
    ]),
    const SizedBox(height: 12),
    ListenableBuilder(
      listenable: widget.appState,
      builder: (_, _) {
        final s = widget.appState;
        return AppCard(
          child: Column(children: [
            if (widget.authState?.hasInstallerAccess == true ||
                widget.authState?.user?.isStaff == true) ...[
              _InfoRow(icon: Icons.link_rounded, label: 'Server', value: s.baseUrl, mono: true),
              const Divider(height: 0.5, thickness: 0.5, color: C.border),
            ],
            _InfoRow(
              icon: Icons.wifi_rounded, label: 'Connection',
              value: s.connectivityStatus.isHealthy ? 'Online' : s.connectivityStatus.shortLabel,
              valueColor: s.connectivityStatus.isHealthy
                  ? C.green
                  : (s.connectivityStatus == ConnectivityStatus.plcDown ? C.orange : C.red),
              badge: true,
            ),
            const Divider(height: 0.5, thickness: 0.5, color: C.border),
            _InfoRow(
              icon: Icons.memory_rounded, label: 'PLC Mode',
              value: s.state.mock ? 'Mock PLC' : 'Real PLC',
              valueColor: s.state.mock ? C.orange : C.green, badge: true,
            ),
            const Divider(height: 0.5, thickness: 0.5, color: C.border),
            _InfoRow(
              icon: Icons.swap_horiz_rounded, label: 'Modbus fallback',
              value: s.state.modbusConnected ? 'Active' : 'Standby',
              valueColor: s.state.modbusConnected ? C.green : C.textTri, badge: true,
            ),
            const Divider(height: 0.5, thickness: 0.5, color: C.border),
            _InfoRow(icon: Icons.lightbulb_outline_rounded, label: 'DALI channels', value: '${s.daliDevices.length}'),
            const Divider(height: 0.5, thickness: 0.5, color: C.border),
            _InfoRow(icon: Icons.toggle_on_outlined, label: 'Wall relays', value: '${s.relayDevices.length}'),
            const Divider(height: 0.5, thickness: 0.5, color: C.border),
            _InfoRow(icon: Icons.touch_app_outlined, label: 'Input switches', value: '${s.switchDevices.length}'),
          ]),
        );
      },
    ),
  ]);

  // ── About ────────────────────────────────────────────────────────────────

  Widget _aboutSection() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    SectionHeader('About'),
    const SizedBox(height: 12),
    AppCard(
      child: Column(children: [
        _InfoRow(icon: Icons.bolt_rounded, label: 'App', value: 'Lugh — by IQS'),
        const Divider(height: 0.5, thickness: 0.5, color: C.border),
        _InfoRow(icon: Icons.info_outline_rounded, label: 'Version', value: '2.0.0'),
        const Divider(height: 0.5, thickness: 0.5, color: C.border),
        _InfoRow(icon: Icons.corporate_fare_rounded, label: 'Protocol', value: 'DALI / IEC 62386'),
        const Divider(height: 0.5, thickness: 0.5, color: C.border),
        _InfoRow(icon: Icons.code_rounded, label: 'Backend', value: 'Django + PyADS'),
      ]),
    ),
  ]);
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared row widgets
// ─────────────────────────────────────────────────────────────────────────────

class _SettingsNavRow extends StatelessWidget {
  final IconData icon;
  final Color    iconColor;
  final String   label;
  final String   sub;
  final VoidCallback onTap;
  const _SettingsNavRow({required this.icon, required this.iconColor,
      required this.label, required this.sub, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(children: [
        Container(
          width: 32, height: 32,
          decoration: BoxDecoration(
            color: iconColor.withAlpha(18),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: iconColor, size: 16),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: AppText.bodyMed),
            Text(sub, style: AppText.caption),
          ]),
        ),
        const Icon(Icons.chevron_right_rounded, color: C.textTri, size: 18),
      ]),
    ),
  );
}

class _SettingsRow extends StatelessWidget {
  final IconData icon;
  final String   label;
  final Color    iconColor;
  final Color    labelColor;
  final VoidCallback? onTap;
  final bool loading;
  const _SettingsRow({required this.icon, required this.label,
      this.iconColor = C.textSec, this.labelColor = C.textPri,
      this.onTap, this.loading = false});

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: loading ? null : onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(children: [
        Icon(icon, color: iconColor, size: 18),
        const SizedBox(width: 12),
        Text(loading ? '${label}ing…' : label,
            style: AppText.bodyMed.copyWith(color: labelColor)),
      ]),
    ),
  );
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String   label;
  final String   value;
  final Color?   valueColor;
  final bool     mono;
  final bool     badge;
  const _InfoRow({required this.icon, required this.label, required this.value,
      this.valueColor, this.mono = false, this.badge = false});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Row(children: [
      Icon(icon, size: 15, color: C.textTri),
      const SizedBox(width: 10),
      Text(label, style: AppText.bodySm),
      const Spacer(),
      badge
          ? _Badge(text: value, color: valueColor ?? C.textSec)
          : Flexible(
              child: Text(value, textAlign: TextAlign.end,
                  overflow: TextOverflow.ellipsis,
                  style: mono
                      ? AppText.mono.copyWith(color: C.textSec)
                      : GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600,
                          color: valueColor ?? C.textPri)),
            ),
    ]),
  );
}

class _Badge extends StatelessWidget {
  final String text; final Color color;
  const _Badge({required this.text, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: color.withAlpha(18), borderRadius: BorderRadius.circular(8),
      border: Border.all(color: color.withAlpha(50), width: 0.5),
    ),
    child: Text(text, style: GoogleFonts.inter(
      fontSize: 10, fontWeight: FontWeight.w700, color: color)),
  );
}
