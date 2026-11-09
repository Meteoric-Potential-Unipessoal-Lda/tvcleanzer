import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/adb_client.dart';
import '../state/current_tv.dart';
import '../state/history.dart';
import '../state/launcher_skin_state.dart';
import '../theme/app_theme.dart';
import 'root_shell.dart';

/// Animated loader shown right after the native splash. Loads saved state
/// and prepares the ADB key (the first launch spends a few seconds on it).
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});
  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  String _status = 'Загружаем…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    final started = DateTime.now();
    await Future.wait([
      ref.read(historyProvider.notifier).load(),
      ref.read(currentTvProvider.notifier).load(),
      ref.read(selectedSkinProvider.notifier).load(),
    ]);
    if (!await AdbClient.hasKeys() && mounted) {
      setState(() => _status = 'Создаём ключ для подключения к ТВ…');
    }
    try {
      await AdbClient.warmUp();
    } catch (_) {
      // Will be retried on the first connection.
    }
    // Keep the animation on screen long enough to read, but no longer.
    final left = const Duration(milliseconds: 1400) - DateTime.now().difference(started);
    if (left > Duration.zero) await Future.delayed(left);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 450),
      pageBuilder: (_, __, ___) => const RootShell(),
      transitionsBuilder: (_, anim, __, child) => FadeTransition(
        opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
        child: child,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(children: [
        // Soft accent glow behind the logo
        Center(
          child: Container(
            width: 260,
            height: 260,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [
                AppColors.accent.withValues(alpha: .22),
                AppColors.accent.withValues(alpha: 0),
              ]),
            ),
          )
              .animate(onPlay: (c) => c.repeat(reverse: true))
              .scale(
                begin: const Offset(.85, .85),
                end: const Offset(1.1, 1.1),
                duration: 1600.ms,
                curve: Curves.easeInOut,
              ),
        ),
        Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: Image.asset('assets/icon/icon.png', width: 112, height: 112),
            )
                .animate()
                .scale(
                  begin: const Offset(.6, .6),
                  duration: 650.ms,
                  curve: Curves.elasticOut,
                )
                .fadeIn(duration: 300.ms)
                .then(delay: 200.ms)
                .shimmer(duration: 1200.ms, color: Colors.white24),
            const Gap(24),
            Text('TVCleanzer',
                    style: GoogleFonts.syne(
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        color: AppColors.fg,
                        letterSpacing: -.5))
                .animate()
                .fadeIn(delay: 250.ms, duration: 400.ms)
                .slideY(begin: .3, end: 0, curve: Curves.easeOutCubic),
            const Gap(6),
            const Text('Чистый телевизор без лишнего',
                    style: TextStyle(color: AppColors.fgMid, fontSize: 14))
                .animate()
                .fadeIn(delay: 400.ms, duration: 400.ms),
          ]),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 72,
          child: Column(children: [
            const _DotsLoader(),
            const Gap(14),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Text(_status,
                  key: ValueKey(_status),
                  style: const TextStyle(color: AppColors.fgMuted, fontSize: 12)),
            ),
          ]).animate().fadeIn(delay: 500.ms),
        ),
      ]),
    );
  }
}

class _DotsLoader extends StatelessWidget {
  const _DotsLoader();
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        return Container(
          width: 8,
          height: 8,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          decoration: const BoxDecoration(
              color: AppColors.accent, shape: BoxShape.circle),
        )
            .animate(onPlay: (c) => c.repeat())
            .scaleXY(begin: .5, end: 1, delay: (i * 160).ms, duration: 420.ms, curve: Curves.easeOut)
            .then()
            .scaleXY(begin: 1, end: .5, duration: 420.ms, curve: Curves.easeIn);
      }),
    );
  }
}
