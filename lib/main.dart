import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'screens/home_screen.dart';
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
    const ProviderScope(child: TvClearApp()),
  );
}

class TvClearApp extends StatelessWidget {
  const TvClearApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TVCleanzer',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.buildTheme(),
      home: const HomeScreen(),
    );
  }
}
