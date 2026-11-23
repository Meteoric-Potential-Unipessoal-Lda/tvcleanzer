// Screenshots of the «Лаунчер» tab, rendered by Flutter itself (not part of `flutter test`).
// Run:  flutter test test_shots/launcher_shots_test.dart --update-goldens --dart-define=TVC_LANG=ru
// PNGs land in test_shots/goldens/.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvcleanzer/l10n/l10n.dart';
import 'package:tvcleanzer/models/tv_device.dart';
import 'package:tvcleanzer/screens/launcher_screen.dart';
import 'package:tvcleanzer/screens/onboarding_screen.dart';
import 'package:tvcleanzer/services/adb_package_manager.dart';
import 'package:tvcleanzer/state/current_tv.dart';
import 'package:tvcleanzer/theme/app_theme.dart';

final _tv = TvDevice(
  id: 'shot', name: 'Xiaomi TV', brand: 'Xiaomi', model: 'MiTV-MOOQ1', androidVer: '11',
  sdkVersion: 30, ramMb: 2048, ramFreeMb: 900, ipAddress: '192.168.1.50', port: 5555,
  discoveredAt: DateTime(2026, 11, 23),
);

class _Tv extends CurrentTvNotifier {
  _Tv() {
    state = _tv;
  }
}

class _Apm extends AdbPackageManager {
  final String? home;
  final bool installed;
  final int version;
  final Map<String, String> settings;
  _Apm({this.home, this.installed = true, this.version = 62, this.settings = const {}});
  @override
  Future<String?> currentLauncher(TvDevice device) async => home;
  @override
  Future<bool> isLauncherInstalled(TvDevice device) async => installed;
  @override
  Future<int> launcherVersion(TvDevice device) async => version;
  @override
  Future<LauncherState> launcherState(TvDevice device) async => LauncherState(
      apps: const [], kids: false, hasPin: false, hasWallpaper: false, version: version, settings: settings);
}

Future<void> _fonts() async {
  final dir = '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts';
  Future<void> load(String family, List<String> files) async {
    final l = FontLoader(family);
    for (final f in files) {
      final file = File('$dir/$f');
      if (file.existsSync()) l.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    await l.load();
  }
  final roboto = Directory(dir).listSync().map((e) => e.path.split('/').last).where((n) => n.startsWith('Roboto-')).toList();
  await load('Roboto', roboto);
  await load('MaterialIcons', ['MaterialIcons-Regular.otf']);
  for (final f in ['Syne_700', 'Syne_600', 'Syne_regular', 'Syne_800', 'Syne']) {
    await load(f, roboto);
  }
}

/// google_fonts looks for DMSans-*.ttf / Syne-*.ttf in the app's assets and, in a test, throws
/// when they are missing. Serve Roboto under those names through the test asset channel
/// (everything else still comes from the real test assets).
void _fakeGoogleFonts() {
  final dir = '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts';
  Uint8List roboto(String w) {
    final f = File('$dir/Roboto-$w.ttf');
    return (f.existsSync() ? f : File('$dir/Roboto-Regular.ttf')).readAsBytesSync();
  }
  const weights = {
    'Thin': 'Thin', 'ExtraLight': 'Thin', 'Light': 'Light', 'Regular': 'Regular', 'Medium': 'Medium',
    'SemiBold': 'Medium', 'Bold': 'Bold', 'ExtraBold': 'Black', 'Black': 'Black',
  };
  final fonts = <String, Uint8List>{};
  for (final fam in ['DMSans', 'Syne']) {
    weights.forEach((v, r) {
      final b = roboto(r);
      fonts['google_fonts/$fam-$v.ttf'] = b;
      fonts['google_fonts/$fam-${v == 'Regular' ? '' : v}Italic.ttf'] = b;
    });
  }
  final assets = Platform.environment['UNIT_TEST_ASSETS'] ?? 'build/unit_test_assets';
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler('flutter/assets',
      (ByteData? message) async {
    final key = Uri.decodeFull(utf8.decode(message!.buffer.asUint8List(message.offsetInBytes, message.lengthInBytes)));
    final font = fonts[key];
    if (font != null) return ByteData.sublistView(font);
    final file = File('$assets/$key');
    if (key == 'AssetManifest.bin') {
      final real = file.existsSync()
          ? const StandardMessageCodec().decodeMessage(ByteData.sublistView(file.readAsBytesSync())) as Map<Object?, Object?>
          : <Object?, Object?>{};
      return const StandardMessageCodec().encodeMessage(<Object?, Object?>{
        ...real,
        for (final k in fonts.keys) k: [<String, Object?>{'asset': k}],
      });
    }
    return file.existsSync() ? ByteData.sublistView(file.readAsBytesSync()) : null;
  });
}

const _set = {
  'style': '0', 'icons': '1', 'iconShape': '1', 'barClock': '1', 'greeting': '0', 'oneLine': '1',
  'weatherCity': 'Лиссабон', 'favCols': '5', 'clockFont': '1', 'ambient': '1', 'tiles': '1',
};

Future<void> _shot(WidgetTester t, String name, _Apm apm, double h, List<String> open) async {
  t.view.physicalSize = Size(393 * 3, h * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  final base = AppTheme.buildTheme();
  final theme = base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'Roboto'),
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'Roboto'));
  await t.pumpWidget(ProviderScope(
    overrides: [
      adbServiceProvider.overrideWithValue(apm),
      currentTvProvider.overrideWith((ref) => _Tv()),
    ],
    child: MaterialApp(debugShowCheckedModeBanner: false, theme: theme, home: const LauncherScreen()),
  ));
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 250));
  }
  for (final g in open) {
    await t.tap(find.widgetWithText(InkWell, g).first);
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 150));
    }
  }
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
}


