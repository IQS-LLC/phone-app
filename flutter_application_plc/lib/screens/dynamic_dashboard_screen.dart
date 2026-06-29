import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../auth/auth_state.dart';
import '../models/auth_models.dart';
import '../theme.dart';
import '../widgets/common_widgets.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Dynamic Dashboard Screen
// Shows TwinCAT symbols discovered from the active PLCDevice, grouped by GVL.
// Each symbol is rendered by WidgetFactory based on its classified type.
// ─────────────────────────────────────────────────────────────────────────────

class DynamicDashboardScreen extends StatefulWidget {
  final AuthState authState;
  const DynamicDashboardScreen({super.key, required this.authState});

  @override
  State<DynamicDashboardScreen> createState() => _DynamicDashboardScreenState();
}

class _DynamicDashboardScreenState extends State<DynamicDashboardScreen> {
  List<DiscoveryGroup>? _groups;
  bool _loading   = false;
  bool _scanning  = false;
  String? _error;

  // Live symbol values — updated by polling
  final Map<String, dynamic> _values = {};
  Timer? _poller;

  AuthState get _auth => widget.authState;

  @override
  void initState() {
    super.initState();
    _loadLayout();
  }

  @override
  void dispose() {
    _poller?.cancel();
    super.dispose();
  }

  // ── Load cached layout from backend ────────────────────────────────────────

  Future<void> _loadLayout() async {
    final dev = _auth.activeDevice;
    if (dev == null) return;

    setState(() { _loading = true; _error = null; });

    final headers = await _auth.service.authHeaders();
    final baseUrl = await _auth.service.getBaseUrl();
    if (headers == null || baseUrl == null) {
      setState(() { _loading = false; _error = 'Not authenticated'; });
      return;
    }

    try {
      final resp = await http.get(
        Uri.parse('$baseUrl/manage/discovery/${dev.id}/widgets/'),
        headers: headers,
      ).timeout(const Duration(seconds: 8));

      if (resp.statusCode == 200) {
        final j = jsonDecode(resp.body) as Map<String, dynamic>;
        if (j['ok'] == true) {
          final raw = j['groups'] as List<dynamic>;
          setState(() {
            _groups  = raw
                .map((e) => DiscoveryGroup.fromJson(e as Map<String, dynamic>))
                .toList();
            _loading = false;
          });
          return;
        }
      }

      // No cache — trigger a scan
      if (resp.statusCode == 404) {
        await _runScan();
        return;
      }

      setState(() { _loading = false; _error = 'Failed to load layout'; });
    } catch (e) {
      setState(() { _loading = false; _error = e.toString(); });
    }
  }

  // ── Trigger discovery scan ────────────────────────────────────────────────

