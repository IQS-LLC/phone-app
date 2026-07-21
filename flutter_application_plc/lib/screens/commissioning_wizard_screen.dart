import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/auth_state.dart';
import '../models/commissioning_models.dart';
import '../services/commissioning_service.dart';
import '../theme.dart';
import 'map_editor_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Commissioning Wizard — Tech Team only
//
// Guides an installer through the full apartment commissioning sequence:
//   0  Network Discovery    — find Beckhoff PLCs on the subnet
//   1  PLC Connectivity     — verify ADS / AMS Net ID
//   2  Apartment Setup      — create apartment, assign PLC, add rooms
//   3  Symbol Discovery     — scan TwinCAT symbols, verify I/O counts
//   4  Floor Plan           — upload floor plan image / PDF
//   5  Map Editor           — place and link devices (launches existing editor)
//   6  I/O Commissioning    — test every device one by one
//   7  Resident Accounts    — create and assign residents
//   8  Handover             — publish and hand over
// ─────────────────────────────────────────────────────────────────────────────

const _kStepTitles = [
  'Network Discovery',
  'PLC Connectivity',
  'Apartment Setup',
  'Symbol Discovery',
  'Floor Plan',
  'Map Editor',
  'I/O Commissioning',
  'Resident Accounts',
  'Handover',
];

const _kStepIcons = [
  Icons.wifi_find_rounded,
  Icons.cable_rounded,
  Icons.apartment_rounded,
  Icons.manage_search_rounded,
  Icons.map_rounded,
  Icons.edit_square,
  Icons.electrical_services_rounded,
  Icons.person_add_rounded,
  Icons.check_circle_rounded,
];

class CommissioningWizardScreen extends StatefulWidget {
  final AuthState    authState;
  final VoidCallback onClose;

  const CommissioningWizardScreen({
    super.key,
    required this.authState,
    required this.onClose,
  });

  @override
  State<CommissioningWizardScreen> createState() => _CommissioningWizardScreenState();
}

