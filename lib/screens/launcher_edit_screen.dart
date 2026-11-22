import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gap/gap.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../models/launcher_look.dart';
import '../models/tv_device.dart';
import '../services/adb_client.dart';
import '../services/adb_package_manager.dart';
import '../services/app_log.dart';
import '../state/launcher_look_state.dart';
import '../theme/app_theme.dart';

import '../l10n/l10n.dart';
/// Set up the launcher on the TV from the phone: favourites order,
/// kids mode, own photo as background.
class LauncherEditScreen extends ConsumerStatefulWidget {
  final TvDevice tv;
  const LauncherEditScreen({super.key, required this.tv});
  @override
  ConsumerState<LauncherEditScreen> createState() => _LauncherEditScreenState();
}

class _LauncherEditScreenState extends ConsumerState<LauncherEditScreen> {
  LauncherState? _state;
  String? _error;
  bool _saving = false;

  List<String> _favs = [];
  Set<String> _kidsApps = {};
  bool _kids = false;
  String _autostart = '';  // app opened when the TV is switched on ('' = home screen)
  final _pin = TextEditingController();
  File? _preview;     // copy of the photo sent to this TV, for the preview
  double? _dim;       // slider value while dragging
  String _dream = ''; // the TV's screensaver component
  int _dreamDelay = 0; // minutes before the screensaver starts (0 = unknown)
  String? _photoStep; // photo upload progress
  String? _musicStep; // music upload progress

  @override
  void initState() {
    super.initState();
    _load();
    _loadPreview();
  }

  Future<File> _previewFile() async {
    final dir = await getApplicationSupportDirectory();
    final id = widget.tv.ipAddress.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');
    return File('${dir.path}/wallpaper_$id.jpg');
  }

