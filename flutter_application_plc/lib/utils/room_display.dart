/// Presentation-only room-name formatting. Every device/room grouping,
/// filter, and API request still uses the raw room string exactly as the
/// backend sent it — this only decides what a human reads on screen, so a
/// future raw DB value (a new placeholder name, inconsistent casing from a
/// commissioning import, etc.) can never leak into the UI unformatted
/// again without someone having to actively bypass this function.
///
/// Deliberately NOT a database migration: the raw value is legitimate
/// grouping/join data (equality checks throughout dashboard_screen.dart
/// key off it), and a technician's Reconfigure Devices / Apartment
/// Management screens should still show what's actually stored. Only the
/// resident-facing renders below go through this.
class RoomDisplay {
  RoomDisplay._();

  /// Raw values (case-insensitive) that mean "no real room set" — shown as
  /// a friendly catch-all instead of exposing the backend's internal
  /// placeholder. Covers both find_device.plc.registry's own fallback
  /// ('Unassigned', for devices with no Room FK at all) and a literal
  /// "not assigned" placeholder Room row, seen live in Apartment 16's data.
  static const _unassignedValues = {'unassigned', 'not assigned', ''};

  static bool isUnassigned(String raw) => _unassignedValues.contains(raw.trim().toLowerCase());

  /// The friendly label for a raw room string — title-cased, with the
  /// unassigned placeholder mapped to a plain "Other" rather than exposing
  /// database terminology to a resident.
  static String label(String raw) {
    if (isUnassigned(raw)) return 'Other';
    return _titleCase(raw.trim());
  }

  static String _titleCase(String s) {
    if (s.isEmpty) return s;
    return s.split(RegExp(r'\s+')).map((word) {
      if (word.isEmpty) return word;
      // Leave anything already containing a capital past the first letter
      // alone (acronyms like "AC", "TV", ordinals like "2nd") — only fix
      // the common all-lowercase case ("shower" -> "Shower").
      final restHasUpper = word.substring(1).contains(RegExp(r'[A-Z]'));
      if (restHasUpper) return word;
      return word[0].toUpperCase() + word.substring(1).toLowerCase();
    }).join(' ');
  }
}
