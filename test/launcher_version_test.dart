import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvcleanzer/services/adb_package_manager.dart';

/// The phone decides whether to update the TV's launcher by [AdbPackageManager.bundledLauncherVersion].
/// Forgetting to bump it (1.3.62–1.3.63) left every 0.55 TV un-updated with no hint.
void main() {
  test('bundledLauncherVersion = launcher/AndroidManifest.xml versionCode', () {
    final manifest = File('launcher/AndroidManifest.xml').readAsStringSync();
    final code = int.parse(RegExp(r'versionCode="(\d+)"').firstMatch(manifest)!.group(1)!);
    expect(AdbPackageManager.bundledLauncherVersion, code);
  });
}
