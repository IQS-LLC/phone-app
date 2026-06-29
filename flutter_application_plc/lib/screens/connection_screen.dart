import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../auth/auth_state.dart';
import '../models/auth_models.dart';
import '../theme.dart';
import '../widgets/common_widgets.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Connection Screen — manage Beckhoff TwinCAT devices
// ─────────────────────────────────────────────────────────────────────────────

class ConnectionScreen extends StatefulWidget {
  final AuthState authState;
  const ConnectionScreen({super.key, required this.authState});

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  bool _testing = false;
  int? _testingId;

  AuthState get _auth => widget.authState;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _auth,
      builder: (_, _) => Scaffold(
        backgroundColor: C.bg,
        appBar: AppBar(
          title: const Text('My Controllers'),
          actions: [
            IconBtn(
              icon:  Icons.add_rounded,
              onTap: () => _showAddSheet(context),
            ),
            const SizedBox(width: 12),
          ],
        ),
        body: _auth.devices.isEmpty
            ? EmptyState(
                icon:     Icons.cable_outlined,
                title:    'No controllers yet',
                subtitle: 'Add your Beckhoff TwinCAT device to get started.',
                action:   PrimaryButton(
                  label: 'Add Controller',
                  icon:  Icons.add_rounded,
                  onTap: () => _showAddSheet(context),
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: _auth.devices.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (_, idx) => _DeviceCard(
                  device:    _auth.devices[idx],
                  isActive:  _auth.activeDevice?.id == _auth.devices[idx].id,
                  isTesting: _testingId == _auth.devices[idx].id && _testing,
                  onSetActive:  () => _auth.setActiveDevice(_auth.devices[idx]),
                  onTest:       () => _testDevice(_auth.devices[idx]),
                  onEdit:       () => _showEditSheet(context, _auth.devices[idx]),
                  onDelete:     () => _confirmDelete(context, _auth.devices[idx]),
                ),
              ),
      ),
    );
  }

  // ── Test connectivity ──────────────────────────────────────────────────────

  Future<void> _testDevice(PlcDeviceConfig dev) async {
    setState(() { _testing = true; _testingId = dev.id; });

    final headers = await _auth.service.authHeaders();
    final baseUrl = await _auth.service.getBaseUrl();

    if (headers == null || baseUrl == null) {
      setState(() { _testing = false; _testingId = null; });
      return;
    }

    try {
      final resp = await http.post(
        Uri.parse('$baseUrl/manage/devices/${dev.id}/test/'),
        headers: headers,
      ).timeout(const Duration(seconds: 10));

      if (!mounted) return;
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      final reachable = j['reachable'] as bool? ?? false;

      _showSnack(
        reachable
            ? '${dev.name} — reachable ✓'
            : '${dev.name} — unreachable. Check IP and network.',
        reachable ? C.green : C.red,
      );
    } catch (e) {
      if (mounted) _showSnack('Test failed: $e', C.red);
    } finally {
      if (mounted) setState(() { _testing = false; _testingId = null; });
    }
  }

  // ── Add / edit sheet ───────────────────────────────────────────────────────

  void _showAddSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _DeviceFormSheet(
        authState: _auth,
        onSaved: (name, ip, ams, desc, port) async {
          final nav = Navigator.of(context);
          await _auth.addDevice(
            name:        name,
            ipAddress:   ip,
            amsNetId:    ams,
            description: desc,
            adsPort:     port,
          );
          nav.pop();
        },
      ),
    );
  }

  void _showEditSheet(BuildContext context, PlcDeviceConfig dev) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _DeviceFormSheet(
        authState: _auth,
        existing: dev,
        onSaved: (name, ip, ams, desc, port) async {
          final nav = Navigator.of(context);
          final headers = await _auth.service.authHeaders();
          final baseUrl = await _auth.service.getBaseUrl();
          if (headers == null || baseUrl == null) return;
          await http.patch(
            Uri.parse('$baseUrl/manage/devices/${dev.id}/'),
            headers: headers,
            body: jsonEncode({
              'name': name, 'ip_address': ip,
              'ams_net_id': ams, 'description': desc, 'ads_port': port,
            }),
          ).timeout(const Duration(seconds: 8));
          await _auth.refreshDevices();
          nav.pop();
        },
      ),
    );
  }

  // ── Delete ─────────────────────────────────────────────────────────────────

  void _confirmDelete(BuildContext context, PlcDeviceConfig dev) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: C.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Remove "${dev.name}"?', style: AppText.h3),
          const SizedBox(height: 8),
          Text(
            'This removes the controller from your account. '
            'Your PLC will keep running.',
            style: AppText.bodySm,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Row(children: [
            Expanded(
              child: PrimaryButton(
                label: 'Cancel',
                color: C.textSec,
                onTap: () => Navigator.pop(context),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: PrimaryButton(
                label: 'Remove',
                color: C.red,
                onTap: () async {
                  Navigator.pop(context);
                  await _auth.deleteDevice(dev.id);
                },
              ),
            ),
          ]),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  // ── Snack helper ───────────────────────────────────────────────────────────

  void _showSnack(String msg, Color borderColor) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: AppText.body),
      backgroundColor: C.card,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        side: BorderSide(color: borderColor, width: 1.5),
      ),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.all(16),
    ));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Device card
