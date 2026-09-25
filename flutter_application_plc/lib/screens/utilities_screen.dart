import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/auth_state.dart';
import '../config/runtime_config.dart';
import '../models/device_state.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../theme.dart';
import '../utils/room_display.dart';
import '../widgets/common_widgets.dart';

/// Ventilators, balcony/mirror/var lights and the other fixtures that were
/// wired straight into the PLC's push-button logic without ever getting a
/// dedicated screen — added to the app on 2026-08-18 (see NamedRelay /
/// ApartmentDevice.TYPE_TOGGLE). Available to every resident, not just Tech
/// Team — these are ordinary household devices, not commissioning tools.
class UtilitiesScreen extends StatefulWidget {
  final AuthState authState;
  final int apartmentId;

  const UtilitiesScreen({
    super.key,
    required this.authState,
    required this.apartmentId,
  });

  @override
  State<UtilitiesScreen> createState() => _UtilitiesScreenState();
}

class _UtilitiesScreenState extends State<UtilitiesScreen> {
  late ApiService _api;
  bool _svcReady = false;
  bool _loading = true;
  String? _loadError;

  List<ToggleDevice> _devices = [];
  Map<String, bool?> _states = {};
  bool _plcConnected = false;
  final Set<String> _pending = {};
  Timer? _pollTimer;

  DeviceState _stateOf(String varName) => resolveDeviceState(
        pending: null, raw: _states[varName], systemConnected: _plcConnected,
      );

  @override
  void initState() {
    super.initState();
    _init();
    // This screen's ApiService is built once with whatever URL was current
    // at open time. Without this, changing the server (Settings, or the
    // login-screen recovery sheet if this screen were somehow still mounted
    // underneath) would leave it silently polling the old address for as
    // long as this screen stays alive — the same class of bug AppState was
    // hardened against, just narrower in blast radius. See RuntimeConfig's
    // doc comment.
    RuntimeConfig.instance.addListener(_onConfigChanged);
  }

  @override
  void dispose() {
    RuntimeConfig.instance.removeListener(_onConfigChanged);
    _pollTimer?.cancel();
    super.dispose();
  }

  void _onConfigChanged() {
    final svc = widget.authState.service;
    _api = ApiService(
      RuntimeConfig.instance.serverUrl,
      tokenProvider: () => svc.getAccessToken(),
      tokenRefresher: () => svc.refreshAccessToken(),
    );
  }