class _CommissioningWizardScreenState extends State<CommissioningWizardScreen>
    with TickerProviderStateMixin {

  int _step = 0;

  // Shared commissioning state passed between steps
  ApartmentInfo? _apartment;
  int?           _plcDeviceId;
  bool           _editorOpen = false;
  bool           _svcReady   = false;

  late CommissioningService _svc;
  late final PageController _pageCtrl;

  @override
  void initState() {
    super.initState();
    _pageCtrl = PageController();
    _initSvc();
  }

  Future<void> _initSvc() async {
    final svc     = widget.authState.service;
    final baseUrl = await svc.getBaseUrl() ?? '';
    _svc = CommissioningService(
      baseUrl,
      tokenProvider:  () => svc.getAccessToken(),
      tokenRefresher: () => svc.refreshAccessToken(),
    );
    if (mounted) { setState(() => _svcReady = true); }
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  void _goTo(int step) {
    setState(() => _step = step);
    _pageCtrl.animateToPage(
      step,
      duration: Dur.normal,
      curve:    Cur.smooth,
    );
  }

  void _next() { if (_step < _kStepTitles.length - 1) _goTo(_step + 1); }
  void _back() { if (_step > 0) _goTo(_step - 1); }

  void _openEditor() => setState(() => _editorOpen = true);
  void _closeEditor() => setState(() => _editorOpen = false);

  @override
  Widget build(BuildContext context) {
    if (!_svcReady) {
      return const Scaffold(
        backgroundColor: C.bg,
        body: Center(child: CircularProgressIndicator(color: C.accent)),
      );
    }
    return Stack(children: [
      Scaffold(
        backgroundColor: C.bg,
        body: SafeArea(child: Column(children: [
          _TopBar(
            step:      _step,
            total:     _kStepTitles.length,
            title:     _kStepTitles[_step],
            onClose:   widget.onClose,
            onStepTap: _goTo,
          ),
          Expanded(
            child: PageView(
              controller:  _pageCtrl,
              physics:     const NeverScrollableScrollPhysics(),
              onPageChanged: (i) => setState(() => _step = i),
              children: [
                _StepDiscover(svc: _svc, onDeviceRegistered: (id) {
                  setState(() => _plcDeviceId = id);
                }),
                _StepConnectTest(svc: _svc, deviceId: _plcDeviceId),
                _StepApartment(
                  svc:        _svc,
                  plcDeviceId: _plcDeviceId,
                  onApartment: (apt) => setState(() => _apartment = apt),
                ),
                _StepSymbolScan(svc: _svc, deviceId: _plcDeviceId),
                _StepFloorPlan(svc: _svc, apartment: _apartment),
                _StepMapEditor(onOpenEditor: _openEditor, apartment: _apartment),
                _StepIOTest(svc: _svc, apartment: _apartment),
                _StepResidents(svc: _svc, apartment: _apartment),
                _StepHandover(svc: _svc, apartment: _apartment),
              ],
            ),
          ),
          _BottomNav(
            step:    _step,
            total:   _kStepTitles.length,
            onBack:  _back,
            onNext:  _next,
            onClose: widget.onClose,
          ),
        ])),
      ),

      if (_editorOpen)
        Positioned.fill(
          child: MapEditorScreen(
            authState: widget.authState,
            onClose:   _closeEditor,
          ),
        ),
    ]);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Top bar — step progress dots + title
// ─────────────────────────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final int      step, total;
  final String   title;
  final VoidCallback onClose;
  final void Function(int) onStepTap;

  const _TopBar({
    required this.step,
    required this.total,
    required this.title,
    required this.onClose,
    required this.onStepTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      decoration: const BoxDecoration(
        color:  C.surface,
        border: Border(bottom: BorderSide(color: C.border, width: 0.5)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('COMMISSIONING WIZARD',
                  style: AppText.badge.copyWith(color: C.accent, letterSpacing: 1.2)),
              const SizedBox(height: 3),
              Text(title, style: AppText.h2),
            ]),
          ),
          GestureDetector(
            onTap: onClose,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color:        C.card,
                borderRadius: BorderRadius.circular(8),
                border:       Border.all(color: C.border, width: 0.5),
              ),
              child: const Icon(Icons.close_rounded, size: 18, color: C.textSec),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        // Step dots
        SizedBox(
          height: 28,
          child: Row(children: [
            for (int i = 0; i < total; i++) ...[
              if (i > 0) Expanded(child: Container(
                height: 1,
                color: i <= step ? C.accent.withAlpha(80) : C.border,
              )),
              GestureDetector(
                onTap: () => onStepTap(i),
                child: AnimatedContainer(
                  duration: Dur.normal,
                  curve:    Cur.smooth,
                  width:    i == step ? 28 : 20,
                  height:   i == step ? 28 : 20,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < step
                        ? C.green
                        : i == step
                            ? C.accent
                            : C.card2,
                    border: i == step
                        ? null
                        : Border.all(color: C.border, width: 0.5),
                    boxShadow: i == step ? S.accentGlow : null,
                  ),
                  child: Center(
                    child: i < step
                        ? const Icon(Icons.check_rounded, size: 12, color: C.bg)
                        : Icon(_kStepIcons[i],
                              size:  i == step ? 14 : 10,
                              color: i == step ? C.bg : C.textTri),
                  ),
                ),
              ),
            ],
          ]),
        ),
        const SizedBox(height: 10),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Bottom navigation
// ─────────────────────────────────────────────────────────────────────────────

class _BottomNav extends StatelessWidget {
  final int step, total;
  final VoidCallback onBack, onNext, onClose;

  const _BottomNav({
    required this.step,
    required this.total,
    required this.onBack,
    required this.onNext,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final isLast = step == total - 1;
    return Container(
      padding: EdgeInsets.fromLTRB(16, 12, 16,
          12 + MediaQuery.of(context).padding.bottom),
      decoration: const BoxDecoration(
        color:  C.surface,
        border: Border(top: BorderSide(color: C.border, width: 0.5)),
      ),
      child: Row(children: [
        if (step > 0)
          _NavBtn(
            label: 'Back',
            icon:  Icons.arrow_back_rounded,
            onTap: onBack,
          )
        else
          const SizedBox(width: 100),
        const Spacer(),
        Text('${step + 1} / $total',
            style: AppText.small.copyWith(color: C.textTri)),
        const Spacer(),
        isLast
            ? _NavBtn(
                label:   'Finish',
                icon:    Icons.check_rounded,
                primary: true,
                onTap:   onClose,
              )
            : _NavBtn(
                label:   'Next',
                icon:    Icons.arrow_forward_rounded,
                primary: true,
                onTap:   onNext,
                iconEnd: true,
              ),
      ]),
    );
  }
}

class _NavBtn extends StatelessWidget {
  final String   label;
  final IconData icon;
  final bool     primary;
  final bool     iconEnd;
  final VoidCallback onTap;

  const _NavBtn({
    required this.label,
    required this.icon,
    required this.onTap,
    this.primary = false,
    this.iconEnd  = false,
  });

  @override
  Widget build(BuildContext context) {
    final bg = primary ? C.accent : C.card2;
    final fg = primary ? C.bg     : C.textSec;
    return GestureDetector(
      onTap: () { HapticFeedback.lightImpact(); onTap(); },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
        decoration: BoxDecoration(
          color:        bg,
          borderRadius: BorderRadius.circular(12),
          boxShadow:    primary ? S.accentGlow : null,
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (!iconEnd) ...[Icon(icon, size: 16, color: fg), const SizedBox(width: 6)],
          Text(label, style: AppText.bodyMed.copyWith(color: fg)),
          if (iconEnd)  ...[const SizedBox(width: 6), Icon(icon, size: 16, color: fg)],
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared step layout helpers
// ─────────────────────────────────────────────────────────────────────────────

Widget _stepHeader(String title, String subtitle) => Padding(
  padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(title,    style: AppText.h1),
    const SizedBox(height: 6),
    Text(subtitle, style: AppText.body.copyWith(color: C.textSec)),
  ]),
);

Widget _statusChip(String label, {required bool ok, bool warn = false}) {
  final color = ok ? C.green : warn ? C.orange : C.red;
  final bg    = ok ? C.greenLo : warn ? C.orangeLo : C.redLo;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color:        bg,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(ok ? Icons.check_circle_rounded : warn
          ? Icons.warning_rounded : Icons.cancel_rounded,
          size: 12, color: color),
      const SizedBox(width: 5),
      Text(label, style: AppText.badge.copyWith(color: color, letterSpacing: 0.6)),
    ]),
  );
}

Widget _card(Widget child) => Container(
  margin:      const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
  padding:     const EdgeInsets.all(16),
  decoration:  BoxDecoration(
    color:        C.card,
    borderRadius: BorderRadius.circular(12),
    border:       Border.all(color: C.border, width: 0.5),
    boxShadow:    S.card,
  ),
  child: child,
);

// ─────────────────────────────────────────────────────────────────────────────
// Step 0 — Network Discovery
// ─────────────────────────────────────────────────────────────────────────────

class _StepDiscover extends StatefulWidget {
  final CommissioningService svc;
  final void Function(int deviceId) onDeviceRegistered;

  const _StepDiscover({required this.svc, required this.onDeviceRegistered});

  @override
  State<_StepDiscover> createState() => _StepDiscoverState();
}

class _StepDiscoverState extends State<_StepDiscover> {
  bool                  _scanning = false;
  String?               _error;
  List<DiscoveredPLC>   _found    = [];
  final Set<String>     _registering = {};

  Future<void> _scan() async {
    setState(() { _scanning = true; _error = null; _found = []; });
    final r = await widget.svc.scanNetwork();
    setState(() {
      _scanning = false;
      if (r.success) {
        _found = r.value;
      } else {
        _error = r.error;
      }
    });
  }

  Future<void> _register(DiscoveredPLC plc) async {
    setState(() => _registering.add(plc.ipAddress));
    final r = await widget.svc.registerPLC(
      name:       'PLC ${plc.ipAddress}',
      ipAddress:  plc.ipAddress,
      amsNetId:   plc.amsNetId,
    );
    if (!mounted) return;
    if (r.success) {
      widget.onDeviceRegistered(r.value);
      await _scan(); // refresh list
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(r.error ?? 'Registration failed'),
                 backgroundColor: C.red),
      );
    }
    setState(() => _registering.remove(plc.ipAddress));
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _stepHeader(
          'Network Discovery',
          'Scan the local network for Beckhoff CX controllers running TwinCAT 3. '
          'Configure PLC_DISCOVERY_SUBNETS on the server to control which subnets are searched.',
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: GestureDetector(
            onTap: _scanning ? null : _scan,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                gradient:     _scanning ? null : G.accent,
                color:        _scanning ? C.card2 : null,
                borderRadius: BorderRadius.circular(12),
                boxShadow:    _scanning ? null : S.accentGlow,
              ),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                if (_scanning)
                  const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: C.textSec))
                else
                  const Icon(Icons.wifi_find_rounded, size: 18, color: C.bg),
                const SizedBox(width: 8),
                Text(_scanning ? 'Scanning…' : 'Scan Network',
                    style: AppText.bodyMed.copyWith(
                      color: _scanning ? C.textSec : C.bg)),
              ]),
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          _card(Row(children: [
            const Icon(Icons.error_outline_rounded, color: C.red, size: 18),
            const SizedBox(width: 10),
            Expanded(child: Text(_error!, style: AppText.body.copyWith(color: C.red))),
          ])),
        ],
        if (_found.isEmpty && !_scanning && _error == null) ...[
          const SizedBox(height: 24),
          Center(child: Column(children: [
            Icon(Icons.wifi_off_rounded, size: 48, color: C.textTri),
            const SizedBox(height: 12),
            Text('No results yet — tap Scan Network',
                style: AppText.body.copyWith(color: C.textTri)),
          ])),
        ],
        for (final plc in _found) ...[
          const SizedBox(height: 6),
          _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(plc.ipAddress, style: AppText.title),
                const SizedBox(height: 3),
                Text(plc.amsNetId, style: AppText.mono),
              ])),
              _statusChip(
                plc.connectionQuality,
                ok:   plc.connectionQuality == 'excellent',
                warn: plc.connectionQuality == 'good',
              ),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              _statusChip(
                plc.isRegistered ? 'Registered' : 'Not registered',
                ok: plc.isRegistered,
              ),
              if (plc.apartmentName != null) ...[
                const SizedBox(width: 8),
                Text('→ ${plc.apartmentName}',
                    style: AppText.small.copyWith(color: C.textSec)),
              ],
              const Spacer(),
              if (!plc.isRegistered)
                _registering.contains(plc.ipAddress)
                    ? const SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: C.accent))
                    : GestureDetector(
                        onTap: () => _register(plc),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                          decoration: BoxDecoration(
                            color:        C.accentLo,
                            borderRadius: BorderRadius.circular(8),
                            border:       Border.all(color: C.accent.withAlpha(80)),
                          ),
                          child: Text('Register',
                              style: AppText.bodyMed.copyWith(color: C.accent)),
                        ),
                      ),
            ]),
          ])),
        ],
        const SizedBox(height: 12),
        _card(Row(children: [
          const Icon(Icons.info_outline_rounded, size: 16, color: C.blue),
          const SizedBox(width: 10),
          Expanded(child: Text(
            'You can also register a PLC manually via Settings → Manage Devices '
            'if automatic discovery does not find it.',
            style: AppText.small.copyWith(color: C.textSec),
          )),
        ])),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Step 1 — PLC Connectivity Test
