import 'package:flutter_test/flutter_test.dart';
import 'package:tvcleanzer/services/adb_package_manager.dart';
import 'package:tvcleanzer/services/protection.dart';
import 'package:tvcleanzer/l10n/l10n.dart';

void main() {
  test('Yandex TV and Sber core packages are never removed', () {
    for (final p in [
      'com.yandex.tv.home', 'com.yandex.tv.services', 'com.yandex.tv.services.core',
      'com.yandex.tv.settings', 'com.yandex.tv.setupwizard', 'com.yandex.tv.live',
      'com.yandex.tv.input.hdmi', 'com.yandex.io.sdk', 'com.yandex.webview',
      'com.yandex.launcher.updaterapp', 'ru.yandex.androidkeyboard.tv',
      'ru.sberdevices.services', 'ru.sberdevices.services.core', 'ru.sberdevices.assistant',
      'ru.sberdevices.tvinputs', 'ru.sberdevices.app.starkeyboard', 'ru.sberdevices.webview',
      'ru.sberdevices.starlauncher', 'ru.sberdevices.starmarket', 'ru.sberdevices.updater',
      'com.sberbank.settings', 'com.cvte.fac.menu', 'com.cvte.factory.at', 'com.stb.factorymenu',
      'com.cvte.tv.setting', 'com.example.upgrad', 'com.google.android.tv',
    ]) {
      expect(Protection.isProtected(p), isTrue, reason: p);
    }
  });

  test('Yandex and Sber extras stay removable', () {
    for (final p in [
      'com.yandex.android.advid', 'com.yandex.tv.bugreportsender', 'com.yandex.tv.alice',
      'com.yandex.tv.input.efir', 'com.yandex.tv.daydream', 'ru.sberdevices.survey',
      'ru.sberdevices.starcleaner', 'ru.sberdevices.subscriptions', 'ru.sberdevices.music',
      'com.salute.star', 'com.cvte.tv.pictorial', 'com.cvte.dssshare.dlna',
    ]) {
      expect(Protection.isProtected(p), isFalse, reason: p);
    }
  });

  test('Sber and Yandex firmwares disable instead of uninstalling', () {
    expect(AdbPackageManager.usesDisable(['android', 'ru.sberdevices.services']), isTrue);
    expect(AdbPackageManager.usesDisable(['com.yandex.tv.services']), isTrue);
    expect(AdbPackageManager.usesDisable(['com.google.android.tvlauncher']), isFalse);
  });

  test('package reason: description first, list count on its own line', () {
    final r = trReason('Браузер: уберите, если не открываете сайты на телевизоре · скрывают в 2 из 472 проверенных списков');
    final lines = r.split('\n');
    expect(lines.length, 2);
    expect(lines[1], contains('472'));
    expect(trReason('Обычное приложение: уберите, если не пользуетесь').contains('\n'), isFalse);
  });
}
