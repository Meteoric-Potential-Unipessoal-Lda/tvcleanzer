import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/launcher_skin.dart';

final selectedSkinProvider =
    StateNotifierProvider<SelectedSkinNotifier, LauncherSkin>(
        (ref) => SelectedSkinNotifier());

class SelectedSkinNotifier extends StateNotifier<LauncherSkin> {
  SelectedSkinNotifier() : super(LauncherSkin.all.first);

  static const _key = 'launcher_skin';

  Future<void> load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      state = LauncherSkin.byId(sp.getString(_key));
    } catch (_) {}
  }

  Future<void> select(LauncherSkin s) async {
    state = s;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_key, s.id);
    } catch (_) {}
  }
}
