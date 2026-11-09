import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/launcher_skin.dart';
import '../services/adb_package_manager.dart';
import '../state/current_tv.dart';
import '../state/launcher_skin_state.dart';
import '../theme/app_theme.dart';

const _knownLaunchers = {
  'com.google.android.tvlauncher': 'Стандартный Android TV',
  'com.google.android.apps.tv.launcherx': 'Google TV',
  'com.mitv.tvhome': 'Xiaomi PatchWall',
  'com.mitv.tvhome.atv': 'Xiaomi PatchWall',
  'com.spocky.projengmenu': 'Projectivy Launcher',
  'me.efesser.flauncher': 'FLauncher',
  'com.tvcleanzer.launcher': 'TVCleanzer Launcher',
};

class LauncherScreen extends ConsumerStatefulWidget {
  const LauncherScreen({super.key});
  @override
  ConsumerState<LauncherScreen> createState() => _LauncherScreenState();
}

class _LauncherScreenState extends ConsumerState<LauncherScreen> {
  bool _checking = false;
  bool _checked = false;
  String? _launcher;
  String? _error;

  Future<void> _check() async {
    final tv = ref.read(currentTvProvider);
    if (tv == null) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final pkg = await ref.read(adbServiceProvider).currentLauncher(tv);
      _launcher = pkg;
      _checked = true;
    } catch (_) {
      _error = 'Телевизор не отвечает. Проверьте, что он включён и в той же Wi-Fi сети.';
    }
    if (mounted) setState(() => _checking = false);
  }

  @override
  Widget build(BuildContext context) {
    final skin = ref.watch(selectedSkinProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Лаунчер')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _SkinPreview(skin: skin),
          const Gap(20),
          _label('Шкурки'),
          const Gap(10),
          SizedBox(
            height: 108,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: LauncherSkin.all.length,
              separatorBuilder: (_, __) => const Gap(10),
              itemBuilder: (_, i) {
                final s = LauncherSkin.all[i];
                return _SkinChip(
                  skin: s,
                  selected: s.id == skin.id,
                  onTap: () => ref.read(selectedSkinProvider.notifier).select(s),
                ).animate(delay: (i * 50).ms).fadeIn().slideX(begin: .2, end: 0);
              },
            ),
          ),
          const Gap(24),
          _currentLauncherCard(),
          const Gap(12),
          _ourLauncherCard(),
        ],
      ),
    );
  }

  Widget _label(String text) => Text(text.toUpperCase(),
      style: const TextStyle(
          fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: .8, color: AppColors.fgMuted));

  Widget _card({required Widget child}) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.bgCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.cardBd),
        ),
        child: child,
      );

  Widget _currentLauncherCard() {
    final tv = ref.watch(currentTvProvider);
    String body;
    if (tv == null) {
      body = 'Выберите телевизор на вкладке «Очистка».';
    } else if (_error != null) {
      body = _error!;
    } else if (!_checked) {
      body = 'Узнаем, какой лаунчер сейчас главный на «${tv.shortName.isEmpty ? tv.ipAddress : tv.shortName}».';
    } else if (_launcher == null) {
      body = 'Главный лаунчер не выбран: телевизор спрашивает при нажатии «Домой».';
    } else {
      body = _knownLaunchers[_launcher] ?? _launcher!;
    }
    return _card(
      child: Row(children: [
        const Icon(Icons.home_rounded, color: AppColors.accent),
        const Gap(12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Сейчас на телевизоре',
                style: TextStyle(fontSize: 12, color: AppColors.fgMuted)),
            const Gap(2),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Text(body,
                  key: ValueKey(body),
                  style: TextStyle(
                      fontSize: 14,
                      color: _error != null ? AppColors.danger : AppColors.fg,
                      fontWeight: _checked ? FontWeight.w600 : FontWeight.w400)),
            ),
          ]),
        ),
        if (tv != null) ...[
          const Gap(8),
          _checking
              ? const SizedBox(
                  width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
              : TextButton(onPressed: _check, child: Text(_checked ? 'Обновить' : 'Проверить')),
        ],
      ]),
    );
  }

  Widget _ourLauncherCard() => _card(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('TVCleanzer Launcher',
                style: GoogleFonts.syne(
                    fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.fg)),
            const Gap(8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.warn.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(50),
              ),
              child: const Text('в разработке',
                  style: TextStyle(fontSize: 11, color: AppColors.warn, fontWeight: FontWeight.w600)),
            ),
          ]),
          const Gap(8),
          const Text(
            'Свой лаунчер для телевизора: шкурка, порядок приложений и обои '
            'настраиваются отсюда, с телефона. Выберите шкурку уже сейчас — '
            'она применится сразу после установки.',
            style: TextStyle(fontSize: 13, color: AppColors.fgMid, height: 1.5),
          ),
          const Gap(12),
          const SizedBox(
            width: double.infinity,
            child: FilledButton(onPressed: null, child: Text('Установить на ТВ — скоро')),
          ),
        ]),
      );
}

