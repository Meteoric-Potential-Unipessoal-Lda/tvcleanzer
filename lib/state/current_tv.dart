import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/tv_device.dart';

/// The TV the user worked with last. Used by the Launcher and Remote tabs.
final currentTvProvider =
    StateNotifierProvider<CurrentTvNotifier, TvDevice?>((ref) => CurrentTvNotifier());

class CurrentTvNotifier extends StateNotifier<TvDevice?> {
  CurrentTvNotifier() : super(null);

  static const _key = 'current_tv';

  /// Leaves the demo: back to the last real TV, or to no TV at all.
  Future<void> restoreSaved() async {
    state = null;
    await load();
  }

  Future<void> load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_key);
      if (raw == null) return;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      state = TvDevice.fromAdb(
        ip: m['ip'] as String,
        port: (m['port'] as num?)?.toInt() ?? 5555,
        brand: m['brand'] as String? ?? '',
        model: m['model'] as String? ?? '',
        androidVer: m['androidVer'] as String? ?? '',
        sdkVersion: (m['sdk'] as num?)?.toInt() ?? 0,
        ramMb: (m['ramMb'] as num?)?.toInt() ?? 0,
        ramFreeMb: (m['ramFreeMb'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      // corrupted value — start without a TV
    }
  }

  /// «Remove from the list»: no saved TV any more.
  Future<void> forget() async {
    state = null;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove(_key);
    } catch (_) {}
  }

  Future<void> select(TvDevice d) async {
    state = d;
    if (d.isDemo) return; // the demo TV never outlives the app session
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_key, jsonEncode({
        'ip': d.ipAddress,
        'port': d.port,
        'brand': d.brand,
        'model': d.model,
        'androidVer': d.androidVer,
        'sdk': d.sdkVersion,
        'ramMb': d.ramMb,
        'ramFreeMb': d.ramFreeMb,
      }));
    } catch (_) {}
  }
}
