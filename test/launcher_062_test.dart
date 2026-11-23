import 'package:flutter_test/flutter_test.dart';
import 'package:tvcleanzer/models/launcher_look.dart';
import 'package:tvcleanzer/services/adb_package_manager.dart';

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
}
