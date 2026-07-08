import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme.dart';
import '../auth/auth_state.dart';
import '../models/auth_models.dart';
import '../widgets/common_widgets.dart';
import 'room_device_layout_screen.dart';

/// Tech Team only. Gives an at-a-glance view of every apartment in the
/// system — who lives there, how many rooms/devices it has, and whether
/// its controller is online — without digging through the user list one
/// account at a time.
class ApartmentManagementScreen extends StatefulWidget {
  final AuthState authState;
  const ApartmentManagementScreen({super.key, required this.authState});

  @override
  State<ApartmentManagementScreen> createState() => _ApartmentManagementScreenState();
}

class _ApartmentManagementScreenState extends State<ApartmentManagementScreen> {
  bool _loading = true;
  String? _error;
  List<ApartmentOverview> _apartments = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    final apartments = await widget.authState.fetchApartmentOverview();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (apartments == null) {
        _error = 'Could not load apartments.';
      } else {
        _apartments = apartments;
      }
    });
  }

  void _openCreateApartment() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _CreateApartmentSheet(
        onSubmit: (name, building, floor) async {
          final error = await widget.authState.createApartment(
            name: name, building: building, floor: floor,
          );
          if (error != null) {
            if (mounted) AppToast.show(context, error, error: true);
            return false;
          }
          await _load();
          if (mounted) AppToast.show(context, 'Apartment created');
          return true;
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: C.bg,
    appBar: AppBar(
      backgroundColor: C.surface,
      title: const Text('Apartment Management'),
      iconTheme: const IconThemeData(color: C.textSec),
      actions: [
        IconButton(
          icon: const Icon(Icons.add_home_work_rounded, color: C.accent),
          tooltip: 'Create Apartment',
          onPressed: _openCreateApartment,
        ),
      ],
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator(color: C.accent))
        : _error != null
            ? EmptyState(
                icon: Icons.error_outline_rounded,
                title: 'Couldn\'t load apartments',
                subtitle: _error,
                action: PrimaryButton(label: 'Retry', onTap: _load),
              )
            : RefreshIndicator(
                color: C.accent,
                backgroundColor: C.card,
                onRefresh: _load,
                child: _apartments.isEmpty
                    ? EmptyState(
                        icon: Icons.apartment_rounded,
                        title: 'No apartments yet',
                        action: PrimaryButton(label: 'Create Apartment', onTap: _openCreateApartment),
                      )
                    : ListView.builder(
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                        itemCount: _apartments.length,
                        itemBuilder: (_, i) => Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _ApartmentCard(
                            apartment: _apartments[i],
                            authState: widget.authState,
                            onChanged: _load,
                          ),
                        ),
                      ),
              ),
  );
}

class _ApartmentCard extends StatefulWidget {
  final ApartmentOverview apartment;
  final AuthState authState;
  final VoidCallback onChanged;
  const _ApartmentCard({required this.apartment, required this.authState, required this.onChanged});

  @override
  State<_ApartmentCard> createState() => _ApartmentCardState();
}

class _ApartmentCardState extends State<_ApartmentCard> {
  bool _expanded = false;