  Future<void> _runScan() async {
    final dev = _auth.activeDevice;
    if (dev == null) return;

    setState(() { _scanning = true; _error = null; });

    final headers = await _auth.service.authHeaders();
    final baseUrl = await _auth.service.getBaseUrl();
    if (headers == null || baseUrl == null) {
      setState(() { _scanning = false; });
      return;
    }

    try {
      final resp = await http.post(
        Uri.parse('$baseUrl/manage/discovery/${dev.id}/scan/'),
        headers: headers,
      ).timeout(const Duration(seconds: 30));

      if (resp.statusCode == 200) {
        final j = jsonDecode(resp.body) as Map<String, dynamic>;
        if (j['ok'] == true) {
          // Reload layout after scan
          setState(() { _scanning = false; _loading = true; });
          await _loadLayout();
          return;
        }
      }
      setState(() { _scanning = false; _error = 'Discovery scan failed'; });
    } catch (e) {
      setState(() { _scanning = false; _error = e.toString(); });
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _auth,
      builder: (_, _) {
        final dev = _auth.activeDevice;
        if (dev == null) {
          return const _NoDevice();
        }

        return Scaffold(
          backgroundColor: C.bg,
          appBar: AppBar(
            title: Text(dev.name),
            actions: [
              if (_scanning)
                const Padding(
                  padding: EdgeInsets.only(right: 16),
                  child: SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2, color: C.accent,
                    ),
                  ),
                )
              else
                IconBtn(
                  icon:  Icons.radar_rounded,
                  onTap: _runScan,
                ),
              const SizedBox(width: 4),
            ],
          ),
          body: _buildBody(dev),
        );
      },
    );
  }

  Widget _buildBody(PlcDeviceConfig dev) {
    if (_loading) return _LoadingSkeleton();

    if (_scanning) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(
            width: 40, height: 40,
            child: CircularProgressIndicator(color: C.accent, strokeWidth: 2.5),
          ),
          const SizedBox(height: 20),
          Text('Discovering symbols…', style: AppText.h3),
          const SizedBox(height: 6),
          Text(
            'Scanning ${dev.name} (${dev.amsNetId})',
            style: AppText.bodySm,
          ),
        ]),
      );
    }

    if (_error != null) {
      return EmptyState(
        icon:     Icons.error_outline_rounded,
        title:    'Discovery failed',
        subtitle: _error,
        action:   PrimaryButton(
          label: 'Retry Scan',
          icon:  Icons.refresh_rounded,
          onTap: _runScan,
        ),
      );
    }

    if (_groups == null || _groups!.isEmpty) {
      return EmptyState(
        icon:     Icons.radar_rounded,
        title:    'No symbols found',
        subtitle: 'Run a discovery scan to auto-detect your TwinCAT variables.',
        action:   PrimaryButton(
          label: 'Start Discovery',
          icon:  Icons.search_rounded,
          onTap: _runScan,
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadLayout,
      color:     C.accent,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _groups!.length,
        itemBuilder: (_, idx) => _GroupSection(
          group:  _groups![idx],
          values: _values,
          onWrite: _writeSymbol,
        ),
      ),
    );
  }

  // ── Write a symbol value ────────────────────────────────────────────────────

  Future<void> _writeSymbol(DiscoveredSymbol sym, dynamic value) async {
    // Optimistic update
    setState(() => _values[sym.fullName] = value);

    // TODO: implement generic ADS write via backend in a future update.
    // For now, route known widget types through the existing PLC endpoints.
    // These always go through the central Django server — never a PLC's own
    // IP — the backend resolves the right apartment from the JWT.
    final headers = await _auth.service.authHeaders();
    final baseUrl = await _auth.service.getBaseUrl();
    if (headers == null || baseUrl == null) return;

    try {
      if (sym.widgetType == WidgetType.daliSlider) {
        // Extract channel number from symbol name (e.g. nBrightness_3 → 3)
        final match = RegExp(r'_(\d+)$').firstMatch(sym.name);
        final ch    = int.tryParse(match?.group(1) ?? '');
        if (ch != null) {
          await http.post(
            Uri.parse('$baseUrl/plc/dali/$ch/brightness/'),
            headers: headers,
            body: {'brightness': value.toString()},
          ).timeout(const Duration(seconds: 5));
        }
      } else if (sym.widgetType == WidgetType.toggle &&
          sym.category == 'relays') {
        final match = RegExp(r'_(\d+)$').firstMatch(sym.name);
        final ch    = int.tryParse(match?.group(1) ?? '');
        if (ch != null) {
          await http.post(
            Uri.parse('$baseUrl/plc/relay/$ch/'),
            headers: headers,
            body: {'state': value.toString()},
          ).timeout(const Duration(seconds: 5));
        }
      }
    } catch (_) {
      // Revert optimistic value on failure
      if (mounted) setState(() => _values.remove(sym.fullName));
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Group section
// ─────────────────────────────────────────────────────────────────────────────

class _GroupSection extends StatefulWidget {
  final DiscoveryGroup             group;
  final Map<String, dynamic>       values;
  final void Function(DiscoveredSymbol, dynamic) onWrite;

  const _GroupSection({
    required this.group,
    required this.values,
    required this.onWrite,
  });

  @override
  State<_GroupSection> createState() => _GroupSectionState();
}

class _GroupSectionState extends State<_GroupSection> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final g = widget.group;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section header
          GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Row(children: [
              _CategoryIcon(category: g.category),
              const SizedBox(width: 10),
              Expanded(
                child: Text(g.title, style: AppText.h3),
              ),
              Text(
                '${g.widgets.length}',
                style: AppText.bodySm.copyWith(color: C.textSec),
              ),
              const SizedBox(width: 6),
              Icon(
                _expanded
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                color: C.textSec, size: 18,
              ),
            ]),
          ),
          const SizedBox(height: 10),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve:    Curves.easeInOut,
            child: _expanded
                ? AppCard(
                    child: Column(
                      children: [
                        for (int i = 0; i < g.widgets.length; i++) ...[
                          if (i > 0) const AppDivider(indent: EdgeInsets.symmetric(horizontal: 16)),
                          _SymbolTile(
                            sym:     g.widgets[i],
                            value:   widget.values[g.widgets[i].fullName],
                            onWrite: (val) => widget.onWrite(g.widgets[i], val),
                          ),
                        ],
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Symbol tile — dispatches to the right widget factory
// ─────────────────────────────────────────────────────────────────────────────

class _SymbolTile extends StatelessWidget {
  final DiscoveredSymbol         sym;
  final dynamic                  value;
  final void Function(dynamic)   onWrite;

  const _SymbolTile({
    required this.sym,
    required this.value,
    required this.onWrite,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: switch (sym.widgetType) {
        WidgetType.daliSlider   => _SliderTile(sym: sym, value: value, onWrite: onWrite),
        WidgetType.toggle       => _ToggleTile(sym: sym, value: value, onWrite: onWrite),
        WidgetType.alarmCard    => _AlarmTile(sym: sym, value: value),
        WidgetType.thermostat   => _ThermostatTile(sym: sym, value: value, onWrite: onWrite),
        WidgetType.modeSelector => _ModeTile(sym: sym, value: value, onWrite: onWrite),
        WidgetType.gauge        => _GaugeTile(sym: sym, value: value),
        WidgetType.numericDisplay ||
        WidgetType.textDisplay  => _ReadOnlyTile(sym: sym, value: value),
        WidgetType.unknown      => _ReadOnlyTile(sym: sym, value: value),
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Individual widget implementations
// ─────────────────────────────────────────────────────────────────────────────

class _SliderTile extends StatefulWidget {
  final DiscoveredSymbol       sym;
  final dynamic                value;
  final void Function(dynamic) onWrite;
  const _SliderTile({required this.sym, required this.value, required this.onWrite});

  @override
  State<_SliderTile> createState() => _SliderTileState();
}

class _SliderTileState extends State<_SliderTile> {
  late double _local;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _local = (widget.value as num?)?.toDouble() ?? 0.0;
  }

  @override
  void didUpdateWidget(_SliderTile old) {
    super.didUpdateWidget(old);
    if (!_dragging && widget.value != old.value) {
      _local = (widget.value as num?)?.toDouble() ?? _local;
    }
  }

  @override
  Widget build(BuildContext context) {
    final pct = _local.round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(Icons.lightbulb_outline_rounded,
              color: pct > 0 ? C.accent : C.textTri, size: 16),
          const SizedBox(width: 8),
          Expanded(child: Text(widget.sym.label, style: AppText.bodyMed)),
          Text(
            '$pct%',
            style: AppText.num.copyWith(
              color: pct > 0 ? C.accent : C.textTri,
            ),
          ),
        ]),
        const SizedBox(height: 4),
        Slider(
          value:    _local,
          min:      widget.sym.minValue ?? 0,
          max:      widget.sym.maxValue ?? 100,
          onChangeStart: (_) => setState(() => _dragging = true),
          onChanged: (v) => setState(() => _local = v),
          onChangeEnd: (v) {
            setState(() => _dragging = false);
            widget.onWrite(v.round());
          },
        ),
      ],
    );
  }
}

class _ToggleTile extends StatelessWidget {
  final DiscoveredSymbol       sym;
  final dynamic                value;
  final void Function(dynamic) onWrite;
  const _ToggleTile({required this.sym, required this.value, required this.onWrite});

  @override
  Widget build(BuildContext context) {
    final on = value == true || value == 1;
    return Row(children: [
      Icon(
        on ? Icons.toggle_on_rounded : Icons.toggle_off_rounded,
        color: on ? C.green : C.textTri, size: 18,
      ),
      const SizedBox(width: 10),
      Expanded(child: Text(sym.label, style: AppText.bodyMed)),
      Switch(
        value:     on,
        onChanged: sym.readOnly ? null : (v) => onWrite(v),
      ),
    ]);
  }
}

class _AlarmTile extends StatelessWidget {
  final DiscoveredSymbol sym;
  final dynamic          value;
  const _AlarmTile({required this.sym, required this.value});

  @override
  Widget build(BuildContext context) {
    final active = value == true || value == 1;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:        active ? C.redLo : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: active ? C.red.withAlpha(80) : Colors.transparent,
        ),
      ),
      child: Row(children: [
        Icon(
          active ? Icons.warning_amber_rounded : Icons.check_circle_outline_rounded,
          color: active ? C.red : C.green,
          size: 18,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            sym.label,
            style: AppText.bodyMed.copyWith(
              color: active ? C.red : C.textPri,
            ),
          ),
        ),
        if (active)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color:        C.red.withAlpha(22),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text('ACTIVE', style: AppText.labelSm.copyWith(color: C.red)),
          ),
      ]),
    );
  }
}

