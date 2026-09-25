import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../auth/auth_state.dart';
import '../theme.dart';
import '../widgets/common_widgets.dart';
import 'superscan_screen.dart';
import 'utilities_screen.dart';

/// Building-wide admin panel for a building-level apartment (e.g. "Building
/// Common Areas") — sunset/sunrise override, poll cooldown, Christmas chase,
/// fade smoothness, and ballast/device scanning in one place. is_staff (IT
/// Team) only; every endpoint it calls is IsAdminUser server-side too.
class BuildingControlsScreen extends StatefulWidget {
  final AuthState authState;
  final int apartmentId;
  final String apartmentName;

  const BuildingControlsScreen({
    super.key,
    required this.authState,
    required this.apartmentId,
    required this.apartmentName,
  });

  @override
  State<BuildingControlsScreen> createState() => _BuildingControlsScreenState();
}

class _BuildingControlsScreenState extends State<BuildingControlsScreen> {
  bool _loading = true;
  String? _error;

  bool _autoSunset = true;
  TimeOfDay? _sunset;
  TimeOfDay? _sunrise;
  double _pollS = 1;
  bool _christmas = false;
  bool _christmasBusy = false;

  late double _dimMs;
  late double _undimMs;

  @override
  void initState() {
    super.initState();
    final u = widget.authState.user;
    _dimMs   = (u?.dimDurationMs ?? 800).toDouble().clamp(100, 5000);
    _undimMs = (u?.undimDurationMs ?? 500).toDouble().clamp(100, 5000);
    _load();
  }

  TimeOfDay? _parse(Object? v) {
    if (v is! String || !v.contains(':')) return null;
    final p = v.split(':');
    return TimeOfDay(hour: int.parse(p[0]), minute: int.parse(p[1]));
  }

  String _fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  void _apply(Map<String, dynamic> s) {
    _autoSunset = s['auto_sunset_sunrise'] as bool? ?? true;
    _sunset     = _parse(s['sunset_override_time']);
    _sunrise    = _parse(s['sunrise_override_time']);
    _pollS      = ((s['poll_interval_s'] as num?) ?? 1).toDouble().clamp(1, 60);
    _christmas  = s['christmas_mode_active'] as bool? ?? false;
  }

