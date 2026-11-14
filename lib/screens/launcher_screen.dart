import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/launcher_skin.dart';
import '../services/adb_client.dart';
import '../services/adb_package_manager.dart';
import '../services/app_log.dart';
import '../state/current_tv.dart';
import '../state/launcher_skin_state.dart';
import '../theme/app_theme.dart';
import 'launcher_edit_screen.dart';

import '../l10n/l10n.dart';
final _knownLaunchers = {
  'com.google.android.tvlauncher': tr('Стандартный Android TV'),
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
  bool? _installed;     // TVCleanzer Launcher on the TV (null = unknown)
  String? _step;        // install/uninstall progress text
  String? _installError;

  static final _offline =
      tr('Телевизор не отвечает. Проверьте, что он включён и в той же Wi-Fi сети.');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check(silent: true));
  }

  Future<void> _check({bool silent = false}) async {
    final tv = ref.read(currentTvProvider);
    if (tv == null || _checking) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final api = ref.read(adbServiceProvider);
      final pkg = await api.currentLauncher(tv);
      _launcher = pkg;
      _installed = pkg == AdbPackageManager.launcherPkg || await api.isLauncherInstalled(tv);
      _checked = true;
    } catch (_) {
      if (!silent) _error = _offline;
    }
    if (mounted) setState(() => _checking = false);
  }

  Future<void> _install() async {
    final tv = ref.read(currentTvProvider);
    if (tv == null) return;
    setState(() {
      _installError = null;
      _step = tr('Готовим лаунчер…');
    });
    try {
      Uint8List apk;
      try {
        final data = await rootBundle.load('assets/launcher/tvcleanzer-launcher.apk');
        apk = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } catch (_) {
        throw AdbException(tr('Лаунчер ещё не собран: запустите launcher/build.sh и пересоберите приложение.'));
      }
      await ref.read(adbServiceProvider).installLauncher(
            tv, apk, ref.read(selectedSkinProvider).id,
            onStep: (s) { if (mounted) setState(() => _step = s); },
          );
      _installed = true;
      _launcher = AdbPackageManager.launcherPkg;
      _checked = true;
    } on AdbException catch (e) {
      AppLog.error('launcher install', e);
      _installError = e.message;
    } catch (e) {
      AppLog.error('launcher install', e);
      _installError = _offline;
    }
    if (mounted) setState(() => _step = null);
  }

  Future<void> _uninstall() async {
    final tv = ref.read(currentTvProvider);
    if (tv == null) return;
    setState(() {
      _installError = null;
      _step = tr('Возвращаем стандартный лаунчер…');
    });
    try {
      await ref.read(adbServiceProvider).uninstallLauncher(tv);
      _installed = false;
      _checked = false;
      _launcher = null;
    } catch (_) {
      _installError = _offline;
    }
    if (mounted) setState(() => _step = null);
    _check(silent: true);
  }

  /// Pick a skin; if the launcher is already on the TV, apply it right away.
  void _selectSkin(LauncherSkin s) {
    ref.read(selectedSkinProvider.notifier).select(s);
    final tv = ref.read(currentTvProvider);
    if (tv != null && _installed == true) {
      ref.read(adbServiceProvider).applyLauncherSkin(tv, s.id).catchError((_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(tr('Не удалось применить шкурку: телевизор не отвечает.'))));
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final skin = ref.watch(selectedSkinProvider);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Лаунчер'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _SkinPreview(skin: skin),
          const Gap(20),
          _label(tr('Шкурки')),
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
                  onTap: () => _selectSkin(s),
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
      body = tr('Выберите телевизор на вкладке «Очистка».');
    } else if (_error != null) {
      body = _error!;
    } else if (!_checked) {
      body = tr('Узнаем, какой лаунчер сейчас главный на «{0}».', [tv.shortName.isEmpty ? tv.ipAddress : tv.shortName]);
    } else if (_launcher == null) {
      body = tr('Главный лаунчер не выбран: телевизор спрашивает при нажатии «Домой».');
    } else {
      body = _knownLaunchers[_launcher] ?? tr('Лаунчер производителя ({0})', [_launcher]);
    }
    return _card(
      child: Row(children: [
        const Icon(Icons.home_rounded, color: AppColors.accent),
        const Gap(12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Сейчас на телевизоре'),
                style: const TextStyle(fontSize: 12, color: AppColors.fgMuted)),
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
              : TextButton(onPressed: _check, child: Text(_checked ? tr('Обновить') : tr('Проверить'))),
        ],
      ]),
    );
  }

  Widget _ourLauncherCard() {
    final tv = ref.watch(currentTvProvider);
    final busy = _step != null;
    final installed = _installed == true;
    final (chipText, chipColor) = installed
        ? (tr('установлен'), AppColors.ok)
        : (tr('не установлен'), AppColors.fgMid);
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('TVCleanzer Launcher',
              style: GoogleFonts.syne(
                  fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.fg)),
          const Gap(8),
          if (_installed != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: chipColor.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(50),
              ),
              child: Text(chipText,
                  style: TextStyle(fontSize: 11, color: chipColor, fontWeight: FontWeight.w600)),
            ),
        ]),
        const Gap(8),
        Text(
          installed
              ? tr('Шкурка меняется сразу: просто выберите другую выше. На телевизоре: долгое нажатие OK на приложении — добавить в избранное, переставить или скрыть; шестерёнка — настройки.')
              : tr('Лёгкий красивый лаунчер: часы, избранное, все приложения, шкурки. Меньше 100 КБ, работает даже на слабых телевизорах (Android 7+).'),
          style: const TextStyle(fontSize: 13, color: AppColors.fgMid, height: 1.5),
        ),
        if (_installError != null) ...[
          const Gap(10),
          Text(_installError!,
              style: const TextStyle(fontSize: 13, color: AppColors.danger, height: 1.4)),
        ],
        const Gap(12),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: busy
              ? Row(key: const ValueKey('busy'), children: [
                  const SizedBox(
                      width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  const Gap(12),
                  Expanded(
                      child: Text(_step!,
                          style: const TextStyle(color: AppColors.fg, fontSize: 14))),
                ])
              : SizedBox(
                  key: ValueKey(installed),
                  width: double.infinity,
                  child: installed
                      ? Column(children: [
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              icon: const Icon(Icons.tune_rounded),
                              label: Text(tr('Настроить: избранное, детям, обои')),
                              onPressed: tv == null ? null : () => Navigator.push(context,
                                  MaterialPageRoute(builder: (_) => LauncherEditScreen(tv: tv))),
                            ),
                          ),
                          const Gap(10),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.fg,
                                side: const BorderSide(color: AppColors.cardBd),
                                padding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                              icon: const Icon(Icons.system_update_alt_rounded),
                              label: Text(tr('Обновить лаунчер на ТВ')),
                              onPressed: tv == null ? null : _install,
                            ),
                          ),
                          const Gap(10),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                          icon: const Icon(Icons.undo_rounded, size: 18),
                          label: Text(tr('Вернуть стандартный лаунчер')),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.fg,
                            side: const BorderSide(color: AppColors.cardBd),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          onPressed: tv == null ? null : _uninstall,
                            ),
                          ),
                        ])
                      : FilledButton.icon(
                          icon: const Icon(Icons.download_rounded),
                          label: Text(tr('Установить на телевизор')),
                          onPressed: tv == null ? null : _install,
                        ),
                ),
        ),
      ]),
    );
  }
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
          Text(tr('Избранное'), style: const TextStyle(fontSize: 10, color: Colors.white60)),
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
          Text(tr('Приложения'), style: const TextStyle(fontSize: 10, color: Colors.white60)),
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