class _ThermostatTile extends StatelessWidget {
  final DiscoveredSymbol       sym;
  final dynamic                value;
  final void Function(dynamic) onWrite;
  const _ThermostatTile({required this.sym, required this.value, required this.onWrite});

  @override
  Widget build(BuildContext context) {
    final temp = (value as num?)?.toDouble() ?? 20.0;
    final min  = sym.minValue ?? 15.0;
    final max  = sym.maxValue ?? 30.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Icon(Icons.thermostat_rounded, color: C.orange, size: 16),
          const SizedBox(width: 8),
          Expanded(child: Text(sym.label, style: AppText.bodyMed)),
          Text(
            '${temp.toStringAsFixed(1)}°C',
            style: AppText.num.copyWith(color: C.orange),
          ),
        ]),
        const SizedBox(height: 4),
        Slider(
          value:     temp.clamp(min, max),
          min:       min,
          max:       max,
          divisions: ((max - min) * 2).round(),
          onChanged: sym.readOnly ? null : (v) => onWrite(double.parse(v.toStringAsFixed(1))),
        ),
      ],
    );
  }
}

class _ModeTile extends StatelessWidget {
  final DiscoveredSymbol       sym;
  final dynamic                value;
  final void Function(dynamic) onWrite;
  const _ModeTile({required this.sym, required this.value, required this.onWrite});

