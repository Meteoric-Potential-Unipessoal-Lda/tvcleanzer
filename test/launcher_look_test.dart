import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvcleanzer/models/launcher_look.dart';
import 'package:tvcleanzer/models/tv_device.dart';
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

  test('LauncherLook 0.7: clock home, font, size and weather city', () {
    final l = LauncherLook.fromMap({
      'style': '1', 'clockPos': '0', 'clockSize': '500', 'clockFont': '3',
      'weatherCity': "Saint-Jean d'Arc", 'lat': '51.7682', 'lon': '55.0970',
    });
    expect(l.style, 1);
    expect(l.clockPos, 0);
    expect(l.clockSize, 180);
    expect(l.clockFont, 3);
    expect(l.weatherCity, "Saint-Jean d'Arc");
    expect(l.extras, contains('--ei style 1'));
    expect(l.extras, contains("--es weatherCity 'Saint-Jean d'\\''Arc'"));
    expect(l.extras, contains('--ef lat 51.7682'));
    final off = LauncherLook.fromMap({'weatherCity': '-'});
    expect(off.weatherCity, '');
    expect(off.clockPos, 1);
    expect(off.extras, contains('--es weatherCity ""'));
    expect(off.extras, isNot(contains('--ef lat')));
  });

  test('demo TV: install launcher, send a photo, read fine settings back', () async {
    DemoTv.reset();
    final api = AdbPackageManager();
    final tv = DemoTv.device();
    final bind = await api.installLauncher(tv, Uint8List(100), 'neon',
        look: const LauncherLook(anim: 1, tiles: 0, wallDim: 60));
    expect(bind, LauncherBind.role);
    expect(await api.launcherVersion(tv), AdbPackageManager.bundledLauncherVersion);

    await api.setWallpaper(tv, Uint8List.fromList(List.filled(5000, 7)));
    final st = await api.launcherState(tv);
    expect(st.hasWallpaper, true);
    expect(st.version, AdbPackageManager.bundledLauncherVersion);
    final look = LauncherLook.fromMap(st.settings);
    expect(look.anim, 1);
    expect(look.tiles, 0);
    expect(look.wallDim, 60);

    await api.applyLauncherLook(tv,
        const LauncherLook(style: 1, clockSize: 130, weatherCity: 'Оренбург', lat: 51.77, lon: 55.1));
    final back = LauncherLook.fromMap((await api.launcherState(tv)).settings);
    expect(back.style, 1);
    expect(back.clockSize, 130);
    expect(back.weatherCity, 'Оренбург');

    await api.removeWallpaper(tv);
    expect((await api.launcherState(tv)).hasWallpaper, false);
  });
}