// ─────────────────────────────────────────────────────────────────────────────

class _DeviceCard extends StatelessWidget {
  final PlcDeviceConfig device;
  final bool            isActive;
  final bool            isTesting;
  final VoidCallback    onSetActive;
  final VoidCallback    onTest;
  final VoidCallback    onEdit;
  final VoidCallback    onDelete;

  const _DeviceCard({
    required this.device,
    required this.isActive,
    required this.isTesting,
    required this.onSetActive,
    required this.onTest,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return TapScale(
      onTap: onSetActive,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color:        isActive ? C.accentLo : C.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isActive ? C.accent.withAlpha(80) : C.border,
            width: isActive ? 1.5 : 1.0,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              // Status indicator
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color:        isActive ? C.accent.withAlpha(22) : C.elevated,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.memory_rounded,
                  color: isActive ? C.accent : C.textSec,
                  size: 18,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                        child: Text(device.name, style: AppText.h3),
                      ),
                      if (isActive)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: C.accent.withAlpha(22),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text('ACTIVE', style: AppText.labelSm.copyWith(color: C.accent)),
                        ),
                    ]),
                    if (device.description.isNotEmpty)
                      Text(device.description, style: AppText.bodySm),
                  ],
                ),
              ),
            ]),
            const SizedBox(height: 12),
            // Connection details
            _MonoRow(label: 'IP',  value: device.ipAddress),
            const SizedBox(height: 4),
            _MonoRow(label: 'AMS', value: device.amsNetId),
            const SizedBox(height: 4),
            _MonoRow(label: 'Port', value: device.adsPort.toString()),
            const SizedBox(height: 14),
            // Action buttons
            Row(children: [
              _ActionBtn(
                icon:    isTesting ? null : Icons.wifi_tethering_rounded,
                label:   isTesting ? 'Testing…' : 'Test',
                onTap:   isTesting ? null : onTest,
                loading: isTesting,
              ),
              const SizedBox(width: 8),
              _ActionBtn(icon: Icons.edit_outlined,   label: 'Edit',   onTap: onEdit),
              const SizedBox(width: 8),
              _ActionBtn(icon: Icons.delete_outline,  label: 'Remove', onTap: onDelete, danger: true),
            ]),
          ],
        ),
      ),
    );
  }
}

class _MonoRow extends StatelessWidget {
  final String label;
  final String value;
  const _MonoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(
        width: 36,
        child: Text(label, style: AppText.labelSm),
      ),
      Expanded(
        child: Text(
          value,
          style: AppText.mono.copyWith(fontSize: 12, color: C.textSec),
        ),
      ),
    ],
  );
}

class _ActionBtn extends StatelessWidget {
  final IconData?    icon;
  final String       label;
  final VoidCallback? onTap;
  final bool         danger;
  final bool         loading;