  Future<void> _init() async {
    final svc = widget.authState.service;
    _api = ApiService(
      RuntimeConfig.instance.serverUrl,
      tokenProvider: () => svc.getAccessToken(),
      tokenRefresher: () => svc.refreshAccessToken(),
    );
    _svcReady = true;
    await _loadDevices();
    await _pollState();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _pollState());
  }

  Future<void> _loadDevices() async {
    if (!mounted) return;
    final r = await _api.getDevices();
    if (!mounted) return;
    if (!r.success || r.data == null) {
      setState(() { _loading = false; _loadError = r.errorMessage ?? 'Failed to load devices'; });
      return;
    }
    final devices = [
      ...(r.data!['toggles'] as List<dynamic>? ?? [])
          .map((e) => ToggleDevice.fromJson(e as Map<String, dynamic>)),
      ...(r.data!['custom'] as List<dynamic>? ?? [])
          .map((e) => ToggleDevice.fromCustomJson(e as Map<String, dynamic>)),
    ];
    setState(() { _devices = devices; });
  }

  Future<void> _pollState() async {
    if (!mounted) return;
    final r = await _api.getState();
    if (!mounted) return;
    if (!r.success || r.data == null) {
      setState(() { _loading = false; _loadError ??= r.errorMessage; });
      return;
    }
    final raw = r.data!['toggles'] as Map<String, dynamic>? ?? {};
    final rawCustom = r.data!['custom'] as Map<String, dynamic>? ?? {};
    setState(() {
      _loading = false;
      _loadError = null;
      _states = {
        ...raw.map((k, v) => MapEntry(k, v as bool?)),
        ...rawCustom.map((k, v) => MapEntry('custom:$k', v as bool?)),
      };
      _plcConnected = r.data!['plc_connected'] as bool? ?? false;
    });
  }

  Future<void> _setToggle(ToggleDevice dev, bool on) async {
    setState(() {
      _pending.add(dev.varName);
      _states[dev.varName] = on;
    });
    final r = dev.apartmentDeviceId != null
        ? await _api.setCustom(dev.apartmentDeviceId!, on)
        : await _api.setToggle(dev.varName, on);
    if (!mounted) return;
    setState(() => _pending.remove(dev.varName));
    if (!r.success) {
      setState(() => _states[dev.varName] = !on);
      AppToast.show(context, r.errorMessage ?? '${dev.name} command failed', error: true);
    }
  }

  Map<String, List<ToggleDevice>> get _grouped {
    final map = <String, List<ToggleDevice>>{};
    for (final d in _devices) {
      map.putIfAbsent(d.room, () => []).add(d);
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      appBar: AppBar(
        backgroundColor: C.surface,
        iconTheme: const IconThemeData(color: C.textSec),
        title: Text('Utilities', style: AppText.h3),
      ),
      body: !_svcReady || (_loading && _devices.isEmpty)
          ? const Center(child: CircularProgressIndicator(color: C.accent))
          : _loadError != null && _devices.isEmpty
              ? EmptyState(
                  icon: Icons.error_outline_rounded,
                  title: 'Could not load utilities',
                  subtitle: _loadError,
                  action: PrimaryButton(label: 'Retry', onTap: () async {
                    setState(() { _loading = true; _loadError = null; });
                    await _loadDevices();
                    await _pollState();
                  }),
                )
              : _devices.isEmpty
                  ? const EmptyState(
                      icon: Icons.tune_rounded,
                      title: 'No utilities configured',
                      subtitle: 'Ventilators, balcony/mirror lights and similar fixtures show up here once added.',
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                      children: [
                        for (final entry in _grouped.entries) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
                            child: Text(RoomDisplay.label(entry.key).toUpperCase(), style: AppText.bodySm.copyWith(
                              color: C.textTri, fontWeight: FontWeight.w600, letterSpacing: 0.5,
                            )),
                          ),
                          AppCard(
                            child: Column(children: [
                              for (var i = 0; i < entry.value.length; i++) ...[
                                if (i > 0) const Divider(height: 0.5, thickness: 0.5, color: C.border),
                                _UtilityRow(
                                  device: entry.value[i],
                                  state: _stateOf(entry.value[i].varName),
                                  busy: _pending.contains(entry.value[i].varName),
                                  onChanged: (v) => _setToggle(entry.value[i], v),
                                ),
                              ],
                            ]),
                          ),
                        ],
                      ],
                    ),
    );
  }
}

class _UtilityRow extends StatelessWidget {
  final ToggleDevice device;
  final DeviceState state;
  final bool busy;
  final ValueChanged<bool> onChanged;

  const _UtilityRow({
    required this.device,
    required this.state,
    required this.busy,
    required this.onChanged,
  });

  bool get on => state.isOn;
  bool get known => state.isKnown;

  IconData get _icon {
    final n = device.name.toLowerCase();
    if (n.contains('ventilator')) return Icons.air_rounded;
    if (n.contains('balcony')) return Icons.balcony_rounded;
    if (n.contains('mirror')) return Icons.wb_incandescent_rounded;
    return Icons.lightbulb_outline_rounded;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Row(children: [
        Container(
          width: 32, height: 32,
          decoration: BoxDecoration(
            color: (on ? C.accent : (known ? C.textTri : C.orange)).withAlpha(18),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(known ? _icon : Icons.help_outline_rounded,
              color: on ? C.accent : (known ? C.textTri : C.orange), size: 16),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(device.name, style: AppText.bodyMed),
            if (!known)
              Text(state == DeviceState.unavailable ? 'Hardware unreachable' : 'State unknown',
                  style: AppText.bodySm.copyWith(color: C.orange))
            else if (!device.writable)
              Text('Automatic — follows its sensor', style: AppText.bodySm.copyWith(color: C.textTri)),
          ]),
        ),
        if (busy)
          const SizedBox(width: 18, height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: C.accent))
        else if (device.writable && known)
          Switch(value: on, activeThumbColor: C.accent, onChanged: onChanged)
        else
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: (on ? C.green : (known ? C.textTri : C.orange)).withAlpha(18),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(known ? (on ? 'ON' : 'OFF') : state.label, style: AppText.bodySm.copyWith(
              color: on ? C.green : (known ? C.textTri : C.orange), fontWeight: FontWeight.w600,
            )),
          ),
      ]),
    );
  }
}