  Future<void> _load() async {
    final s = await widget.authState.getBuildingSettings(widget.apartmentId);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (s == null) {
        _error = 'Could not load building settings';
      } else {
        _error = null;
        _apply(s);
      }
    });
  }

  Future<void> _save({
    bool? auto, String? sunset, String? sunrise, int? poll, required String what,
  }) async {
    final s = await widget.authState.updateBuildingSettings(
      widget.apartmentId,
      autoSunsetSunrise: auto, sunsetOverrideTime: sunset,
      sunriseOverrideTime: sunrise, pollIntervalS: poll,
    );
    if (!mounted) return;
    if (s == null) {
      AppToast.show(context, 'Could not save $what', error: true);
      await _load();
      return;
    }
    setState(() => _apply(s));
  }

  Future<void> _pickTime({required bool sunset}) async {
    final initial = (sunset ? _sunset : _sunrise) ??
        (sunset ? const TimeOfDay(hour: 18, minute: 30) : const TimeOfDay(hour: 6, minute: 30));
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked == null) return;
    setState(() => sunset ? _sunset = picked : _sunrise = picked);
    await _save(
      sunset: sunset ? _fmt(picked) : null,
      sunrise: sunset ? null : _fmt(picked),
      what: sunset ? 'sunset time' : 'sunrise time',
    );
  }

  Future<void> _toggleAuto(bool v) async {
    setState(() => _autoSunset = v);
    // Turning auto off with no times yet → seed sensible defaults so the
    // override is immediately meaningful instead of silently inactive.
    await _save(
      auto: v,
      sunset:  (!v && _sunset  == null) ? '18:30' : null,
      sunrise: (!v && _sunrise == null) ? '06:30' : null,
      what: 'sunset/sunrise mode',
    );
  }

  Future<void> _toggleChristmas() async {
    final next = !_christmas;
    setState(() { _christmasBusy = true; });
    final ok = await widget.authState.setChristmasMode(widget.apartmentId, next);
    if (!mounted) return;
    setState(() {
      _christmasBusy = false;
      if (ok) _christmas = next;
    });
    AppToast.show(
      context,
      ok ? (next ? 'Christmas mode on' : 'Christmas mode off') : 'Could not change Christmas mode',
      error: !ok,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      appBar: AppBar(
        backgroundColor: C.surface,
        iconTheme: const IconThemeData(color: C.textSec),
        title: Text('Building Controls', style: AppText.h3),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: C.accent))
          : _error != null
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_error!, style: AppText.body.copyWith(color: C.red)),
                  const SizedBox(height: 12),
                  TextButton(onPressed: () { setState(() => _loading = true); _load(); },
                      child: const Text('Retry')),
                ]))
              : RefreshIndicator(
                  onRefresh: _load,
                  color: C.accent,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
                    children: [
                      _christmasCard(),
                      const SizedBox(height: 24),
                      _sunSection(),
                      const SizedBox(height: 24),
                      _smoothnessSection(),
                      const SizedBox(height: 24),
                      _cooldownSection(),
                      const SizedBox(height: 24),
                      _devicesSection(),
                    ],
                  ),
                ),
    );
  }

  // ── Christmas mode ────────────────────────────────────────────────────────

  Widget _christmasCard() => GestureDetector(
    onTap: _christmasBusy ? null : _toggleChristmas,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          colors: _christmas
              ? const [Color(0xFFB3202A), Color(0xFF1E7A3E)]
              : const [C.card2, C.card],
          begin: Alignment.topLeft, end: Alignment.bottomRight,
        ),
        border: Border.all(color: _christmas ? C.green : C.border),
      ),
      child: Row(children: [
        Container(
          width: 52, height: 52,
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(_christmas ? 40 : 12),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(Icons.celebration_rounded,
              color: _christmas ? Colors.white : C.accent, size: 28),
        ),
        const SizedBox(width: 16),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Christmas Mode',
              style: GoogleFonts.inter(fontSize: 17, fontWeight: FontWeight.w700, color: C.textPri)),
          const SizedBox(height: 4),
          Text(
            _christmas
                ? 'Running — building lights are chasing in sequence. Tap to stop.'
                : 'Synchronized chase across every building light. Tap to start.',
            style: AppText.bodySm.copyWith(color: _christmas ? Colors.white70 : C.textSec),
          ),
        ])),
        const SizedBox(width: 12),
        _christmasBusy
            ? const SizedBox(width: 22, height: 22,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : Icon(_christmas ? Icons.stop_circle_rounded : Icons.play_circle_fill_rounded,
                color: _christmas ? Colors.white : C.accent, size: 34),
      ]),
    ),
  );

  // ── Sunset / sunrise ──────────────────────────────────────────────────────

  Widget _iconBox(IconData icon, Color color) => Container(
    width: 32, height: 32,
    decoration: BoxDecoration(color: color.withAlpha(18), borderRadius: BorderRadius.circular(10)),
    child: Icon(icon, color: color, size: 16),
  );

  Widget _sunSection() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    SectionHeader('Sunset & Sunrise'),
    const SizedBox(height: 4),
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        'Automatic by default — the building follows its own schedule. Turn automatic off '
        'to set exact on/off times yourself: lights switch on at sunset and off at sunrise.',
        style: AppText.bodySm.copyWith(color: C.textTri),
      ),
    ),
    const SizedBox(height: 12),
    AppCard(child: Column(children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(children: [
          _iconBox(Icons.auto_mode_rounded, C.teal),
          const SizedBox(width: 12),
          Expanded(child: Text('Automatic', style: AppText.bodyMed)),
          Switch(value: _autoSunset, activeThumbColor: C.accent, onChanged: _toggleAuto),
        ]),
      ),
      const Divider(height: 0.5, thickness: 0.5, color: C.border),
      _timeRow(
        icon: Icons.wb_twilight_rounded, color: C.orange, label: 'Sunset (lights on)',
        value: _sunset, onTap: _autoSunset ? null : () => _pickTime(sunset: true),
      ),
      const Divider(height: 0.5, thickness: 0.5, color: C.border),
      _timeRow(
        icon: Icons.wb_sunny_rounded, color: C.blue, label: 'Sunrise (lights off)',
        value: _sunrise, onTap: _autoSunset ? null : () => _pickTime(sunset: false),
      ),
    ])),
  ]);

  Widget _timeRow({
    required IconData icon, required Color color, required String label,
    required TimeOfDay? value, required VoidCallback? onTap,
  }) => InkWell(
    onTap: onTap,
    child: Opacity(
      opacity: onTap == null ? 0.45 : 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(children: [
          _iconBox(icon, color),
          const SizedBox(width: 12),
          Expanded(child: Text(label, style: AppText.bodyMed)),
          Text(
            onTap == null ? 'Auto' : (value != null ? _fmt(value) : 'Set'),
            style: AppText.bodyMed.copyWith(color: onTap == null ? C.textSec : C.accent),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right_rounded, color: C.textTri, size: 18),
          ],
        ]),
      ),
    ),
  );

  // ── Smoothness ────────────────────────────────────────────────────────────

  String _fadeLabel(double ms) =>
      ms < 1000 ? '${ms.round()}ms' : '${(ms / 1000).toStringAsFixed(1)}s';

  Future<void> _commitFade({int? dim, int? undim}) async {
    final ok = await widget.authState.updateFadeDurations(dimMs: dim, undimMs: undim);
    if (!ok && mounted) AppToast.show(context, 'Could not save fade speed', error: true);
  }

  Widget _sliderRow({
    required IconData icon, required Color color, required String label,
    required String valueLabel, required double value, required double min,
    required double max, required int divisions,
    required ValueChanged<double> onChanged, required ValueChanged<double> onChangeEnd,
  }) => Column(children: [
    Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(children: [
        _iconBox(icon, color),
        const SizedBox(width: 12),
        Expanded(child: Text(label, style: AppText.bodyMed)),
        Text(valueLabel, style: AppText.bodySm.copyWith(color: C.textSec)),
      ]),
    ),
    SliderTheme(
      data: SliderTheme.of(context).copyWith(activeTrackColor: color, thumbColor: color),
      child: Slider(
        value: value, min: min, max: max, divisions: divisions,
        onChanged: onChanged, onChangeEnd: onChangeEnd,
      ),
    ),
  ]);

  Widget _smoothnessSection() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    SectionHeader('Smoothness & Dimming'),
    const SizedBox(height: 4),
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        'How gently dimmable lights fade down and back up. This building\'s current '
        'outputs are on/off relays — fades apply as soon as dimmable ballasts are added.',
        style: AppText.bodySm.copyWith(color: C.textTri),
      ),
    ),
    const SizedBox(height: 12),
    AppCard(child: Column(children: [
      _sliderRow(
        icon: Icons.trending_down_rounded, color: C.blue, label: 'Dim Speed',
        valueLabel: _fadeLabel(_dimMs), value: _dimMs, min: 100, max: 5000, divisions: 49,
        onChanged: (v) => setState(() => _dimMs = v),
        onChangeEnd: (v) => _commitFade(dim: v.round()),
      ),
      const Divider(height: 0.5, thickness: 0.5, color: C.border),
      _sliderRow(
        icon: Icons.trending_up_rounded, color: C.orange, label: 'Undim Speed',
        valueLabel: _fadeLabel(_undimMs), value: _undimMs, min: 100, max: 5000, divisions: 49,
        onChanged: (v) => setState(() => _undimMs = v),
        onChangeEnd: (v) => _commitFade(undim: v.round()),
      ),
    ])),
  ]);

  // ── Cooldown ──────────────────────────────────────────────────────────────

  Widget _cooldownSection() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    SectionHeader('Update Cooldown'),
    const SizedBox(height: 4),
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        'Minimum time between status refreshes from the controller. 1s is the fastest the '
        'controller safely supports — raise it to lighten load on the building\'s PLC.',
        style: AppText.bodySm.copyWith(color: C.textTri),
      ),
    ),
    const SizedBox(height: 12),
    AppCard(child: _sliderRow(
      icon: Icons.timer_rounded, color: C.purple, label: 'Refresh every',
      valueLabel: '${_pollS.round()}s', value: _pollS, min: 1, max: 60, divisions: 59,
      onChanged: (v) => setState(() => _pollS = v),
      onChangeEnd: (v) => _save(poll: v.round(), what: 'cooldown'),
    )),
  ]);

  // ── Devices & ballasts ────────────────────────────────────────────────────

  Widget _navRow({
    required IconData icon, required Color color, required String label,
    required String sub, required VoidCallback onTap,
  }) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(children: [
        _iconBox(icon, color),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: AppText.bodyMed),
          const SizedBox(height: 2),
          Text(sub, style: AppText.bodySm.copyWith(color: C.textSec)),
        ])),
        const Icon(Icons.chevron_right_rounded, color: C.textTri, size: 18),
      ]),
    ),
  );

  Widget _devicesSection() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    SectionHeader('Lights & Ballasts'),
    const SizedBox(height: 12),
    AppCard(child: Column(children: [
      _navRow(
        icon: Icons.lightbulb_rounded, color: C.orange, label: 'All Building Lights',
        sub: 'Turn each common-area light on or off',
        onTap: () => Navigator.push(context, MaterialPageRoute(
          builder: (_) => UtilitiesScreen(authState: widget.authState, apartmentId: widget.apartmentId),
        )),
      ),
      const Divider(height: 0.5, thickness: 0.5, color: C.border),
      _navRow(
        icon: Icons.travel_explore_rounded, color: C.purple, label: 'Scan for Ballasts',
        sub: 'Find every ballast and output on the building controller, then add them',
        onTap: () => Navigator.push(context, MaterialPageRoute(
          builder: (_) => SuperscanScreen(
            authState: widget.authState,
            apartmentId: widget.apartmentId,
            apartmentName: widget.apartmentName,
          ),
        )),
      ),
    ])),
  ]);
}
