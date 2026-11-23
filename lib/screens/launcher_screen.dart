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
  String? _lookTv;      // id of the TV whose settings the phone now shows (#21)
  int _gen = 0;         // bumps on a TV switch: a late answer from the old TV is dropped

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
    if (tv == null) return;
    final gen = ++_gen;
    bool stale() => !mounted || gen != _gen || ref.read(currentTvProvider)?.id != tv.id;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final api = ref.read(adbServiceProvider);
      final pkg = await api.currentLauncher(tv);
      final installed = pkg == AdbPackageManager.launcherPkg || await api.isLauncherInstalled(tv);
      final version = installed ? await api.launcherVersion(tv) : null;
      // #21: two TVs, one phone — the answer of the TV we left must not land on the new one
      if (stale()) return;
      _launcher = pkg;
      _installed = installed;
      _version = version;
      _weatherErr = null;
      if ((_version ?? 0) < 8) _lookTv = tv.id; // too old to report: the phone's copy is all there is
      if ((_version ?? 0) >= 8) {
        final st = await api.launcherState(tv);
        if (stale()) return;
        // What the TV has now, not the phone's old copy: settings changed on the TV itself
        // (launcher 0.54+) were overwritten by the phone's look on the next change or update
        // («слетают многие настройки», an owner).
        if (st.settings.containsKey('style')) {
          await ref.read(launcherLookProvider.notifier).set(LauncherLook.fromMap(st.settings));
          final sk = st.settings['skin'];
          if (sk != null && sk.isNotEmpty) await ref.read(selectedSkinProvider.notifier).select(LauncherSkin.byId(sk));
        }
        _lookTv = tv.id; // read from this TV (no «style» yet = nothing there to overwrite)
        final e = st.settings['weatherErr']?.toString() ?? '-';
        if (e != '-' && e.isNotEmpty) {
          _weatherErr = e;
          AppLog.error('launcher weather', e);
        }
      }
      _checked = true;
    } catch (_) {
      if (stale()) return;
      if (!silent) _error = _offline;
    }
    if (mounted && gen == _gen) setState(() => _checking = false);
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
            // an update keeps what the owner set up on the TV; a new install gets the phone's look
            look: ref.read(launcherLookProvider),
            keepSettings: _installed == true,
            onStep: (s) { if (mounted) setState(() => _step = s); },
          );
      _installed = true;
      // what the TV really has now, not what we hoped: «Обновить» said done and the TV kept
      // the old launcher (owners: no Витрина, no round icons after the update)
      final api = ref.read(adbServiceProvider);
      _version = await api.launcherVersion(tv).catchError((_) => AdbPackageManager.bundledLauncherVersion);
      if ((_version ?? 0) < AdbPackageManager.bundledLauncherVersion) {
        final msg = 'TV keeps v$_version, bundled v${AdbPackageManager.bundledLauncherVersion}';
        AppLog.error('launcher install', msg);
        _installError = tr('Установка не удалась: {0}', ['0.$_version → 0.${AdbPackageManager.bundledLauncherVersion}']);
      }
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
    // #21: the phone still shows another TV's settings (this one did not answer yet):
    // sending them would copy that TV's launcher onto this one. Read this TV first.
    if (_lookTv != tv.id) {
      _check(silent: true);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('Не получилось: телевизор не отвечает.'))));
      return;
    }
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
      _lookDebounce?.cancel();
      setState(() {
        _lookTv = null;
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
    final tv = ref.watch(currentTvProvider);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Лаунчер'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          const TvBanner(),
          if (tv != null) const Gap(12),
          // what needs doing (install / update / make it Home) comes first, not under 25 settings
          _statusCard(),
          const Gap(16),
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
          ..._lookGroups(look),
          if (_installed == true) _tvGroup(),
          const Gap(10),
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
        // ListTile / SwitchListTile paint on the nearest Material: without this one the card's
        // colour hides their splashes (debug assertion «ListTile background color … invisible»)
        child: Material(type: MaterialType.transparency, child: child),
      );

  /// Groups the owner opened (kept while the app runs, so a tab switch doesn't fold them).
  static final Set<String> _open = {};

  /// A setting the TV's launcher is too old for: say so on the row, not in one line at the end.
  String? _need(int v) => v > 0 && _installed == true && _version != null && _version! < v
      ? tr('Нужен лаунчер 0.{0} или новее — обновите его вверху', ['$v'])
      : null;

  Widget _group(String id, IconData icon, String title, String summary, List<Widget> children) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: _Group(
          icon: icon,
          title: title,
          summary: summary,
          open: _open.contains(id),
          onTap: () {
            HapticFeedback.selectionClick();
            setState(() {
              if (!_open.remove(id)) _open.add(id);
            });
          },
          children: children,
        ),
      );

  /// Choices as pills that wrap to a second line: the segmented buttons cut long words
  /// («Очень медленно», «Маленькие», five clock fonts) on a phone.
  Widget _pills(String title, List<String> labels, int value, ValueChanged<int> onChanged,
      {List<IconData>? icons, List<TextStyle>? styles, String? hint, int need = 0}) {
    final note = _need(need);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontSize: 13, color: AppColors.fgMid)),
        const Gap(8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (var i = 0; i < labels.length; i++)
            _Pill(
              label: labels[i],
              icon: icons?[i],
              style: styles?[i],
              selected: i == value,
              onTap: () {
                if (i != value) onChanged(i);
              },
            ),
        ]),
        if (hint != null) ...[
          const Gap(6),
          Text(hint, style: const TextStyle(fontSize: 12, height: 1.4, color: AppColors.fgMuted)),
        ],
        if (note != null) ...[
          const Gap(6),
          Text(note, style: const TextStyle(fontSize: 12, height: 1.4, color: AppColors.warn)),
        ],
      ]),
    );
  }

  Widget _sw(String title, String? sub, bool value, ValueChanged<bool> onChanged, {int need = 0}) {
    final note = _need(need);
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(title, style: const TextStyle(fontSize: 14, color: AppColors.fg)),
      subtitle: sub == null && note == null
          ? null
          : Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              if (sub != null) Text(sub, style: const TextStyle(fontSize: 12, color: AppColors.fgMuted)),
              if (note != null) Text(note, style: const TextStyle(fontSize: 12, color: AppColors.warn)),
            ]),
      value: value,
      onChanged: onChanged,
    );
  }

  /// Fine settings in five folding groups, each with a one-line summary of what is set.
  List<Widget> _lookGroups(LauncherLook look) {
    String join(List<String> xs) => xs.where((s) => s.isNotEmpty).join(' · ');
    final s0 = look.style == 0, s1 = look.style == 1, s2 = look.style == 2;

    final styleL = [tr('Плитки'), tr('Часы и док'), tr('Витрина')];
    final favL = [tr('Один ряд'), tr('По 4'), tr('По 5'), tr('По 6')];
    final favI = const [0, 4, 5, 6].contains(look.favCols) ? const [0, 4, 5, 6].indexOf(look.favCols) : 0;
    final inputsL = [tr('Вверху'), tr('Внизу'), tr('Скрыты')];
    final barL = [tr('Крупные'), tr('Средние'), tr('Мелкие')];
    final sizeL = [tr('Меньше'), tr('Обычные'), tr('Крупнее'), tr('Огромные')];
    final sizeI = const [80, 100, 130, 160].indexOf(look.clockSize).clamp(0, 3);
    final fontL = [tr('Тонкий'), tr('Лёгкий'), tr('Обычный'), tr('Узкий'), tr('Жирный')];
    final posL = [tr('Слева'), tr('По центру')];
    final iconsL = [tr('Авто'), tr('Иконки'), tr('ТВ-баннеры'), tr('Маленькие')];
    final shapeL = [tr('Скруглённые'), tr('Круглые')];
    final tilesL = [tr('Мелкие'), tr('Обычные'), tr('Крупные')];
    final animL = [tr('Полные'), tr('Мягкие'), tr('Выкл.')];
    final speedL = [tr('Авто'), tr('Быстро'), tr('Медленно'), tr('Очень медленно')];
    final autoL = [tr('Нет'), tr('Каждый час'), tr('Каждый день')];
    // «Размер часов» multiplies «Часы вверху» on the tiles screen: there the three presets are
    // enough, the fine size stays only for whoever already changed it
    final showSize = !s0 || look.clockSize != 100;
    // small icons are always round; TV banners have no shape
    final showShape = look.icons == 0 || look.icons == 1;

    return [
      _group('home', Icons.dashboard_rounded, tr('Главный экран'),
          join([styleL[look.style], if (s0) tr('Избранное: {0}', [favL[favI]]), 'HDMI: ${inputsL[look.inputs]}']), [
        _pills(tr('Вид главного экрана'), styleL, look.style, (v) => _setLook(look.copyWith(style: v)),
            icons: const [Icons.grid_view_rounded, Icons.schedule_rounded, Icons.view_carousel_rounded]),
        if (s0) ...[
          _pills(tr('Избранное на главном экране'), favL, favI,
              (v) => _setLook(look.copyWith(favCols: const [0, 4, 5, 6][v]))),
          if (favI == 0)
            _pills(tr('Рамка избранного'), [tr('Во всю ширину'), tr('Слева'), tr('По центру')], look.favAlign,
                (v) => _setLook(look.copyWith(favAlign: v)), need: 68),
          _sw(tr('Приложения на втором экране'), tr('На главном только избранное, приложения — ниже по кнопке ▼'),
              look.appsBelow, (v) => _setLook(look.copyWith(appsBelow: v))),
        ],
        if (s2)
          _sw(tr('Название приложения над плитками'), null, look.heroTitle,
              (v) => _setLook(look.copyWith(heroTitle: v))),
        _pills(tr('Источники (HDMI)'), inputsL, look.inputs, (v) => _setLook(look.copyWith(inputs: v))),
      ]),
      _group('bar', Icons.view_day_rounded, tr('Верхняя панель'),
          join([
            if (s0 && !look.greeting) tr('Без приветствия'),
            if (s0 && look.oneLine) tr('Дата в одну строку'),
            look.weatherCity.isEmpty ? tr('Без погоды') : tr('Погода: {0}', [look.weatherCity]),
            if (look.cleanBar) '⚙',
          ]), [
        if (s0) ...[
          _sw(tr('Приветствие'), tr('«Добрый вечер» над часами'), look.greeting,
              (v) => _setLook(look.copyWith(greeting: v)), need: 61),
          _sw(tr('Дата и погода в одну строку'), tr('Рядом с часами, а не столбиком'), look.oneLine,
              (v) => _setLook(look.copyWith(oneLine: v)), need: 61),
        ],
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
        _sw(tr('Память на главном экране'), tr('Нажатие закрывает приложения в фоне и освобождает память'), look.memPill,
            (v) => _setLook(look.copyWith(memPill: v)), need: 36),
        if (!look.cleanBar)
          _pills(tr('Значки вверху'), [tr('Надписи'), tr('Значки'), tr('Мини в углу')], look.barStyle,
              (v) => _setLook(look.copyWith(barStyle: v)), need: 68),
        if (!look.cleanBar)
          _sw(tr('Bluetooth на главном экране'),
              tr('Включён ли и что подключено; нажатие — включить, выключить или открыть настройки'), look.btPill,
              (v) => _setLook(look.copyWith(btPill: v)), need: 63),
        _sw(tr('Только шестерёнка вверху'), tr('Без плашек сети и «Настройки ТВ»: шестерёнка открывает настройки ТВ, удержание — настройки лаунчера'),
            look.cleanBar, (v) => _setLook(look.copyWith(cleanBar: v)), need: 49),
      ]),
      _group('clock', Icons.schedule_rounded, tr('Часы'),
          join([
            if (s0) barL[look.barClock] else if (showSize) sizeL[sizeI],
            if (s0 && showSize) sizeL[sizeI],
            fontL[look.clockFont],
            if (s1) posL[look.clockPos],
            look.clock24 ? '21:45' : '9:45',
          ]), [
        if (s0)
          _pills(tr('Часы вверху'), barL, look.barClock, (v) => _setLook(look.copyWith(barClock: v)), need: 61),
        if (showSize)
          _pills(tr('Размер часов'), sizeL, sizeI,
              (v) => _setLook(look.copyWith(clockSize: const [80, 100, 130, 160][v]))),
        _pills(tr('Шрифт часов'), fontL, look.clockFont, (v) => _setLook(look.copyWith(clockFont: v)),
            styles: const [
              TextStyle(fontWeight: FontWeight.w200),
              TextStyle(fontWeight: FontWeight.w300),
              TextStyle(fontWeight: FontWeight.w400),
              TextStyle(fontWeight: FontWeight.w500, letterSpacing: -.6),
              TextStyle(fontWeight: FontWeight.w800),
            ]),
        if (s1) _pills(tr('Часы на экране'), posL, look.clockPos, (v) => _setLook(look.copyWith(clockPos: v))),
        if (s1)
          _sw(tr('Дата и погода в одну строку'), tr('Рядом с часами, а не столбиком'), look.oneLine,
              (v) => _setLook(look.copyWith(oneLine: v)), need: 76),
        _sw(tr('Часы 24 часа'), null, look.clock24, (v) => _setLook(look.copyWith(clock24: v))),
        _sw(tr('Стекло под часами'), tr('Полупрозрачная подложка под часами, датой и погодой'), look.clockGlass,
            (v) => _setLook(look.copyWith(clockGlass: v)), need: 68),
      ]),
      _group('icons', Icons.apps_rounded, tr('Значки и плитки'),
          join([
            iconsL[look.icons],
            if (showShape) shapeL[look.iconShape],
            tr('Размер плиток: {0}', [tilesL[look.tiles]]),
          ]), [
        _pills(tr('Иконки приложений'), iconsL, look.icons, (v) => _setLook(look.copyWith(icons: v))),
        if (showShape)
          _pills(tr('Форма значков'), shapeL, look.iconShape, (v) => _setLook(look.copyWith(iconShape: v)),
              icons: const [Icons.crop_square_rounded, Icons.circle_outlined],
              // launcher 0.88: «Плитки» favourites turn round too, the hint about banners is gone
              need: 62),
        _pills(tr('Размер плиток'), tilesL, look.tiles, (v) => _setLook(look.copyWith(tiles: v))),
        _pills(tr('Подсветка выбора'), [tr('Белая'), tr('Цвет темы'), tr('Без рамки')],
            look.ringOff ? 2 : (look.ringAccent ? 1 : 0),
            (v) => _setLook(look.copyWith(ringAccent: v == 1, ringOff: v == 2))),
        _sw(tr('Названия под всеми плитками'), tr('Иначе — только у выбранной'), look.labels,
            (v) => _setLook(look.copyWith(labels: v))),
        _sw(tr('Без названий приложений'), tr('Только значки: док и ряды станут ниже'), look.noLabels,
            (v) => _setLook(look.copyWith(noLabels: v)), need: 83),
      ]),
      _group('motion', Icons.auto_awesome_rounded, tr('Фон и анимация'),
          join([
            look.ambient ? tr('Живой фон') : tr('Без живого фона'),
            tr('Анимации: {0}', [animL[look.anim]]),
            if (look.skinAuto > 0) autoL[look.skinAuto],
          ]), [
        _pills(tr('Стекло'), [tr('Светлое'), tr('Прозрачное'), tr('Тёмное')], look.shelf,
            (v) => _setLook(look.copyWith(shelf: v)),
            hint: tr('Под избранным, доком, часами и значками вверху'), need: 72),
        _sw(tr('Живой фон'), tr('Свечение медленно плывёт по экрану'), look.ambient,
            (v) => _setLook(look.copyWith(ambient: v))),
        if (look.ambient)
          _pills(tr('Скорость живого фона'), speedL, const [0, 8, 30, 90].indexOf(look.ambientSec).clamp(0, 3),
              (v) => _setLook(look.copyWith(ambientSec: const [0, 8, 30, 90][v])), need: 48),
        _pills(tr('Анимации'), animL, look.anim, (v) => _setLook(look.copyWith(anim: v))),
        _pills(tr('Менять тему сама'), autoL, look.skinAuto, (v) => _setLook(look.copyWith(skinAuto: v)), need: 48),
        const Gap(4),
        Text(tr('Слабый телевизор подтормаживает? Выключите анимации и живой фон.'),
            style: const TextStyle(fontSize: 12, height: 1.4, color: AppColors.fgMuted)),
      ]),
      Center(
        child: TextButton.icon(
          style: TextButton.styleFrom(foregroundColor: AppColors.fgMid),
          icon: const Icon(Icons.restart_alt_rounded, size: 18),
          label: Text(tr('Вернуть вид по умолчанию')),
          onPressed: () => _resetLook(look),
        ),
      ),
      const Gap(6),
    ];
  }

  Future<void> _resetLook(LauncherLook look) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('Вернуть вид по умолчанию?')),
        content: Text(tr('Все настройки в группах выше, кроме темы и погоды, станут как после установки лаунчера.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Отмена'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('Вернуть'))),
        ],
      ),
    );
    if (yes == true && mounted) {
      _setLook(const LauncherLook()
          .copyWith(weatherCity: look.weatherCity, lat: look.lat, lon: look.lon, wallDim: look.wallDim));
    }
  }

  /// Installed but another home screen is on. Not while an update is due: the update makes
  /// it Home again anyway, and two orange buttons with two warnings only confuse.
  bool get _notHome => _installed == true && !_outdated && _checked && _launcher != null &&
      _launcher != AdbPackageManager.launcherPkg;

  /// One card on top: is it there, is it the home screen, is it fresh — and the one button
  /// that matters right now. The rarely needed buttons live in «Лаунчер на телевизоре» below.
  Widget _statusCard() {
    final tv = ref.watch(currentTvProvider);
    final busy = _step != null;
    final installed = _installed == true;
    final v = _version ?? 0;
    final ours = _checked && _launcher == AdbPackageManager.launcherPkg;
    final (chipText, chipColor) = installed
        ? ('${tr('установлен')}${v > 0 ? ' · 0.$v' : ''}', _outdated ? AppColors.warn : AppColors.ok)
        : (tr('не установлен'), AppColors.fgMid);
    final String now;
    if (tv == null) {
      now = tr('Выберите телевизор на вкладке «Очистка».');
    } else if (_error != null) {
      now = _error!;
    } else if (!_checked) {
      now = tr('Узнаем, какой лаунчер сейчас главный на «{0}».', [tv.shortName.isEmpty ? tv.ipAddress : tv.shortName]);
    } else if (_launcher == null) {
      now = tr('Главный лаунчер не выбран: телевизор спрашивает при нажатии «Домой».');
    } else {
      now = _knownLaunchers[_launcher] ?? tr('Лаунчер производителя ({0})', [_launcher]);
    }
    const bigPad = EdgeInsets.symmetric(vertical: 14);
    Widget warnRow(IconData icon, String text) => Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 18, color: AppColors.warn),
            const Gap(8),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 13, color: AppColors.warn, height: 1.4))),
          ]),
        );
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          // the name and the chip wrap rather than cut the name («TVCleanz…» on a phone)
          Expanded(
            child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text('TVCleanzer Launcher',
                  style: GoogleFonts.syne(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.fg)),
              if (_installed != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: chipColor.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(50),
                  ),
                  child: Text(chipText, style: TextStyle(fontSize: 11, color: chipColor, fontWeight: FontWeight.w600)),
                ),
            ]),
          ),
          if (tv != null)
            _checking
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                : IconButton(
                    tooltip: _checked ? tr('Обновить') : tr('Проверить'),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.refresh_rounded, color: AppColors.fgMuted),
                    onPressed: _check,
                  ),
        ]),
        const Gap(4),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(ours ? Icons.check_circle_rounded : Icons.home_rounded,
              size: 18, color: _error != null ? AppColors.danger : ours ? AppColors.ok : AppColors.fgMuted),
          const Gap(8),
          Expanded(
            child: Text.rich(
                TextSpan(children: [
                  if (tv != null && _error == null && _checked)
                    TextSpan(text: '${tr('Сейчас на телевизоре')}: ', style: const TextStyle(color: AppColors.fgMuted)),
                  TextSpan(
                      text: now,
                      style: TextStyle(
                          color: _error != null ? AppColors.danger : AppColors.fg,
                          fontWeight: _checked ? FontWeight.w600 : FontWeight.w400)),
                ]),
                style: const TextStyle(fontSize: 13, height: 1.4),
              ),
          ),
        ]),
        if (!installed && _installed != null) ...[
          const Gap(8),
          Text(tr('Лёгкий красивый лаунчер: часы, избранное, все приложения, темы. Меньше 100 КБ, работает даже на слабых телевизорах (Android 7+; на Android 5–6 — пробная поддержка).'),
              style: const TextStyle(fontSize: 13, color: AppColors.fgMid, height: 1.5)),
        ],
        if (_outdated)
          warnRow(Icons.new_releases_rounded,
              tr('Есть новая версия лаунчера: исправления и новые функции. Нажмите оранжевую кнопку ниже — настройки и избранное сохранятся.')),
        if (_installError != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(_installError!, style: const TextStyle(fontSize: 13, color: AppColors.danger, height: 1.4)),
          ),
        if (_bindMsg != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(_bindMsg!,
                style: TextStyle(fontSize: 13, height: 1.4, color: _bindOk ? AppColors.ok : AppColors.warn)),
          )
        else if (_notHome)
          warnRow(Icons.warning_amber_rounded,
              tr('Лаунчер установлен, но главный экран сейчас другой — прошивка его вернула. Нажмите «Сделать главным ещё раз».')),
        const Gap(12),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: busy
              ? Row(key: const ValueKey('busy'), children: [
                  const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  const Gap(12),
                  Expanded(child: Text(_step!, style: const TextStyle(color: AppColors.fg, fontSize: 14))),
                ])
              : SizedBox(
                  key: ValueKey('$installed$_outdated$_notHome'),
                  width: double.infinity,
                  child: !installed
                      ? FilledButton.icon(
                          style: FilledButton.styleFrom(padding: bigPad),
                          icon: const Icon(Icons.download_rounded),
                          label: Text(tr('Установить на телевизор')),
                          onPressed: tv == null ? null : _install,
                        )
                      : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          // #6: the update must be the first thing seen, in orange
                          if (_outdated) ...[
                            FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.warn,
                                foregroundColor: Colors.black,
                                padding: bigPad,
                              ),
                              icon: const Icon(Icons.system_update_alt_rounded),
                              label: Text('${tr('Обновить лаунчер на ТВ')} · 0.$v → 0.${AdbPackageManager.bundledLauncherVersion}'),
                              onPressed: tv == null ? null : _install,
                            ),
                            const Gap(10),
                          ],
                          if (_notHome) ...[
                            FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.warn,
                                foregroundColor: Colors.black,
                                padding: bigPad,
                              ),
                              icon: const Icon(Icons.home_rounded),
                              label: Text(tr('Сделать главным ещё раз')),
                              onPressed: tv == null ? null : _rebind,
                            ),
                            const Gap(10),
                          ],
                          FilledButton.icon(
                            style: FilledButton.styleFrom(padding: bigPad),
                            icon: const Icon(Icons.tune_rounded),
                            label: Text(tr('Настроить: избранное, детям, обои')),
                            onPressed: tv == null
                                ? null
                                : () => Navigator.push(
                                    context, MaterialPageRoute(builder: (_) => LauncherEditScreen(tv: tv))),
                          ),
                        ]),
                ),
        ),
      ]),
    );
  }

  /// Rare buttons, folded: make Home again, reinstall, give the TV its own launcher back.
  Widget _tvGroup() {
    final tv = ref.watch(currentTvProvider);
    final off = tv == null || _step != null;
    final v = _version ?? 0;
    Widget btn(IconData icon, String label, VoidCallback onPressed) => Padding(
          padding: const EdgeInsets.only(top: 10),
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.fg,
              side: const BorderSide(color: AppColors.cardBd),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            icon: Icon(icon, size: 18),
            label: Text(label),
            onPressed: off ? null : onPressed,
          ),
        );
    return _group('tv', Icons.build_rounded, tr('Лаунчер на телевизоре'),
        '${tr('установлен')}${v > 0 ? ' · 0.$v' : ''}', [
      Text(tr('Тема меняется сразу: просто выберите другую выше. На телевизоре: долгое нажатие OK на приложении — добавить в избранное, переставить или скрыть; шестерёнка — настройки.'),
          style: const TextStyle(fontSize: 13, color: AppColors.fgMid, height: 1.5)),
      const Gap(4),
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (!_notHome) btn(Icons.home_rounded, tr('Сделать главным ещё раз'), _rebind),
        if (!_outdated) btn(Icons.refresh_rounded, tr('Переустановить лаунчер'), _install),
        btn(Icons.undo_rounded, tr('Вернуть стандартный лаунчер'), _uninstall),
      ]),
    ]);
  }
}

