import 'package:shared_preferences/shared_preferences.dart';

/// Local-only "favorite lights" list for the Resident dashboard's Favorites
/// row. Deliberately client-side and per-device (not synced to the
/// backend) — favoriting a light is a personal shortcut, not an
/// authorization decision, so it doesn't belong in the permission model.
class FavoritesService {
  static const _key = 'favorite_dali_channels';

  static Future<Set<int>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? const [];
    return raw.map(int.parse).toSet();
  }

  static Future<void> save(Set<int> channels) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, channels.map((c) => c.toString()).toList());
  }
}
