import 'package:shared_preferences/shared_preferences.dart';

/// Recent search queries. Kept on device and never leave it.
///
/// This is privacy boundary, not just convenience: server intentionally never
/// logs or stores search query text (`AGENTS.md`, "Where to find logs"), so
/// search history cannot exist anywhere except device. List is short —
/// quick suggestion, not an archive.
class RecentQueries {
  RecentQueries({
    this.limit = 10,
    Future<SharedPreferences>? store,
    String? namespace,
  }) : _store = store ?? SharedPreferences.getInstance(),
       _key = namespace == null ? key : '$namespace/$key';

  static const key = 'recent-queries';

  final int limit;
  final Future<SharedPreferences> _store;
  final String _key;

  Future<List<String>> load() async {
    try {
      return (await _store).getStringList(_key) ?? const [];
    } catch (_) {
      // Storage unavailable — non-fatal: suggestions disappear, search
      // keeps working. Never crash screen because of history.
      return const [];
    }
  }

  /// Remember query. Repeated query moves to top without duplication.
  Future<List<String>> remember(String query) async {
    final text = query.trim();
    if (text.isEmpty) {
      return load();
    }
    final kept = [
      text,
      ...(await load()).where(
        (item) => item.toLowerCase() != text.toLowerCase(),
      ),
    ];
    final cut = kept.take(limit).toList();
    try {
      await (await _store).setStringList(_key, cut);
    } catch (_) {
      // Write failed — list remains as before on next launch.
    }
    return cut;
  }

  Future<void> clear() async {
    try {
      await (await _store).remove(_key);
    } catch (_) {
      // Nothing to clear or storage unavailable.
    }
  }
}
