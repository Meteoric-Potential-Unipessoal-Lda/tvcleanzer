import 'dart:convert';
import 'dart:io';

import '../models/launcher_look.dart';

/// 1.3.168 «Поделиться видом»: the launcher's look as a code a friend types or pastes into their
/// TVCleanzer (an idea from couch-tv's design codes). Only what differs from the defaults, plus
/// the theme; never the city (weather), apps or favourites. «TVC1-» + gzip + base64url.
class LookCode {
  LookCode._();

  static const prefix = 'TVC1-';

  /// Personal or not about the look: left out of the code.
  static const _private = {'weatherCity', 'lat', 'lon', 'showCity'};

  static String encode(LauncherLook look, String skinId) {
    final def = const LauncherLook().toJson();
    final m = <String, Object>{
      for (final e in look.toJson().entries)
        if (!_private.contains(e.key) && def[e.key] != e.value) e.key: e.value,
      'skin': skinId,
    };
    final z = gzip.encode(utf8.encode(jsonEncode(m)));
    return prefix + base64Url.encode(z).replaceAll('=', '');
  }

  /// The look's settings and 'skin' from a code (spaces and line breaks don't matter); null when
  /// it is not a code.
  static Map<String, Object?>? decode(String code) {
    var s = code.replaceAll(RegExp(r'\s'), '');
    final i = s.indexOf(prefix);
    if (i < 0) return null;
    s = s.substring(i + prefix.length);
    if (s.isEmpty || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(s)) return null;
    while (s.length % 4 != 0) {
      s += '=';
    }
    try {
      final m = jsonDecode(utf8.decode(gzip.decode(base64Url.decode(s))));
      if (m is! Map) return null;
      return {
        for (final e in m.entries)
          if (e.key is String && !_private.contains(e.key)) e.key as String: e.value,
      };
    } catch (_) {
      return null;
    }
  }

  /// The look from a code over [current]: the code's settings, the defaults for the rest, the
  /// owner's own city kept.
  static LauncherLook apply(LauncherLook current, Map<String, Object?> code) => LauncherLook.fromMap({
        ...const LauncherLook().toJson(),
        ...code,
        'weatherCity': current.weatherCity,
        'lat': current.lat,
        'lon': current.lon,
        'showCity': current.showCity,
      });
}
