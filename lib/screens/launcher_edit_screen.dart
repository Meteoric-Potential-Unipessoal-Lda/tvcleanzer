import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gap/gap.dart';
import 'package:image_picker/image_picker.dart';

import '../models/tv_device.dart';
import '../services/adb_client.dart';
import '../services/adb_package_manager.dart';
import '../services/app_log.dart';
import '../theme/app_theme.dart';

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

  @override
  void initState() {
    super.initState();
    _load();
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
      if (mounted) setState(() => _error = 'Телевизор не отвечает. Проверьте, что он включён и в той же Wi-Fi сети.');
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
      _snack('Не получилось: телевизор не отвечает.');
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
          title: const Text('Лаунчер на ТВ'),
          bottom: const TabBar(
            indicatorColor: AppColors.accent,
            labelColor: AppColors.accent,
            unselectedLabelColor: AppColors.fgMid,
            tabs: [Tab(text: 'Избранное'), Tab(text: 'Детям'), Tab(text: 'Обои')],
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
            FilledButton(onPressed: _load, child: const Text('Попробовать снова')),
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
                const Expanded(
                  child: Text('Потяните за ручку, чтобы поменять порядок. Первые четыре видны сразу.',
                      style: TextStyle(color: AppColors.fgMuted, fontSize: 12, height: 1.4)),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Добавить'),
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
        _saveBar('Применить на ТВ', () => _run('Избранное обновлено на телевизоре',
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
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text('Добавить в избранное', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
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
              title: const Text('Детский режим'),
              subtitle: const Text('На ТВ останутся только выбранные приложения. Выйти — по PIN.',
                  style: TextStyle(fontSize: 12, color: AppColors.fgMuted)),
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
              labelText: st.hasPin ? 'Новый PIN (необязательно)' : 'PIN для выхода (4–8 цифр)',
              filled: true,
              fillColor: AppColors.bgCard,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
          const Text('Не настоящая блокировка: ребёнок, который знает про отладку, обойдёт её. '
              'Но от случайных приложений и рекламы — защитит.',
              style: TextStyle(fontSize: 11, color: AppColors.fgMuted, height: 1.4)),
          const Gap(16),
          const Text('ЧТО МОЖНО ДЕТЯМ',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: .8, color: AppColors.fgMuted)),
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
      _saveBar('Применить на ТВ', () {
        final pin = _pin.text.trim();
        if (_kids && !st.hasPin && pin.length < 4) {
          _snack('Сначала придумайте PIN из 4–8 цифр — без него из детского режима не выйти.');
          return;
        }
        _run(_kids ? 'Детский режим включён на телевизоре' : 'Настройки детского режима сохранены', () async {
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
    final has = _state!.hasWallpaper;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Container(
        height: 180,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: const LinearGradient(colors: [Color(0xFF1E293B), Color(0xFF2E2A5C)]),
          border: Border.all(color: AppColors.cardBd),
        ),
        alignment: Alignment.center,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(has ? Icons.photo_rounded : Icons.add_photo_alternate_rounded,
              size: 48, color: has ? AppColors.accent : AppColors.fgMid),
          const Gap(8),
          Text(has ? 'На ТВ стоит ваше фото' : 'Фон сейчас из шкурки',
              style: const TextStyle(color: AppColors.fg, fontWeight: FontWeight.w600)),
        ]),
      ).animate().fadeIn(duration: 250.ms),
      const Gap(16),
      const Text('Фото слегка затемнится, чтобы текст на ТВ читался. Лучше горизонтальное, 16:9.',
          style: TextStyle(color: AppColors.fgMuted, fontSize: 12, height: 1.4)),
      const Gap(16),
      FilledButton.icon(
        icon: _saving
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.photo_library_rounded),
        label: const Text('Выбрать фото'),
        onPressed: _saving ? null : _pickPhoto,
      ),
      if (has) ...[
        const Gap(10),
        OutlinedButton.icon(
          icon: const Icon(Icons.hide_image_rounded),
          label: const Text('Убрать фото'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.fg,
            side: const BorderSide(color: AppColors.cardBd),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
          onPressed: _saving ? null : () => _run('Фон вернулся к шкурке', () async {
            await ref.read(adbServiceProvider).removeWallpaper(widget.tv);
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
      _snack('Нет доступа к фото. Разрешите его в настройках телефона.');
      return;
    }
    if (img == null) return;
    final bytes = await img.readAsBytes();
    await _run('Фото стоит фоном на телевизоре', () async {
      await ref.read(adbServiceProvider).setWallpaper(widget.tv, bytes);
      await _load();
    });
  }
}
