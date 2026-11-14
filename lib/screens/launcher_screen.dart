import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/launcher_look.dart';
import '../models/launcher_skin.dart';
import '../services/adb_client.dart';
import '../services/adb_package_manager.dart';
import '../services/app_log.dart';
import '../state/current_tv.dart';
import '../state/launcher_look_state.dart';
import '../state/launcher_skin_state.dart';
import '../theme/app_theme.dart';
import 'launcher_edit_screen.dart';

import '../l10n/l10n.dart';
final _knownLaunchers = {
  'com.google.android.tvlauncher': tr('Стандартный Android TV'),
  'com.google.android.apps.tv.launcherx': 'Google TV',
  'com.mitv.tvhome': 'Xiaomi PatchWall',
  'com.mitv.tvhome.atv': 'Xiaomi PatchWall',
  'com.yandex.tv.home': tr('Яндекс ТВ'),
  'ru.sberdevices.starlauncher': tr('Салют ТВ (Сбер)'),
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
  int? _version;        // launcher versionCode on the TV
  Timer? _lookDebounce;

  @override
  void dispose() {
    _lookDebounce?.cancel();
    super.dispose();
  }

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
      _version = _installed == true ? await api.launcherVersion(tv) : null;
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
            look: ref.read(launcherLookProvider),
            onStep: (s) { if (mounted) setState(() => _step = s); },
          );
      _installed = true;
      _version = AdbPackageManager.bundledLauncherVersion;
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

  /// Fine settings: saved on the phone, sent to the TV a moment after the last change.
  void _setLook(LauncherLook look) {
    HapticFeedback.selectionClick();
    ref.read(launcherLookProvider.notifier).set(look);
    final tv = ref.read(currentTvProvider);
    if (tv == null || _installed != true) return;
    _lookDebounce?.cancel();
    _lookDebounce = Timer(const Duration(milliseconds: 400), () {
      ref.read(adbServiceProvider).applyLauncherLook(tv, ref.read(launcherLookProvider)).catchError((_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(tr('Не получилось: телевизор не отвечает.'))));
        }
      });
    });
  }

  bool get _outdated =>
      _installed == true && _version != null && _version! < AdbPackageManager.bundledLauncherVersion;

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
    final look = ref.watch(launcherLookProvider);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Лаунчер'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _SkinPreview(skin: skin, look: look),
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
          const Gap(20),
          _label(tr('Тонкая настройка')),
          const Gap(10),
          _lookCard(look),
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

  Widget _lookCard(LauncherLook look) {
    Widget seg(String title, List<String> labels, int value, ValueChanged<int> onChanged) =>
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 13, color: AppColors.fgMid)),
          const Gap(6),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<int>(
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                selectedBackgroundColor: AppColors.accentDim,
                selectedForegroundColor: AppColors.accent,
                foregroundColor: AppColors.fgMid,
                side: const BorderSide(color: AppColors.cardBd),
              ),
              segments: [
                for (var i = 0; i < labels.length; i++)
                  ButtonSegment<int>(value: i, label: Text(labels[i], maxLines: 1, overflow: TextOverflow.ellipsis)),
              ],
              selected: {value},
              onSelectionChanged: (v) => onChanged(v.first),
            ),
          ),
        ]);
    Widget sw(String title, String? sub, bool value, ValueChanged<bool> onChanged) => SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(title, style: const TextStyle(fontSize: 14, color: AppColors.fg)),
          subtitle: sub == null
              ? null
              : Text(sub, style: const TextStyle(fontSize: 12, color: AppColors.fgMuted)),
          value: value,
          onChanged: onChanged,
        );
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        seg(tr('Анимации'), [tr('Полные'), tr('Мягкие'), tr('Выкл.')], look.anim,
            (v) => _setLook(look.copyWith(anim: v))),
        const Gap(14),
        seg(tr('Размер плиток'), [tr('Мелкие'), tr('Обычные'), tr('Крупные')], look.tiles,
            (v) => _setLook(look.copyWith(tiles: v))),
        const Gap(14),
        seg(tr('Подсветка выбора'), [tr('Белая'), tr('Цвет шкурки')], look.ringAccent ? 1 : 0,
            (v) => _setLook(look.copyWith(ringAccent: v == 1))),
        const Gap(6),
        sw(tr('Живой фон'), tr('Свечение медленно плывёт по экрану'), look.ambient,
            (v) => _setLook(look.copyWith(ambient: v))),
        sw(tr('Часы 24 часа'), null, look.clock24, (v) => _setLook(look.copyWith(clock24: v))),
        sw(tr('Названия под всеми плитками'), tr('Иначе — только у выбранной'), look.labels,
            (v) => _setLook(look.copyWith(labels: v))),
        const Gap(4),
        Text(
          _outdated
              ? tr('Эти настройки появились в новой версии лаунчера: нажмите «Обновить лаунчер на ТВ» ниже.')
              : tr('Слабый телевизор подтормаживает? Выключите анимации и живой фон.'),
          style: TextStyle(fontSize: 12, height: 1.4, color: _outdated ? AppColors.warn : AppColors.fgMuted),
        ),
      ]),
    );
  }

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
        if (_outdated) ...[
          const Gap(10),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.new_releases_rounded, size: 18, color: AppColors.warn),
            const Gap(8),
            Expanded(
              child: Text(tr('Есть новая версия лаунчера: тонкие настройки, живой фон, новые шкурки и надёжная загрузка фото. Нажмите «Обновить лаунчер на ТВ».'),
                  style: const TextStyle(fontSize: 13, color: AppColors.warn, height: 1.4)),
            ),
          ]),
        ],
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
  final LauncherLook look;
  const _SkinPreview({required this.skin, required this.look});

  static const _d = Duration(milliseconds: 450);

  @override
  Widget build(BuildContext context) {
    final ring = look.ringAccent ? skin.accent : Colors.white;
    final focusScale = switch (look.anim) { 2 => 1.0, 1 => 1.03, _ => 1.06 };
    final cols = const [7, 6, 5][look.tiles];
    final favs = const [5, 4, 3][look.tiles];
    final live = look.ambient && look.anim != 2;
    Widget tile({bool focused = false, double radius = 8}) => AnimatedContainer(
          duration: _d,
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: focused ? skin.accent.withValues(alpha: .25) : skin.tile,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
                color: focused ? ring : Colors.transparent, width: 2),
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
        child: Stack(clipBehavior: Clip.none, children: [
          // accent glow; drifts when "live background" is on
          Positioned(
            right: -40,
            top: -60,
            child: _Glow(color: skin.accent, size: 170, live: live),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
              Expanded(child: AnimatedScale(
                  scale: focusScale, duration: _d, child: tile(focused: true))),
              for (var i = 1; i < favs; i++) ...[
                const Gap(8),
                Expanded(child: tile()),
              ],
            ]),
          ),
          const Gap(10),
          Text(tr('Приложения'), style: const TextStyle(fontSize: 10, color: Colors.white60)),
          const Gap(6),
          SizedBox(
            height: 26,
            child: Row(children: [
              for (var i = 0; i < cols; i++) ...[
                if (i > 0) const Gap(6),
                Expanded(child: tile(radius: 6)),
              ],
            ]),
          ),
        ]),
        ]),
      ),
    );
  }
}

/// Soft accent glow of the preview; slowly moves like the TV's live background.
class _Glow extends StatelessWidget {
  final Color color;
  final double size;
  final bool live;
  const _Glow({required this.color, required this.size, required this.live});

  @override
  Widget build(BuildContext context) {
    final glow = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(colors: [color.withValues(alpha: .22), color.withValues(alpha: 0)]),
      ),
    );
    if (!live) return glow;
    return glow
        .animate(key: ValueKey(color), onPlay: (c) => c.repeat(reverse: true))
        .move(begin: Offset.zero, end: const Offset(-26, 14), duration: 5.seconds, curve: Curves.easeInOut);
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
