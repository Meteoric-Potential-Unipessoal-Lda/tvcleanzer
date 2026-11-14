// Store screenshots on the built-in demo TV.
// Run: tools/store_shots.sh  (iOS simulator, every language)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tvcleanzer/l10n/l10n.dart';
import 'package:tvcleanzer/main.dart' as app;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  Future<void> wait(WidgetTester t, int ms) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await t.pump();
    }
  }

  /// Waits until [f] shows up (real network/demo delays), then a bit more
  /// so entry animations finish.
  Future<void> waitFor(WidgetTester t, Finder f, {int timeoutMs = 60000}) async {
    final end = DateTime.now().add(Duration(milliseconds: timeoutMs));
    var n = 0;
    while (f.evaluate().isEmpty) {
      if (DateTime.now().isAfter(end)) fail('not found: $f');
      await wait(t, 200);
      // ignore: avoid_print
      if (++n % 50 == 0) print('STEP still waiting (${n ~/ 5}s) for $f');
    }
    await wait(t, 900);
  }

  /// Text finder that ignores case (section headers are upper-cased).
  Finder txt(String s) => find.byWidgetPredicate((w) {
        final d = w is Text ? (w.data ?? w.textSpan?.toPlainText()) : null;
        return d != null && d.toLowerCase() == s.toLowerCase();
      }, description: 'text "$s"');

  Future<void> tap(WidgetTester t, Finder f) async {
    await waitFor(t, f.hitTestable());
    await t.tap(f.hitTestable().first);
    await wait(t, 300);
  }

  // tools/store_shots.sh watches the log for "SHOT <name>" and grabs the
  // simulator screen (real status bar, full resolution).
  Future<void> shot(WidgetTester t, String name) async {
    await wait(t, 600);
    // ignore: avoid_print
    print('SHOT ${appLanguage}_$name');
    await wait(t, 2500);
  }

  void step(String s) {
    // ignore: avoid_print
    print('STEP $s');
  }

  testWidgets('store screenshots', (t) async {
    step('start');
    app.main();
    // Splash waits for the ADB key: a fresh install generates RSA-2048,
    // which is slow in a debug build on the simulator.
    await waitFor(t, txt(tr('Нет телевизора рядом? Попробовать демо')), timeoutMs: 600000);

    step('home ready');
    // 1. Scan of the demo TV
    await tap(t, txt(tr('Нет телевизора рядом? Попробовать демо')));
    await waitFor(t, txt(tr('Рекомендуем убрать')));
    await shot(t, '1_scan');

    step('scan done');
    // 2. Speed-up with before/after
    await tap(t, txt(tr('Пуск')));
    await waitFor(t, txt(tr('Телевизор ускорен')));
    await wait(t, 1500); // counters
    await shot(t, '4_boost');
    await tap(t, txt(tr('Отлично')));
    await wait(t, 800);

    step('boost done');
    // 3. Cleaning result
    await tap(t, find.ancestor(
      of: find.byIcon(Icons.cleaning_services_rounded),
      matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
    ));
    await tap(t, txt(tr('Очистить')));
    await waitFor(t, txt(tr('Телевизор очищен!')), timeoutMs: 40000);
    await wait(t, 1200);
    await shot(t, '2_result');

    // 4. Home with the TV found
    await tap(t, txt(tr('Готово')));
    await wait(t, 1500);
    await shot(t, '6_home');

    step('home done');
    // 5. Launcher
    await tap(t, find.byIcon(Icons.dashboard_customize_outlined));
    final check = txt(tr('Проверить')).hitTestable();
    if (check.evaluate().isNotEmpty) {
      await t.tap(check.first);
      await wait(t, 2500);
    }
    await wait(t, 1000);
    await shot(t, '3_launcher');

    step('launcher done');
    // 6. Remote
    await tap(t, find.byIcon(Icons.settings_remote_outlined));
    await tap(t, txt(tr('Домой')));
    await wait(t, 2500);
    await shot(t, '5_remote');

    step('remote done');
    // 7. History
    await tap(t, find.byIcon(Icons.history_rounded));
    await wait(t, 1200);
    await shot(t, '7_history');
  });
}
