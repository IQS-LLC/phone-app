import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../auth/auth_state.dart';
import '../models/relabel_models.dart';
import '../services/light_relabel_service.dart';
import '../theme.dart';
import '../widgets/common_widgets.dart';

class _InputType {
  final String key;      // matches device_type sent to assign endpoint
  final String label;
  final IconData icon;
  const _InputType(this.key, this.label, this.icon);
}

const _inputTypes = [
  _InputType('switch', 'Switches', Icons.toggle_on_outlined),
  _InputType('motion_sensor', 'Motion', Icons.sensors_rounded),
  _InputType('door_sensor', 'Doors', Icons.door_front_door_outlined),
  _InputType('window_sensor', 'Windows', Icons.window_outlined),
];

/// Watches every raw switch/sensor input terminal LIVE — press a physical
/// switch or trip a sensor and the matching entry lights up green
/// immediately, whether or not it's assigned to a room/name yet. Tap any
/// entry to assign it. Companion to LightReconfigureScreen, which does the
/// same identify-by-testing idea for outputs (DALI/relay/curtain) instead
/// of inputs. is_staff only — see has_relabel_access server-side.
class InputIdentifyScreen extends StatefulWidget {
  final AuthState authState;
  final int    apartmentId;
  final String apartmentName;

  const InputIdentifyScreen({
    super.key,
    required this.authState,
    required this.apartmentId,
    required this.apartmentName,
  });

  @override
  State<InputIdentifyScreen> createState() => _InputIdentifyScreenState();
}

class _InputIdentifyScreenState extends State<InputIdentifyScreen> {
  late LightRelabelService _svc;
  bool _svcReady = false;

  int _typeIndex = 0;
  _InputType get _type => _inputTypes[_typeIndex];

  bool _loading = true;
  String? _loadError;
  InputSnapshot? _snapshot;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _initSvc();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _initSvc() async {
    final svc     = widget.authState.service;
    final baseUrl = await svc.getBaseUrl() ?? '';
    _svc = LightRelabelService(
      baseUrl,
      tokenProvider:  () => svc.getAccessToken(),
      tokenRefresher: () => svc.refreshAccessToken(),
    );
    _svcReady = true;
    await _poll(showSpinner: true);
    _pollTimer = Timer.periodic(const Duration(milliseconds: 900), (_) => _poll());
  }

  Future<void> _poll({bool showSpinner = false}) async {
    if (!mounted) return;
    if (showSpinner) setState(() { _loading = true; _loadError = null; });
    final r = await _svc.listInputs(widget.apartmentId);
    if (!mounted) return;
    if (!r.success) {
      setState(() { _loading = false; _loadError = r.error; });
      return;
    }
    setState(() {
      _loading = false;
      _loadError = null;
      _snapshot = r.value;
    });
  }

  List<InputChannelSlot> _channelsFor(_InputType type) {
    final s = _snapshot;
    if (s == null) return [];
    return switch (type.key) {
      'switch'        => s.switches,
      'motion_sensor'  => s.motionSensors,
      'door_sensor'    => s.doorSensors,
      'window_sensor'  => s.windowSensors,
      _ => [],
    };
  }

