import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../auth/auth_state.dart';
import '../config/runtime_config.dart';
import '../models/superscan_models.dart';
import '../services/superscan_service.dart';
import '../theme.dart';
import '../widgets/common_widgets.dart';

/// SuperScan — no-code discovery/capability-mapping tool. Walks every
/// device the backend already knows about (and, in Deep mode, every raw PLC
/// symbol nothing knows about yet), records what it finds, and — only in
/// Full/Deep mode — safely exercises writable devices with the exact
/// pulse-and-restore protocol the Commissioning Wizard already uses in
/// production. is_staff (IT Team) ONLY, same bar as AutomationsScreen —
/// never shown to Owner/Resident/Building Owner.
class SuperscanScreen extends StatefulWidget {
  final AuthState authState;
  final int    apartmentId;
  final String apartmentName;

  const SuperscanScreen({
    super.key,
    required this.authState,
    required this.apartmentId,
    required this.apartmentName,
  });

  @override
  State<SuperscanScreen> createState() => _SuperscanScreenState();
}

class _SuperscanScreenState extends State<SuperscanScreen> {
  late SuperscanService _svc;
  bool _svcReady = false;

  List<ScanRunSummary> _history = [];
  ScanRunSummary? _activeRun;
  Timer? _pollTimer;

  bool _loadingCaps = true;
  String? _capsError;
  List<DiscoveredCapabilitySummary> _caps = [];
  CapabilitySummaryCounts _summary = CapabilitySummaryCounts.empty;

  String? _filterDeviceType;
  String? _filterTestStatus;

  @override
  void initState() {
    super.initState();
    _init();
    RuntimeConfig.instance.addListener(_onConfigChanged);
  }

  @override
  void dispose() {
    RuntimeConfig.instance.removeListener(_onConfigChanged);
    _pollTimer?.cancel();
    super.dispose();
  }

  // Rebuilds _svc if the server URL changes while this screen is open —
  // without this it would keep silently talking to the old server for as
  // long as the screen stays mounted. Same class of bug AppState was
  // hardened against; see RuntimeConfig's doc comment.
  void _onConfigChanged() {
    final svc = widget.authState.service;
    _svc = SuperscanService(
      RuntimeConfig.instance.serverUrl,
      tokenProvider:  () => svc.getAccessToken(),
      tokenRefresher: () => svc.refreshAccessToken(),
    );
  }

  Future<void> _init() async {
    final svc = widget.authState.service;
    _svc = SuperscanService(
      RuntimeConfig.instance.serverUrl,
      tokenProvider:  () => svc.getAccessToken(),
      tokenRefresher: () => svc.refreshAccessToken(),
    );
    _svcReady = true;
    await _loadHistory();
    await _loadCapabilities();
  }

  Future<void> _loadHistory() async {
    final r = await _svc.runList(widget.apartmentId);
    if (!mounted || !r.success) return;
    setState(() {
      _history = r.value;
      final running = _history.where((run) => run.isRunning).firstOrNull;
      if (running != null && _activeRun == null) {
        _activeRun = running;
        _startPolling();
      }
    });
  }

