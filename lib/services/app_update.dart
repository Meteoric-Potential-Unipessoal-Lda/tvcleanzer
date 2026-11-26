import 'dart:convert';
import 'dart:io';

import 'app_log.dart';
import 'support.dart';

/// «Обновление из самого приложения» (1.3.188, Sergey: «устал с двух телефонов перекидывать APK»).
/// Telegram / GitHub builds for Android only: Google Play forbids an app updating itself, and the
/// App Store updates iPhones by itself. The newest release on GitHub carries TVCleanzer-<ver>.apk;
/// the phone's browser downloads it and Android's own installer puts it over this one — no
/// install permission for the app itself (Play's rules stay out of it).
class AppUpdate {
  AppUpdate._();

  static const _api =
      'https://api.github.com/repos/Meteoric-Potential-Unipessoal-Lda/tvcleanzer/releases/latest';

  static bool get supported => !Support.storeBuild && Platform.isAndroid;

  /// The newer APK on GitHub as (version, download url), or null (none, offline, a store build).
  static Future<(String, String)?> check() async {
    if (!supported) return null;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(Uri.parse(_api));
      req.headers.set('Accept', 'application/vnd.github+json');
      req.headers.set('User-Agent', 'TVCleanzer/$appVersion');
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 20));
      return pick(jsonDecode(body), appVersion);
    } catch (_) {
      return null; // offline or GitHub unreachable: nothing to offer
    } finally {
      client.close(force: true);
    }
  }

  /// From a GitHub release (decoded JSON): the APK newer than [current], if there is one.
  static (String, String)? pick(Object? release, String current) {
    if (release is! Map) return null;
    final assets = release['assets'];
    if (assets is! List) return null;
    for (final a in assets) {
      if (a is! Map) continue;
      final m = RegExp(r'^TVCleanzer-(\d+(?:\.\d+)+)\.apk$').firstMatch('${a['name']}');
      final url = '${a['browser_download_url'] ?? ''}';
      if (m != null && url.startsWith('https://') && newer(m.group(1)!, current)) return (m.group(1)!, url);
    }
    return null;
  }

  /// [a] is a later version than [b] (1.3.188 > 1.3.99).
  static bool newer(String a, String b) {
    List<int> parts(String s) => s.split('.').map((x) => int.tryParse(x) ?? 0).toList();
    final x = parts(a), y = parts(b);
    for (var i = 0; i < x.length || i < y.length; i++) {
      final p = i < x.length ? x[i] : 0, q = i < y.length ? y[i] : 0;
      if (p != q) return p > q;
    }
    return false;
  }
}
