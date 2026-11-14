import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvcleanzer/models/launcher_look.dart';
import 'package:tvcleanzer/services/adb_package_manager.dart';
import 'package:tvcleanzer/services/demo_tv.dart';

void main() {
  test('LauncherLook reads the launcher settings rows and clamps values', () {
    final l = LauncherLook.fromMap({
      'anim': '2', 'ringAccent': '1', 'tiles': '9', 'wallDim': '-5',
      'ambient': '0', 'clock24': '1', 'labels': '1',
    });
    expect(l.anim, 2);
    expect(l.ringAccent, true);
    expect(l.tiles, 2);
    expect(l.wallDim, 0);
    expect(l.ambient, false);
    expect(l.labels, true);
    expect(l.extras, contains('--ei tiles 2'));
    expect(l.extras, contains('--ez ambient false'));
  });

  test('demo TV: install launcher, send a photo, read fine settings back', () async {
    DemoTv.reset();
    final api = AdbPackageManager();
    final tv = DemoTv.device();
    await api.installLauncher(tv, Uint8List(100), 'neon',
        look: const LauncherLook(anim: 1, tiles: 0, wallDim: 60));
    expect(await api.launcherVersion(tv), AdbPackageManager.bundledLauncherVersion);

    await api.setWallpaper(tv, Uint8List.fromList(List.filled(5000, 7)));
    final st = await api.launcherState(tv);
    expect(st.hasWallpaper, true);
    expect(st.version, AdbPackageManager.bundledLauncherVersion);
    final look = LauncherLook.fromMap(st.settings);
    expect(look.anim, 1);
    expect(look.tiles, 0);
    expect(look.wallDim, 60);

    await api.removeWallpaper(tv);
    expect((await api.launcherState(tv)).hasWallpaper, false);
  });
}