  const _ActionBtn({
    this.icon,
    required this.label,
    this.onTap,
    this.danger  = false,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = danger ? C.red : C.textSec;
    return TapScale(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color:        danger ? C.redLo : C.elevated,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: danger ? C.red.withAlpha(50) : C.border2,
          ),
        ),
        child: loading
            ? SizedBox(
                width: 12, height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.5, color: color),
              )
            : Row(mainAxisSize: MainAxisSize.min, children: [
                if (icon != null) ...[
                  Icon(icon, size: 12, color: color),
                  const SizedBox(width: 5),
                ],
                Text(label, style: AppText.labelSm.copyWith(color: color)),
              ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Add / Edit form sheet
// ─────────────────────────────────────────────────────────────────────────────

class _DeviceFormSheet extends StatefulWidget {
  final AuthState         authState;
  final PlcDeviceConfig?  existing;
  final Future<void> Function(String name, String ip, String ams, String desc, int port) onSaved;

  const _DeviceFormSheet({
    required this.authState,
    required this.onSaved,
    this.existing,
  });

  @override
  State<_DeviceFormSheet> createState() => _DeviceFormSheetState();
}

class _DeviceFormSheetState extends State<_DeviceFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _ipCtrl;
  late final TextEditingController _amsCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _portCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameCtrl = TextEditingController(text: e?.name       ?? '');
    _ipCtrl   = TextEditingController(text: e?.ipAddress  ?? '');
    _amsCtrl  = TextEditingController(text: e?.amsNetId   ?? '');
    _descCtrl = TextEditingController(text: e?.description ?? '');
    _portCtrl = TextEditingController(text: (e?.adsPort ?? 851).toString());
  }

  @override
  void dispose() {
    for (final c in [_nameCtrl, _ipCtrl, _amsCtrl, _descCtrl, _portCtrl]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    await widget.onSaved(
      _nameCtrl.text.trim(),
      _ipCtrl.text.trim(),
      _amsCtrl.text.trim(),
      _descCtrl.text.trim(),
      int.tryParse(_portCtrl.text.trim()) ?? 851,
    );
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return Padding(
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
            // Handle
            Center(
              child: Container(
                width: 36, height: 4,
                decoration: BoxDecoration(
                  color: C.border2,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              isEdit ? 'Edit Controller' : 'Add Controller',
              style: AppText.h2,
            ),
            const SizedBox(height: 4),
            Text(
              'Enter the TwinCAT connection details from your Beckhoff device.',
              style: AppText.bodySm,
            ),
            const SizedBox(height: 20),
            _field('NAME',       _nameCtrl, hint: 'Office PLC',       keyboard: TextInputType.text),
            const SizedBox(height: 12),
            _field('IP ADDRESS', _ipCtrl,   hint: '192.168.0.158',    keyboard: TextInputType.number,
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            _field('AMS NET ID', _amsCtrl,  hint: '192.168.0.158.1.1', keyboard: TextInputType.text,
              validator: (v) {
                if (v == null || v.trim().isEmpty) return 'Required';
                final parts = v.trim().split('.');
                if (parts.length != 6) return '6 octets required (e.g. 1.2.3.4.1.1)';
                return null;
              },
            ),
            const SizedBox(height: 12),
            _field('ADS PORT',   _portCtrl, hint: '851',              keyboard: TextInputType.number,
              validator: (v) {
                final n = int.tryParse(v ?? '');
                return (n == null || n < 1 || n > 65535) ? 'Port 1–65535' : null;
              },
            ),
            const SizedBox(height: 12),
            _field('DESCRIPTION (OPTIONAL)', _descCtrl, hint: 'Main building controller', required: false),
            const SizedBox(height: 20),
            PrimaryButton(
              label:   isEdit ? 'Save Changes' : 'Add Controller',
              loading: _saving,
              onTap:   _save,
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController ctrl, {
    String hint = '',
    TextInputType keyboard = TextInputType.text,
    bool required = true,
    String? Function(String?)? validator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppText.label),
        const SizedBox(height: 6),
        TextFormField(
          controller:   ctrl,
          style:        AppText.mono.copyWith(fontSize: 13, color: C.textPri),
          keyboardType: keyboard,
          autocorrect:  false,
          decoration: InputDecoration(
            hintText:  hint,
            hintStyle: AppText.mono.copyWith(color: C.textTri),
            filled:    true,
            fillColor: C.elevated,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide:   const BorderSide(color: C.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide:   const BorderSide(color: C.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide:   const BorderSide(color: C.accent, width: 1.5),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide:   const BorderSide(color: C.red),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide:   const BorderSide(color: C.red, width: 1.5),
            ),
            errorStyle: AppText.bodySm.copyWith(color: C.red),
          ),
          validator: validator ?? (v) => (required && (v == null || v.trim().isEmpty))
              ? 'Required'
              : null,
        ),
      ],
    );
  }
}
