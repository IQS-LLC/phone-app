import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../auth/auth_state.dart';
import '../config/runtime_config.dart';
import '../models/automation_models.dart';
import '../services/automation_service.dart';
import '../theme.dart';
import '../widgets/common_widgets.dart';

/// "When this switch/sensor does X, do Y to that light/relay/curtain" —
/// defined entirely on the phone, no TwinCAT/ST code involved. Runs
/// alongside — never replaces — whatever's already hardwired inside the
/// PLC's own program for a given input; see AutomationRule's docstring.
/// is_staff only, same bar as LightReconfigureScreen/InputIdentifyScreen.
class AutomationsScreen extends StatefulWidget {
  final AuthState authState;
  final int    apartmentId;
  final String apartmentName;

  const AutomationsScreen({
    super.key,
    required this.authState,
    required this.apartmentId,
    required this.apartmentName,
  });

  @override
  State<AutomationsScreen> createState() => _AutomationsScreenState();
}

class _AutomationsScreenState extends State<AutomationsScreen> {
  late AutomationService _svc;
  bool _svcReady = false;
  bool _loading = true;
  String? _loadError;
  AutomationSnapshot? _snapshot;

  @override
  void initState() {
    super.initState();
    _initSvc();
    RuntimeConfig.instance.addListener(_onConfigChanged);
  }

  @override
  void dispose() {
    RuntimeConfig.instance.removeListener(_onConfigChanged);
    super.dispose();
  }

  // Rebuilds _svc if the server URL changes while this screen is open —
  // without this it would keep silently talking to the old server for as
  // long as the screen stays mounted. Same class of bug AppState was
  // hardened against; see RuntimeConfig's doc comment.
  void _onConfigChanged() {
    final svc = widget.authState.service;
    _svc = AutomationService(
      RuntimeConfig.instance.serverUrl,
      tokenProvider:  () => svc.getAccessToken(),
      tokenRefresher: () => svc.refreshAccessToken(),
    );
  }