// ─────────────────────────────────────────────────────────────────────────────

class _StepConnectTest extends StatefulWidget {
  final CommissioningService svc;
  final int? deviceId;

  const _StepConnectTest({required this.svc, required this.deviceId});

  @override
  State<_StepConnectTest> createState() => _StepConnectTestState();
}

class _StepConnectTestState extends State<_StepConnectTest> {
  bool           _testing = false;
  String?        _error;
  PLCTestResult? _result;

  Future<void> _test() async {
    final id = widget.deviceId;
    if (id == null) {
      setState(() => _error = 'No PLC registered yet — complete Step 0 first.');
      return;
    }
    setState(() { _testing = true; _error = null; _result = null; });
    final r = await widget.svc.testPLC(id);
    setState(() {
      _testing = false;
      if (r.success) { _result = r.value; } else { _error = r.error; }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _stepHeader(
          'PLC Connectivity',
          'Verify that the Beckhoff ADS router (port 48898) and runtime (port 851) '
          'are both reachable from the server. A green result confirms the AMS Net ID is correct.',
        ),
        const SizedBox(height: 8),
        if (widget.deviceId == null)
          _card(Row(children: [
            const Icon(Icons.warning_rounded, color: C.orange, size: 18),
            const SizedBox(width: 10),
            Expanded(child: Text('Register a PLC in Step 0 first.',
                style: AppText.body.copyWith(color: C.orange))),
          ]))
        else ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: GestureDetector(
              onTap: _testing ? null : _test,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  gradient:     _testing ? null : G.accent,
                  color:        _testing ? C.card2 : null,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow:    _testing ? null : S.accentGlow,
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  if (_testing)
                    const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: C.textSec))
                  else
                    const Icon(Icons.cable_rounded, size: 18, color: C.bg),
                  const SizedBox(width: 8),
                  Text(_testing ? 'Testing…' : 'Test Connectivity',
                      style: AppText.bodyMed.copyWith(
                        color: _testing ? C.textSec : C.bg)),
                ]),
              ),
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          _card(Row(children: [
            const Icon(Icons.error_outline_rounded, color: C.red, size: 18),
            const SizedBox(width: 10),
            Expanded(child: Text(_error!, style: AppText.body.copyWith(color: C.red))),
          ])),
        ],
        if (_result != null) ...[
          const SizedBox(height: 12),
          _card(Column(children: [
            _ProbeRow(label: 'ADS Router (48898)',
                probe: _result!.adsRouter),
            const Divider(height: 16),
            _ProbeRow(label: 'ADS Runtime (851)',
                probe: _result!.adsRuntime),
          ])),
          const SizedBox(height: 8),
          _card(Row(children: [
            Icon(
              _result!.fullyReachable
                  ? Icons.check_circle_rounded
                  : Icons.cancel_rounded,
              size:  18,
              color: _result!.fullyReachable ? C.green : C.red,
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(
              _result!.fullyReachable
                  ? 'Both ADS endpoints reachable. AMS Net ID verified.'
                  : 'One or more endpoints failed. Check TwinCAT is in Run mode and ADS routes are configured.',
              style: AppText.body.copyWith(
                color: _result!.fullyReachable ? C.green : C.red),
            )),
          ])),
        ],
      ]),
    );
  }
}