  String _lastComms(ApartmentPlcStatus? plc) {
    if (plc == null) return 'No controller assigned';
    if (plc.lastSeenAt == null) return 'Never connected';
    final t = DateTime.tryParse(plc.lastSeenAt!);
    if (t == null) return 'Unknown';
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1)  return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24)   return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.apartment;
    final plc = a.plc;
    final online = plc != null && plc.isActive;

    return AppCard(
      child: Column(children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              Container(
                width: 38, height: 38,
                decoration: BoxDecoration(
                  color: (online ? C.green : C.textTri).withAlpha(20),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(Icons.apartment_rounded,
                    color: online ? C.green : C.textTri, size: 17),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(a.name, style: AppText.bodyMed),
                    const SizedBox(height: 2),
                    Text(
                      a.owner != null ? 'Owner: ${a.owner!.displayName}' : 'No owner assigned',
                      style: AppText.bodySm.copyWith(fontSize: 11),
                    ),
                  ],
                ),
              ),
              _Pill(
                label: plc == null ? 'No PLC' : (online ? 'Online' : 'Offline'),
                color: plc == null ? C.textTri : (online ? C.green : C.red),
              ),
              const SizedBox(width: 4),
              AnimatedRotation(
                turns: _expanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 200),
                child: const Icon(Icons.expand_more_rounded, color: C.textTri, size: 18),
              ),
            ]),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          child: _expanded ? _details(a) : const SizedBox(width: double.infinity),
        ),
      ]),
    );
  }

  Widget _details(ApartmentOverview a) => Column(children: [
    const AppDivider(),
    Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: _Stat(icon: Icons.meeting_room_outlined, label: 'Rooms', value: '${a.roomCount}')),
            Expanded(child: _Stat(icon: Icons.cable_rounded, label: 'Devices', value: '${a.deviceCount}')),
            Expanded(child: _Stat(icon: Icons.people_outline_rounded, label: 'Residents', value: '${a.residents.length}')),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Icon(Icons.sync_rounded, size: 13, color: C.textTri),
            const SizedBox(width: 6),
            Text('Last communication: ${_lastComms(a.plc)}', style: AppText.bodySm.copyWith(fontSize: 11)),
          ]),
          if (a.owner != null || a.residents.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('ASSIGNED USERS', style: AppText.label),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [
              if (a.owner != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: C.accent.withAlpha(16),
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(color: C.accent.withAlpha(50)),
                  ),
                  child: Text('${a.owner!.displayName} (Owner)',
                      style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: C.accent)),
                ),
              for (final r in a.residents)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: C.blue.withAlpha(14),
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(color: C.blue.withAlpha(45)),
                  ),
                  child: Text(r.displayName,
                      style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w500, color: C.blue)),
                ),
            ]),
          ],
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: _ActionBtn(
                icon: Icons.router_rounded, label: 'Edit Controller',
                onTap: () => _openPlcEditor(a),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _ActionBtn(
                icon: Icons.dashboard_customize_rounded, label: 'Rooms & Devices',
                onTap: () => Navigator.push(context, MaterialPageRoute(
                  builder: (_) => RoomDeviceLayoutScreen(
                    authState: widget.authState, apartmentId: a.id, apartmentName: a.name,
                  ),
                )).then((_) => widget.onChanged()),
              ),
            ),
          ]),
        ],
      ),
    ),
  ]);

  void _openPlcEditor(ApartmentOverview a) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _PlcEditorSheet(
        authState: widget.authState, apartmentId: a.id, apartmentName: a.name,
        onChanged: widget.onChanged,
      ),
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String   label;
  final VoidCallback onTap;
  const _ActionBtn({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => TapScale(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: C.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: C.border),
      ),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, size: 14, color: C.textSec),
        const SizedBox(width: 6),
        Text(label, style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: C.textSec)),
      ]),
    ),
  );
}

class _Stat extends StatelessWidget {
  final IconData icon;
  final String   label;
  final String   value;
  const _Stat({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Column(children: [
    Icon(icon, size: 16, color: C.textSec),
    const SizedBox(height: 4),
    Text(value, style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w700, color: C.textPri)),
    Text(label, style: AppText.bodySm.copyWith(fontSize: 10)),
  ]);
}

class _Pill extends StatelessWidget {
  final String label;
  final Color  color;
  const _Pill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withAlpha(16),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: color.withAlpha(50)),
    ),
    child: Text(label,
        style: GoogleFonts.inter(fontSize: 9, fontWeight: FontWeight.w700, color: color)),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Create Apartment sheet
// ─────────────────────────────────────────────────────────────────────────────

class _CreateApartmentSheet extends StatefulWidget {
  final Future<bool> Function(String name, String building, String floor) onSubmit;
  const _CreateApartmentSheet({required this.onSubmit});

  @override
  State<_CreateApartmentSheet> createState() => _CreateApartmentSheetState();
}

class _CreateApartmentSheetState extends State<_CreateApartmentSheet> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _buildingCtrl = TextEditingController();
  final _floorCtrl = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_nameCtrl, _buildingCtrl, _floorCtrl]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    final ok = await widget.onSubmit(
      _nameCtrl.text.trim(), _buildingCtrl.text.trim(), _floorCtrl.text.trim(),
    );
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
    } else {
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(
      left: 20, right: 20, top: 20,
      bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
    ),
    child: Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const BottomSheetHandle(),
          const SizedBox(height: 16),
          Text('Create Apartment', style: AppText.h2),
          const SizedBox(height: 4),
          Text('Adds a new house/unit. Assign residents and a controller afterward.',
              style: AppText.bodySm),
          const SizedBox(height: 20),
          _formField('NAME', _nameCtrl, hint: 'Apartment 24',
            validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null),
          const SizedBox(height: 12),
          _formField('BUILDING (OPTIONAL)', _buildingCtrl, hint: 'Tower B', required: false),
          const SizedBox(height: 12),
          _formField('FLOOR (OPTIONAL)', _floorCtrl, hint: '3', required: false),
          const SizedBox(height: 20),
          PrimaryButton(label: 'Create Apartment', loading: _saving, onTap: _submit),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );

  Widget _formField(
    String label, TextEditingController ctrl, {
    String hint = '', bool required = true, String? Function(String?)? validator,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: AppText.label),
      const SizedBox(height: 6),
      TextFormField(
        controller: ctrl,
        style: AppText.body.copyWith(color: C.textPri),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: AppText.bodySm.copyWith(color: C.textTri),
          filled: true,
          fillColor: C.elevated,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: C.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: C.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: C.accent, width: 1.5),
          ),
          errorStyle: AppText.bodySm.copyWith(color: C.red),
        ),
        validator: validator ?? (v) => (required && (v == null || v.trim().isEmpty)) ? 'Required' : null,
      ),
    ],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// PLC editor sheet — the actual fix for "can't write a server/CX IP from the