  Future<void> _loadPreview() async {
    try {
      final f = await _previewFile();
      if (await f.exists() && mounted) setState(() => _preview = f);
    } catch (_) {}
  }

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _error = null; _state = null; });
    try {
      final st = await ref.read(adbServiceProvider).launcherState(widget.tv);
      if (st.version >= 15) {
        try {
          _dream = await ref.read(adbServiceProvider).currentDream(widget.tv);
          _dreamDelay = await ref.read(adbServiceProvider).screensaverDelayMin(widget.tv);
        } catch (_) {}
      }
      final favs = st.apps.where((a) => a.fav >= 0).toList()..sort((a, b) => a.fav.compareTo(b.fav));
      if (!mounted) return;
      // Launcher 0.4+ reports its fine settings: the phone shows what the TV really has.
      if (st.version >= 4) {
        ref.read(launcherLookProvider.notifier).set(LauncherLook.fromMap(st.settings));
      }
      setState(() {
        _state = st;
        _favs = favs.map((a) => a.pkg).toList();
        _kidsApps = st.apps.where((a) => a.kids).map((a) => a.pkg).toSet();
        _kids = st.kids;
        final a = st.settings['autostart'] ?? '-';
        _autostart = a == '-' ? '' : a;
      });
    } on AdbException catch (e) {
      AppLog.error('launcher state', e);
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      AppLog.error('launcher state', e);
      if (mounted) setState(() => _error = tr('Телевизор не отвечает. Проверьте, что он включён и в той же Wi-Fi сети.'));
    }
  }

  String _label(String pkg) {
    if (pkg.startsWith('input:')) {
      final id = pkg.substring(6);
      for (final i in _state?.inputs ?? const <LauncherInput>[]) {
        if (i.id == id) return i.label;
      }
      return id;
    }
    return _labelApp(pkg);
  }

  String _labelApp(String pkg) =>
      _state?.apps.firstWhere((a) => a.pkg == pkg,
          orElse: () => LauncherApp(pkg: pkg, label: pkg, fav: -1, hidden: false, kids: false)).label ?? pkg;

  Future<void> _run(String done, Future<void> Function() job) async {
    setState(() => _saving = true);
    try {
      await job();
      HapticFeedback.mediumImpact();
      _snack(done);
    } on AdbException catch (e) {
      AppLog.error('launcher apply', e);
      _snack(e.message);
    } catch (e) {
      AppLog.error('launcher apply', e);
      _snack(tr('Не получилось: телевизор не отвечает.'));
    }
    if (mounted) setState(() => _saving = false);
  }

  void _snack(String t) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr('Лаунчер на ТВ')),
          bottom: TabBar(
            indicatorColor: AppColors.accent,
            labelColor: AppColors.accent,
            unselectedLabelColor: AppColors.fgMid,
            tabs: [Tab(text: tr('Избранное')), Tab(text: tr('Детям')), Tab(text: tr('Обои'))],
          ),
        ),
        body: _error != null
            ? _errorView()
            : _state == null
                ? const Center(child: CircularProgressIndicator())
                : TabBarView(children: [_favTab(), _kidsTab(), _wallTab()]),
      ),
    );
  }

  Widget _errorView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.tv_off_rounded, size: 48, color: AppColors.danger),
            const Gap(12),
            Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.fgMid)),
            const Gap(16),
            FilledButton(onPressed: _load, child: Text(tr('Попробовать снова'))),
          ]),
        ),
      );

  Widget _saveBar(String text, VoidCallback? onPressed) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: _saving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send_to_mobile_rounded),
              label: Text(text),
              onPressed: _saving ? null : onPressed,
            ),
          ),
        ),
      );

  // ── Favourites ─────────────────────────────────────────────────────────

  Widget _favTab() => Column(children: [
        Expanded(
          child: ReorderableListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            header: Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _autostartRow(),
                const Gap(8),
                Row(children: [
                Expanded(
                  child: Text(tr('Потяните за ручку, чтобы поменять порядок. Первые четыре видны сразу.'),
                      style: const TextStyle(color: AppColors.fgMuted, fontSize: 12, height: 1.4)),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.add_rounded),
                  label: Text(tr('Добавить')),
                  onPressed: _addFav,
                ),
              ]),
              ]),
            ),
            itemCount: _favs.length,
            onReorderItem: (a, b) => setState(() => _favs.insert(b, _favs.removeAt(a))),
            itemBuilder: (_, i) => Container(
              key: ValueKey(_favs[i]),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: AppColors.bgCard,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: i < 4 ? AppColors.accent.withValues(alpha: .35) : AppColors.cardBd),
              ),
              child: Material(type: MaterialType.transparency, child: ListTile(
                leading: CircleAvatar(
                  radius: 14,
                  backgroundColor: AppColors.accentDim,
                  child: Text('${i + 1}', style: const TextStyle(color: AppColors.accent, fontSize: 12)),
                ),
                title: Text(_label(_favs[i]), maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: AppColors.fgMuted),
                    onPressed: () => setState(() => _favs.removeAt(i)),
                  ),
                  ReorderableDragStartListener(
                    index: i,
                    child: const Icon(Icons.drag_handle_rounded, color: AppColors.fgMid),
                  ),
                ]),
              )),
            ),
          ),
        ),
        _saveBar(tr('Применить на ТВ'), () => _run(tr('Избранное обновлено на телевизоре'),
            () => ref.read(adbServiceProvider).applyLauncher(widget.tv, favorites: _favs))),
      ]);

  /// «When the TV is switched on, open …» (launcher 0.6+).
  Widget _autostartRow() {
    final st = _state!;
    final newEnough = st.version >= 6;
    final apps = [...st.apps]..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      decoration: BoxDecoration(
        color: AppColors.bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cardBd),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        DropdownButtonFormField<String>(
          initialValue: apps.any((a) => a.pkg == _autostart) ||
                  st.inputs.any((i) => 'input:${i.id}' == _autostart)
              ? _autostart
              : '',
          isExpanded: true,
          decoration: InputDecoration(labelText: tr('При включении ТВ открывать'), border: InputBorder.none),
          items: [
            DropdownMenuItem(value: '', child: Text(tr('Главный экран (лаунчер)'))),
            // launcher 0.31+: an input, e.g. HDMI with a box — the TV works as a plain screen
            for (final i in st.inputs)
              DropdownMenuItem(value: 'input:${i.id}', child: Text(tr('Источник: {0}', [i.label]), maxLines: 1, overflow: TextOverflow.ellipsis)),
            for (final a in apps)
              DropdownMenuItem(value: a.pkg, child: Text(a.label, maxLines: 1, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: !newEnough || _saving
              ? null
              : (v) {
                  final pkg = v ?? '';
                  setState(() => _autostart = pkg);
                  _run(pkg.isEmpty ? tr('При включении откроется главный экран') : tr('При включении откроется «{0}»', [_label(pkg)]),
                      () => ref.read(adbServiceProvider).setLauncherAutostart(widget.tv, pkg));
                },
        ),
        Text(
          newEnough
              ? tr('Например, YouTube или онлайн-кинотеатр: включили телевизор — и сразу в нём. Кнопка «Домой» по-прежнему ведёт в лаунчер.')
              : tr('Эта настройка появилась в новой версии лаунчера: обновите его на вкладке «Лаунчер».'),
          style: const TextStyle(color: AppColors.fgMuted, fontSize: 12, height: 1.4),
        ),
      ]),
    );
  }

  void _addFav() {
    final rest = _state!.apps.where((a) => !_favs.contains(a.pkg)).toList();
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.bgCard,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .7,
        builder: (_, sc) => ListView(
          controller: sc,
          padding: const EdgeInsets.all(12),
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(tr('Добавить в избранное'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            ),
            for (final a in rest)
              ListTile(
                title: Text(a.label),
                subtitle: Text(a.pkg, style: const TextStyle(fontSize: 11, color: AppColors.fgMuted)),
                trailing: const Icon(Icons.add_circle_outline_rounded, color: AppColors.accent),
                onTap: () {
                  setState(() => _favs.add(a.pkg));
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    );
  }

  // ── Kids mode ──────────────────────────────────────────────────────────

  Widget _kidsTab() {
    final st = _state!;
    return Column(children: [
      Expanded(
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 12), children: [
          Container(
            decoration: BoxDecoration(
              color: AppColors.bgCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.cardBd),
            ),
            child: Material(type: MaterialType.transparency, child: SwitchListTile(
              value: _kids,
              activeThumbColor: AppColors.accent,
              onChanged: (v) => setState(() => _kids = v),
              title: Text(tr('Детский режим')),
              subtitle: Text(tr('На ТВ останутся только выбранные приложения. Выйти — по PIN.'),
                  style: const TextStyle(fontSize: 12, color: AppColors.fgMuted)),
            )),
          ),
          const Gap(12),
          TextField(
            controller: _pin,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: 8,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: st.hasPin ? tr('Новый PIN (необязательно)') : tr('PIN для выхода (4–8 цифр)'),
              filled: true,
              fillColor: AppColors.bgCard,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
          Text(tr('Не настоящая блокировка: ребёнок, который знает про отладку, обойдёт её. Но от случайных приложений и рекламы — защитит.'),
              style: const TextStyle(fontSize: 11, color: AppColors.fgMuted, height: 1.4)),
          const Gap(16),
          Text(tr('ЧТО МОЖНО ДЕТЯМ'),
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: .8, color: AppColors.fgMuted)),
          const Gap(6),
          for (final a in st.apps)
            CheckboxListTile(
              value: _kidsApps.contains(a.pkg),
              activeColor: AppColors.accent,
              contentPadding: EdgeInsets.zero,
              title: Text(a.label),
              onChanged: (v) => setState(() => v == true ? _kidsApps.add(a.pkg) : _kidsApps.remove(a.pkg)),
            ),
        ]),
      ),
      _saveBar(tr('Применить на ТВ'), () {
        final pin = _pin.text.trim();
        if (_kids && !st.hasPin && pin.length < 4) {
          _snack(tr('Сначала придумайте PIN из 4–8 цифр — без него из детского режима не выйти.'));
          return;
        }
        _run(_kids ? tr('Детский режим включён на телевизоре') : tr('Настройки детского режима сохранены'), () async {
          await ref.read(adbServiceProvider).applyLauncher(widget.tv,
              kidsApps: _kidsApps, pin: pin.isEmpty ? null : pin, kids: _kids);
          _pin.clear();
          await _load();
        });
      }),
    ]);
  }

  // ── Wallpaper ──────────────────────────────────────────────────────────

  Widget _wallTab() {
    final st = _state!;
    final has = st.hasWallpaper;
    final look = ref.watch(launcherLookProvider);
    final dim = _dim ?? look.wallDim.toDouble();
    final preview = has ? _preview : null;
    return ListView(padding: const EdgeInsets.all(16), children: [
      AspectRatio(
        aspectRatio: 16 / 9,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Stack(fit: StackFit.expand, children: [
            if (preview != null)
              Image.file(preview, fit: BoxFit.cover, gaplessPlayback: true)
            else
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [Color(0xFF1E293B), Color(0xFF2E2A5C)]),
                ),
              ),
            if (preview != null)
              AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                color: Colors.black.withValues(alpha: dim / 100),
              ),
            if (preview != null)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Text('20:45',
                      style: TextStyle(fontSize: 34, color: Colors.white, fontWeight: FontWeight.w200)),
                ),
              )
            else
              Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(has ? Icons.photo_rounded : Icons.add_photo_alternate_rounded,
                      size: 48, color: has ? AppColors.accent : AppColors.fgMid),
                  const Gap(8),
                  Text(has ? tr('На ТВ стоит ваше фото') : tr('Фон сейчас из темы'),
                      style: const TextStyle(color: AppColors.fg, fontWeight: FontWeight.w600)),
                ]),
              ),
          ]),
        ),
      ).animate().fadeIn(duration: 250.ms),
      const Gap(16),
      if (has) ...[
        Row(children: [
          Text(tr('Затемнение фото'), style: const TextStyle(color: AppColors.fg, fontSize: 14)),
          const Spacer(),
          Text('${dim.round()}%', style: const TextStyle(color: AppColors.fgMid, fontSize: 13)),
        ]),
        Slider(
          value: dim,
          min: 0,
          max: 90,
          divisions: 9,
          activeColor: AppColors.accent,
          onChanged: (v) => setState(() => _dim = v),
          onChangeEnd: (v) async {
            final next = look.copyWith(wallDim: v.round());
            await ref.read(launcherLookProvider.notifier).set(next);
            if (mounted) setState(() => _dim = null);
            try {
              await ref.read(adbServiceProvider).applyLauncherLook(widget.tv, next);
            } catch (_) {
              _snack(tr('Не получилось: телевизор не отвечает.'));
            }
          },
        ),
        if (st.version < 4)
          Text(tr('Затемнение работает в новой версии лаунчера: обновите его на вкладке «Лаунчер».'),
              style: const TextStyle(color: AppColors.warn, fontSize: 12, height: 1.4)),
        const Gap(8),
      ],
      Text(tr('Лучше горизонтальное фото, 16:9. Затемнение помогает читать часы и названия на ярких снимках.'),
          style: const TextStyle(color: AppColors.fgMuted, fontSize: 12, height: 1.4)),
      const Gap(16),
      FilledButton.icon(
        icon: _saving
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.photo_library_rounded),
        label: Text(_saving ? tr('Отправляем фото на телевизор…') : tr('Выбрать фото')),
        onPressed: _saving ? null : _pickPhoto,
      ),
      if (has) ...[
        const Gap(10),
        OutlinedButton.icon(
          icon: const Icon(Icons.hide_image_rounded),
          label: Text(tr('Убрать фото')),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.fg,
            side: const BorderSide(color: AppColors.cardBd),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
          onPressed: _saving ? null : () => _run(tr('Фон вернулся к теме'), () async {
            await ref.read(adbServiceProvider).removeWallpaper(widget.tv);
            try {
              final f = await _previewFile();
              if (await f.exists()) await f.delete();
            } catch (_) {}
            _preview = null;
            await _load();
          }),
        ),
      ],
      const Gap(28),
      ..._photoFrame(st),
    ]);
  }

  // ── Photo frame (launcher 0.15+) ───────────────────────────────────────

  static const _secSteps = [10, 30, 60, 300];

  List<Widget> _photoFrame(LauncherState st) {
    final count = int.tryParse(st.settings['photos'] ?? '') ?? 0;
    final sec = int.tryParse(st.settings['photoSec'] ?? '') ?? 30;
    final home = st.settings['homePhotos'] == '1';
    final on = _dream.contains('PhotoDream');
    final busy = _saving || _photoStep != null || _musicStep != null;
    return [
      Text(tr('Фоторамка'),
          style: const TextStyle(color: AppColors.fg, fontSize: 17, fontWeight: FontWeight.w700)),
      const Gap(6),
      Text(tr('Ваши фото по очереди, с часами и погодой: когда телевизор простаивает, и, если хотите, фоном главного экрана. Включается только по вашему желанию.'),
          style: const TextStyle(color: AppColors.fgMid, fontSize: 13, height: 1.4)),
      const Gap(12),
      if (st.version < 15)
        Text(tr('Эта настройка появилась в новой версии лаунчера: обновите его на вкладке «Лаунчер».'),
            style: const TextStyle(color: AppColors.warn, fontSize: 12, height: 1.4))
      else ...[
        Text(tr('На телевизоре фото: {0}', [count]),
            style: const TextStyle(color: AppColors.fg, fontSize: 14)),
        if (_photoStep != null) ...[
          const Gap(8),
          Row(children: [
            const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            const Gap(10),
            Expanded(child: Text(_photoStep!, style: const TextStyle(color: AppColors.fgMid, fontSize: 13))),
          ]),
        ],
        const Gap(10),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              icon: const Icon(Icons.add_photo_alternate_rounded),
              label: Text(tr('Добавить фото')),
              onPressed: busy ? null : _addPhotos,
            ),
          ),
          if (count > 0) ...[
            const Gap(10),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.fg,
                side: const BorderSide(color: AppColors.cardBd),
              ),
              onPressed: busy ? null : () => _run(tr('Фото удалены'), () async {
                await ref.read(adbServiceProvider).clearPhotos(widget.tv);
                await _load();
              }),
              child: Text(tr('Удалить все')),
            ),
          ],
        ]),
        const Gap(6),
        Text(tr('До 30 фото. Они уменьшаются до 1920 пикселей и занимают немного места.'),
            style: const TextStyle(color: AppColors.fgMuted, fontSize: 12, height: 1.4)),
        if (count > 0) ...[
          const Gap(14),
          Text(tr('Смена фото'), style: const TextStyle(fontSize: 13, color: AppColors.fgMid)),
          const Gap(6),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<int>(
              showSelectedIcon: false,
              segments: [
                for (final v in _secSteps)
                  ButtonSegment(value: v, label: Text(v >= 60 ? tr('{0} мин', [v ~/ 60]) : tr('{0} с', [v]))),
              ],
              selected: {_secSteps.contains(sec) ? sec : 30},
              onSelectionChanged: busy ? null : (v) => _run(tr('Сохранено'), () async {
                await ref.read(adbServiceProvider).setPhotoOptions(widget.tv, seconds: v.first);
                await _load();
              }),
            ),
          ),
          const Gap(6),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: home,
            activeThumbColor: AppColors.accent,
            title: Text(tr('Менять фон главного экрана'), style: const TextStyle(color: AppColors.fg, fontSize: 14)),
            subtitle: Text(tr('Фото сменяют друг друга вместо одного фона'),
                style: const TextStyle(color: AppColors.fgMuted, fontSize: 12)),
            onChanged: busy ? null : (v) => _run(tr('Сохранено'), () async {
              await ref.read(adbServiceProvider).setPhotoOptions(widget.tv, homePhotos: v);
              await _load();
            }),
          ),
        ],
        const Gap(16),
        ..._musicBlock(st, busy),
        const Gap(8),
        if (on) ...[
          Row(children: [
            const Icon(Icons.check_circle_rounded, color: AppColors.ok, size: 18),
            const Gap(8),
            Expanded(child: Text(tr('Сейчас заставка телевизора — фоторамка'),
                style: const TextStyle(color: AppColors.ok, fontSize: 13))),
          ]),
          const Gap(12),
          Text(tr('Включать, когда телевизор простоит'), style: const TextStyle(fontSize: 13, color: AppColors.fgMid)),
          const Gap(6),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<int>(
              showSelectedIcon: false,
              emptySelectionAllowed: true,
              segments: [
                for (final m in const [5, 10, 15, 30]) ButtonSegment(value: m, label: Text(tr('{0} мин', [m]))),
              ],
              selected: {if (const [5, 10, 15, 30].contains(_dreamDelay)) _dreamDelay},
              onSelectionChanged: busy ? null : (v) {
                if (v.isEmpty) return;
                _run(tr('Сохранено'), () async {
                  await ref.read(adbServiceProvider).setScreensaverDelayMin(widget.tv, v.first);
                  if (mounted) setState(() => _dreamDelay = v.first);
                });
              },
            ),
          ),
          const Gap(8),
          FilledButton.icon(
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(tr('Показать сейчас')),
            onPressed: busy ? null : () async {
              final ok = await ref.read(adbServiceProvider).startScreensaverNow(widget.tv).catchError((_) => false);
              _snack(ok ? tr('Фоторамка запущена на телевизоре')
                  : tr('Телевизор не дал запустить заставку сразу: она включится сама, когда ТВ постоит без дела.'));
            },
          ),
          const Gap(8),
          OutlinedButton.icon(
            icon: const Icon(Icons.undo_rounded, size: 18),
            label: Text(tr('Вернуть прежнюю заставку')),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.fg,
              side: const BorderSide(color: AppColors.cardBd),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onPressed: busy ? null : () => _run(tr('Прежняя заставка возвращена'), () async {
              await ref.read(adbServiceProvider).disablePhotoFrame(widget.tv, st.settings['prevDream'] ?? '');
              await _load();
            }),
          ),
        ] else
          OutlinedButton.icon(
            icon: const Icon(Icons.slideshow_rounded),
            label: Text(tr('Сделать заставкой телевизора')),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.fg,
              side: const BorderSide(color: AppColors.cardBd),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onPressed: busy ? null : () => _run(
                tr('Фоторамка включена: она появится, когда телевизор постоит без дела. Через сколько минут — задаётся в настройках ТВ, раздел «Заставка».'),
                () async {
                  await ref.read(adbServiceProvider).enablePhotoFrame(widget.tv);
                  await _load();
                }),
          ),
      ],
      const Gap(24),
    ];
  }

  /// Music in the photo frame (launcher 0.61+): the owner's tracks, shuffled, while the frame is on.
  List<Widget> _musicBlock(LauncherState st, bool busy) {
    final n = int.tryParse(st.settings['music'] ?? '') ?? 0;
    final playing = st.settings['frameMusic'] != '0';
    return [
      Text(tr('Музыка в фоторамке'),
          style: const TextStyle(color: AppColors.fg, fontSize: 15, fontWeight: FontWeight.w600)),
      const Gap(4),
      Text(tr('Играет, пока на экране фоторамка. Громкость — пультом телевизора.'),
          style: const TextStyle(color: AppColors.fgMid, fontSize: 13, height: 1.4)),
      const Gap(8),
      if (st.version < AdbPackageManager.musicLauncher)
        Text(tr('Музыка в фоторамке появилась в новой версии лаунчера: обновите его на вкладке «Лаунчер».'),
            style: const TextStyle(color: AppColors.warn, fontSize: 12, height: 1.4))
      else ...[
        Text(tr('На телевизоре треков: {0}', [n]), style: const TextStyle(color: AppColors.fg, fontSize: 14)),
        if (_musicStep != null) ...[
          const Gap(8),
          Row(children: [
            const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            const Gap(10),
            Expanded(child: Text(_musicStep!, style: const TextStyle(color: AppColors.fgMid, fontSize: 13))),
          ]),
        ],
        const Gap(10),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              icon: const Icon(Icons.library_music_rounded),
              label: Text(tr('Добавить музыку')),
              onPressed: busy ? null : _addMusic,
            ),
          ),
          if (n > 0) ...[
            const Gap(10),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.fg,
                side: const BorderSide(color: AppColors.cardBd),
              ),
              onPressed: busy ? null : () => _run(tr('Музыка удалена'), () async {
                await ref.read(adbServiceProvider).clearMusic(widget.tv);
                await _load();
              }),
              child: Text(tr('Удалить музыку')),
            ),
          ],
        ]),
        if (n > 0)
          Material(
            type: MaterialType.transparency,
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: playing,
              activeThumbColor: AppColors.accent,
              title: Text(tr('Играет вместе с фото'), style: const TextStyle(color: AppColors.fg, fontSize: 14)),
              onChanged: busy ? null : (v) => _run(tr('Сохранено'), () async {
                await ref.read(adbServiceProvider).setFrameMusic(widget.tv, v);
                await _load();
              }),
            ),
          ),
        const Gap(4),
        Text(tr('MP3, M4A, FLAC и другие, до 30 треков. Можно и без фото: тогда играет под часы.'),
            style: const TextStyle(color: AppColors.fgMuted, fontSize: 12, height: 1.4)),
      ],
    ];
  }

  Future<void> _addMusic() async {
    FilePickerResult? res;
    try {
      res = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: const ['mp3', 'm4a', 'aac', 'ogg', 'flac', 'wav'],
          allowMultiple: true,
          withData: false);
    } catch (e) {
      AppLog.error('pick music', e);
    }
    final files = (res?.files ?? const <PlatformFile>[]).where((f) => f.path != null).take(30).toList();
    if (files.isEmpty) return;
    final tracks = <({String name, int length, Stream<List<int>> Function() open})>[];
    for (final f in files) {
      final file = File(f.path!);
      try {
        tracks.add((name: f.name, length: await file.length(), open: () => file.openRead()));
      } catch (e) {
        AppLog.error('read track', e);
      }
    }
    if (!mounted) return;
    if (tracks.isEmpty) {
      _snack(tr('Не удалось прочитать файл. Сохраните его в «Файлы» и попробуйте снова.'));
      return;
    }
    setState(() => _musicStep = tr('Отправляем трек {0} из {1}…', [1, tracks.length]));
    try {
      final n = await ref.read(adbServiceProvider).addMusic(widget.tv, tracks, onProgress: (done, total) {
        if (mounted && done < total) {
          setState(() => _musicStep = tr('Отправляем трек {0} из {1}…', [done + 1, total]));
        }
      });
      HapticFeedback.mediumImpact();
      _snack(tr('Музыка добавлена: {0}', [n]));
    } on AdbException catch (e) {
      AppLog.error('music', e);
      _snack(e.message);
    } catch (e) {
      AppLog.error('music', e);
      _snack(tr('Не получилось: телевизор не отвечает.'));
    }
    if (mounted) setState(() => _musicStep = null);
    await _load();
  }

  Future<void> _addPhotos() async {
    List<XFile> picked;
    try {
      picked = await ImagePicker().pickMultiImage(maxWidth: 1920, maxHeight: 1920, imageQuality: 92, limit: 30);
    } catch (e) {
      AppLog.error('pick photos', e);
      _snack(tr('Нет доступа к фото. Разрешите его в настройках телефона.'));
      return;
    }
    if (picked.isEmpty) return;
    final bytes = <Uint8List>[];
    for (final x in picked.take(30)) {
      final b = await x.readAsBytes();
      if (b.isNotEmpty) bytes.add(b);
    }
    if (bytes.isEmpty) {
      _snack(tr('Не удалось прочитать фото. Выберите другое.'));
      return;
    }
    setState(() => _photoStep = tr('Отправляем фото {0} из {1}…', [1, bytes.length]));
    try {
      await ref.read(adbServiceProvider).addPhotos(widget.tv, bytes, onProgress: (done, total) {
        if (mounted && done < total) {
          setState(() => _photoStep = tr('Отправляем фото {0} из {1}…', [done + 1, total]));
        }
      });
      HapticFeedback.mediumImpact();
      _snack(tr('Фото добавлены: {0}', [bytes.length]));
    } on AdbException catch (e) {
      AppLog.error('photos', e);
      _snack(e.message);
    } catch (e) {
      AppLog.error('photos', e);
      _snack(tr('Не получилось: телевизор не отвечает.'));
    }
    if (mounted) setState(() => _photoStep = null);
    await _load();
  }

  Future<void> _pickPhoto() async {
    final XFile? img;
    try {
      img = await ImagePicker().pickImage(
          source: ImageSource.gallery, maxWidth: 1920, maxHeight: 1920, imageQuality: 85);
    } catch (e) {
      AppLog.error('pick photo', e);
      _snack(tr('Нет доступа к фото. Разрешите его в настройках телефона.'));
      return;
    }
    if (img == null) return;
    final bytes = await img.readAsBytes();
    if (bytes.isEmpty) {
      _snack(tr('Не удалось прочитать фото. Выберите другое.'));
      return;
    }
    await _run(tr('Фото стоит фоном на телевизоре'), () async {
      await ref.read(adbServiceProvider).setWallpaper(widget.tv, bytes);
      try {
        final f = await _previewFile();
        await f.writeAsBytes(bytes, flush: true);
        PaintingBinding.instance.imageCache.evict(FileImage(f));
        _preview = f;
      } catch (_) {}
      await _load();
    });
  }
}
