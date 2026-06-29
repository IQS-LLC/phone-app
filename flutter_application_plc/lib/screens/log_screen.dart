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

  String _fmt(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: C.bg,
    appBar: AppBar(
      backgroundColor: C.surface,
      title: const Text('Activity Log'),
      iconTheme: const IconThemeData(color: C.textSec),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(height: 1, color: C.border),
      ),
      actions: [
        // Filter toggle
        Padding(
          padding: const EdgeInsets.only(right: 4),
          child: TapScale(
            onTap: () => setState(() => _errorsOnly = !_errorsOnly),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: _errorsOnly ? C.red.withAlpha(20) : C.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _errorsOnly ? C.red.withAlpha(70) : C.border,
                ),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.error_outline_rounded,
                    size: 13,
                    color: _errorsOnly ? C.red : C.textSec),
                const SizedBox(width: 4),
                Text('Errors',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: _errorsOnly
                          ? FontWeight.w600 : FontWeight.w400,
                      color: _errorsOnly ? C.red : C.textSec,
                    )),
              ]),
            ),
          ),
        ),
        // Clear button
        ListenableBuilder(
          listenable: widget.appState,
          builder: (ctx, child) => widget.appState.log.isEmpty
              ? const SizedBox.shrink()
              : TapScale(
                  onTap: () {
                    HapticFeedback.lightImpact();
                    _confirmClear(ctx);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.delete_outline_rounded,
                          size: 15, color: C.red),
                      const SizedBox(width: 4),
                      Text('Clear',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: C.red,
                          )),
                    ]),
                  ),
                ),
        ),
      ],
    ),
    body: ListenableBuilder(
      listenable: widget.appState,
      builder: (ctx, child) {
        final all      = widget.appState.log;
        final filtered = _errorsOnly
            ? all.where((e) => e.isError).toList()
            : all;

        if (filtered.isEmpty) {
          return EmptyState(
            icon:     _errorsOnly
                ? Icons.check_circle_outline_rounded
                : Icons.receipt_long_outlined,
            title:    _errorsOnly ? 'No errors — all clear' : 'No log entries yet',
            subtitle: _errorsOnly
                ? 'All commands completed successfully.'
                : 'Commands and events will appear here.',
          );
        }

        return ListView.builder(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
          itemCount: filtered.length,
          itemBuilder: (ctx, i) => _LogTile(
            entry:    filtered[i],
            fmt:      _fmt,
            isFirst:  i == 0,
            isLast:   i == filtered.length - 1,
          ),
        );
      },
    ),
  );

  void _confirmClear(BuildContext ctx) {
    showModalBottomSheet(
      context: ctx,
      backgroundColor: C.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36, height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: C.border2,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const Icon(Icons.delete_outline_rounded,
                  color: C.red, size: 28),
              const SizedBox(height: 12),
              Text('Clear activity log?', style: AppText.h3),
              const SizedBox(height: 6),
              Text('This cannot be undone.',
                  style: AppText.bodySm, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              Row(children: [
                Expanded(
                  child: TapScale(
                    onTap: () => Navigator.pop(sheetCtx),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      decoration: BoxDecoration(
                        color: C.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: C.border),
                      ),
                      child: Center(
                        child: Text('Cancel',
                            style: GoogleFonts.inter(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: C.textSec,
                            )),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TapScale(
                    onTap: () {
                      widget.appState.clearLog();
                      Navigator.pop(sheetCtx);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      decoration: BoxDecoration(
                        color: C.red.withAlpha(18),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: C.red.withAlpha(70)),
                      ),
                      child: Center(
                        child: Text('Clear',
                            style: GoogleFonts.inter(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: C.red,
                            )),
                      ),
                    ),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Log tile
// ─────────────────────────────────────────────────────────────────────────────

class _LogTile extends StatelessWidget {
  final LogEntry               entry;
  final String Function(DateTime) fmt;
  final bool isFirst;
  final bool isLast;

  const _LogTile({
    required this.entry,
    required this.fmt,
    required this.isFirst,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    final color = entry.isError ? C.red : C.green;
    final isNew = DateTime.now().difference(entry.time).inSeconds < 5;

    return Container(
      margin: EdgeInsets.only(
        top:    isFirst ? 0 : 1,
        bottom: isLast  ? 0 : 0,
      ),
      decoration: BoxDecoration(
        color: isFirst && isNew
            ? color.withAlpha(8)
            : C.card,
        borderRadius: BorderRadius.vertical(
          top:    Radius.circular(isFirst ? 12 : 0),
          bottom: Radius.circular(isLast  ? 12 : 0),
        ),
        border: Border(
          left: BorderSide(color: C.border),
          right: BorderSide(color: C.border),
          top: BorderSide(
            color: isFirst ? C.border : C.border.withAlpha(100)),
          bottom: isLast
              ? const BorderSide(color: C.border)
              : BorderSide.none,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status dot
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 12),
              child: Container(
                width: 7, height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                  boxShadow: [
                    BoxShadow(
                      color:      color.withAlpha(60),
                      blurRadius: 4,
                    ),
                  ],
                ),
              ),
            ),
            // Message + time
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.message,
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: entry.isError ? C.red : C.textPri,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    fmt(entry.time),
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 10,
                      color: C.textTri,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