  static const _modeNames = ['Off', 'Heat', 'Cool', 'Auto', 'Fan'];

  @override
  Widget build(BuildContext context) {
    final mode = (value as num?)?.toInt() ?? 0;
    final count = ((sym.maxValue ?? 4) + 1).toInt().clamp(2, _modeNames.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Icon(Icons.tune_rounded, color: C.blue, size: 16),
          const SizedBox(width: 8),
          Text(sym.label, style: AppText.bodyMed),
        ]),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: List.generate(count, (i) {
              final selected = mode == i;
              return Padding(
                padding: EdgeInsets.only(right: i < count - 1 ? 8 : 0),
                child: TapScale(
                  onTap: sym.readOnly ? null : () => onWrite(i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                    decoration: BoxDecoration(
                      color: selected ? C.blueLo : C.elevated,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: selected ? C.blue.withAlpha(80) : C.border2,
                        width: selected ? 1.5 : 1.0,
                      ),
                    ),
                    child: Text(
                      i < _modeNames.length ? _modeNames[i] : '$i',
                      style: AppText.bodyMed.copyWith(
                        color: selected ? C.blue : C.textSec,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ],
    );
  }
}

class _GaugeTile extends StatelessWidget {
  final DiscoveredSymbol sym;
  final dynamic          value;
  const _GaugeTile({required this.sym, required this.value});

  @override
  Widget build(BuildContext context) {
    final val = (value as num?)?.toDouble() ?? 0.0;
    final max = sym.maxValue ?? 100.0;
    final pct = max > 0 ? (val / max).clamp(0.0, 1.0) : 0.0;
    final display = sym.unit.isNotEmpty
        ? '${val.toStringAsFixed(1)} ${sym.unit}'
        : val.toStringAsFixed(1);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Icon(Icons.speed_rounded, color: C.teal, size: 16),
          const SizedBox(width: 8),
          Expanded(child: Text(sym.label, style: AppText.bodyMed)),
          Text(display, style: AppText.num.copyWith(color: C.teal)),
        ]),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value:            pct,
            backgroundColor:  C.border2,
            color:            C.teal,
            minHeight:        4,
          ),
        ),
      ],
    );
  }
}