class _ProbeRow extends StatelessWidget {
  final String       label;
  final PLCProbeResult probe;

  const _ProbeRow({required this.label, required this.probe});

  @override
  Widget build(BuildContext context) => Row(children: [
    Icon(probe.reachable ? Icons.check_circle_rounded : Icons.cancel_rounded,
        size: 16, color: probe.reachable ? C.green : C.red),
    const SizedBox(width: 10),
    Expanded(child: Text(label, style: AppText.body)),
    Text('${probe.latencyMs} ms',
        style: AppText.mono.copyWith(color: probe.reachable ? C.green : C.red)),
  ]);
}

// ─────────────────────────────────────────────────────────────────────────────
// Step 2 — Apartment Setup
// ─────────────────────────────────────────────────────────────────────────────

class _StepApartment extends StatefulWidget {
  final CommissioningService svc;
  final int?          plcDeviceId;
  final void Function(ApartmentInfo) onApartment;

  const _StepApartment({
    required this.svc,
    required this.plcDeviceId,
    required this.onApartment,
  });

  @override
  State<_StepApartment> createState() => _StepApartmentState();
}

class _StepApartmentState extends State<_StepApartment> {
  bool                   _loading   = false;
  List<ApartmentInfo>    _apartments = [];
  ApartmentInfo?         _selected;
  String?                _error;

  final _nameCtrl     = TextEditingController();
  final _buildingCtrl = TextEditingController();
  final _floorCtrl    = TextEditingController();
  final _roomCtrl     = TextEditingController();
  final List<String>   _rooms = [];
  bool _creating = false;
  bool _showNew  = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _buildingCtrl.dispose();
    _floorCtrl.dispose();
    _roomCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    final r = await widget.svc.listApartments();
    setState(() {
      _loading = false;
      if (r.success) { _apartments = r.value; } else { _error = r.error; }
    });
  }

  Future<void> _create() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    setState(() => _creating = true);

    final r = await widget.svc.createApartment(
      name:     name,
      building: _buildingCtrl.text.trim(),
      floor:    _floorCtrl.text.trim(),
    );
    if (!mounted) return;

    if (!r.success) {
      setState(() { _creating = false; _error = r.error; });
      return;
    }

    final apt = r.value;

    // Assign PLC if one was registered
    if (widget.plcDeviceId != null) {
      await widget.svc.assignPLC(apt.id, widget.plcDeviceId!);
    }

    // Create rooms
    for (final room in _rooms) {
      await widget.svc.addRoom(apt.id, room);
    }

    setState(() { _creating = false; _showNew = false; });
    widget.onApartment(apt);
    await _load();
  }

  void _select(ApartmentInfo apt) {
    setState(() => _selected = apt);
    widget.onApartment(apt);
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _stepHeader(
          'Apartment Setup',
          'Select an existing apartment or create a new one, then assign the PLC and add rooms.',
        ),

        if (_loading) const Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator(color: C.accent)),
        ),

        if (_error != null) _card(Row(children: [
          const Icon(Icons.error_outline_rounded, color: C.red, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(_error!, style: AppText.body.copyWith(color: C.red))),
        ])),

        for (final apt in _apartments) ...[
          const SizedBox(height: 6),
          GestureDetector(
            onTap: () => _select(apt),
            child: _card(Row(children: [
              Container(
                width: 20, height: 20,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _selected?.id == apt.id ? C.accent : C.card2,
                  border: Border.all(
                      color: _selected?.id == apt.id ? C.accent : C.border),
                ),
                child: _selected?.id == apt.id
                    ? const Icon(Icons.check_rounded, size: 12, color: C.bg)
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(apt.name, style: AppText.title),
                if (apt.building.isNotEmpty || apt.floor.isNotEmpty)
                  Text('${apt.building} Floor ${apt.floor}',
                      style: AppText.small.copyWith(color: C.textSec)),
              ])),
            ])),
          ),
        ],

        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: GestureDetector(
            onTap: () => setState(() => _showNew = !_showNew),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color:        C.card2,
                borderRadius: BorderRadius.circular(12),
                border:       Border.all(color: C.border),
              ),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(_showNew ? Icons.expand_less_rounded : Icons.add_rounded,
                    size: 18, color: C.accent),
                const SizedBox(width: 6),
                Text(_showNew ? 'Cancel' : 'New Apartment',
                    style: AppText.bodyMed.copyWith(color: C.accent)),
              ]),
            ),
          ),
        ),

        if (_showNew) ...[
          const SizedBox(height: 12),
          _card(Column(children: [
            _FieldRow('Apartment Name *', _nameCtrl, hint: 'e.g. Apartment 16'),
            const SizedBox(height: 10),
            _FieldRow('Building',         _buildingCtrl, hint: 'e.g. Tower A'),
            const SizedBox(height: 10),
            _FieldRow('Floor',            _floorCtrl, hint: 'e.g. 4'),
            const Divider(height: 20),
            Row(children: [
              Expanded(child: _FieldRow('Add Room', _roomCtrl, hint: 'Living Room')),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: () {
                  final r = _roomCtrl.text.trim();
                  if (r.isNotEmpty) {
                    setState(() { _rooms.add(r); _roomCtrl.clear(); });
                  }
                },
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: C.accentLo,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: C.accent.withAlpha(80)),
                  ),
                  child: const Icon(Icons.add_rounded, color: C.accent, size: 18),
                ),
              ),
            ]),
            if (_rooms.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final room in _rooms)
                  Chip(
                    label:       Text(room, style: AppText.small),
                    deleteIcon:  const Icon(Icons.close_rounded, size: 12),
                    onDeleted:   () => setState(() => _rooms.remove(room)),
                    backgroundColor: C.card2,
                    side:        const BorderSide(color: C.border, width: 0.5),
                    padding:     const EdgeInsets.symmetric(horizontal: 4),
                  ),
              ]),
            ],
            const SizedBox(height: 12),
            GestureDetector(
              onTap: _creating ? null : _create,
              child: Container(
                width:   double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 13),
                decoration: BoxDecoration(
                  gradient:     _creating ? null : G.accent,
                  color:        _creating ? C.card2 : null,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(child: _creating
                    ? const SizedBox(width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: C.textSec))
                    : Text('Create Apartment',
                          style: AppText.bodyMed.copyWith(color: C.bg))),
              ),
            ),
          ])),
        ],
      ]),
    );
  }
}

