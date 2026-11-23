import 'package:flutter_test/flutter_test.dart';
import 'package:tvcleanzer/models/launcher_look.dart';
import 'package:tvcleanzer/services/adb_package_manager.dart';
import 'package:tvcleanzer/state/remote.dart';

/// Launcher 0.62: the icon shape (rounded / round) can be set from the phone.
void main() {
  test('icon shape travels to the TV and back', () {
    expect(const LauncherLook().iconShape, 0);
    final l = LauncherLook.fromMap({'iconShape': '1'});
    expect(l.iconShape, 1);
    expect(l.extras, contains('--ei iconShape 1'));
    expect(LauncherLook.fromMap(l.toJson()).iconShape, 1);
    expect(LauncherLook.fromMap({'iconShape': '7'}).iconShape, 1);
    expect(LauncherLook.fromMap({}).iconShape, 0);
    expect(l.copyWith(style: 2).iconShape, 1);
  });

  test('the bundled launcher knows the icon shape extra', () {
    expect(AdbPackageManager.bundledLauncherVersion, greaterThanOrEqualTo(62));
  });

  test('power puts an awake TV to sleep with SLEEP, POWER only as a fallback (#12)', () {
    final c = RemoteController.powerCmd;
    expect(c, contains('input keyevent 223'));
    expect(c, contains('input keyevent 224'));
    expect(c, contains('input keyevent 26'));
    expect(c.indexOf('keyevent 223'), lessThan(c.indexOf('keyevent 26')));
    expect(c, contains('setsid sh -c'));
    expect(c.trimRight(), endsWith('fi'));
  });
}
