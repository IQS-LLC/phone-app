import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../auth/auth_state.dart';
import '../config/runtime_config.dart';
import '../models/relabel_models.dart';
import '../services/light_relabel_service.dart';
import '../theme.dart';
import '../widgets/common_widgets.dart';

class _OutputType {
  final String key;
  final String label;
  final String noun;
  final IconData icon;
  const _OutputType(this.key, this.label, this.noun, this.icon);
}

const _outputTypes = [
  _OutputType('dali', 'Lights', 'light', Icons.lightbulb_rounded),
  _OutputType('relay', 'Wall Relays', 'wall light', Icons.toggle_on_rounded),
  _OutputType('curtain', 'Curtains', 'curtain', Icons.curtains_closed_rounded),
];

/// Lets IT Team walk every output channel (DALI dimmer, wall relay,
/// curtain) one at a time, flash it so they can see which physical fixture
/// it drives, and fix its room + display name on the spot — for correcting
/// channels that were mislabeled during initial commissioning, and for
/// finding channels that were never assigned a room/name at all.
///
/// is_staff only — see has_relabel_access server-side and the Settings
/// screen, which only ever shows the entry point inside its Tech Team
/// section, never Device Management (that section is Owner/Installer
/// visible too, this screen must not be reachable from there).
class LightReconfigureScreen extends StatefulWidget {
  final AuthState authState;
  final int    apartmentId;
  final String apartmentName;

  const LightReconfigureScreen({
    super.key,
    required this.authState,
    required this.apartmentId,
    required this.apartmentName,
  });

  @override
  State<LightReconfigureScreen> createState() => _LightReconfigureScreenState();
}

class _LightReconfigureScreenState extends State<LightReconfigureScreen> {
  late LightRelabelService _svc;
  bool _svcReady = false;

  int _typeIndex = 0;
  _OutputType get _type => _outputTypes[_typeIndex];

  bool _loading = true;
  String? _loadError;
  List<OutputChannelSlot> _channels = [];
  List<RelabelRoom> _rooms = [];
  int _index = 0;

  bool _flashing = false;
  bool _saving = false;

  final _nameCtrl = TextEditingController();
  int? _selectedRoomId;
  String? _pendingNewRoomName;

  @override
  void initState() {
    super.initState();
    _initSvc();
    RuntimeConfig.instance.addListener(_onConfigChanged);
  }

  @override
  void dispose() {
    RuntimeConfig.instance.removeListener(_onConfigChanged);
    _nameCtrl.dispose();
    super.dispose();
  }

  // Rebuilds _svc if the server URL changes while this screen is open —
  // without this it would keep silently talking to the old server for as
  // long as the screen stays mounted. Same class of bug AppState was
  // hardened against; see RuntimeConfig's doc comment.
  void _onConfigChanged() {
    final svc = widget.authState.service;
    _svc = LightRelabelService(
      RuntimeConfig.instance.serverUrl,
      tokenProvider:  () => svc.getAccessToken(),
      tokenRefresher: () => svc.refreshAccessToken(),
    );
  }

  Future<void> _initSvc() async {
    final svc = widget.authState.service;
    _svc = LightRelabelService(
      RuntimeConfig.instance.serverUrl,
      tokenProvider:  () => svc.getAccessToken(),
      tokenRefresher: () => svc.refreshAccessToken(),
    );
    _svcReady = true;
    await _load();
  }

