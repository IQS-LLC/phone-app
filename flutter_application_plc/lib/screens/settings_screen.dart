import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme.dart';
import '../state/app_state.dart';
import '../auth/auth_state.dart';
import '../widgets/common_widgets.dart';
import 'connection_screen.dart';
import 'dynamic_dashboard_screen.dart';

const String kUrlPrefKey = 'server_url';

class SettingsScreen extends StatefulWidget {
  final AppState  appState;
  final AuthState? authState;
  const SettingsScreen({super.key, required this.appState, this.authState});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _urlCtrl;
  final FocusNode _urlFocus = FocusNode();
  bool _saving = false;
  bool _urlDirty = false;

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController(text: widget.appState.baseUrl)
      ..addListener(() {
        final dirty = _urlCtrl.text.trim() != widget.appState.baseUrl;
        if (dirty != _urlDirty) setState(() => _urlDirty = dirty);
      });
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _urlFocus.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty || !_urlDirty) return;
    setState(() => _saving = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kUrlPrefKey, url);
    widget.appState.setBaseUrl(url);
    if (mounted) {
      setState(() { _saving = false; _urlDirty = false; });
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: C.bg,
    appBar: AppBar(
      backgroundColor: C.surface,
      title: const Text('Settings'),
      iconTheme: const IconThemeData(color: C.textSec),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(height: 1, color: C.border),
      ),
    ),
    body: ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 48),
      children: [
        _serverSection(),
        const SizedBox(height: 24),
        if (widget.authState != null) ...[
          _deviceManagementSection(),
          const SizedBox(height: 24),
        ],
        _statusSection(),
        const SizedBox(height: 24),
        _aboutSection(),
      ],
    ),
  );

  // ── Device management (controllers + auto-discovery) ─────────────────────

  Widget _deviceManagementSection() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SectionHeader('Device Management'),
      const SizedBox(height: 10),
      AppCard(
        child: Column(children: [
          _NavRow(
            icon:  Icons.cable_outlined,
            color: C.blue,
            label: 'Controllers',
            subtitle: 'Manage Beckhoff CX devices (IP, AMS Net ID)',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ConnectionScreen(authState: widget.authState!),
              ),
            ),
          ),
          const AppDivider(),
          _NavRow(
            icon:  Icons.radar_rounded,
            color: C.accent,
            label: 'Auto-Discovery',
            subtitle: 'Scan a controller and build a dynamic dashboard',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => DynamicDashboardScreen(authState: widget.authState!),
              ),
            ),
          ),
        ]),
      ),
    ],
  );

  // ── Server section ─────────────────────────────────────────────────────────

  Widget _serverSection() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SectionHeader('Server'),
      const SizedBox(height: 10),
      AppCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                width: 32, height: 32,
                decoration: BoxDecoration(
                  color: C.blue.withAlpha(18),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Icon(Icons.dns_outlined, color: C.blue, size: 16),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Django Server URL', style: AppText.bodyMed),
                  Text('Backend API endpoint',
                      style: AppText.bodySm.copyWith(fontSize: 10)),
                ],
              ),
            ]),
            const SizedBox(height: 14),
            TextField(
              controller: _urlCtrl,
              focusNode:  _urlFocus,
              style:       GoogleFonts.jetBrainsMono(
                fontSize: 13, color: C.textPri,
              ),
              keyboardType: TextInputType.url,
              autocorrect:  false,
              onSubmitted:  (_) => _save(),
              decoration: InputDecoration(
                hintText: 'http://192.168.0.158:8000',
                hintStyle: GoogleFonts.jetBrainsMono(
                  fontSize: 13, color: C.textTri,
                ),
                filled:    true,
                fillColor: C.surface,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 11),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: C.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: C.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: C.accent, width: 1.5),
                ),
                suffixIcon: _urlDirty
                    ? IconButton(
                        icon: const Icon(Icons.close_rounded,
                            size: 16, color: C.textSec),
                        onPressed: () {
                          _urlCtrl.text = widget.appState.baseUrl;
                          _urlFocus.unfocus();
                        },
                      )
                    : null,
              ),
            ),
            const SizedBox(height: 12),
            AnimatedOpacity(
              opacity: _urlDirty ? 1.0 : 0.4,
              duration: const Duration(milliseconds: 200),
              child: PrimaryButton(
                label:   'Save & Reconnect',
                icon:    Icons.sync_rounded,
                onTap:   _save,
                loading: _saving,
              ),
            ),
          ],
        ),
      ),
    ],
  );

  // ── Status section ─────────────────────────────────────────────────────────

  Widget _statusSection() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SectionHeader('System Status'),
      const SizedBox(height: 10),
      ListenableBuilder(
        listenable: widget.appState,
        builder: (ctx, child) {
          final s = widget.appState;
          return AppCard(
            child: Column(children: [
              _InfoRow(
                icon:  Icons.link_rounded,
                label: 'Server',
                value: s.baseUrl,
                mono:  true,
              ),
              const AppDivider(),
              _InfoRow(
                icon:       Icons.wifi_rounded,
                label:      'Connection',
                value:      s.connected ? 'Online' : 'Offline',
                valueColor: s.connected ? C.green : C.red,
                badge:      true,
              ),
              const AppDivider(),
              _InfoRow(
                icon:       Icons.memory_rounded,
                label:      'PLC Mode',
                value:      s.state.mock ? 'Mock PLC' : 'Real PLC',
                valueColor: s.state.mock ? C.orange : C.green,
                badge:      true,
              ),
              const AppDivider(),
              _InfoRow(
                icon:  Icons.lightbulb_outline_rounded,
                label: 'DALI channels',
                value: s.daliDevices.length.toString(),
              ),
              const AppDivider(),
              _InfoRow(
                icon:  Icons.toggle_on_outlined,
                label: 'Wall relays',
                value: s.relayDevices.length.toString(),
              ),
              const AppDivider(),
              _InfoRow(
                icon:  Icons.touch_app_outlined,
                label: 'Input switches',
                value: s.switchDevices.length.toString(),
              ),
            ]),
          );
        },
      ),
    ],
  );

  // ── About section ──────────────────────────────────────────────────────────

  Widget _aboutSection() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SectionHeader('About'),
      const SizedBox(height: 10),
      AppCard(
        child: Column(children: [
          _InfoRow(
            icon:  Icons.bolt_rounded,
            label: 'App',
            value: 'Lugh — by IQS',
          ),
          const AppDivider(),
          _InfoRow(
            icon:  Icons.info_outline_rounded,
            label: 'Version',
            value: '2.0.0',
          ),
          const AppDivider(),
          _InfoRow(
            icon:  Icons.corporate_fare_rounded,
            label: 'Protocol',
            value: 'DALI / IEC 62386',
          ),
          const AppDivider(),
          _InfoRow(
            icon:  Icons.code_rounded,
            label: 'Backend',
            value: 'Django + PyADS',
          ),
        ]),
      ),
    ],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Navigation row
