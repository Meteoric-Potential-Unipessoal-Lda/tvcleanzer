import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/launcher_look.dart';
import '../models/launcher_skin.dart';
import '../models/tv_device.dart';
import '../services/adb_client.dart';
import '../services/adb_package_manager.dart';
import '../services/app_log.dart';
import '../services/geo.dart';
import '../state/current_tv.dart';
import '../state/launcher_look_state.dart';
import '../state/launcher_skin_state.dart';
import '../theme/app_theme.dart';
import 'launcher_edit_screen.dart';
import '../widgets/support_card.dart';

import '../l10n/l10n.dart';
import '../widgets/tv_switcher.dart';
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
  String? _bindMsg;     // result of the last «make it the home screen»
  bool _bindOk = true;
  String? _weatherErr;  // launcher 0.8+: why the TV could not get the weather
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
      _weatherErr = null;
      if ((_version ?? 0) >= 8) {
        final e = (await api.launcherState(tv)).settings['weatherErr']?.toString() ?? '-';
        if (e != '-' && e.isNotEmpty) {
          _weatherErr = e;
          AppLog.error('launcher weather', e);
        }
      }
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
      final bind = await ref.read(adbServiceProvider).installLauncher(
            tv, apk, ref.read(selectedSkinProvider).id,
            look: ref.read(launcherLookProvider),
            onStep: (s) { if (mounted) setState(() => _step = s); },
          );
      _installed = true;
      _version = AdbPackageManager.bundledLauncherVersion;
      _showBind(bind);
    } on AdbException catch (e) {
      AppLog.error('launcher install', e);
      _installError = e.message;
    } catch (e) {
      AppLog.error('launcher install', e);
      _installError = _offline;
    }
    if (mounted) setState(() => _step = null);
    _check(silent: true);
  }

  void _showBind(LauncherBind b) {
    if (b == LauncherBind.needsGoogleTvHard) {
      _bindOk = false;
      _bindMsg = tr('Лаунчер стоит, но Google TV забирает кнопку «Домой» себе.');
      WidgetsBinding.instance.addPostFrameCallback((_) => _askGoogleTvHard());
      return;
    }
    _bindOk = b != LauncherBind.failed;
    _bindMsg = switch (b) {
      LauncherBind.needsGoogleTvHard => '',
      LauncherBind.role => tr('Готово: кнопка «Домой» открывает TVCleanzer Launcher.'),
      LauncherBind.hard => tr('Готово: прошивка возвращала свой лаунчер, поэтому он убран (вернётся кнопкой «Вернуть стандартный лаунчер»). Кнопка «Домой» открывает TVCleanzer Launcher. Удаляйте наш лаунчер только этой кнопкой, не в настройках телевизора.'),
      LauncherBind.service => tr('Готово: свой лаунчер прошивки остаётся, но кнопку «Домой» и экран при включении перехватывает TVCleanzer Launcher.'),
      LauncherBind.failed => tr('Лаунчер стоит, но телевизор не даёт сделать его главным: «Домой» открывает свой экран. Нажмите «Сделать главным ещё раз»; если не поможет — откройте лаунчер из списка приложений ТВ и пришлите отчёт через «?».'),
    };
  }

  /// Google TV that keeps Home: the only way left is to switch Google TV Home off. Asked,
  /// with the one thing to remember: remove our launcher only with TVCleanzer.
  Future<void> _askGoogleTvHard() async {
    if (!mounted) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('Закрепить лаунчер надёжно?')),
        content: Text(tr('Этот Google TV не даёт перехватить кнопку «Домой». Закрепить TVCleanzer Launcher можно, только выключив родной экран Google TV.\n\nВажно: потом удаляйте наш лаунчер ТОЛЬКО через TVCleanzer (кнопка «Вернуть стандартный лаунчер»). Если удалить его в настройках телевизора, останется чёрный экран — родной экран придётся включать вручную в настройках.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Не надо'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('Закрепить'))),
        ],
      ),
    );
    if (yes == true) await _rebind(googleTvHard: true);
  }

  /// Installed but Home opens something else (firmware took it back): bind again.
  Future<void> _rebind({bool googleTvHard = false}) async {
    final tv = ref.read(currentTvProvider);
    if (tv == null) return;
    setState(() { _installError = null; _bindMsg = null; _step = tr('Делаем главным экраном…'); });
    try {
      _showBind(await ref.read(adbServiceProvider).rebindLauncher(tv,
          googleTvHard: googleTvHard,
          onStep: (s) { if (mounted) setState(() => _step = s); }));
    } catch (_) {
      _installError = _offline;
    }
    if (mounted) setState(() => _step = null);
    _check(silent: true);
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
    } on AdbException catch (e) {
      _installError = e.message;
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

  Future<void> _pickCity(LauncherLook look) async {
    final picked = await showModalBottomSheet<GeoPlace?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.bgCard,
      builder: (_) => const _CitySheet(),
    );
    if (picked == null) return;
    _setLook(picked.name.isEmpty
        ? look.copyWith(weatherCity: '', lat: 0, lon: 0)
        : look.copyWith(weatherCity: picked.name, lat: picked.lat, lon: picked.lon));
    // The TV fetches it right away; ask it how that went.
    if (picked.name.isNotEmpty) {
      Future<void>.delayed(const Duration(seconds: 15), () { if (mounted) _check(silent: true); });
    }
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
              SnackBar(content: Text(tr('Не удалось применить тему: телевизор не отвечает.'))));
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final skin = ref.watch(selectedSkinProvider);
    final look = ref.watch(launcherLookProvider);
    // another TV chosen (switcher in the title, or on the Cleaning tab): look at that one
    ref.listen<TvDevice?>(currentTvProvider, (prev, next) {
      if (prev?.id == next?.id) return;
      setState(() {
        _checked = false;
        _launcher = null;
        _installed = null;
        _version = null;
        _error = null;
        _bindMsg = null;
        _installError = null;
        _weatherErr = null;
      });
      _check(silent: true);
    });
    return Scaffold(
      appBar: AppBar(title: Text(tr('Лаунчер'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          const TvBanner(),
          if (ref.watch(currentTvProvider) != null) const Gap(16),
          _SkinPreview(skin: skin, look: look),
          const Gap(20),
          _label(tr('Тема')),
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
          const Gap(20),
          const SupportCard(compact: true),
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
        seg(tr('Вид главного экрана'), [tr('Плитки'), tr('Часы и док'), tr('Витрина')], look.style,
            (v) => _setLook(look.copyWith(style: v))),
        const Gap(14),
        if (look.style == 2) ...[
          sw(tr('Название приложения над плитками'), null, look.heroTitle,
              (v) => _setLook(look.copyWith(heroTitle: v))),
          const Gap(8),
        ],
        seg(tr('Иконки приложений'), [tr('Авто'), tr('Иконки'), tr('ТВ-баннеры')], look.icons,
            (v) => _setLook(look.copyWith(icons: v))),
        const Gap(14),
        seg(tr('Размер часов'), [tr('Меньше'), tr('Обычные'), tr('Крупнее'), tr('Огромные')],
            const [80, 100, 130, 160].indexOf(look.clockSize).clamp(0, 3),
            (v) => _setLook(look.copyWith(clockSize: const [80, 100, 130, 160][v]))),
        const Gap(14),
        seg(tr('Шрифт часов'), [tr('Тонкий'), tr('Лёгкий'), tr('Обычный'), tr('Узкий'), tr('Жирный')], look.clockFont,
            (v) => _setLook(look.copyWith(clockFont: v))),
        if (look.style == 1) ...[
          const Gap(14),
          seg(tr('Часы на экране'), [tr('Слева'), tr('По центру')], look.clockPos,
              (v) => _setLook(look.copyWith(clockPos: v))),
        ],
        const Gap(6),
        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: const Icon(Icons.wb_cloudy_rounded, color: AppColors.accent),
          title: Text(tr('Погода на главном экране'), style: const TextStyle(fontSize: 14, color: AppColors.fg)),
          subtitle: Text(
              look.weatherCity.isEmpty
                  ? tr('Выключена — нажмите, чтобы выбрать город')
                  : _weatherErr == null
                      ? look.weatherCity
                      : '${look.weatherCity} — ${tr('телевизор не может получить погоду: проверьте, что на нём есть интернет')}',
              style: TextStyle(fontSize: 12, color: _weatherErr == null || look.weatherCity.isEmpty ? AppColors.fgMuted : AppColors.warn)),
          trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.fgMuted),
          onTap: () => _pickCity(look),
        ),
        const Gap(8),
        seg(tr('Анимации'), [tr('Полные'), tr('Мягкие'), tr('Выкл.')], look.anim,
            (v) => _setLook(look.copyWith(anim: v))),
        const Gap(14),
        seg(tr('Размер плиток'), [tr('Мелкие'), tr('Обычные'), tr('Крупные')], look.tiles,
            (v) => _setLook(look.copyWith(tiles: v))),
        const Gap(14),
        if (look.style == 0) ...[
          seg(tr('Избранное на главном экране'), [tr('Один ряд'), tr('По 4'), tr('По 5'), tr('По 6')],
              const [0, 4, 5, 6].contains(look.favCols) ? const [0, 4, 5, 6].indexOf(look.favCols) : 0,
              (v) => _setLook(look.copyWith(favCols: const [0, 4, 5, 6][v]))),
          const Gap(6),
          sw(tr('Приложения на втором экране'), tr('На главном только избранное, приложения — ниже по кнопке ▼'),
              look.appsBelow, (v) => _setLook(look.copyWith(appsBelow: v))),
          const Gap(8),
        ],
        seg(tr('Источники (HDMI)'), [tr('Вверху'), tr('Внизу'), tr('Скрыты')], look.inputs,
            (v) => _setLook(look.copyWith(inputs: v))),
        const Gap(14),
        seg(tr('Подсветка выбора'), [tr('Белая'), tr('Цвет темы')], look.ringAccent ? 1 : 0,
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
              ? tr('Тема меняется сразу: просто выберите другую выше. На телевизоре: долгое нажатие OK на приложении — добавить в избранное, переставить или скрыть; шестерёнка — настройки.')
              : tr('Лёгкий красивый лаунчер: часы, избранное, все приложения, темы. Меньше 100 КБ, работает даже на слабых телевизорах (Android 7+; на Android 5–6 — пробная поддержка).'),
          style: const TextStyle(fontSize: 13, color: AppColors.fgMid, height: 1.5),
        ),
        if (_outdated) ...[
          const Gap(10),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.new_releases_rounded, size: 18, color: AppColors.warn),
            const Gap(8),
            Expanded(
              child: Text(tr('Есть новая версия лаунчера: вид «Витрина», настоящие иконки приложений и новые темы. Нажмите «Обновить лаунчер на ТВ».'),
                  style: const TextStyle(fontSize: 13, color: AppColors.warn, height: 1.4)),
            ),
          ]),
        ],
        if (_installError != null) ...[
          const Gap(10),
          Text(_installError!,
              style: const TextStyle(fontSize: 13, color: AppColors.danger, height: 1.4)),
        ],
        if (_bindMsg != null) ...[
          const Gap(10),
          Text(_bindMsg!,
              style: TextStyle(fontSize: 13, height: 1.4, color: _bindOk ? AppColors.ok : AppColors.warn)),
        ] else if (installed && _checked && _launcher != null && _launcher != AdbPackageManager.launcherPkg) ...[
          const Gap(10),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.warning_amber_rounded, size: 18, color: AppColors.warn),
            const Gap(8),
            Expanded(
              child: Text(tr('Лаунчер установлен, но главный экран сейчас другой — прошивка его вернула. Нажмите «Сделать главным ещё раз».'),
                  style: const TextStyle(fontSize: 13, color: AppColors.warn, height: 1.4)),
            ),
          ]),
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
                              icon: const Icon(Icons.home_rounded),
                              label: Text(tr('Сделать главным ещё раз')),
                              onPressed: tv == null ? null : _rebind,
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