  Future<void> _initSvc() async {
    final svc = widget.authState.service;
    _svc = AutomationService(
      RuntimeConfig.instance.serverUrl,
      tokenProvider:  () => svc.getAccessToken(),
      tokenRefresher: () => svc.refreshAccessToken(),
    );
    _svcReady = true;
    await _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _loadError = null; });
    final r = await _svc.listRules(widget.apartmentId);
    if (!mounted) return;
    if (!r.success) {
      setState(() { _loading = false; _loadError = r.error; });
      return;
    }
    setState(() { _loading = false; _snapshot = r.value; });
  }

  Future<void> _toggle(AutomationRuleSummary rule, bool value) async {
    final r = await _svc.setEnabled(widget.apartmentId, rule.id, value);
    if (!mounted) return;
    if (!r.success) {
      AppToast.show(context, r.error ?? 'Update failed', error: true);
      return;
    }
    await _load();
  }

  Future<void> _delete(AutomationRuleSummary rule) async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: C.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const BottomSheetHandle(),
          const SizedBox(height: 16),
          Text('Delete "${rule.name}"?', style: AppText.h3, textAlign: TextAlign.center),
          const SizedBox(height: 24),
          Row(children: [
            Expanded(child: PrimaryButton(label: 'Cancel', color: C.textSec, onTap: () => Navigator.pop(ctx, false))),
            const SizedBox(width: 12),
            Expanded(child: PrimaryButton(label: 'Delete', color: C.red, onTap: () => Navigator.pop(ctx, true))),
          ]),
        ]),
      ),
    );
    if (confirmed != true) return;
    final r = await _svc.deleteRule(widget.apartmentId, rule.id);
    if (!mounted) return;
    if (!r.success) {
      AppToast.show(context, r.error ?? 'Delete failed', error: true);
      return;
    }
    AppToast.show(context, 'Deleted "${rule.name}"');
    await _load();
  }

  Future<void> _openCreateSheet() async {
    final snap = _snapshot;
    if (snap == null) return;
    if (snap.triggers.isEmpty) {
      AppToast.show(context, 'No switches or sensors assigned yet — use Identify Switches & Sensors first', error: true);
      return;
    }
    if (snap.actions.isEmpty) {
      AppToast.show(context, 'No lights, relays, or curtains assigned yet — use Reconfigure Devices first', error: true);
      return;
    }

    final nameCtrl = TextEditingController();
    AutomationDevice? trigger = snap.triggers.first;
    bool triggerState = true;
    AutomationDevice? action = snap.actions.first;
    String actionValue = _defaultActionValue(action!);
    bool saving = false;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: C.card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(sheetContext).viewInsets.bottom + 28),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Center(child: BottomSheetHandle()),
              const SizedBox(height: 16),
              Text('New Automation', style: AppText.h3),
              const SizedBox(height: 16),
              TextField(
                controller: nameCtrl,
                autofocus: true,
                style: AppText.body.copyWith(color: C.textPri),
                decoration: InputDecoration(
                  hintText: 'e.g. Guest Bathroom motion → light',
                  hintStyle: AppText.bodySm.copyWith(color: C.textTri),
                  filled: true, fillColor: C.elevated,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(height: 16),
              Text('When', style: AppText.bodyMed),
              const SizedBox(height: 8),
              _DevicePicker(
                devices: snap.triggers,
                selected: trigger,
                onSelected: (d) => setSheet(() => trigger = d),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: _StateChip(label: 'becomes ACTIVE', selected: triggerState,
                    onTap: () => setSheet(() => triggerState = true))),
                const SizedBox(width: 8),
                Expanded(child: _StateChip(label: 'becomes inactive', selected: !triggerState,
                    onTap: () => setSheet(() => triggerState = false))),
              ]),
              const SizedBox(height: 20),
              Text('Then', style: AppText.bodyMed),
              const SizedBox(height: 8),
              _DevicePicker(
                devices: snap.actions,
                selected: action,
                onSelected: (d) => setSheet(() {
                  action = d;
                  actionValue = _defaultActionValue(d);
                }),
              ),
              const SizedBox(height: 12),
              _ActionValueEditor(
                device: action!,
                value: actionValue,
                onChanged: (v) => setSheet(() => actionValue = v),
              ),
              const SizedBox(height: 24),
              PrimaryButton(
                label: saving ? 'Saving…' : 'Create Automation',
                loading: saving,
                onTap: saving ? () {} : () async {
                  final name = nameCtrl.text.trim();
                  if (name.isEmpty) {
                    AppToast.show(sheetContext, 'Give this automation a name first', error: true);
                    return;
                  }
                  setSheet(() => saving = true);
                  final r = await _svc.createRule(
                    widget.apartmentId,
                    name: name,
                    triggerDeviceId: trigger!.id,
                    triggerState: triggerState,
                    actionDeviceId: action!.id,
                    actionValue: actionValue,
                  );
                  if (!sheetContext.mounted) return;
                  setSheet(() => saving = false);
                  if (!r.success) {
                    AppToast.show(sheetContext, r.error ?? 'Create failed', error: true);
                    return;
                  }
                  Navigator.pop(sheetContext);
                  await _load();
                  if (mounted) AppToast.show(context, 'Created "$name"');
                },
              ),
            ]),
          ),
        ),
      ),
    );
  }

  static String _defaultActionValue(AutomationDevice device) => switch (device.deviceType) {
        'dali' => '100',
        'relay' || 'appliance' => 'true',
        'curtain' => 'up',
        _ => '',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      appBar: AppBar(
        backgroundColor: C.surface,
        iconTheme: const IconThemeData(color: C.textSec),
        title: Text('Automations', style: AppText.h3),
      ),
      floatingActionButton: _svcReady && _snapshot != null
          ? FloatingActionButton.extended(
              onPressed: _openCreateSheet,
              backgroundColor: C.accent,
              icon: const Icon(Icons.add_rounded, color: Colors.black),
              label: Text('New Rule', style: GoogleFonts.inter(color: Colors.black, fontWeight: FontWeight.w700)),
            )
          : null,
      body: !_svcReady || _loading
          ? const Center(child: CircularProgressIndicator(color: C.accent))
          : _loadError != null
              ? EmptyState(
                  icon: Icons.error_outline_rounded,
                  title: 'Could not load automations',
                  subtitle: _loadError,
                  action: PrimaryButton(label: 'Retry', onTap: _load),
                )
              : (_snapshot?.rules.isEmpty ?? true)
                  ? const EmptyState(
                      icon: Icons.bolt_rounded,
                      title: 'No automations yet',
                      subtitle: 'Tap "New Rule" to create one — no PLC code required.',
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
                      itemCount: _snapshot!.rules.length,
                      itemBuilder: (_, i) {
                        final rule = _snapshot!.rules[i];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: AppCard(
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Row(children: [
                                  Expanded(child: Text(rule.name, style: AppText.bodyMed)),
                                  Switch(
                                    value: rule.enabled,
                                    activeThumbColor: C.accent,
                                    onChanged: (v) => _toggle(rule, v),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline_rounded, color: C.red, size: 18),
                                    onPressed: () => _delete(rule),
                                  ),
                                ]),
                                Text(
                                  'When ${rule.triggerDevice.label} becomes '
                                  '${rule.triggerState ? "active" : "inactive"} → '
                                  'set ${rule.actionDevice.label} to ${rule.actionValue}',
                                  style: AppText.bodySm,
                                ),
                              ]),
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}

