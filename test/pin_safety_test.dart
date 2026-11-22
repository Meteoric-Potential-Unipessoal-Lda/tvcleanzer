import 'package:flutter_test/flutter_test.dart';
import 'package:tvcleanzer/services/adb_package_manager.dart';

/// 1.3.66: what the launcher pinning may switch off, the TV-side guard, the clean reinstall,
/// the Chinese Xiaomi careful mode and the TV language helpers.
void main() {
  test('core packages are never switched off by the pinning (#3, #46)', () {
    expect(AdbPackageManager.unsafeDump('    userId=1000\n    pkgFlags=[ SYSTEM HAS_CODE ]'), 'system uid');
    expect(AdbPackageManager.unsafeDump('    appId=1000'), 'system uid');
    expect(AdbPackageManager.unsafeDump('    sharedUser=SharedUserSetting{1a2b android.uid.system/1000}'), isNotNull);
    expect(AdbPackageManager.unsafeDump('    pkgFlags=[ SYSTEM HAS_CODE PERSISTENT ]'), 'persistent');
    expect(AdbPackageManager.unsafeDump('    userId=10071\n    pkgFlags=[ SYSTEM HAS_CODE ALLOW_CLEAR_USER_DATA ]'), isNull);
    expect(AdbPackageManager.unsafeDump('    userId=10001'), isNull); // 1000 only as a whole number
  });

  test('the guard script puts the homes back unless the check passed', () {
    final s = AdbPackageManager.guardScript(['com.example.home', 'com.tv.launcher'], 150, '42');
    expect(s, isNot(contains("'"))); // it travels inside single quotes
    expect(s, contains('trap "" HUP'));
    expect(s, contains('sleep 150'));
    expect(s, contains('[ ! -f /data/local/tmp/tvcleanzer_ok_42 ]'));
    expect(s, contains('for p in com.example.home com.tv.launcher; do pm install-existing \$p'));
    expect(s, contains('pm enable \$p'));
  });

  test('only a key or leftover problem asks for a clean reinstall (#6, #23)', () {
    expect(AdbPackageManager.needsCleanReinstall(
        'Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: Package com.tvcleanzer.launcher signatures do not match]'), isTrue);
    expect(AdbPackageManager.needsCleanReinstall('Failure [INSTALL_FAILED_DUPLICATE_PERMISSION: perm=x]'), isTrue);
    expect(AdbPackageManager.needsCleanReinstall('Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE]'), isFalse);
    expect(AdbPackageManager.needsCleanReinstall('Failure [INSTALL_FAILED_VERSION_DOWNGRADE]'), isFalse);
  });

  test('Chinese Xiaomi firmware is told from the global one', () {
    expect(AdbPackageManager.chinaXiaomi({'com.mitv.tvhome', 'com.android.vending'}), isTrue);
    expect(AdbPackageManager.chinaXiaomi({'com.xiaomi.mitv.settings', 'com.miui.analytics'}), isTrue);
    expect(AdbPackageManager.chinaXiaomi({'com.mitv.tvhome.atv', 'com.xiaomi.mitv.settings', 'com.android.vending'}), isFalse);
    expect(AdbPackageManager.chinaXiaomi({'com.google.android.tvlauncher', 'com.android.vending'}), isFalse);
  });

  test('TV language is read from getprop / settings lines', () {
    expect(AdbPackageManager.localeFrom('\nnull\nzh-CN\n'), 'zh-CN');
    expect(AdbPackageManager.localeFrom('ru-RU\nzh-CN'), 'ru-RU');
    expect(AdbPackageManager.localeFrom('en-US,ru-RU\n'), 'en-US');
    expect(AdbPackageManager.localeFrom('null\n\n'), '');
    expect(AdbPackageManager.keyboardName('com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME'), 'Gboard');
    expect(AdbPackageManager.keyboardName('com.example.ime/.Svc'), 'com.example.ime');
  });

  test('screen timeout for «Экран и сон»: minutes, never, unknown', () {
    expect(AdbPackageManager.sleepMinutes(600000), 10);
    expect(AdbPackageManager.sleepMinutes(14400000), 240);
    expect(AdbPackageManager.sleepMinutes(AdbPackageManager.neverMs), -1);
    expect(AdbPackageManager.sleepMinutes(0), 0);
    expect(AdbPackageManager.sleepMinutes(-1), 0);
  });
}