/// City search for the weather (Open-Meteo geocoding). Returns a place, an empty
/// place for «switch off», or null when closed.
class _CitySheet extends StatefulWidget {
  const _CitySheet();
  @override
  State<_CitySheet> createState() => _CitySheetState();
}

class _CitySheetState extends State<_CitySheet> {
  final _q = TextEditingController();
  List<GeoPlace> _found = const [];
  bool _busy = false;
  String? _msg;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _changed(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () => _search(v));
  }

  Future<void> _search(String v) async {
    if (v.trim().length < 2) {
      setState(() { _found = const []; _msg = null; });
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await Geo.search(v, lang: Localizations.localeOf(context).languageCode);
      if (!mounted) return;
      setState(() { _found = r; _msg = r.isEmpty ? tr('Ничего не нашлось') : null; });
    } catch (_) {
      if (mounted) setState(() => _msg = tr('Нет интернета на телефоне'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Город для погоды'),
                  style: GoogleFonts.syne(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.fg)),
              const Gap(12),
              TextField(
                controller: _q,
                autofocus: true,
                onChanged: _changed,
                decoration: InputDecoration(
                  hintText: tr('Например, Оренбург'),
                  suffixIcon: _busy
                      ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                      : null,
                ),
              ),
              if (_msg != null) ...[
                const Gap(8),
                Text(_msg!, style: const TextStyle(color: AppColors.fgMuted, fontSize: 13)),
              ],
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: ListView(shrinkWrap: true, children: [
                  for (final p in _found)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(p.name, style: const TextStyle(color: AppColors.fg)),
                      subtitle: Text(p.region, style: const TextStyle(color: AppColors.fgMuted, fontSize: 12)),
                      onTap: () => Navigator.pop(context, p),
                    ),
                ]),
              ),
              TextButton.icon(
                icon: const Icon(Icons.cloud_off_rounded),
                label: Text(tr('Не показывать погоду')),
                onPressed: () => Navigator.pop(context, const GeoPlace('', '', 0, 0)),
              ),
              Text(tr('Погоду телевизор берёт с Open-Meteo или met.no раз в полчаса; о вас туда ничего не отправляется.'),
                  style: const TextStyle(color: AppColors.fgMuted, fontSize: 11, height: 1.4)),
            ]),
          ),
        ),
      );
}
