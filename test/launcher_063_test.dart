import 'package:flutter_test/flutter_test.dart';
import 'package:tvcleanzer/models/launcher_look.dart';
import 'package:tvcleanzer/services/adb_package_manager.dart';

/// Launcher 0.63: the Bluetooth pill can be hidden from the phone.
void main() {
  test('Bluetooth pill travels to the TV and back', () {
    expect(const LauncherLook().btPill, isTrue);
    final l = LauncherLook.fromMap({'btPill': '0'});
    expect(l.btPill, isFalse);
    expect(l.extras, contains('--ez btPill false'));
    expect(LauncherLook.fromMap(l.toJson()).btPill, isFalse);
    expect(LauncherLook.fromMap({}).btPill, isTrue);
    expect(AdbPackageManager.bundledLauncherVersion, greaterThanOrEqualTo(63));
  });
}