class _DevicePicker extends StatelessWidget {
  final List<AutomationDevice> devices;
  final AutomationDevice? selected;
  final ValueChanged<AutomationDevice> onSelected;
  const _DevicePicker({required this.devices, required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) => Wrap(spacing: 8, runSpacing: 8, children: [
    for (final d in devices)
      ChoiceChip(
        label: Text(d.label),
        selected: selected?.id == d.id,
        selectedColor: C.accentLo,
        backgroundColor: C.card2,
        labelStyle: AppText.bodySm.copyWith(color: selected?.id == d.id ? C.accent : C.textSec),
        side: BorderSide(color: selected?.id == d.id ? C.accent : C.border),
        onSelected: (_) => onSelected(d),
      ),
  ]);
}

class _StateChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _StateChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => ChoiceChip(
    label: Center(child: Text(label)),
    selected: selected,
    selectedColor: C.accentLo,
    backgroundColor: C.card2,
    labelStyle: AppText.bodySm.copyWith(color: selected ? C.accent : C.textSec),
    side: BorderSide(color: selected ? C.accent : C.border),
    onSelected: (_) => onTap(),
  );
}

class _ActionValueEditor extends StatelessWidget {
  final AutomationDevice device;
  final String value;
  final ValueChanged<String> onChanged;
  const _ActionValueEditor({required this.device, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    switch (device.deviceType) {
      case 'dali':
        final pct = double.tryParse(value) ?? 100;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Brightness: ${pct.round()}%', style: AppText.bodySm),
          Slider(
            value: pct.clamp(0, 100),
            min: 0, max: 100, divisions: 20,
            activeColor: C.accent,
            onChanged: (v) => onChanged(v.round().toString()),
          ),
        ]);
      case 'relay':
      case 'appliance':
        return Row(children: [
          Expanded(child: _StateChip(label: 'Turn ON', selected: value == 'true', onTap: () => onChanged('true'))),
          const SizedBox(width: 8),
          Expanded(child: _StateChip(label: 'Turn OFF', selected: value == 'false', onTap: () => onChanged('false'))),
        ]);
      case 'curtain':
        return Row(children: [
          for (final v in ['up', 'stop', 'down']) ...[
            if (v != 'up') const SizedBox(width: 8),
            Expanded(child: _StateChip(label: v.toUpperCase(), selected: value == v, onTap: () => onChanged(v))),
          ],
        ]);
      default:
        return const SizedBox.shrink();
    }
  }
}