  Future<void> _loadCapabilities() async {
    setState(() { _loadingCaps = true; _capsError = null; });
    final r = await _svc.capabilityList(
      widget.apartmentId,
      deviceType: _filterDeviceType,
      testStatus: _filterTestStatus,
    );
    if (!mounted) return;
    if (!r.success) {
      setState(() { _loadingCaps = false; _capsError = r.error; });
      return;
    }
    setState(() {
      _loadingCaps = false;
      _caps = r.value.$1;
      _summary = r.value.$2;
    });
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) => _pollStatus());
  }

  Future<void> _pollStatus() async {
    final run = _activeRun;
    if (run == null) { _pollTimer?.cancel(); return; }
    final r = await _svc.runStatus(widget.apartmentId, run.id);
    if (!mounted || !r.success) return;
    setState(() => _activeRun = r.value);
    if (!r.value.isRunning) {
      _pollTimer?.cancel();
      await _loadHistory();
      await _loadCapabilities();
    }
  }

  Future<void> _startScan(String mode) async {
    final r = await _svc.start(widget.apartmentId, mode);
    if (!mounted) return;
    if (!r.success) {
      AppToast.show(context, r.error ?? 'Could not start scan', error: true);
      return;
    }
    setState(() => _activeRun = r.value);
    _startPolling();
  }

  Future<void> _stopScan() async {
    final run = _activeRun;
    if (run == null) return;
    final r = await _svc.stop(widget.apartmentId, run.id);
    if (!mounted) return;
    if (!r.success) {
      AppToast.show(context, r.error ?? 'Could not stop scan', error: true);
      return;
    }
    AppToast.show(context, 'Stopping…');
  }

  Future<void> _openModeSheet() async {
    final mode = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: C.card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => const _ModeSelectSheet(),
    );
    if (mode != null && mounted) _startScan(mode);
  }

  Future<void> _openCapabilityDetail(DiscoveredCapabilitySummary cap) async {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: C.card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _CapabilityDetailSheet(svc: _svc, apartmentId: widget.apartmentId, capId: cap.id, initial: cap),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: C.bg,
    appBar: AppBar(
      backgroundColor: C.surface,
      iconTheme: const IconThemeData(color: C.textSec),
      title: Text('SuperScan · ${widget.apartmentName}', style: AppText.h3),
    ),
    body: !_svcReady
        ? const Center(child: CircularProgressIndicator(color: C.accent))
        : RefreshIndicator(
            color: C.accent,
            backgroundColor: C.card,
            onRefresh: () async { await _loadHistory(); await _loadCapabilities(); },
            child: ListView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                _scanControlCard(),
                const SizedBox(height: 16),
                if (_history.isNotEmpty) ...[
                  SectionHeader('Last scan'),
                  const SizedBox(height: 8),
                  _lastScanCard(),
                  const SizedBox(height: 16),
                ],
                SectionHeader('Capability dashboard'),
                const SizedBox(height: 8),
                _summaryChips(),
                const SizedBox(height: 10),
                _filterRow(),
                const SizedBox(height: 10),
                _capabilityList(),
              ],
            ),
          ),
  );

  // ── Scan control ────────────────────────────────────────────────────────

  Widget _scanControlCard() {
    final run = _activeRun;
    final running = run?.isRunning ?? false;
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(color: C.purple.withAlpha(22), borderRadius: BorderRadius.circular(11)),
              child: const Icon(Icons.travel_explore_rounded, color: C.purple, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('SuperScan', style: AppText.h3),
                Text(
                  running ? (run!.progressLabel.isEmpty ? 'Scanning…' : run.progressLabel) : 'Discover, map, and safely test every capability',
                  style: AppText.bodySm,
                ),
              ]),
            ),
          ]),
          const SizedBox(height: 14),
          if (running) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: run!.progressTotal > 0 ? run.progressFraction : null,
                minHeight: 8,
                backgroundColor: C.elevated,
                color: C.accent,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              run.progressTotal > 0 ? '${run.progressCurrent} / ${run.progressTotal}' : 'Starting…',
              style: AppText.bodySm.copyWith(fontSize: 11),
            ),
            const SizedBox(height: 14),
            PrimaryButton(
              label: 'STOP SCAN', color: C.red, icon: Icons.stop_circle_rounded,
              onTap: _stopScan,
            ),
          ] else
            PrimaryButton(
              label: 'Run SuperScan', icon: Icons.search_rounded,
              onTap: _openModeSheet,
            ),
        ]),
      ),
    );
  }

  Widget _lastScanCard() {
    final run = _history.first;
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            _StatusPill(status: run.status),
            const SizedBox(width: 8),
            Text(_modeLabel(run.mode), style: AppText.bodyMed.copyWith(fontSize: 12)),
            const Spacer(),
            Text(_relativeTime(run.startedAt), style: AppText.bodySm.copyWith(fontSize: 10)),
          ]),
          const SizedBox(height: 10),
          Wrap(spacing: 14, runSpacing: 6, children: [
            _StatChip(label: 'capabilities', value: run.capabilitiesDiscovered),
            if (run.capabilitiesTested > 0) ...[
              _StatChip(label: 'tested', value: run.capabilitiesTested, color: C.blue),
              _StatChip(label: 'passed', value: run.testsPassed, color: C.green),
              if (run.testsFailed > 0) _StatChip(label: 'failed', value: run.testsFailed, color: C.red),
            ],
            if (run.unknownCount > 0) _StatChip(label: 'unknown', value: run.unknownCount, color: C.orange),
            if (run.newSinceLast > 0) _StatChip(label: 'new', value: run.newSinceLast, color: C.teal),
            if (run.changedSinceLast > 0) _StatChip(label: 'changed', value: run.changedSinceLast, color: C.purple),
            if (run.removedSinceLast > 0) _StatChip(label: 'removed', value: run.removedSinceLast, color: C.red),
          ]),
          if (run.errorMessage.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(run.errorMessage, style: AppText.bodySm.copyWith(color: C.red, fontSize: 11)),
          ],
        ]),
      ),
    );
  }

  // ── Capability dashboard ────────────────────────────────────────────────

  Widget _summaryChips() => Wrap(spacing: 8, runSpacing: 8, children: [
    _CountBadge(label: 'Total', value: _summary.total, color: C.textSec),
    _CountBadge(label: 'Known', value: _summary.known, color: C.blue),
    _CountBadge(label: 'Unknown', value: _summary.unknown, color: C.orange),
    _CountBadge(label: 'Tested OK', value: _summary.testedOk, color: C.green),
    _CountBadge(label: 'Tested Failed', value: _summary.testedFailed, color: C.red),
    _CountBadge(label: 'Observed only', value: _summary.observedOnly, color: C.textTri),
  ]);

  static const _deviceTypeFilters = [
    'dali', 'relay', 'curtain', 'appliance', 'toggle', 'switch',
    'named_switch', 'door_sensor', 'window_sensor', 'motion_sensor', 'unknown_symbol',
  ];

  Widget _filterRow() => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(children: [
      _FilterChip(
        label: 'All types', selected: _filterDeviceType == null,
        onTap: () { setState(() => _filterDeviceType = null); _loadCapabilities(); },
      ),
      for (final t in _deviceTypeFilters) ...[
        const SizedBox(width: 6),
        _FilterChip(
          label: _deviceTypeLabel(t), selected: _filterDeviceType == t,
          onTap: () { setState(() => _filterDeviceType = _filterDeviceType == t ? null : t); _loadCapabilities(); },
        ),
      ],
      const SizedBox(width: 12),
      Container(width: 1, height: 20, color: C.border),
      const SizedBox(width: 12),
      _FilterChip(
        label: 'Failed only', selected: _filterTestStatus == 'tested_failed', color: C.red,
        onTap: () {
          setState(() => _filterTestStatus = _filterTestStatus == 'tested_failed' ? null : 'tested_failed');
          _loadCapabilities();
        },
      ),
      const SizedBox(width: 6),
      _FilterChip(
        label: 'Not tested', selected: _filterTestStatus == 'not_tested',
        onTap: () {
          setState(() => _filterTestStatus = _filterTestStatus == 'not_tested' ? null : 'not_tested');
          _loadCapabilities();
        },
      ),
    ]),
  );

  Widget _capabilityList() {
    if (_loadingCaps) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator(color: C.accent)),
      );
    }
    if (_capsError != null) {
      return EmptyState(
        icon: Icons.error_outline_rounded, title: 'Could not load capabilities',
        subtitle: _capsError, action: PrimaryButton(label: 'Retry', onTap: _loadCapabilities),
      );
    }
    if (_caps.isEmpty) {
      return const EmptyState(
        icon: Icons.travel_explore_rounded, title: 'Nothing discovered yet',
        subtitle: 'Run a SuperScan to build the capability map.',
      );
    }
    return Column(children: [
      for (final cap in _caps) ...[
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _CapabilityRow(cap: cap, onTap: () => _openCapabilityDetail(cap)),
        ),
      ],
    ]);
  }
}