class _FieldRow extends StatelessWidget {
  final String                label;
  final TextEditingController ctrl;
  final String                hint;

  const _FieldRow(this.label, this.ctrl, {this.hint = ''});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: AppText.small.copyWith(color: C.textSec)),
      const SizedBox(height: 6),
      TextField(
        controller:  ctrl,
        style:       AppText.body,
        decoration:  InputDecoration(
          hintText:      hint,
          hintStyle:     AppText.body.copyWith(color: C.textTri),
          filled:        true,
          fillColor:     C.card2,
          border:        OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide:   const BorderSide(color: C.border, width: 0.5),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide:   const BorderSide(color: C.border, width: 0.5),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide:   const BorderSide(color: C.accent, width: 1),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          isDense:        true,
        ),
      ),
    ],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Step 3 — Symbol Discovery
// ─────────────────────────────────────────────────────────────────────────────

class _StepSymbolScan extends StatefulWidget {
  final CommissioningService svc;
  final int? deviceId;

  const _StepSymbolScan({required this.svc, required this.deviceId});

  @override
  State<_StepSymbolScan> createState() => _StepSymbolScanState();
}

class _StepSymbolScanState extends State<_StepSymbolScan> {
  bool             _scanning = false;
  String?          _error;
  SymbolScanResult? _result;

  Future<void> _scan() async {
    final id = widget.deviceId;
    if (id == null) {
      setState(() => _error = 'Register a PLC first (Step 0).');
      return;
    }
    setState(() { _scanning = true; _error = null; _result = null; });
    final r = await widget.svc.scanSymbols(id);
    setState(() {
      _scanning = false;
      if (r.success) { _result = r.value; } else { _error = r.error; }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _stepHeader(
          'Symbol Discovery',
          'Enumerate all TwinCAT 3 symbols on the PLC. Verify that DALI, relay, '
          'curtain and sensor GVLs are present before configuring I/O points.',
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: GestureDetector(
            onTap: _scanning ? null : _scan,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                gradient:     _scanning ? null : G.accent,
                color:        _scanning ? C.card2 : null,
                borderRadius: BorderRadius.circular(12),
                boxShadow:    _scanning ? null : S.accentGlow,
              ),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                if (_scanning)
                  const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: C.textSec))
                else
                  const Icon(Icons.manage_search_rounded, size: 18, color: C.bg),
                const SizedBox(width: 8),
                Text(_scanning ? 'Scanning symbols…' : 'Scan TwinCAT Symbols',
                    style: AppText.bodyMed.copyWith(
                      color: _scanning ? C.textSec : C.bg)),
              ]),
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          _card(Row(children: [
            const Icon(Icons.error_outline_rounded, color: C.red, size: 18),
            const SizedBox(width: 10),
            Expanded(child: Text(_error!, style: AppText.body.copyWith(color: C.red))),
          ])),
        ],
        if (_result != null) ...[
          const SizedBox(height: 12),
          _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.check_circle_rounded, color: C.green, size: 18),
              const SizedBox(width: 8),
              Text('${_result!.symbolCount} symbols discovered in ${_result!.scanDurationMs} ms',
                  style: AppText.body.copyWith(color: C.green)),
            ]),
            if (_result!.categoryCounts.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 6, children: [
                for (final e in _result!.categoryCounts.entries)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color:        C.card2,
                      borderRadius: BorderRadius.circular(999),
                      border:       Border.all(color: C.border, width: 0.5),
                    ),
                    child: Text('${e.key}: ${e.value}',
                        style: AppText.small.copyWith(color: C.textSec)),
                  ),
              ]),
            ],
          ])),
        ],
        const SizedBox(height: 12),
        _card(Row(children: [
          const Icon(Icons.info_outline_rounded, size: 16, color: C.blue),
          const SizedBox(width: 10),
          Expanded(child: Text(
            'After scanning, add I/O devices in Settings → Manage Apartments → Devices, '
            'then return to continue.',
            style: AppText.small.copyWith(color: C.textSec),
          )),
        ])),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Step 4 — Floor Plan
// ─────────────────────────────────────────────────────────────────────────────

class _StepFloorPlan extends StatelessWidget {
  final CommissioningService svc;
  final ApartmentInfo?       apartment;

