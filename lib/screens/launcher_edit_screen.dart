import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gap/gap.dart';
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
  final _pin = TextEditingController();
  File? _preview;     // copy of the photo sent to this TV, for the preview
  double? _dim;       // slider value while dragging

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
      });
    } on AdbException catch (e) {
      AppLog.error('launcher state', e);
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      AppLog.error('launcher state', e);
      if (mounted) setState(() => _error = tr('Телевизор не отвечает. Проверьте, что он включён и в той же Wi-Fi сети.'));
    }
  }

  String _label(String pkg) =>
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
              child: Row(children: [
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
              child: ListTile(
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
              ),
            ),
          ),
        ),
        _saveBar(tr('Применить на ТВ'), () => _run(tr('Избранное обновлено на телевизоре'),
            () => ref.read(adbServiceProvider).applyLauncher(widget.tv, favorites: _favs))),
      ]);

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
            child: SwitchListTile(
              value: _kids,
              activeThumbColor: AppColors.accent,
              onChanged: (v) => setState(() => _kids = v),
              title: Text(tr('Детский режим')),
              subtitle: Text(tr('На ТВ останутся только выбранные приложения. Выйти — по PIN.'),
                  style: const TextStyle(fontSize: 12, color: AppColors.fgMuted)),
            ),
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
                  Text(has ? tr('На ТВ стоит ваше фото') : tr('Фон сейчас из шкурки'),
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
          onPressed: _saving ? null : () => _run(tr('Фон вернулся к шкурке'), () async {
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
    ]);
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