// Tech Team console". Distinct from Settings → Controllers, which manages
// PLCDevice rows scoped to their creator and never linked to an apartment.
// ─────────────────────────────────────────────────────────────────────────────

class _PlcEditorSheet extends StatefulWidget {
  final AuthState authState;
  final int    apartmentId;
  final String apartmentName;
  final VoidCallback onChanged;
  const _PlcEditorSheet({
    required this.authState, required this.apartmentId, required this.apartmentName,
    required this.onChanged,
  });

  @override
  State<_PlcEditorSheet> createState() => _PlcEditorSheetState();
}

class _PlcEditorSheetState extends State<_PlcEditorSheet> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _ipCtrl   = TextEditingController();
  final _amsCtrl  = TextEditingController();
  final _portCtrl = TextEditingController(text: '851');
  bool _loading = true;
  bool _saving  = false;
  bool _hadExisting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final plc = await widget.authState.fetchApartmentPlc(widget.apartmentId);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (plc != null) {
        _hadExisting = true;
        _nameCtrl.text = plc.name;
        _ipCtrl.text   = plc.ipAddress;
        _amsCtrl.text  = plc.amsNetId;
        _portCtrl.text = plc.adsPort.toString();
      }
    });
  }

  @override
  void dispose() {
    for (final c in [_nameCtrl, _ipCtrl, _amsCtrl, _portCtrl]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    final error = await widget.authState.setApartmentPlc(
      widget.apartmentId,
      ipAddress: _ipCtrl.text.trim(), amsNetId: _amsCtrl.text.trim(),
      name: _nameCtrl.text.trim(), adsPort: int.tryParse(_portCtrl.text.trim()) ?? 851,
    );
    if (!mounted) return;
    if (error != null) {
      setState(() => _saving = false);
      AppToast.show(context, error, error: true);
      return;
    }
    widget.onChanged();
    Navigator.pop(context);
    AppToast.show(context, 'Controller assigned to ${widget.apartmentName}');
  }

  Future<void> _unassign() async {
    setState(() => _saving = true);
    final ok = await widget.authState.unassignApartmentPlc(widget.apartmentId);
    if (!mounted) return;
    if (ok) {
      widget.onChanged();
      Navigator.pop(context);
      AppToast.show(context, 'Controller unassigned');
    } else {
      setState(() => _saving = false);
      AppToast.show(context, 'Could not unassign', error: true);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(
      left: 20, right: 20, top: 20,
      bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
    ),
    child: Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const BottomSheetHandle(),
          const SizedBox(height: 16),
          Text('Controller — ${widget.apartmentName}', style: AppText.h2),
          const SizedBox(height: 4),
          Text('TwinCAT connection details for the Beckhoff CX serving this apartment.',
              style: AppText.bodySm),
          const SizedBox(height: 20),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator(color: C.accent)),
            )
          else ...[
            _field('NAME (OPTIONAL)', _nameCtrl, hint: '${widget.apartmentName} PLC', required: false),
            const SizedBox(height: 12),
            _field('IP ADDRESS', _ipCtrl, hint: '192.168.0.158',
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null),
            const SizedBox(height: 12),
            _field('AMS NET ID', _amsCtrl, hint: '192.168.0.158.1.1',
              validator: (v) {
                if (v == null || v.trim().isEmpty) return 'Required';
                final parts = v.trim().split('.');
                if (parts.length != 6) return '6 octets required (e.g. 1.2.3.4.1.1)';
                return null;
              }),
            const SizedBox(height: 12),
            _field('ADS PORT', _portCtrl, hint: '851',
              validator: (v) {
                final n = int.tryParse(v ?? '');
                return (n == null || n < 1 || n > 65535) ? 'Port 1–65535' : null;
              }),
            const SizedBox(height: 20),
            PrimaryButton(
              label: _hadExisting ? 'Save Changes' : 'Assign Controller',
              loading: _saving, onTap: _save,
            ),
            if (_hadExisting) ...[
              const SizedBox(height: 8),
              PrimaryButton(label: 'Unassign Controller', color: C.red, onTap: _saving ? () {} : _unassign),
            ],
          ],
          const SizedBox(height: 8),
        ],
      ),
    ),
  );

  Widget _field(
    String label, TextEditingController ctrl, {
    String hint = '', bool required = true, String? Function(String?)? validator,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: AppText.label),
      const SizedBox(height: 6),
      TextFormField(
        controller: ctrl,
        style: AppText.mono.copyWith(fontSize: 13, color: C.textPri),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: AppText.mono.copyWith(color: C.textTri),
          filled: true,
          fillColor: C.elevated,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: C.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: C.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: C.accent, width: 1.5),
          ),
          errorStyle: AppText.bodySm.copyWith(color: C.red),
        ),
        validator: validator ?? (v) => (required && (v == null || v.trim().isEmpty)) ? 'Required' : null,
      ),
    ],
  );
}
