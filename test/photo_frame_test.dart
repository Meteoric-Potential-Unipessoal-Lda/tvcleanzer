import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvcleanzer/services/adb_package_manager.dart';
import 'package:tvcleanzer/services/demo_tv.dart';

void main() {
  test('demo TV: photo frame photos, options and screensaver', () async {
    DemoTv.reset();
    final api = AdbPackageManager();
    final tv = DemoTv.device();
    await api.installLauncher(tv, Uint8List(100), 'neon');

    final seen = <int>[];
    await api.addPhotos(tv, [Uint8List.fromList(List.filled(3000, 1)), Uint8List.fromList(List.filled(4000, 2))],
        onProgress: (d, t) => seen.add(d));
    var st = await api.launcherState(tv);
    expect(st.settings['photos'], '2');
    expect(seen.last, 2);

    await api.setPhotoOptions(tv, seconds: 60, homePhotos: true);
    st = await api.launcherState(tv);
    expect(st.settings['photoSec'], '60');
    expect(st.settings['homePhotos'], '1');

    expect(await api.screensaverDelayMin(tv), 15);
    await api.setScreensaverDelayMin(tv, 5);
    expect(await api.screensaverDelayMin(tv), 5);
    expect(await api.startScreensaverNow(tv), isTrue);

    await api.enablePhotoFrame(tv);
    expect(await api.currentDream(tv), AdbPackageManager.photoDream);
    st = await api.launcherState(tv);
    await api.disablePhotoFrame(tv, st.settings['prevDream'] ?? '');
    expect(await api.currentDream(tv), '');

    await api.clearPhotos(tv);
    expect((await api.launcherState(tv)).settings['photos'], '0');
  });
}
