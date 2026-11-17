import 'package:shared_preferences/shared_preferences.dart';

/// TVs the owner typed in by IP address ("Enter the TV's IP"). The search only walks the
/// phone's own /24 network, so a TV on another subnet, behind a mesh node or on a wider
/// network was never found (a Sony Android 7 report). These addresses are probed on every
/// search too.
class ManualTvs {
  ManualTvs._();

  static const _key = 'manual_tvs';
  static const max = 8;

  /// "ip:port" → (ip, port). Port 5555 when it is missing.
  static (String, int)? parse(String raw) {
    final m = RegExp(r'^\s*(\d{1,3}(?:\.\d{1,3}){3})\s*(?::\s*(\d{2,5}))?\s*$').firstMatch(raw);
    if (m == null) return null;
    final ip = m.group(1)!;
    if (ip.split('.').map(int.parse).any((n) => n > 255)) return null;
    final port = m.group(2) == null ? 5555 : int.parse(m.group(2)!);
    if (port < 1 || port > 65535) return null;
    return (ip, port);
  }

  static Future<List<(String, int)>> load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return (sp.getStringList(_key) ?? const []).map(parse).whereType<(String, int)>().toList();
    } catch (_) {
      return const [];
    }
  }

  /// Newest first; the same IP replaces its old entry.
  static Future<void> remember(String ip, int port) async {
    try {
      final sp = await SharedPreferences.getInstance();
      final list = (sp.getStringList(_key) ?? const []).where((e) => parse(e)?.$1 != ip).toList();
      await sp.setStringList(_key, ['$ip:$port', ...list].take(max).toList());
    } catch (_) {}
  }

  static Future<void> forget(String ip) async {
    try {
      final sp = await SharedPreferences.getInstance();
      final list = (sp.getStringList(_key) ?? const []).where((e) => parse(e)?.$1 != ip).toList();
      await sp.setStringList(_key, list);
    } catch (_) {}
  }
}
