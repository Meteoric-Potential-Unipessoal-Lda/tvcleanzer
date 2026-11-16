import 'package:flutter_test/flutter_test.dart';
import 'package:tvcleanzer/services/adb_package_manager.dart';
import 'package:tvcleanzer/services/demo_tv.dart';

void main() {
  test('demo TV: Google Play is on, nothing to turn back on', () async {
    DemoTv.reset();
    final api = AdbPackageManager();
    expect(await api.googlePlayHidden(DemoTv.device()), isFalse);
    expect(await api.restoreGooglePlay(DemoTv.device()), isA<bool>());
  });
}