  const _StepFloorPlan({required this.svc, required this.apartment});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _stepHeader(
          'Floor Plan',
          'Upload a floor plan image (JPG, PNG, PDF, or SVG) as the background for the '
          'Digital Twin map. The installer uses this to place devices visually.',
        ),
        const SizedBox(height: 12),
        if (apartment == null)
          _card(Row(children: [
            const Icon(Icons.warning_rounded, color: C.orange, size: 18),
            const SizedBox(width: 10),
            Expanded(child: Text(
              'Select or create an apartment first (Step 2).',
              style: AppText.body.copyWith(color: C.orange),
            )),
          ]))
        else ...[
          _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Apartment: ${apartment!.name}', style: AppText.title),
            const SizedBox(height: 12),
            Text(
              'The floor plan upload is available inside the Map Editor. '
              'Open the Map Editor in Step 5, tap the background image icon in the toolbar, '
              'and upload your floor plan.',
              style: AppText.body.copyWith(color: C.textSec),
            ),
          ])),
          const SizedBox(height: 8),
          _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Supported formats', style: AppText.bodyMed.copyWith(color: C.textPri)),
            const SizedBox(height: 10),
            for (final f in [
              ('JPG / PNG',  'Raster floor plan photograph or scan'),
              ('PDF',        'Architectural drawing (first page rendered)'),
              ('SVG',        'Vector CAD export — scales without loss'),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    width: 56,
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: C.blueLo,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(f.$1,
                        style: AppText.badge.copyWith(color: C.blue, letterSpacing: 0.5),
                        textAlign: TextAlign.center),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(f.$2,
                      style: AppText.small.copyWith(color: C.textSec))),
                ]),
              ),
          ])),
        ],
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Step 5 — Map Editor (links to existing screen)
// ─────────────────────────────────────────────────────────────────────────────

class _StepMapEditor extends StatelessWidget {
  final VoidCallback   onOpenEditor;
  final ApartmentInfo? apartment;

  const _StepMapEditor({required this.onOpenEditor, required this.apartment});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _stepHeader(
          'Map Editor',
          'Open the Digital Twin editor to place device icons on the floor plan and '
          'link each one to a PLC variable. When done, close the editor to return here.',
        ),
        const SizedBox(height: 20),
        if (apartment == null)
          _card(Row(children: [
            const Icon(Icons.warning_rounded, color: C.orange, size: 18),
            const SizedBox(width: 10),
            Expanded(child: Text(
              'Select an apartment in Step 2 before opening the editor.',
              style: AppText.body.copyWith(color: C.orange),
            )),
          ]))
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: GestureDetector(
              onTap: onOpenEditor,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 22),
                decoration: BoxDecoration(
                  gradient:     G.accent,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow:    S.accentGlow,
                ),
                child: Column(children: [
                  const Icon(Icons.edit_square, size: 36, color: C.bg),
                  const SizedBox(height: 10),
                  Text('Open Map Editor',
                      style: AppText.h2.copyWith(color: C.bg)),
                  const SizedBox(height: 4),
                  Text('For: ${apartment!.name}',
                      style: AppText.body.copyWith(color: C.bg.withAlpha(180))),
                ]),
              ),
            ),
          ),
        const SizedBox(height: 20),
        _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('In the Map Editor:', style: AppText.bodyMed),
          const SizedBox(height: 10),
          for (final step in [
            '1. Tap the background icon and upload your floor plan',
            '2. Use the device palette to place DALI, relay, curtain, and sensor icons',
            '3. Tap each placed device → Properties → assign its PLC variable',
            '4. Save using the save button in the toolbar',
            '5. Close the editor to return to this wizard',
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.arrow_right_rounded, size: 16, color: C.accent),
                const SizedBox(width: 6),
                Expanded(child: Text(step,
                    style: AppText.body.copyWith(color: C.textSec))),
              ]),
            ),
        ])),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Step 6 — I/O Commissioning (device-by-device test)
// ─────────────────────────────────────────────────────────────────────────────

class _StepIOTest extends StatefulWidget {
  final CommissioningService svc;
  final ApartmentInfo?       apartment;

  const _StepIOTest({required this.svc, required this.apartment});

  @override
  State<_StepIOTest> createState() => _StepIOTestState();
}

class _StepIOTestState extends State<_StepIOTest> {
  bool              _loading = false;
  String?           _error;
  List<IOTestResult> _tests  = [];

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  Future<void> _loadDevices() async {
    final apt = widget.apartment;
    if (apt == null) return;
    setState(() { _loading = true; _error = null; });

    final r = await widget.svc.listDevices(apt.id);
    setState(() {
      _loading = false;
      if (r.success) {
        _tests = r.value.map((d) => IOTestResult(
          deviceId:   d.id,
          deviceName: d.name,
          deviceType: d.deviceType,
          status:     IOTestStatus.untested,
        )).toList();
      } else {
        _error = r.error;
      }
    });
  }

  Future<void> _test(int index) async {
    final apt = widget.apartment;
    if (apt == null) return;

    setState(() {
      _tests[index] = _tests[index].copyWith(status: IOTestStatus.testing);
    });

    final r = await widget.svc.testIODevice(apt.id, _tests[index].deviceId);

    setState(() {
      if (r.success) {
        _tests[index] = _tests[index].copyWith(
          status: IOTestStatus.passed,
          action: r.data?['action'] as String?,
        );
      } else {
        _tests[index] = _tests[index].copyWith(
          status: IOTestStatus.failed,
          error:  r.error,
        );
      }
    });
  }

  Future<void> _testAll() async {
    for (int i = 0; i < _tests.length; i++) {
      if (!mounted) return;
      await _test(i);
      // Small gap between tests to prevent ADS flooding
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  @override
  Widget build(BuildContext context) {
    final passed  = _tests.where((t) => t.status == IOTestStatus.passed).length;
    final failed  = _tests.where((t) => t.status == IOTestStatus.failed).length;
    final testing = _tests.any((t)    => t.status == IOTestStatus.testing);

    return Column(children: [
      _stepHeader(
        'I/O Commissioning',
        'Test every configured I/O point. DALI channels flash briefly, relays pulse ON/OFF, '
        'curtains move 0.8 s then stop. Confirm the correct device responds.',
      ),

      if (widget.apartment == null)
        _card(Row(children: [
          const Icon(Icons.warning_rounded, color: C.orange, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text('Select an apartment in Step 2.',
              style: AppText.body.copyWith(color: C.orange))),
        ]))
      else ...[
        // Summary bar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(children: [
            _statusChip('$passed passed', ok: true),
            const SizedBox(width: 8),
            if (failed > 0) _statusChip('$failed failed', ok: false),
            const Spacer(),
            if (!testing && _tests.isNotEmpty)
              GestureDetector(
                onTap: _testAll,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color:        C.accentLo,
                    borderRadius: BorderRadius.circular(8),
                    border:       Border.all(color: C.accent.withAlpha(80)),
                  ),
                  child: Text('Test All',
                      style: AppText.bodyMed.copyWith(color: C.accent)),
                ),
              ),
          ]),
        ),

        if (_loading) const Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator(color: C.accent)),
        ),

        if (_error != null) _card(Row(children: [
          const Icon(Icons.error_outline_rounded, color: C.red, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(_error!, style: AppText.body.copyWith(color: C.red))),
        ])),

        Expanded(
          child: ListView.builder(
            padding:     const EdgeInsets.only(bottom: 24),
            itemCount:   _tests.length,
            itemBuilder: (ctx, i) {
              final t = _tests[i];
              return _IOTestTile(
                result:  t,
                onTest:  () => _test(i),
              );
            },
          ),
        ),
      ],
    ]);
  }
}