/// The first-run connection guide, page by page (taps by visible text).
Future<void> _shotGuide(WidgetTester t, String name, List<String> taps, {double h = 852}) async {
  t.view.physicalSize = Size(393 * 3, h * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  final base = AppTheme.buildTheme();
  final theme = base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'Roboto'),
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'Roboto'));
  await t.pumpWidget(ProviderScope(
    overrides: [adbServiceProvider.overrideWithValue(_Apm(installed: false))],
    child: MaterialApp(debugShowCheckedModeBanner: false, theme: theme, home: const OnboardingScreen(firstRun: true)),
  ));
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 250));
  }
  for (final g in taps) {
    await t.tap(find.text(g).hitTestable().first);
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 150));
    }
  }
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    GoogleFonts.config.allowRuntimeFetching = false;
    _fakeGoogleFonts();
    // test_shots/ is outside test/, so the analyzer doesn't know it's a test
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    await _fonts();
  });

  testWidgets('1 installed, all folded', (t) async {
    t.platformDispatcher.localesTestValue = const [Locale('ru')];
    initLanguage();
    await _shot(t, '1_folded', _Apm(home: AdbPackageManager.launcherPkg, settings: _set), 1750, const []);
  });

  testWidgets('2 groups open', (t) async {
    await _shot(t, '2_open', _Apm(home: AdbPackageManager.launcherPkg, settings: _set), 3300,
        const ['Главный экран', 'Верхняя панель', 'Часы', 'Значки и плитки', 'Фон и анимация']);
  });

  testWidgets('3 old launcher, not Home', (t) async {
    // groups stay open from the previous shot (kept while the app runs)
    await _shot(t, '3_old', _Apm(home: 'com.google.android.tvlauncher', version: 55, settings: _set), 3500, const []);
  });

  testWidgets('4 not installed', (t) async {
    await _shot(t, '4_none', _Apm(home: 'com.mitv.tvhome.atv', installed: false), 3300, const []);
  });

  testWidgets('5 guide: welcome', (t) => _shotGuide(t, '5_welcome', const []));
  testWidgets('6 guide: brand', (t) => _shotGuide(t, '6_brand', const ['Начать']));
  testWidgets('7 guide: home screen', (t) => _shotGuide(t, '7_platform', const ['Начать', 'Haier']));
  testWidgets('8 guide: a step', (t) => _shotGuide(t, '8_step', const ['Начать', 'Haier', 'Android TV', 'Дальше']));
  testWidgets('9 guide: not found', (t) => _shotGuide(t, '9_waiting',
      const ['Начать', 'Haier', 'Android TV', 'Дальше', 'Дальше', 'Дальше', 'Дальше', 'Отладка включена', 'Не находится?'],
      h: 1500));
}
