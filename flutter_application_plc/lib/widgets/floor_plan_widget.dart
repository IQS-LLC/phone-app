import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// Apartment Floor Plan — Interactive Digital Twin
//
// Based on actual architectural drawings for Apartments 16 & 8.
// Both apartments share identical layout.
//
//   ┌──────────────────┬────────────┐
//   │   LIVING ROOM    │  KITCHEN   │
//   ├ ─ ─ ─ ─ ─ ─ ─ ─ │            │
//   │   DINING ROOM    ├────────────┤
//   ├──────────────────│  BEDROOM   │
//   │  HALLWAY / ENTRY │            │
//   └──────────────────┴────────────┘
// ═══════════════════════════════════════════════════════════════════════════════

class FloorRoomDef {
  final String name;
  final Rect   bounds;    // normalized 0–1
  final bool   openPlan;  // no solid wall on top edge

  const FloorRoomDef({
    required this.name,
    required this.bounds,
    this.openPlan = false,
  });
}

// Normalised 0–1 bounds derived from electrical drawing (logW=100, logH=80)
const apartmentLayout = <FloorRoomDef>[
  FloorRoomDef(name: 'Living Room',      bounds: Rect.fromLTWH(0.00, 0.000, 0.40, 0.500)),
  FloorRoomDef(name: 'Dining Room',      bounds: Rect.fromLTWH(0.00, 0.500, 0.40, 0.350), openPlan: true),
  FloorRoomDef(name: 'Kitchen',          bounds: Rect.fromLTWH(0.40, 0.000, 0.20, 0.350)),
  FloorRoomDef(name: 'Bathroom',         bounds: Rect.fromLTWH(0.60, 0.000, 0.12, 0.325)),
  FloorRoomDef(name: 'Main Corridor',    bounds: Rect.fromLTWH(0.40, 0.350, 0.20, 0.375)),
  FloorRoomDef(name: 'Private Corridor', bounds: Rect.fromLTWH(0.60, 0.325, 0.12, 0.400)),
  FloorRoomDef(name: 'Entrance Hall',    bounds: Rect.fromLTWH(0.24, 0.725, 0.48, 0.113)),
  FloorRoomDef(name: 'Bedroom 1',        bounds: Rect.fromLTWH(0.72, 0.000, 0.20, 0.500)),
  FloorRoomDef(name: 'Guest Bathroom',   bounds: Rect.fromLTWH(0.92, 0.000, 0.08, 0.275)),
  FloorRoomDef(name: 'Bedroom 2',        bounds: Rect.fromLTWH(0.72, 0.500, 0.28, 0.350)),
  FloorRoomDef(name: 'Balcony',          bounds: Rect.fromLTWH(0.00, 0.850, 0.40, 0.150), openPlan: true),
];

// ═══════════════════════════════════════════════════════════════════════════════
// Public widget
// ═══════════════════════════════════════════════════════════════════════════════

class ApartmentFloorPlan extends StatelessWidget {
  final List<String>               rooms;
  final int  Function(String)      onCount;
  final int  Function(String)      totalLights;
  final Color  Function(String)    roomColor;
  final IconData Function(String)  roomIcon;
  final void Function(String)      onTap;

  const ApartmentFloorPlan({
    super.key,
    required this.rooms,
    required this.onCount,
    required this.totalLights,
    required this.roomColor,
    required this.roomIcon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1.25,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;

          final activeColors = <String, Color>{
            for (final def in apartmentLayout)
              if (rooms.contains(def.name) && onCount(def.name) > 0)
                def.name: roomColor(def.name),
          };

          return Container(
            decoration: BoxDecoration(
              color: const Color(0xFF06060F),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: C.border, width: 0.5),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(children: [

                // Blueprint grid
                CustomPaint(
                  size: Size(w, h),
                  painter: _GridPainter(),
                ),

                // Room fills
                ...apartmentLayout.map((def) {
                  final on     = onCount(def.name);
                  final total  = totalLights(def.name);
                  final color  = roomColor(def.name);
                  final active = on > 0;
                  final known  = rooms.contains(def.name);
                  final tiny   = def.bounds.width <= 0.12 ||
                                  def.bounds.height <= 0.15;

                  return Positioned(
                    left:   def.bounds.left   * w,
                    top:    def.bounds.top    * h,
                    width:  def.bounds.width  * w,
                    height: def.bounds.height * h,
                    child: GestureDetector(
                      onTap: known
                          ? () {
                              HapticFeedback.mediumImpact();
                              onTap(def.name);
                            }
                          : null,
                      child: AnimatedContainer(
                        duration: Dur.normal,
                        color: active
                            ? color.withAlpha(20)
                            : known
                                ? const Color(0xFF0C0C1E)
                                : const Color(0xFF080812),
                        child: tiny
                            ? null
                            : _RoomLabel(
                                name:   def.name,
                                icon:   roomIcon(def.name),
                                color:  color,
                                on:     on,
                                total:  total,
                                active: active,
                                known:  known,
                              ),
                      ),
                    ),
                  );
                }),

                // Walls + glow overlay
                CustomPaint(
                  size: Size(w, h),
                  painter: _WallPainter(w: w, h: h, activeColors: activeColors),
                ),
              ]),
            ),
          );
        },
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Room label
// ═══════════════════════════════════════════════════════════════════════════════

class _RoomLabel extends StatelessWidget {
  final String   name;
  final IconData icon;
  final Color    color;
  final int      on, total;
  final bool     active, known;

