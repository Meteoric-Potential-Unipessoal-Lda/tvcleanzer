import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The owner's own names for TVs («Кухня», «Спальня») — asked for in the chat; with two TVs of the
/// same model the list showed the same name twice. Kept by IP address (what identifies a TV in
/// the list); reports «?» keep the real model.
class TvNames {
  TvNames._();

  static const _key = 'tv_names';
  static final Map<String, String> _names = {};

  static String? of(String ip) => _names[ip];

  static Future<void> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw != null) {
        _names
          ..clear()
          ..addAll((jsonDecode(raw) as Map).map((k, v) => MapEntry('$k', '$v')));
      }
    } catch (_) {}
  }

  /// Empty name = back to the model name.
  static Future<void> set(String ip, String name) async {
    final n = name.trim();
    if (n.isEmpty) {
      _names.remove(ip);
    } else {
      _names[ip] = n.length > 40 ? n.substring(0, 40) : n;
    }
    try {
      await (await SharedPreferences.getInstance()).setString(_key, jsonEncode(_names));
    } catch (_) {}
  }
}

/// Bumped on every rename so cards and banners rebuild.
final tvNamesRevProvider = StateProvider<int>((ref) => 0);