/// Mock of the TV home screen in the selected skin. Colours animate on change.
class _SkinPreview extends StatelessWidget {
  final LauncherSkin skin;
  const _SkinPreview({required this.skin});

  static const _d = Duration(milliseconds: 450);

  @override
  Widget build(BuildContext context) {
    Widget tile({bool focused = false, double radius = 8}) => AnimatedContainer(
          duration: _d,
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: focused ? skin.accent.withValues(alpha: .25) : skin.tile,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
                color: focused ? skin.accent : Colors.transparent, width: 2),
          ),
        );

    return AspectRatio(
      aspectRatio: 16 / 9,
      child: AnimatedContainer(
        duration: _d,
        curve: Curves.easeOut,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.cardBd),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [skin.bgTop, skin.bgBottom],
          ),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            AnimatedContainer(
              duration: _d,
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: skin.accent, shape: BoxShape.circle),
            ),
            const Gap(6),
            Text(skin.name,
                style: const TextStyle(fontSize: 11, color: Colors.white70)),
            const Spacer(),
            const Text('20:45',
                style: TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w600)),
          ]),
          const Spacer(),
          const Text('Избранное', style: TextStyle(fontSize: 10, color: Colors.white60)),
          const Gap(6),
          SizedBox(
            height: 40,
            child: Row(children: [
              Expanded(child: Transform.scale(scale: 1.06, child: tile(focused: true))),
              const Gap(8),
              Expanded(child: tile()),
              const Gap(8),
              Expanded(child: tile()),
              const Gap(8),
              Expanded(child: tile()),
            ]),
          ),
          const Gap(10),
          const Text('Приложения', style: TextStyle(fontSize: 10, color: Colors.white60)),
          const Gap(6),
          SizedBox(
            height: 26,
            child: Row(children: [
              for (var i = 0; i < 6; i++) ...[
                if (i > 0) const Gap(6),
                Expanded(child: tile(radius: 6)),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

class _SkinChip extends StatelessWidget {
  final LauncherSkin skin;
  final bool selected;
  final VoidCallback onTap;
  const _SkinChip({required this.skin, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          width: 112,
          height: 72,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [skin.bgTop, skin.bgBottom],
            ),
            border: Border.all(
              color: selected ? skin.accent : AppColors.cardBd,
              width: selected ? 2.5 : 1,
            ),
            boxShadow: selected
                ? [BoxShadow(color: skin.accent.withValues(alpha: .35), blurRadius: 14)]
                : const [],
          ),
          child: Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: AnimatedScale(
                scale: selected ? 1 : 0,
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutBack,
                child: Icon(Icons.check_circle_rounded, color: skin.accent, size: 20),
              ),
            ),
          ),
        ),
        const Gap(6),
        Text(skin.name,
            style: TextStyle(
                fontSize: 12,
                color: selected ? AppColors.fg : AppColors.fgMid,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
      ]),
    );
  }
}
