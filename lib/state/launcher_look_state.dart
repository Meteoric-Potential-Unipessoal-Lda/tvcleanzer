import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/launcher_look.dart';

/// Fine launcher settings chosen on the phone; sent to the TV with the skin.
final launcherLookProvider =
    StateNotifierProvider<LauncherLookNotifier, LauncherLook>((ref) => LauncherLookNotifier());

class LauncherLookNotifier extends StateNotifier<LauncherLook> {
  LauncherLookNotifier() : super(const LauncherLook()) {
    _load();
  }

  static const _key = 'launcher_look';

  Future<void> _load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_key);
      if (raw != null) state = LauncherLook.fromMap(jsonDecode(raw) as Map<String, Object?>);
    } catch (_) {}
  }

  Future<void> set(LauncherLook look) async {
    state = look;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_key, jsonEncode(look.toJson()));
    } catch (_) {}
  }
}