class _IOTestTile extends StatelessWidget {
  final IOTestResult t;
  final VoidCallback onTest;

  const _IOTestTile({required this.result, required this.onTest}) : t = result;

  // ignore: avoid_field_initializers_in_const_classes
  final IOTestResult result;

  Color get _statusColor {
    switch (t.status) {
      case IOTestStatus.passed:  return C.green;
      case IOTestStatus.failed:  return C.red;
      case IOTestStatus.testing: return C.accent;
      default:                   return C.textTri;
    }
  }

  IconData get _statusIcon {
    switch (t.status) {
      case IOTestStatus.passed:  return Icons.check_circle_rounded;
      case IOTestStatus.failed:  return Icons.cancel_rounded;
      case IOTestStatus.testing: return Icons.hourglass_top_rounded;
      default:                   return Icons.radio_button_unchecked_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin:  const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        C.card,
        borderRadius: BorderRadius.circular(12),
        border:       Border.all(
          color: t.status == IOTestStatus.untested ? C.border : _statusColor.withAlpha(80),
          width: 0.5,
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(_statusIcon, size: 18, color: _statusColor),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.deviceName, style: AppText.title),
            Text(t.deviceType, style: AppText.small.copyWith(color: C.textSec)),
          ])),
          if (t.status == IOTestStatus.testing)
            const SizedBox(width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: C.accent))
          else
            GestureDetector(
              onTap: onTest,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color:        t.status == IOTestStatus.passed
                      ? C.greenLo : C.accentLo,
                  borderRadius: BorderRadius.circular(7),
                  border:       Border.all(
                    color: t.status == IOTestStatus.passed
                        ? C.green.withAlpha(80) : C.accent.withAlpha(80),
                  ),
                ),
                child: Text(
                  t.status == IOTestStatus.passed ? 'Re-test' : 'Test',
                  style: AppText.bodyMed.copyWith(
                    color: t.status == IOTestStatus.passed ? C.green : C.accent),
                ),
              ),
            ),
        ]),
        if (t.action != null) ...[
          const SizedBox(height: 6),
          Text(t.action!, style: AppText.small.copyWith(color: C.textSec)),
        ],
        if (t.error != null) ...[
          const SizedBox(height: 6),
          Text(t.error!, style: AppText.small.copyWith(color: C.red)),
        ],
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Step 7 — Resident Accounts
// ─────────────────────────────────────────────────────────────────────────────

class _StepResidents extends StatefulWidget {
  final CommissioningService svc;
  final ApartmentInfo?       apartment;

  const _StepResidents({required this.svc, required this.apartment});

  @override
  State<_StepResidents> createState() => _StepResidentsState();
}

class _StepResidentsState extends State<_StepResidents> {
  final _userCtrl  = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passCtrl  = TextEditingController();
  bool  _creating  = false;
  String? _msg;
  bool    _msgOk   = false;
  final List<String> _created = [];

  @override
  void dispose() {
    _userCtrl.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final apt = widget.apartment;
    if (apt == null) return;

    final username = _userCtrl.text.trim();
    final email    = _emailCtrl.text.trim();
    final password = _passCtrl.text;

    if (username.isEmpty || email.isEmpty || password.isEmpty) {
      setState(() { _msg = 'All fields are required.'; _msgOk = false; });
      return;
    }

    setState(() { _creating = true; _msg = null; });

    final r1 = await widget.svc.createResident(
      username: username,
      email:    email,
      password: password,
    );

    if (!r1.success) {
      setState(() { _creating = false; _msg = r1.error; _msgOk = false; });
      return;
    }

    final r2 = await widget.svc.assignResident(r1.value, apt.id);
    setState(() {
      _creating = false;
      if (r2.success) {
        _created.add(username);
        _userCtrl.clear();
        _emailCtrl.clear();
        _passCtrl.clear();
        _msg   = 'Account created and assigned to ${apt.name}.';
        _msgOk = true;
      } else {
        _msg   = r2.error;
        _msgOk = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _stepHeader(
          'Resident Accounts',
          'Create login accounts for residents of this apartment. '
          'Each account is assigned the resident role — residents cannot see networking '
          'or create/delete accounts.',
        ),
        const SizedBox(height: 8),
        if (widget.apartment == null)
          _card(Row(children: [
            const Icon(Icons.warning_rounded, color: C.orange, size: 18),
            const SizedBox(width: 10),
            Expanded(child: Text(
              'Select an apartment in Step 2.',
              style: AppText.body.copyWith(color: C.orange),
            )),
          ]))
        else ...[
          _card(Column(children: [
            _FieldRow('Username *',    _userCtrl,  hint: 'resident_name'),
            const SizedBox(height: 10),
            _FieldRow('Email *',       _emailCtrl, hint: 'resident@example.com'),
            const SizedBox(height: 10),
            _FieldRow('Temp Password *', _passCtrl, hint: 'Min 8 chars'),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: _creating ? null : _create,
              child: Container(
                width:   double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 13),
                decoration: BoxDecoration(
                  gradient:     _creating ? null : G.accent,
                  color:        _creating ? C.card2 : null,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(child: _creating
                    ? const SizedBox(width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: C.textSec))
                    : Text('Create Resident Account',
                          style: AppText.bodyMed.copyWith(color: C.bg))),
              ),
            ),
          ])),
          if (_msg != null) ...[
            const SizedBox(height: 8),
            _card(Row(children: [
              Icon(
                _msgOk ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                size: 18, color: _msgOk ? C.green : C.red,
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(_msg!,
                  style: AppText.body.copyWith(color: _msgOk ? C.green : C.red))),
            ])),
          ],
          if (_created.isNotEmpty) ...[
            const SizedBox(height: 8),
            _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Created this session:', style: AppText.bodyMed.copyWith(color: C.textSec)),
              const SizedBox(height: 8),
              for (final u in _created)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(children: [
                    const Icon(Icons.person_rounded, size: 14, color: C.green),
                    const SizedBox(width: 6),
                    Text(u, style: AppText.body),
                  ]),
                ),
            ])),
          ],
          const SizedBox(height: 8),
          _card(Row(children: [
            const Icon(Icons.lock_outline_rounded, size: 16, color: C.blue),
            const SizedBox(width: 10),
            Expanded(child: Text(
              'Residents receive a temporary password and must change it on first login. '
              'Only admin accounts (Tech Team) can create or delete users.',
              style: AppText.small.copyWith(color: C.textSec),
            )),
          ])),
        ],
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Step 8 — Handover
// ─────────────────────────────────────────────────────────────────────────────

