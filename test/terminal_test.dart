import 'package:flutter_test/flutter_test.dart';
import 'package:tvcleanzer/services/demo_tv.dart';
import 'package:tvcleanzer/services/terminal.dart';

void main() {
  test('terminal: control codes are cleaned', () {
    expect(cleanTerminal('\x1B]0;title\x07\x1B[32mok\x1B[0m\r\nnext\r'), 'ok\nnext');
  });

  test('terminal: quotes and dashes from an iPhone chat become plain', () {
    expect(terminalPlain('dumpsys window | grep -E \u00ABmCurrentFocus|mFocusedApp\u00BB'),
        'dumpsys window | grep -E "mCurrentFocus|mFocusedApp"');
    expect(terminalPlain('pm list packages -d | grep -E \u201Clauncherx|setupwraith\u201D'),
        'pm list packages -d | grep -E "launcherx|setupwraith"');
    expect(terminalPlain('pm disable-user \u2014user 0 com.example'), 'pm disable-user --user 0 com.example');
    expect(terminalPlain("echo \u2018hi\u2019"), "echo 'hi'");
    expect(terminalPlain('pm list packages -3'), 'pm list packages -3');
  });

  test('terminal: risky commands ask first, ordinary ones do not', () {
    expect(terminalDanger('ls -l /sdcard'), isNull);
    expect(terminalDanger('pm list packages -3'), isNull);
    expect(terminalDanger('pm uninstall -k --user 0 com.google.android.feedback'), isNull);
    expect(terminalDanger('rm -rf /sdcard/Download'), isNotNull);
    expect(terminalDanger('pm uninstall com.example.app'), isNotNull);
    expect(terminalDanger('pm disable-user --user 0 com.android.systemui'), isNotNull);
    expect(terminalDanger('pm clear com.example.app'), isNotNull);
    expect(terminalDanger('reboot recovery'), isNotNull);
    expect(terminalDanger('settings delete secure enabled_accessibility_services'), isNotNull);
  });

  test('terminal: demo TV session answers commands', () async {
    DemoTv.reset();
    final s = await TerminalSession.open(DemoTv.device());
    final out = StringBuffer();
    final sub = s.output.listen(out.write);
    await s.run('pm list packages -3');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(out.toString(), contains('package:'));
    await sub.cancel();
    await s.close();
  });
}