String _modeLabel(String mode) => switch (mode) {
      'passive' => 'Passive scan',
      'quick'   => 'Quick scan',
      'full'    => 'Full scan',
      'deep'    => 'Deep SuperScan',
      _ => mode,
    };

String _deviceTypeLabel(String t) => switch (t) {
      'dali' => 'Lights',
      'relay' => 'Relays',
      'curtain' => 'Curtains',
      'appliance' => 'Appliances',
      'toggle' => 'Named relays',
      'switch' => 'Switches',
      'named_switch' => 'Named switches',
      'door_sensor' => 'Door sensors',
      'window_sensor' => 'Window sensors',
      'motion_sensor' => 'Motion sensors',
      'unknown_symbol' => 'Unknown symbols',
      'security' => 'Security',
      _ => t,
    };

IconData _deviceTypeIcon(String t) => switch (t) {
      'dali' => Icons.lightbulb_outline_rounded,
      'relay' => Icons.toggle_on_outlined,
      'curtain' => Icons.curtains_closed_rounded,
      'appliance' => Icons.kitchen_rounded,
      'toggle' => Icons.tune_rounded,
      'switch' || 'named_switch' => Icons.touch_app_rounded,
      'door_sensor' => Icons.sensor_door_rounded,
      'window_sensor' => Icons.window_rounded,
      'motion_sensor' => Icons.sensors_rounded,
      'security' => Icons.shield_outlined,
      'unknown_symbol' => Icons.help_outline_rounded,
      _ => Icons.device_unknown_rounded,
    };

