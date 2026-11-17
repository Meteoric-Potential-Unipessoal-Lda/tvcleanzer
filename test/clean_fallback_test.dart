import 'package:flutter_test/flutter_test.dart';
import 'package:tvcleanzer/models/tv_device.dart';
import 'package:tvcleanzer/services/adb_package_manager.dart';
import 'package:tvcleanzer/services/demo_tv.dart';

void main() {
  test('demo TV: an app that refuses uninstall gets disabled instead', () async {
    DemoTv.reset();
    final api = AdbPackageManager();
    final tv = DemoTv.device();
    final r = await api.clean(tv, const [
      TvPackage(packageName: 'com.xiaomi.floatingframe', sizeMb: 0, verdict: PackageVerdict.remove),
    ]);
    expect(r.failedPackages, isEmpty);
    expect(r.removedCount, 1);
    expect(await api.rollback(tv, r.backupId), isTrue);
    expect(await api.openAppSettings(tv, 'com.xiaomi.floatingframe'), isTrue);
  });

  test('demo TV: an app the owner installed is only switched off, and comes back', () async {
    DemoTv.reset();
    final api = AdbPackageManager();
    final tv = DemoTv.device();
    final r = await api.clean(tv, const [
      TvPackage(packageName: 'org.videolan.vlc', sizeMb: 0, verdict: PackageVerdict.caution),
    ]);
    expect(r.removedCount, 1);
    expect(await api.rollback(tv, r.backupId), isTrue);
  });
}