  Future<void> _openAssignSheet(InputChannelSlot slot) async {
    final rooms = _snapshot?.rooms ?? [];
    final nameCtrl = TextEditingController(text: slot.name ?? '');
    int? selectedRoomId = slot.roomId;
    String? pendingNewRoomName;
    bool saving = false;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: C.card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
            20, 20, 20, MediaQuery.of(sheetContext).viewInsets.bottom + 28,
          ),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const BottomSheetHandle(),
            const SizedBox(height: 16),
            Text('${_type.label.substring(0, _type.label.length - (_type.label.endsWith("s") ? 1 : 0))} #${slot.index}',
                style: AppText.h3),
            const SizedBox(height: 4),
            Text(
              slot.state == true ? 'Currently ACTIVE — press again to double-check' : 'Currently inactive',
              style: AppText.bodySm.copyWith(color: slot.state == true ? C.green : C.textSec),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: nameCtrl,
              autofocus: true,
              style: AppText.body.copyWith(color: C.textPri),
              decoration: InputDecoration(
                hintText: 'Name, e.g. Laundry Motion Switch',
                hintStyle: AppText.bodySm.copyWith(color: C.textTri),
                filled: true,
                fillColor: C.elevated,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 12),
            Text('Room / Group', style: AppText.bodySm),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final room in rooms)
                ChoiceChip(
                  label: Text(room.name),
                  selected: selectedRoomId == room.id,
                  selectedColor: C.accentLo,
                  backgroundColor: C.card2,
                  labelStyle: AppText.bodySm.copyWith(
                    color: selectedRoomId == room.id ? C.accent : C.textSec,
                  ),
                  side: BorderSide(color: selectedRoomId == room.id ? C.accent : C.border),
                  onSelected: (_) => setSheet(() {
                    selectedRoomId = room.id;
                    pendingNewRoomName = null;
                  }),
                ),
              ChoiceChip(
                label: Text(pendingNewRoomName ?? '+ New Room/Group'),
                selected: pendingNewRoomName != null,
                selectedColor: C.accentLo,
                backgroundColor: C.card2,
                labelStyle: AppText.bodySm.copyWith(
                  color: pendingNewRoomName != null ? C.accent : C.textSec,
                ),
                side: BorderSide(color: pendingNewRoomName != null ? C.accent : C.border),
                onSelected: (_) async {
                  final ctrl = TextEditingController();
                  final name = await showDialog<String>(
                    context: sheetContext,
                    builder: (dialogContext) => AlertDialog(
                      backgroundColor: C.card,
                      title: Text('New Room / Group', style: AppText.h3),
                      content: TextField(
                        controller: ctrl,
                        autofocus: true,
                        style: AppText.body.copyWith(color: C.textPri),
                        decoration: InputDecoration(
                          hintText: 'e.g. Bathroom 2, Kitchen, Guest Bedroom',
                          hintStyle: AppText.bodySm.copyWith(color: C.textTri),
                          filled: true,
                          fillColor: C.elevated,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        onSubmitted: (v) => Navigator.pop(dialogContext, v),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext, null),
                          child: Text('Cancel', style: GoogleFonts.inter(color: C.textSec)),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext, ctrl.text),
                          child: Text('Use This', style: GoogleFonts.inter(color: C.accent, fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                  );
                  if (name != null && name.trim().isNotEmpty) {
                    setSheet(() {
                      pendingNewRoomName = name.trim();
                      selectedRoomId = null;
                    });
                  }
                },
              ),
            ]),
            const SizedBox(height: 20),
            PrimaryButton(
              label: saving ? 'Saving…' : 'Save',
              loading: saving,
              onTap: saving ? () {} : () async {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) {
                  AppToast.show(sheetContext, 'Give it a name first', error: true);
                  return;
                }
                if (selectedRoomId == null && (pendingNewRoomName == null || pendingNewRoomName!.isEmpty)) {
                  AppToast.show(sheetContext, 'Pick or create a room/group first', error: true);
                  return;
                }
                setSheet(() => saving = true);
                final r = await _svc.assignInput(
                  widget.apartmentId,
                  deviceType: _type.key,
                  index: slot.index,
                  name: name,
                  roomId: selectedRoomId,
                  roomName: selectedRoomId == null ? pendingNewRoomName : null,
                );
                if (!sheetContext.mounted) return;
                setSheet(() => saving = false);
                if (!r.success) {
                  AppToast.show(sheetContext, r.error ?? 'Save failed', error: true);
                  return;
                }
                Navigator.pop(sheetContext);
                await _poll();
                if (mounted) AppToast.show(context, 'Saved "$name"');
              },
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final channels = _channelsFor(_type);
    return Scaffold(
      backgroundColor: C.bg,
      appBar: AppBar(
        backgroundColor: C.surface,
        iconTheme: const IconThemeData(color: C.textSec),
        title: Text('Identify Switches & Sensors', style: AppText.h3),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(children: [
            Icon(Icons.podcasts_rounded, size: 14, color: C.green),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Press a physical switch or trip a sensor — the matching entry below turns green.',
                style: AppText.bodySm.copyWith(fontSize: 11),
              ),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(children: [
            for (var i = 0; i < _inputTypes.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(
                child: ChoiceChip(
                  label: Text(_inputTypes[i].label),
                  selected: _typeIndex == i,
                  selectedColor: C.accentLo,
                  backgroundColor: C.card2,
                  labelStyle: AppText.bodySm.copyWith(
                    color: _typeIndex == i ? C.accent : C.textSec,
                    fontSize: 12,
                  ),
                  side: BorderSide(color: _typeIndex == i ? C.accent : C.border),
                  onSelected: (_) => setState(() => _typeIndex = i),
                ),
              ),
            ],
          ]),
        ),
        Expanded(
          child: !_svcReady || (_loading && _snapshot == null)
              ? const Center(child: CircularProgressIndicator(color: C.accent))
              : _loadError != null && _snapshot == null
                  ? EmptyState(
                      icon: Icons.error_outline_rounded,
                      title: 'Could not load inputs',
                      subtitle: _loadError,
                      action: PrimaryButton(label: 'Retry', onTap: () => _poll(showSpinner: true)),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      itemCount: channels.length,
                      itemBuilder: (_, i) {
                        final slot = channels[i];
                        final active = slot.state == true;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: AppCard(
                            color: active ? C.greenLo : null,
                            borderColor: active ? C.green : null,
                            child: InkWell(
                              onTap: () => _openAssignSheet(slot),
                              child: Padding(
                                padding: const EdgeInsets.all(14),
                                child: Row(children: [
                                  Container(
                                    width: 10, height: 10,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: active ? C.green : C.textTri,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text('#${slot.index}', style: AppText.bodyMed),
                                        Text(
                                          slot.assigned
                                              ? '${slot.name} → ${slot.roomName}'
                                              : 'Unassigned',
                                          style: AppText.bodySm.copyWith(
                                            color: slot.assigned ? C.textSec : C.textTri,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (active)
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: C.green.withAlpha(30),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text('ACTIVE', style: AppText.labelSm.copyWith(color: C.green)),
                                    ),
                                  const SizedBox(width: 8),
                                  const Icon(Icons.chevron_right_rounded, color: C.textTri, size: 18),
                                ]),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ]),
    );
  }
}