String _relativeTime(DateTime t) {
  final diff = DateTime.now().toUtc().difference(t.toUtc());
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}

// ─────────────────────────────────────────────────────────────────────────────
// Mode select sheet — safety level shown before any active scan
// ─────────────────────────────────────────────────────────────────────────────

class _ModeSelectSheet extends StatelessWidget {
  const _ModeSelectSheet();

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(left: 20, right: 20, top: 20, bottom: MediaQuery.viewInsetsOf(context).bottom + 28),
    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Center(child: BottomSheetHandle()),
      const SizedBox(height: 12),
      Text('Choose a scan mode', style: AppText.h2),
      const SizedBox(height: 4),
      Text('Every mode is a controlled diagnostic pass — never a stress test.', style: AppText.bodySm),
      const SizedBox(height: 18),
      _ModeCard(
        icon: Icons.visibility_outlined, color: C.blue,
        title: 'Passive', safety: 'Zero commands sent',
        description: 'Reads current state of everything already known. Nothing is written to the PLC.',
        onTap: () => Navigator.pop(context, 'passive'),
      ),
      const SizedBox(height: 10),
      _ModeCard(
        icon: Icons.bolt_outlined, color: C.teal,
        title: 'Quick', safety: 'Zero commands sent',
        description: 'Same as Passive — a fast enumerate-and-read pass, ideal for routine checks.',
        onTap: () => Navigator.pop(context, 'quick'),
      ),
      const SizedBox(height: 10),
      _ModeCard(
        icon: Icons.science_outlined, color: C.orange,
        title: 'Full', safety: 'Actively tests writable devices',
        description: 'Adds a safe pulse-and-restore test on every modeled light, relay, and switch — the '
            'same protocol the Commissioning Wizard already uses. Every device is briefly actuated then '
            'restored to its original state, one at a time.',
        onTap: () => Navigator.pop(context, 'full'),
      ),
      const SizedBox(height: 10),
      _ModeCard(
        icon: Icons.manage_search_rounded, color: C.purple,
        title: 'Deep SuperScan', safety: 'Actively tests writable devices + reads unknown symbols',
        description: 'Everything in Full, plus cross-references the raw PLC symbol table for anything not '
            'yet modeled. Unknown symbols are only ever read, never written to.',
        onTap: () => Navigator.pop(context, 'deep'),
      ),
    ]),
  );
}

class _ModeCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title, safety, description;
  final VoidCallback onTap;
  const _ModeCard({
    required this.icon, required this.color, required this.title,
    required this.safety, required this.description, required this.onTap,
  });

  @override
  Widget build(BuildContext context) => TapScale(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: C.elevated, borderRadius: BorderRadius.circular(14),
        border: Border.all(color: C.border),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 34, height: 34,
          decoration: BoxDecoration(color: color.withAlpha(22), borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, color: color, size: 17),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 4, children: [
              Text(title, style: AppText.bodyMed),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: color.withAlpha(18), borderRadius: BorderRadius.circular(6)),
                child: Text(safety, style: GoogleFonts.inter(fontSize: 9, fontWeight: FontWeight.w700, color: color)),
              ),
            ]),
            const SizedBox(height: 4),
            Text(description, style: AppText.bodySm.copyWith(fontSize: 11)),
          ]),
        ),
      ]),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Small display widgets
// ─────────────────────────────────────────────────────────────────────────────

class _StatusPill extends StatelessWidget {
  final String status;
  const _StatusPill({required this.status});

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'running' => C.blue,
      'completed' => C.green,
      'stopped' => C.orange,
      'failed' => C.red,
      _ => C.textTri,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withAlpha(20), borderRadius: BorderRadius.circular(7)),
      child: Text(status.toUpperCase(),
          style: GoogleFonts.inter(fontSize: 9, fontWeight: FontWeight.w800, color: color, letterSpacing: 0.4)),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final int value;
  final Color? color;
  const _StatChip({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
    Text('$value', style: AppText.bodyMed.copyWith(fontSize: 12, color: color ?? C.textPri)),
    const SizedBox(width: 4),
    Text(label, style: AppText.bodySm.copyWith(fontSize: 10)),
  ]);
}