// ─────────────────────────────────────────────────────────────────────────────

class _NavRow extends StatelessWidget {
  final IconData icon;
  final Color    color;
  final String   label;
  final String   subtitle;
  final VoidCallback onTap;

  const _NavRow({
    required this.icon,
    required this.color,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      child: Row(children: [
        Container(
          width: 32, height: 32,
          decoration: BoxDecoration(
            color:        color.withAlpha(18),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(icon, color: color, size: 16),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: AppText.bodyMed),
              Text(subtitle, style: AppText.bodySm.copyWith(fontSize: 10)),
            ],
          ),
        ),
        const Icon(Icons.chevron_right_rounded, color: C.textTri, size: 18),
      ]),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Info row
// ─────────────────────────────────────────────────────────────────────────────

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String   label;
  final String   value;
  final Color?   valueColor;
  final bool     mono;
  final bool     badge;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
    this.mono  = false,
    this.badge = false,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
    child: Row(children: [
      Icon(icon, size: 15, color: C.textTri),
      const SizedBox(width: 10),
      Text(label, style: AppText.bodySm),
      const Spacer(),
      badge
          ? _Badge(text: value, color: valueColor ?? C.textSec)
          : Flexible(
              child: Text(
                value,
                textAlign: TextAlign.end,
                overflow: TextOverflow.ellipsis,
                style: mono
                    ? GoogleFonts.jetBrainsMono(
                        fontSize: 11, color: C.textSec)
                    : GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: valueColor ?? C.textPri,
                      ),
              ),
            ),
    ]),
  );
}

class _Badge extends StatelessWidget {
  final String text;
  final Color  color;
  const _Badge({required this.text, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
    decoration: BoxDecoration(
      color:        color.withAlpha(18),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: color.withAlpha(55)),
    ),
    child: Text(text,
        style: GoogleFonts.inter(
          fontSize: 10, fontWeight: FontWeight.w700, color: color,
        )),
  );
}
