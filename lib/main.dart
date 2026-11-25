import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'l10n/l10n.dart';
import 'services/app_log.dart';
import 'services/tip_jar.dart';
import 'services/tv_names.dart';
import 'screens/splash_screen.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 1.3.164: a part of a screen that fails to build or lay out shows as a blank space in a release
  // build (Haier tester: the remote's buttons under the arrows were gone) and «?» said nothing.
  // Now the error goes into «?» with where it happened, and the place says so on the screen.
  FlutterError.onError = (d) {
    final where = (d.stack?.toString() ?? '')
        .split('\n')
        .where((l) => l.contains('package:tvcleanzer/'))
        .take(3)
        .map((l) => l.replaceAll(RegExp(r'^#\d+\s+'), '').trim())
        .join(' ← ');
    AppLog.error('ui', '${d.exceptionAsString()}${where.isEmpty ? '' : ' @ $where'}');
    FlutterError.presentError(d);
  };
  ErrorWidget.builder = (d) => Container(
        padding: const EdgeInsets.all(8),
        color: const Color(0x33FF5252),
        child: Text(tr('Ошибка на экране. Нажмите «?» → «Сообщить о проблеме» и пришлите отчёт.'),
            style: const TextStyle(fontSize: 12, color: Color(0xFFFFFFFF))),
      );
  initLanguage();
  await TvNames.load();

  // 1.3.166: Android 15+ draws the app under the navigation bar (edge to edge, forced for our
  // target SDK). Without asking for it the app was not told how tall the bar is: with three-button
  // navigation the bottom tabs and the «?» sheet («Сообщить о проблеме» hidden) went under it
  // (Samsung S24, Haier tester; Danil: «текст заходит за меню навигации»). Edge to edge on
  // purpose: the bars are transparent and their height reaches SafeArea.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  // Keep status bar translucent and use light icons on dark bg
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarContrastEnforced: false,
  ));

  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Store builds: listen for tip purchases from the start (the store may finish one later).
  TipJar.instance.init();

  runApp(
    const ProviderScope(child: TvCleanzerApp()),
  );
}

class TvCleanzerApp extends StatelessWidget {
  const TvCleanzerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TVCleanzer',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.buildTheme(),
      home: const SplashScreen(),
      locale: Locale(appLanguage),
      supportedLocales: [for (final l in supportedLanguages) Locale(l)],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      // 1.3.166: nothing under the phone's navigation bar — screens, sheets and dialogs end above
      // it (the bar's strip shows the app's background)
      builder: (context, child) => _DesktopFrame(
        child: Platform.isAndroid
            ? ColoredBox(
                color: AppColors.bg,
                child: SafeArea(top: false, left: false, right: false, child: child!),
              )
            : child!,
      ),
    );
  }
}

/// On a PC window the phone layout stays a centered column: the whole
/// navigator (sheets and dialogs too) lives inside it.
class _DesktopFrame extends StatelessWidget {
  const _DesktopFrame({required this.child});
  final Widget child;
  static const _maxWidth = 520.0;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    if (mq.size.width <= _maxWidth + 80) return child;
    return ColoredBox(
      color: const Color(0xFF070B16),
      child: Center(
        child: Container(
          width: _maxWidth,
          decoration: const BoxDecoration(
            boxShadow: [BoxShadow(color: Color(0x66000000), blurRadius: 40)],
          ),
          child: MediaQuery(
            data: mq.copyWith(size: Size(_maxWidth, mq.size.height)),
            child: ClipRect(child: child),
          ),
        ),
      ),
    );
  }
}