class _CountBadge extends StatelessWidget {
  final String label;
  final int value;
  final Color color;
  const _CountBadge({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: C.card, borderRadius: BorderRadius.circular(10), border: Border.all(color: C.border),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text('$value', style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w800, color: color)),
      Text(label, style: AppText.bodySm.copyWith(fontSize: 9)),
    ]),
  );
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final Color? color;
  final VoidCallback onTap;
  const _FilterChip({required this.label, required this.selected, required this.onTap, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? C.accent;
    return TapScale(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? c.withAlpha(22) : C.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? c.withAlpha(80) : C.border),
        ),
        child: Text(label,
            style: GoogleFonts.inter(fontSize: 11, fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? c : C.textSec)),
      ),
    );
  }
}

class _CapabilityRow extends StatelessWidget {
  final DiscoveredCapabilitySummary cap;
  final VoidCallback onTap;
  const _CapabilityRow({required this.cap, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final statusColor = switch (cap.testStatus) {
      'tested_ok' => C.green,
      'tested_failed' => C.red,
      'observed' => C.textTri,
      _ => C.orange,
    };
    final statusLabel = switch (cap.testStatus) {
      'tested_ok' => 'Tested OK',
      'tested_failed' => 'Tested — failed',
      'observed' => 'Discovered — not tested',
      _ => 'Not tested',
    };
    return TapScale(
      onTap: onTap,
      child: AppCard(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Container(
              width: 34, height: 34,
              decoration: BoxDecoration(
                color: (cap.isKnownType ? C.blue : C.orange).withAlpha(20),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(_deviceTypeIcon(cap.deviceType),
                  color: cap.isKnownType ? C.blue : C.orange, size: 16),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text(cap.name.isEmpty ? cap.identifier : cap.name,
                        style: AppText.bodyMed.copyWith(fontSize: 12), overflow: TextOverflow.ellipsis),
                  ),
                  if (!cap.isKnownType)
                    Container(
                      margin: const EdgeInsets.only(left: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: C.orange.withAlpha(18), borderRadius: BorderRadius.circular(6)),
                      child: Text('UNKNOWN', style: GoogleFonts.inter(fontSize: 8, fontWeight: FontWeight.w800, color: C.orange)),
                    ),
                ]),
                const SizedBox(height: 3),
                Text(
                  '${_deviceTypeLabel(cap.deviceType)} · ${cap.identifier}'
                  '${cap.room.isNotEmpty ? " · ${cap.room}" : ""}',
                  style: AppText.bodySm.copyWith(fontSize: 10), overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 5),
                Row(children: [
                  Icon(Icons.circle, size: 6, color: statusColor),
                  const SizedBox(width: 5),
                  Text(statusLabel, style: AppText.bodySm.copyWith(fontSize: 10, color: statusColor)),
                  if (cap.lastValue.isNotEmpty) ...[
                    const SizedBox(width: 10),
                    Text('= ${cap.lastValue}', style: AppText.bodySm.copyWith(fontSize: 10)),
                  ],
                ]),
              ]),
            ),
            const Icon(Icons.chevron_right_rounded, color: C.textTri, size: 18),
          ]),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Capability drill-down — Device -> Capability -> Test -> Request -> Response
// -> Result, plus the raw diagnostic log (test logs), as specced.
// ─────────────────────────────────────────────────────────────────────────────

class _CapabilityDetailSheet extends StatefulWidget {
  final SuperscanService svc;
  final int apartmentId;
  final int capId;
  final DiscoveredCapabilitySummary initial;
  const _CapabilityDetailSheet({
    required this.svc, required this.apartmentId, required this.capId, required this.initial,
  });

  @override
  State<_CapabilityDetailSheet> createState() => _CapabilityDetailSheetState();
}

