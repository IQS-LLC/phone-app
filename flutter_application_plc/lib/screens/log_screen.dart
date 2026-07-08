import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../widgets/common_widgets.dart';

class LogScreen extends StatefulWidget {
  final AppState appState;
  const LogScreen({super.key, required this.appState});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  bool _errorsOnly = false;

  String _rel(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24)   return '${diff.inHours}h ago';
    return '${t.day}/${t.month}';
  }

  String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}';

  Map<String, List<LogEntry>> _group(List<LogEntry> entries) {
    final today = DateTime.now();
    final dayStart = DateTime(today.year, today.month, today.day);
    final result = <String, List<LogEntry>>{};
    for (final e in entries) {
      final key = e.time.isAfter(dayStart) ? 'Today' : 'Earlier';
      result.putIfAbsent(key, () => []).add(e);
    }
    return result;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: C.bg,
    body: SafeArea(
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 16, 0),
          child: Row(children: [
            Text('Activity', style: AppText.display.copyWith(fontSize: 26)),
            const Spacer(),
            TapScale(
              onTap: () => setState(() => _errorsOnly = !_errorsOnly),
              child: AnimatedContainer(
                duration: Dur.fast,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color:        _errorsOnly ? C.red.withAlpha(18) : C.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _errorsOnly ? C.red.withAlpha(60) : C.border, width: 0.5,
                  ),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.error_rounded, size: 13,
                      color: _errorsOnly ? C.red : C.textTri),
                  const SizedBox(width: 5),
                  Text('Errors',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: _errorsOnly ? FontWeight.w700 : FontWeight.w400,
                        color: _errorsOnly ? C.red : C.textSec,
                      )),
                ]),
              ),
            ),
            const SizedBox(width: 8),
            ListenableBuilder(
              listenable: widget.appState,
              builder: (_, _) => widget.appState.log.isEmpty
                  ? const SizedBox.shrink()
                  : TapScale(
                      onTap: () {
                        HapticFeedback.lightImpact();
                        _confirmClear(context);
                      },
                      child: Container(
                        width: 36, height: 36,
                        decoration: BoxDecoration(
                          color: C.red.withAlpha(14),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: C.red.withAlpha(40), width: 0.5),
                        ),
                        child: const Icon(Icons.delete_outline_rounded,
                            color: C.red, size: 16),
                      ),
                    ),
            ),
          ]),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: ListenableBuilder(
            listenable: widget.appState,
            builder: (_, _) {
              final all = widget.appState.log;
              final filtered = _errorsOnly
                  ? all.where((e) => e.isError).toList()
                  : all;

              if (filtered.isEmpty) {
                return EmptyState(
                  icon: _errorsOnly
                      ? Icons.check_circle_rounded
                      : Icons.receipt_long_rounded,
                  title:    _errorsOnly ? 'No errors' : 'No activity yet',
                  subtitle: _errorsOnly
                      ? 'All commands completed successfully.'
                      : 'Commands and events will appear here.',
                );
              }

              final groups = _group(filtered);
              final keys = ['Today', 'Earlier']
                  .where((k) => groups.containsKey(k)).toList();

              return CustomScrollView(
                physics: const BouncingScrollPhysics(),
                slivers: [
                  for (final key in keys) ...[
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                      sliver: SliverToBoxAdapter(
                        child: Text(key.toUpperCase(), style: AppText.label),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                      sliver: SliverToBoxAdapter(
                        child: AppCard(
                          child: Column(
                            children: List.generate(groups[key]!.length, (i) {
                              final e = groups[key]![i];
                              return Column(children: [
                                if (i > 0) const Divider(
                                  height: 0.5, thickness: 0.5,
                                  color: C.border, indent: 46, endIndent: 16,
                                ),
                                _Tile(
                                  entry:    e,
                                  rel:      _rel(e.time),
                                  clock:    _clock(e.time),
                                  isLatest: key == 'Today' && i == 0,
                                ),
                              ]);
                            }),
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SliverPadding(padding: EdgeInsets.only(bottom: 16)),
                ],
              );
            },
          ),
        ),
      ]),
    ),
  );

  void _confirmClear(BuildContext ctx) {
    showModalBottomSheet(
      context: ctx,
      backgroundColor: C.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const BottomSheetHandle(),
            const SizedBox(height: 20),
            Container(
              width: 52, height: 52,
              decoration: BoxDecoration(
                color: C.red.withAlpha(16), shape: BoxShape.circle,
              ),
              child: const Icon(Icons.delete_outline_rounded, color: C.red, size: 24),
            ),
            const SizedBox(height: 14),
            Text('Clear activity log?', style: AppText.h3),
            const SizedBox(height: 6),
            Text('This cannot be undone.', style: AppText.bodySm),
            const SizedBox(height: 24),
            Row(children: [
              Expanded(child: PrimaryButton(label: 'Cancel', color: C.textSec,
                  onTap: () => Navigator.pop(sheetCtx))),
              const SizedBox(width: 12),
              Expanded(child: PrimaryButton(label: 'Clear', color: C.red,
                  onTap: () { widget.appState.clearLog(); Navigator.pop(sheetCtx); })),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  final LogEntry entry;
  final String   rel;
  final String   clock;
  final bool     isLatest;
  const _Tile({required this.entry, required this.rel, required this.clock, required this.isLatest});

  @override
  Widget build(BuildContext context) {
    final color = entry.isError ? C.red : C.green;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 22, height: 22,
          decoration: BoxDecoration(color: color.withAlpha(18), shape: BoxShape.circle),
          child: Icon(entry.isError ? Icons.error_rounded : Icons.check_rounded,
              color: color, size: 12),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(entry.message,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: isLatest ? FontWeight.w600 : FontWeight.w400,
                  color: entry.isError ? C.red : C.textPri,
                  height: 1.4,
                )),
            const SizedBox(height: 3),
            Text(clock, style: AppText.mono.copyWith(fontSize: 10, color: C.textTri)),
          ]),
        ),
        const SizedBox(width: 8),
        Text(rel, style: AppText.caption),
      ]),
    );
  }
}
