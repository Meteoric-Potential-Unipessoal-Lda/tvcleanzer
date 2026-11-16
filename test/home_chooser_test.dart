import 'package:flutter_test/flutter_test.dart';
import 'package:tvcleanzer/services/adb_package_manager.dart';

void main() {
  const xml = '<?xml version="1.0"?><hierarchy rotation="0">'
      '<node index="0" text="" resource-id="android:id/resolver_list" bounds="[0,300][1920,900]">'
      '<node index="0" text="Haier Home" resource-id="android:id/text1" bounds="[120,360][900,420]" />'
      '<node index="1" text="TVCleanzer" resource-id="android:id/text1" bounds="[120,460][900,520]" />'
      '</node>'
      '<node index="1" text="Только сейчас" resource-id="android:id/button_once" bounds="[1100,940][1400,1000]" />'
      '<node index="2" text="Всегда" resource-id="android:id/button_always" bounds="[1450,940][1750,1000]" />'
      '</hierarchy>';

  test('home chooser: our launcher and the "Always" button are found', () {
    expect(AdbPackageManager.uiPoint(xml, (t, _) => t == 'TVCleanzer'), (510, 490));
    expect(AdbPackageManager.uiPoint(xml, (_, id) => id == 'android:id/button_always'), (1600, 970));
    expect(AdbPackageManager.uiPoint(xml, (t, _) => t == 'Нет такого'), isNull);
  });
}