class _CapabilityDetailSheetState extends State<_CapabilityDetailSheet> {
  bool _loading = true;
  DiscoveredCapabilitySummary? _cap;
  List<CapabilityTestLogSummary> _logs = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await widget.svc.capabilityDetail(widget.apartmentId, widget.capId);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (r.success) { _cap = r.value.$1; _logs = r.value.$2; }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cap = _cap ?? widget.initial;
    return Padding(
      padding: EdgeInsets.only(left: 20, right: 20, top: 20, bottom: MediaQuery.viewInsetsOf(context).bottom + 28),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.82),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Center(child: BottomSheetHandle()),
            const SizedBox(height: 12),
            Row(children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color: (cap.isKnownType ? C.blue : C.orange).withAlpha(20), borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(_deviceTypeIcon(cap.deviceType), color: cap.isKnownType ? C.blue : C.orange, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(cap.name.isEmpty ? cap.identifier : cap.name, style: AppText.h3),
                  Text('${_deviceTypeLabel(cap.deviceType)} · ${cap.identifier}', style: AppText.bodySm),
                ]),
              ),
            ]),
            const SizedBox(height: 16),
            _detailGrid(cap),
            if (cap.notes.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: C.elevated, borderRadius: BorderRadius.circular(10)),
                child: Text(cap.notes, style: AppText.bodySm.copyWith(fontSize: 11)),
              ),
            ],
            const SizedBox(height: 18),
            Text('Test log', style: AppText.bodyMed),
            const SizedBox(height: 8),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(child: CircularProgressIndicator(color: C.accent)),
              )
            else if (_logs.isEmpty)
              Text(
                cap.canSafelyTest ? 'Not tested yet — run Full or Deep SuperScan.'
                                  : 'This capability is never actively tested (read-only or unmapped).',
                style: AppText.bodySm,
              )
            else
              for (final log in _logs) ...[
                _TestLogRow(log: log),
                const AppDivider(),
              ],
          ]),
        ),
      ),
    );
  }

  Widget _detailGrid(DiscoveredCapabilitySummary cap) => Wrap(spacing: 10, runSpacing: 10, children: [
    _DetailField(label: 'Direction', value: cap.direction),
    _DetailField(label: 'Data type', value: cap.dataType.isEmpty ? '—' : cap.dataType),
    _DetailField(label: 'Valid range', value: cap.validRange.isEmpty ? '—' : cap.validRange),
    _DetailField(label: 'Current value', value: cap.lastValue.isEmpty ? '—' : cap.lastValue),
    _DetailField(label: 'Confidence', value: cap.confidence),
    _DetailField(label: 'Physically confirmed', value: cap.physicalEffectConfirmed ? 'Yes' : 'No'),
    if (!cap.isKnownType) _DetailField(label: 'Raw symbol', value: cap.rawVarName, mono: true),
  ]);
}

class _DetailField extends StatelessWidget {
  final String label, value;
  final bool mono;
  const _DetailField({required this.label, required this.value, this.mono = false});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    constraints: const BoxConstraints(minWidth: 100),
    decoration: BoxDecoration(color: C.elevated, borderRadius: BorderRadius.circular(10)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: AppText.bodySm.copyWith(fontSize: 9)),
      const SizedBox(height: 2),
      Text(value, style: (mono ? AppText.mono : AppText.bodyMed).copyWith(fontSize: 11)),
    ]),
  );
}

class _TestLogRow extends StatelessWidget {
  final CapabilityTestLogSummary log;
  const _TestLogRow({required this.log});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(log.success ? Icons.check_circle_rounded : Icons.error_rounded,
            size: 14, color: log.success ? C.green : C.red),
        const SizedBox(width: 6),
        Expanded(
          child: Text(log.commandSent.isEmpty ? 'read' : log.commandSent,
              style: AppText.bodyMed.copyWith(fontSize: 11)),
        ),
        if (log.latencyMs != null)
          Text('${log.latencyMs!.round()}ms', style: AppText.bodySm.copyWith(fontSize: 10)),
      ]),
      const SizedBox(height: 3),
      Text('before: ${log.stateBefore.isEmpty ? "—" : log.stateBefore}  →  after: ${log.stateAfter.isEmpty ? "—" : log.stateAfter}',
          style: AppText.bodySm.copyWith(fontSize: 10)),
      if (log.response.isNotEmpty)
        Text(log.response, style: AppText.bodySm.copyWith(fontSize: 10, color: C.textTri)),
      if (log.error.isNotEmpty)
        Text(log.error, style: AppText.bodySm.copyWith(fontSize: 10, color: C.red)),
    ]),
  );
}
