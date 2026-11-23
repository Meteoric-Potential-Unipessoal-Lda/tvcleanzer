import 'package:flutter_test/flutter_test.dart';
import 'package:tvcleanzer/models/launcher_look.dart';
import 'package:tvcleanzer/services/adb_package_manager.dart';

/// Launcher 0.68: small icons in the corner (default), the favourites frame, glass under the clock.
void main() {
  test('defaults: mini corner, frame on the left, no glass', () {
    const l = LauncherLook();
    expect(l.barStyle, 2);
    expect(l.favAlign, 1);
    expect(l.clockGlass, isFalse);
    expect(l.extras, contains('--ei barStyle 2 --ei favAlign 1 --ez clockGlass false'));
  });

  test('read back from the launcher and from saved JSON', () {
    final l = LauncherLook.fromMap({'barStyle': '0', 'favAlign': '2', 'clockGlass': '1'});
    expect(l.barStyle, 0);
    expect(l.favAlign, 2);
    expect(l.clockGlass, isTrue);
    final j = LauncherLook.fromMap(l.copyWith(barStyle: 1).toJson());
    expect(j.barStyle, 1);
    expect(j.favAlign, 2);
    expect(LauncherLook.fromMap({'barStyle': '9'}).barStyle, 2);
  });

  test('the app carries launcher 0.68', () {
    expect(AdbPackageManager.bundledLauncherVersion, greaterThanOrEqualTo(68));
  });
}
