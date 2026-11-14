import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvcleanzer/services/adb_client.dart';
import 'package:tvcleanzer/services/adb_package_manager.dart';
import 'package:tvcleanzer/services/demo_tv.dart';

Uint8List _zip(Map<String, List<int>> files) {
  final a = Archive();
  for (final e in files.entries) {
    a.addFile(ArchiveFile(e.key, e.value.length, Uint8List.fromList(e.value)));
  }
  return Uint8List.fromList(ZipEncoder().encode(a));
}

void main() {
  test('apksIn: plain APK, split bundle, and not an app', () {
    final apk = _zip({'AndroidManifest.xml': [1, 2, 3], 'classes.dex': [4]});
    expect(AdbPackageManager.apksIn('a.apk', apk).single.$1, 'a.apk');

    final bundle = _zip({
      'split_config.armeabi_v7a.apk': [1],
      'base.apk': [2, 2],
      'manifest.json': [3],
      'icon.png': [4],
    });
    final parts = AdbPackageManager.apksIn('app.xapk', bundle);
    expect(parts.map((p) => p.$1), ['base.apk', 'split_config.armeabi_v7a.apk']);

    expect(() => AdbPackageManager.apksIn('x.apk', Uint8List.fromList([1, 2, 3])),
        throwsA(isA<AdbException>()));
  });

  test('demo TV: install an APK, list, open and uninstall it', () async {
    DemoTv.reset();
    final api = AdbPackageManager();
    final tv = DemoTv.device();
    final apk = _zip({'AndroidManifest.xml': [1]});
    final pkg = await api.installApk(tv, 'SmartTube.apk', apk);
    expect(pkg, 'org.smarttube.stable');
    final apps = await api.listApps(tv);
    final st = apps.firstWhere((a) => a.pkg == pkg);
    expect(st.user, isTrue);
    expect(st.label, 'SmartTube');
    expect(apps.first.user, isTrue); // owner's apps first
    expect(await api.openApp(tv, pkg), isTrue);
    expect(await api.uninstallApp(tv, pkg), isTrue);
    expect((await api.listApps(tv)).any((a) => a.pkg == pkg), isFalse);

    final bundle = _zip({'base.apk': [1], 'split_config.ru.apk': [2]});
    expect(await api.installApk(tv, 'SmartTube.apks', bundle), 'org.smarttube.stable');
  });
}