class _StepHandover extends StatefulWidget {
  final CommissioningService svc;
  final ApartmentInfo?       apartment;

  const _StepHandover({required this.svc, required this.apartment});

  @override
  State<_StepHandover> createState() => _StepHandoverState();
}

class _StepHandoverState extends State<_StepHandover> {
  bool            _loading  = false;
  bool            _publishing = false;
  String?         _error;
  HandoverSummary? _summary;
  bool            _published = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final apt = widget.apartment;
    if (apt == null) return;
    setState(() { _loading = true; _error = null; });
    final r = await widget.svc.getSummary(apt.id);
    setState(() {
      _loading = false;
      if (r.success) { _summary = r.value; } else { _error = r.error; }
    });
  }

  Future<void> _publish() async {
    final apt = widget.apartment;
    if (apt == null) return;
    setState(() => _publishing = true);
    final r = await widget.svc.publishMap(apt.id);
    setState(() {
      _publishing = false;
      if (r.success) { _published = true; } else { _error = r.error; }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = _summary;
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _stepHeader(
          'Handover',
          'Review the complete commissioning record. Publish the map to make the '
          'Digital Twin visible to residents, then hand over the apartment.',
        ),

        if (_loading) const Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator(color: C.accent)),
        ),

        if (_error != null) _card(Row(children: [
          const Icon(Icons.error_outline_rounded, color: C.red, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(_error!, style: AppText.body.copyWith(color: C.red))),
        ])),

        if (s != null) ...[
          // Apartment summary
          _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.apartment.name, style: AppText.h2),
            if (s.apartment.building.isNotEmpty)
              Text('${s.apartment.building} · Floor ${s.apartment.floor}',
                  style: AppText.body.copyWith(color: C.textSec)),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 6, children: [
              _statusChip('${s.rooms.length} rooms',    ok: s.rooms.isNotEmpty,   warn: s.rooms.isEmpty),
              _statusChip('${s.devices.length} devices', ok: s.devices.isNotEmpty, warn: s.devices.isEmpty),
              _statusChip('${s.residents.length} residents', ok: s.residents.isNotEmpty, warn: s.residents.isEmpty),
              if (s.map != null)
                _statusChip(
                  s.map!['is_published'] == true ? 'Map published' : 'Map unpublished',
                  ok:   s.map!['is_published'] == true,
                  warn: s.map!['is_published'] != true,
                ),
              if (s.plc != null)
                _statusChip('PLC ${s.plc!['ip_address']}', ok: true),
            ]),
          ])),

          // Device breakdown
          if (s.deviceCounts.isNotEmpty)
            _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('I/O Points', style: AppText.bodyMed),
              const SizedBox(height: 10),
              for (final e in s.deviceCounts.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(children: [
                    Text(e.key, style: AppText.body.copyWith(color: C.textSec)),
                    const Spacer(),
                    Text('${e.value}', style: AppText.bodyMed),
                  ]),
                ),
            ])),

          // Residents list
          if (s.residents.isNotEmpty)
            _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Residents', style: AppText.bodyMed),
              const SizedBox(height: 10),
              for (final r in s.residents)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(children: [
                    const Icon(Icons.person_rounded, size: 14, color: C.green),
                    const SizedBox(width: 6),
                    Expanded(child: Text(r['username'] as String? ?? '',
                        style: AppText.body)),
                    Text(r['email'] as String? ?? '',
                        style: AppText.small.copyWith(color: C.textSec)),
                  ]),
                ),
            ])),

          // Publish button
          if (s.map?['is_published'] != true && !_published) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: GestureDetector(
                onTap: _publishing ? null : _publish,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    gradient:     _publishing ? null : G.accent,
                    color:        _publishing ? C.card2 : null,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow:    _publishing ? null : S.accentGlow,
                  ),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    if (_publishing)
                      const SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: C.textSec))
                    else
                      const Icon(Icons.publish_rounded, size: 18, color: C.bg),
                    const SizedBox(width: 8),
                    Text(_publishing ? 'Publishing…' : 'Publish Map',
                        style: AppText.bodyMed.copyWith(
                          color: _publishing ? C.textSec : C.bg)),
                  ]),
                ),
              ),
            ),
          ],

          if (_published || s.map?['is_published'] == true) ...[
            const SizedBox(height: 8),
            _card(Row(children: [
              const Icon(Icons.check_circle_rounded, color: C.green, size: 22),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Commissioning Complete', style: AppText.title.copyWith(color: C.green)),
                const SizedBox(height: 3),
                Text(
                  'The Digital Twin is live. Residents can now log in and control their apartment.',
                  style: AppText.small.copyWith(color: C.textSec),
                ),
              ])),
            ])),
          ],
        ],
      ]),
    );
  }
}
