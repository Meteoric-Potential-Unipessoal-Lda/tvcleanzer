import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'screens/splash_screen.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Keep status bar translucent and use light icons on dark bg
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
  ));

  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

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
      builder: (context, child) => _DesktopFrame(child: child!),
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