/// A folding settings group: icon, title, what is set now; tap to open.
class _Group extends StatelessWidget {
  final IconData icon;
  final String title;
  final String summary;
  final bool open;
  final VoidCallback onTap;
  final List<Widget> children;
  const _Group({
    required this.icon,
    required this.title,
    required this.summary,
    required this.open,
    required this.onTap,
    required this.children,
  });

  @override
  Widget build(BuildContext context) => Material(
        color: AppColors.bgCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.cardBd),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Semantics(
            button: true,
            expanded: open,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                child: Row(children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppColors.accentDim,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, size: 20, color: AppColors.accent),
                  ),
                  const Gap(12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(title,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.fg)),
                      if (summary.isNotEmpty) ...[
                        const Gap(2),
                        Text(summary,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12, height: 1.3, color: AppColors.fgMuted)),
                      ],
                    ]),
                  ),
                  const Gap(4),
                  AnimatedRotation(
                    turns: open ? .5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(Icons.expand_more_rounded, color: AppColors.fgMuted),
                  ),
                ]),
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: open
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Divider(height: 1, color: AppColors.cardBd),
                      const Gap(6),
                      ...children,
                    ]),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ]),
      );
}

/// One choice of a setting; wraps instead of cutting the word.
class _Pill extends StatelessWidget {
  final String label;
  final IconData? icon;
  final TextStyle? style;
  final bool selected;
  final VoidCallback onTap;
  const _Pill({required this.label, this.icon, this.style, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final fg = selected ? AppColors.accent : AppColors.fg;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? AppColors.accentDim : Colors.transparent,
        shape: StadiumBorder(side: BorderSide(color: selected ? AppColors.accent : AppColors.cardBd)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: selected ? AppColors.accent : AppColors.fgMid),
                const Gap(6),
              ],
              Flexible(
                child: Text(label,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: fg).merge(style)),
              ),
            ]),
          ),
        ),
      ),
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
    final ring = look.ringOff ? Colors.transparent : (look.ringAccent ? skin.accent : Colors.white);
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