  const _RoomLabel({
    required this.name,  required this.icon,  required this.color,
    required this.on,    required this.total,
    required this.active, required this.known,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // Icon
        AnimatedContainer(
          duration: Dur.normal,
          width: 26, height: 26,
          decoration: BoxDecoration(
            color: active ? color.withAlpha(35) : Colors.white.withAlpha(5),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Icon(icon,
            color: active ? color : (known ? C.textTri : C.textDim),
            size: 13),
        ),
        // Name + dots
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              name,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: active ? C.textPri : (known ? C.textTri : C.textDim),
                letterSpacing: -0.2,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (total > 0 && known) ...[
              const SizedBox(height: 4),
              Wrap(
                spacing: 3, runSpacing: 3,
                children: List.generate(total, (i) {
                  final isOn = i < on;
                  return AnimatedContainer(
                    duration: Dur.fast,
                    width: 4, height: 4,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isOn ? color : C.border,
                      boxShadow: isOn
                          ? [BoxShadow(color: color.withAlpha(160),
                              blurRadius: 4)]
                          : null,
                    ),
                  );
                }),
              ),
            ],
          ],
        ),
      ],
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// Wall painter — draws interior walls, doors, active glows
// ═══════════════════════════════════════════════════════════════════════════════

class _WallPainter extends CustomPainter {
  final double             w, h;
  final Map<String, Color> activeColors;

  const _WallPainter({
    required this.w, required this.h, required this.activeColors});

  @override
  void paint(Canvas canvas, Size size) {
    final wall = Paint()
      ..color = const Color(0xFF3A3A6A)
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.square
      ..style = PaintingStyle.stroke;

    final dashed = Paint()
      ..color = const Color(0xFF2A2A52)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    // ── Interior walls (normalised 0–1, logW=100 × logH=80) ─────────────────

    // Vertical: Living+Dining | Kitchen+Corridor
    _line(canvas, wall, 0.40, 0.000, 0.40, 0.725);
    // Vertical: Kitchen+Corridor | Bathroom+PrivCorr
    _line(canvas, wall, 0.60, 0.000, 0.60, 0.725);
    // Vertical: bedroom wing left
    _line(canvas, wall, 0.72, 0.000, 0.72, 0.850);
    // Vertical: Bedroom 1 | Guest Bathroom
    _line(canvas, wall, 0.92, 0.000, 0.92, 0.275);
    // Vertical: Entrance Hall left wall
    _line(canvas, wall, 0.24, 0.725, 0.24, 0.838);

    // Horizontal: Kitchen bottom / Main Corridor top
    _line(canvas, wall, 0.40, 0.350, 0.60, 0.350);
    // Horizontal: Bathroom bottom / Private Corridor top
    _line(canvas, wall, 0.60, 0.325, 0.72, 0.325);
    // Horizontal: Guest Bathroom bottom
    _line(canvas, wall, 0.92, 0.275, 1.00, 0.275);
    // Horizontal: Bedroom 1 / Bedroom 2 divider
    _line(canvas, wall, 0.72, 0.500, 1.00, 0.500);
    // Horizontal: Entrance Hall top (left segment)
    _line(canvas, wall, 0.24, 0.725, 0.40, 0.725);
    // Horizontal: Entrance Hall bottom
    _line(canvas, wall, 0.24, 0.838, 0.72, 0.838);
    // Horizontal: Balcony top / Dining bottom
    _line(canvas, wall, 0.00, 0.850, 0.40, 0.850);

    // ── Dashed open-plan divider: Living ↔ Dining ─────────────────────────
    _dashed(canvas, dashed, 0.00, 0.500, 0.40, 0.500);

    // ── Active room glows ─────────────────────────────────────────────────
    for (final entry in activeColors.entries) {
      final def = apartmentLayout
          .where((d) => d.name == entry.key)
          .firstOrNull;
      if (def == null) continue;

      final glow = Paint()
        ..color = entry.value.withAlpha(70)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

      canvas.drawRect(
        Rect.fromLTWH(
          def.bounds.left   * w + 1,
          def.bounds.top    * h + 1,
          def.bounds.width  * w - 2,
          def.bounds.height * h - 2,
        ),
        glow,
      );
    }
  }

  void _line(Canvas c, Paint p, double x1, double y1, double x2, double y2) {
    c.drawLine(Offset(x1 * w, y1 * h), Offset(x2 * w, y2 * h), p);
  }

  void _dashed(Canvas c, Paint p,
      double x1, double y1, double x2, double y2) {
    const segLen = 8.0, gapLen = 5.0;
    final dx = (x2 - x1) * w;
    final dy = (y2 - y1) * h;
    final total = math.sqrt(dx * dx + dy * dy);
    var pos = 0.0;
    while (pos < total) {
      final end = math.min(pos + segLen, total);
      c.drawLine(
        Offset(x1 * w + dx * (pos / total), y1 * h + dy * (pos / total)),
        Offset(x1 * w + dx * (end / total), y1 * h + dy * (end / total)),
        p,
      );
      pos += segLen + gapLen;
    }
  }

  @override
  bool shouldRepaint(_WallPainter old) =>
      old.activeColors.length != activeColors.length;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Blueprint grid
// ═══════════════════════════════════════════════════════════════════════════════

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0xFF10102A)
      ..strokeWidth = 0.5;
    const step = 18.0;
    for (double x = 0; x < size.width;  x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }

  @override
  bool shouldRepaint(_GridPainter _) => false;
}