  Future<void> _switchType(int newTypeIndex) async {
    if (newTypeIndex == _typeIndex) return;
    setState(() { _typeIndex = newTypeIndex; _index = 0; });
    await _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _loadError = null; });
    final r = await _svc.listOutputChannels(widget.apartmentId, _type.key);
    if (!mounted) return;
    if (!r.success) {
      setState(() { _loading = false; _loadError = r.error; });
      return;
    }
    final (channels, rooms) = r.value;
    setState(() {
      _loading = false;
      _channels = channels;
      _rooms = rooms;
      _index = _index.clamp(0, channels.isEmpty ? 0 : channels.length - 1);
      _loadFieldsFromCurrent();
    });
  }

  OutputChannelSlot get _current => _channels[_index];
  int get _configuredCount => _channels.where((c) => c.assigned).length;

  void _loadFieldsFromCurrent() {
    if (_channels.isEmpty) return;
    final c = _current;
    _nameCtrl.text = c.name ?? '';
    _selectedRoomId = c.roomId;
    _pendingNewRoomName = null;
  }

  void _goTo(int newIndex) {
    if (newIndex < 0 || newIndex >= _channels.length) return;
    setState(() {
      _index = newIndex;
      _loadFieldsFromCurrent();
    });
  }

  Future<void> _flash() async {
    setState(() => _flashing = true);
    AppToast.show(context, 'Flashing ${_type.noun} ${_current.channel} — watch for it to blink…',
        kind: ToastKind.info);
    final r = await _svc.flashOutputChannel(widget.apartmentId, _type.key, _current.channel);
    if (!mounted) return;
    setState(() => _flashing = false);
    if (!r.success) {
      AppToast.show(context, r.error ?? 'Flash failed', error: true);
    }
  }

  Future<void> _promptNewRoom() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
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
    if (name == null || name.trim().isEmpty) return;
    setState(() {
      _pendingNewRoomName = name.trim();
      _selectedRoomId = null;
    });
  }

  Future<void> _saveAndNext() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      AppToast.show(context, 'Give this ${_type.noun} a name first', error: true);
      return;
    }
    if (_selectedRoomId == null && (_pendingNewRoomName == null || _pendingNewRoomName!.isEmpty)) {
      AppToast.show(context, 'Pick or create a room/group first', error: true);
      return;
    }

    setState(() => _saving = true);
    final r = await _svc.assignOutputChannel(
      widget.apartmentId, _type.key, _current.channel,
      name: name,
      roomId: _selectedRoomId,
      roomName: _selectedRoomId == null ? _pendingNewRoomName : null,
    );
    if (!mounted) return;
    setState(() => _saving = false);

    if (!r.success) {
      AppToast.show(context, r.error ?? 'Save failed', error: true);
      return;
    }

    final saved = r.value;
    setState(() {
      _channels[_index] = saved;
      if (_selectedRoomId == null &&
          !_rooms.any((room) => room.name == saved.roomName)) {
        _rooms = [..._rooms, RelabelRoom(id: saved.roomId!, name: saved.roomName!)];
      }
    });
    AppToast.show(context, 'Saved "${saved.name}" → ${saved.roomName}');

    if (_index < _channels.length - 1) {
      _goTo(_index + 1);
    } else {
      AppToast.show(context, 'All ${_type.label.toLowerCase()} reviewed', kind: ToastKind.success);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      appBar: AppBar(
        backgroundColor: C.surface,
        iconTheme: const IconThemeData(color: C.textSec),
        title: Text('Reconfigure Devices', style: AppText.h3),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(children: [
            for (var i = 0; i < _outputTypes.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(
                child: ChoiceChip(
                  label: Text(_outputTypes[i].label),
                  selected: _typeIndex == i,
                  selectedColor: C.accentLo,
                  backgroundColor: C.card2,
                  labelStyle: AppText.bodySm.copyWith(
                    color: _typeIndex == i ? C.accent : C.textSec,
                  ),
                  side: BorderSide(color: _typeIndex == i ? C.accent : C.border),
                  onSelected: (_) => _switchType(i),
                ),
              ),
            ],
          ]),
        ),
        Expanded(
          child: !_svcReady || _loading
              ? const Center(child: CircularProgressIndicator(color: C.accent))
              : _loadError != null
                  ? EmptyState(
                      icon: Icons.error_outline_rounded,
                      title: 'Could not load channels',
                      subtitle: _loadError,
                      action: PrimaryButton(label: 'Retry', onTap: _load),
                    )
                  : _channels.isEmpty
                      ? EmptyState(
                          icon: _type.icon,
                          title: 'No ${_type.label.toLowerCase()} found',
                        )
                      : _buildWizard(),
        ),
      ]),
    );
  }

  Widget _buildWizard() {
    final c = _current;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Row(children: [
          Expanded(
            child: LinearProgressIndicator(
              value: (_index + 1) / _channels.length,
              backgroundColor: C.card2,
              color: C.accent,
              minHeight: 4,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Text('${_index + 1} / ${_channels.length} · $_configuredCount configured',
              style: AppText.bodySm.copyWith(fontSize: 11)),
        ]),
      ),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            AppCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Container(
                      width: 40, height: 40,
                      decoration: BoxDecoration(
                        color: C.accentLo, borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(_type.icon, color: C.accent, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${_type.label} — Channel ${c.channel}', style: AppText.h3),
                        Text(
                          c.assigned
                              ? 'Currently: ${c.name} → ${c.roomName}'
                              : 'Not yet assigned',
                          style: AppText.bodySm.copyWith(
                            color: c.assigned ? C.textSec : C.orange,
                          ),
                        ),
                      ]),
                    ),
                  ]),
                  const SizedBox(height: 16),
                  PrimaryButton(
                    label: _flashing ? 'Testing…' : 'Test This ${_type.noun[0].toUpperCase()}${_type.noun.substring(1)}',
                    icon: Icons.flash_on_rounded,
                    loading: _flashing,
                    onTap: _flashing ? () {} : _flash,
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 16),
            Text('Assign this channel', style: AppText.bodyMed),
            const SizedBox(height: 8),
            TextField(
              controller: _nameCtrl,
              style: AppText.body.copyWith(color: C.textPri),
              decoration: InputDecoration(
                hintText: '${_type.noun[0].toUpperCase()}${_type.noun.substring(1)} name, e.g. Laundry Ceiling Light',
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
              for (final room in _rooms)
                ChoiceChip(
                  label: Text(room.name),
                  selected: _selectedRoomId == room.id,
                  selectedColor: C.accentLo,
                  backgroundColor: C.card2,
                  labelStyle: AppText.bodySm.copyWith(
                    color: _selectedRoomId == room.id ? C.accent : C.textSec,
                  ),
                  side: BorderSide(
                    color: _selectedRoomId == room.id ? C.accent : C.border,
                  ),
                  onSelected: (_) => setState(() {
                    _selectedRoomId = room.id;
                    _pendingNewRoomName = null;
                  }),
                ),
              ChoiceChip(
                label: Text(_pendingNewRoomName ?? '+ New Room/Group'),
                selected: _pendingNewRoomName != null,
                selectedColor: C.accentLo,
                backgroundColor: C.card2,
                labelStyle: AppText.bodySm.copyWith(
                  color: _pendingNewRoomName != null ? C.accent : C.textSec,
                ),
                side: BorderSide(
                  color: _pendingNewRoomName != null ? C.accent : C.border,
                ),
                onSelected: (_) => _promptNewRoom(),
              ),
            ]),
          ],
        ),
      ),
      Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        decoration: BoxDecoration(
          color: C.surface,
          border: Border(top: BorderSide(color: C.border, width: 0.5)),
        ),
        child: Row(children: [
          IconButton(
            icon: const Icon(Icons.chevron_left_rounded, color: C.textSec),
            onPressed: _index > 0 ? () => _goTo(_index - 1) : null,
          ),
          Expanded(
            child: TextButton(
              onPressed: _saving ? null : () => _goTo(_index + 1),
              child: Text('Skip', style: GoogleFonts.inter(color: C.textSec, fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: PrimaryButton(
              label: _saving ? 'Saving…' : 'Save & Next',
              loading: _saving,
              onTap: _saving ? () {} : _saveAndNext,
              height: 48,
            ),
          ),
        ]),
      ),
    ]);
  }
}