class _ReadOnlyTile extends StatelessWidget {
  final DiscoveredSymbol sym;
  final dynamic          value;
  const _ReadOnlyTile({required this.sym, required this.value});

  @override
  Widget build(BuildContext context) {
    final display = value != null
        ? (sym.unit.isNotEmpty ? '$value ${sym.unit}' : '$value')
        : '—';
    return Row(children: [
      const Icon(Icons.data_array_rounded, color: C.textTri, size: 14),
      const SizedBox(width: 10),
      Expanded(child: Text(sym.label, style: AppText.body)),
      Text(
        display,
        style: AppText.mono.copyWith(fontSize: 12, color: C.textSec),
      ),
    ]);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

class _CategoryIcon extends StatelessWidget {
  final String category;
  const _CategoryIcon({required this.category});

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (category) {
      'lighting'  => (Icons.lightbulb_outline_rounded,  C.accent),
      'hvac'      => (Icons.thermostat_rounded,          C.orange),
      'alarms'    => (Icons.warning_amber_rounded,       C.red),
      'relays'    => (Icons.electrical_services_rounded, C.green),
      'sensors'   => (Icons.sensors_rounded,             C.teal),
      'energy'    => (Icons.bolt_rounded,                C.accent),
      _           => (Icons.memory_rounded,              C.textSec),
    };
    return Container(
      width: 28, height: 28,
      decoration: BoxDecoration(
        color:        color.withAlpha(20),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, size: 14, color: color),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// No active device placeholder
// ─────────────────────────────────────────────────────────────────────────────

class _NoDevice extends StatelessWidget {
  const _NoDevice();

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: C.bg,
    body: EmptyState(
      icon:     Icons.cable_outlined,
      title:    'No active controller',
      subtitle: 'Go to Settings → Controllers and add a Beckhoff device.',
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Loading skeleton
// ─────────────────────────────────────────────────────────────────────────────

class _LoadingSkeleton extends StatelessWidget {
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: List.generate(3, (_) => Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const ShimmerBox(width: 120, height: 14, radius: 6),
        const SizedBox(height: 10),
        AppCard(
          child: Column(children: List.generate(3, (i) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(children: [
              const ShimmerBox(width: 16, height: 16, radius: 4),
              const SizedBox(width: 10),
              const Expanded(child: ShimmerBox(width: double.infinity, height: 12, radius: 4)),
              const SizedBox(width: 16),
              const ShimmerBox(width: 48, height: 12, radius: 4),
            ]),
          ))),
        ),
      ]),
    )),
  );
}

