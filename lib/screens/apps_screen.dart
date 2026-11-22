import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/tv_device.dart';
import '../services/adb_client.dart';
import '../services/adb_package_manager.dart';
import '../services/app_log.dart';
import '../state/current_tv.dart';
import '../theme/app_theme.dart';

import '../l10n/l10n.dart';
import '../widgets/tv_switcher.dart';

/// Apps on the TV: install an APK from the phone (Yandex TV, Sber and other
/// firmwares without Google Play), open any app on the TV, uninstall apps
/// the owner installed.
class AppsScreen extends ConsumerStatefulWidget {
  /// The tab is on screen: the app list loads only then.
  final bool visible;
  const AppsScreen({super.key, this.visible = true});
  @override
  ConsumerState<AppsScreen> createState() => _AppsScreenState();
}

class _AppsScreenState extends ConsumerState<AppsScreen> {
  List<TvApp>? _apps;
  String? _tvKey;
  bool _loading = false;
  String? _error;
  String? _step;          // install progress
  String? _installMsg;    // last install result
  bool _installOk = false;
  final Set<String> _busy = {};
  bool _playHidden = false; // Google Play is in the firmware but switched off
  bool _playBusy = false;
  String? _sendStep;      // «Отправить файл на ТВ» progress
  String? _sendMsg;
  bool _sendOk = false;
  String? _sentPath;      // the last file sent, for «Открыть на ТВ»

  AdbPackageManager get _api => ref.read(adbServiceProvider);

  Future<void> _load() async {
    final tv = ref.read(currentTvProvider);
    if (tv == null) return;
    setState(() { _loading = true; _error = null; });
    try {
      final apps = await _api.listApps(tv);
      if (mounted) setState(() => _apps = apps);
      final hidden = await _api.googlePlayHidden(tv).catchError((_) => false);
      if (mounted) setState(() => _playHidden = hidden);
    } catch (e) {
      if (mounted) setState(() => _error = e is AdbException ? e.message : tr('Телевизор не отвечает. Проверьте, что он включён и в той же Wi-Fi сети.'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickAndInstall() async {
    final tv = ref.read(currentTvProvider);
    if (tv == null) return;
    FilePickerResult? res;
    try {
      // Only the path: with withData the picker copies the whole file through the Java side,
      // and a big .xapk (Play Market, Kinopoisk: 100+ MB) crashed the app there.
      res = await FilePicker.platform.pickFiles(type: FileType.any, withData: false);
    } catch (e) {
      AppLog.error('pick apk', e);
      res = null;
    }
    final f = res?.files.single;
    if (f == null) return;
    Uint8List? data = f.bytes;
    if (data == null && f.path != null) {
      try {
        data = await File(f.path!).readAsBytes();
      } catch (e) {
        AppLog.error('read apk', e);
      }
    }
    if (data == null) {
      setState(() { _installOk = false; _installMsg = tr('Не удалось прочитать файл. Сохраните его в «Файлы» и попробуйте снова.'); });
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() { _step = tr('Готовим {0}…', [f.name]); _installMsg = null; });
    try {
      final pkg = await _api.installApk(tv, f.name, data,
          onStep: (s) { if (mounted) setState(() => _step = s); });
      if (!mounted) return;
      setState(() {
        _installOk = true;
        _installMsg = tr('Установлено: {0}. Его можно открыть кнопкой ниже.', [f.name]);
      });
      await _load();
      if (pkg.isNotEmpty && mounted) {
        final app = _apps?.where((a) => a.pkg == pkg).firstOrNull;
        if (app != null && app.launchable) _open(app);
      }
    } catch (e) {
      AppLog.error('install ${f.name} ${data.length}', e);
      if (mounted) {
        setState(() {
          _installOk = false;
          _installMsg = e is AdbException ? e.message : tr('Связь с телевизором прервалась. Попробуйте ещё раз.');
        });
      }
    } finally {
      if (mounted) setState(() => _step = null);
    }
  }

  /// «Отправить файл на ТВ»: any file (IPTV playlist, video, music, document) into the TV's
  /// Download/TVCleanzer, read from disk piece by piece.
  Future<void> _pickAndSend() async {
    final tv = ref.read(currentTvProvider);
    if (tv == null) return;
    FilePickerResult? res;
    try {
      res = await FilePicker.platform.pickFiles(type: FileType.any, withData: false);
    } catch (e) {
      AppLog.error('pick file', e);
    }
    final f = res?.files.single;
    if (f == null || f.path == null) return;
    final file = File(f.path!);
    int len;
    try {
      len = await file.length();
    } catch (e) {
      AppLog.error('read file', e);
      setState(() { _sendOk = false; _sendMsg = tr('Не удалось прочитать файл. Сохраните его в «Файлы» и попробуйте снова.'); });
      return;
    }
    HapticFeedback.mediumImpact();
    final mb = (len / 1048576).toStringAsFixed(1);
    setState(() {
      _sendStep = tr('Отправляем на телевизор: {0}% из {1} МБ. Не блокируйте телефон.', [0, mb]);
      _sendMsg = null;
      _sentPath = null;
    });
    try {
      var shown = 0;
      final path = await _api.sendFile(tv, f.name, file.openRead(), len, onProgress: (sent) {
        if (!mounted) return;
        final pct = len == 0 ? 100 : (sent * 100 / len).floor().clamp(0, 100);
        if (pct == shown) return; // a film comes in thousands of pieces: redraw once per percent
        shown = pct;
        setState(() => _sendStep = tr('Отправляем на телевизор: {0}% из {1} МБ. Не блокируйте телефон.', [pct, mb]));
      });
      if (!mounted) return;
      setState(() {
        _sendOk = true;
        _sentPath = path;
        _sendMsg = tr('Готово: {0} на телевизоре в «Загрузки» → «TVCleanzer».', [path.split('/').last]);
      });
    } catch (e) {
      AppLog.error('send ${f.name} $len', e);
      if (mounted) {
        setState(() {
          _sendOk = false;
          _sendMsg = e is AdbException ? e.message : tr('Связь с телевизором прервалась. Попробуйте ещё раз.');
        });
      }
    } finally {
      if (mounted) setState(() => _sendStep = null);
    }
  }

  Future<void> _openSent() async {
    final tv = ref.read(currentTvProvider);
    final p = _sentPath;
    if (tv == null || p == null) return;
    var ok = false;
    try {
      ok = await _api.openTvFile(tv, p);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _sendOk = ok;
      _sendMsg = ok
          ? tr('Открыли на телевизоре.')
          : tr('На телевизоре нет приложения, которое само открывает такой файл. Откройте его из нужного приложения: файл в «Загрузки» → «TVCleanzer».');
    });
  }

  Widget _sendCard() {
    final busy = _sendStep != null;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBd),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: AppColors.accentDim, borderRadius: BorderRadius.circular(10)),
            child: const Icon(Icons.drive_file_move_rounded, color: AppColors.accent, size: 22),
          ),
          const Gap(12),
          Expanded(
            child: Text(tr('Отправить файл на ТВ'),
                style: GoogleFonts.syne(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.fg)),
          ),
        ]),
        const Gap(10),
        Text(
          tr('Плейлист IPTV (.m3u), фильм, музыка, фото, документ — без флешки. Файл ляжет на телевизоре в «Загрузки» → «TVCleanzer». Плейлист потом добавьте в IPTV-приложении: «Добавить плейлист» → «Файл».'),
          style: const TextStyle(fontSize: 13, height: 1.45, color: AppColors.fgMid),
        ),
        const Gap(12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: busy ? null : _pickAndSend,
            icon: busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.upload_file_rounded),
            label: Text(busy ? _sendStep! : tr('Выбрать файл'), overflow: TextOverflow.ellipsis),
          ),
        ),
        if (_sendMsg != null) ...[
          const Gap(10),
          Text(_sendMsg!,
              style: TextStyle(fontSize: 13, height: 1.4, color: _sendOk ? AppColors.ok : AppColors.warn)),
        ],
        if (_sentPath != null && !busy) ...[
          const Gap(8),
          OutlinedButton.icon(
            onPressed: _openSent,
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
            label: Text(tr('Открыть на ТВ')),
          ),
        ],
      ]),
    );
  }

  Future<void> _open(TvApp a) async {
    final tv = ref.read(currentTvProvider);
    if (tv == null) return;
    HapticFeedback.selectionClick();
    setState(() => _busy.add(a.pkg));
    try {
      final ok = await _api.openApp(tv, a.pkg);
      _snack(ok ? tr('Открыли «{0}» на телевизоре', [a.label]) : tr('«{0}» не открывается: у него нет экрана запуска.', [a.label]));
    } catch (_) {
      _snack(tr('Телевизор не отвечает.'));
    } finally {
      if (mounted) setState(() => _busy.remove(a.pkg));
    }
  }

  Future<void> _uninstall(TvApp a) async {
    final tv = ref.read(currentTvProvider);
    if (tv == null) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('Удалить «{0}»?', [a.label])),
        content: Text(tr('Приложение и его данные будут удалены с телевизора. Вернуть можно только установкой заново.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Отмена'))),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(tr('Удалить'), style: const TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (yes != true) return;
    setState(() => _busy.add(a.pkg));
    try {
      final ok = await _api.uninstallApp(tv, a.pkg);
      if (ok) {
        setState(() => _apps?.removeWhere((x) => x.pkg == a.pkg));
        _snack(tr('«{0}» удалено', [a.label]));
      } else {
        _snack(tr('Телевизор не дал удалить «{0}».', [a.label]));
      }
    } catch (_) {
      _snack(tr('Телевизор не отвечает.'));
    } finally {
      if (mounted) setState(() => _busy.remove(a.pkg));
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final tv = ref.watch(currentTvProvider);
    final key = tv == null ? null : '${tv.ipAddress}:${tv.port}';
    if (key != _tvKey) {
      _tvKey = key;
      _apps = null;
      _error = null;
      _installMsg = null;
      if (key != null && widget.visible) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _load());
      }
    } else if (key != null && _apps == null && !_loading && _error == null && widget.visible) {
      // The tab became visible: load lazily.
      WidgetsBinding.instance.addPostFrameCallback((_) { if (_apps == null && !_loading) _load(); });
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Приложения')),
        actions: [
          if (tv != null)
            IconButton(
              tooltip: tr('Обновить'),
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh_rounded),
            ),
        ],
      ),
      body: tv == null
          ? _empty(tr('Выберите телевизор на вкладке «Очистка».'))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  const TvBanner(),
                  const Gap(14),
                  if (_playHidden) ...[_playCard(), const Gap(14)],
                  _installCard(),
                  const Gap(14),
                  _sendCard(),
                  const Gap(20),
                  Text(tr('НА ТЕЛЕВИЗОРЕ'),
                      style: const TextStyle(
                          fontSize: 12, letterSpacing: 1.2, fontWeight: FontWeight.w700, color: AppColors.fgMuted)),
                  const Gap(10),
                  if (_error != null)
                    Text(_error!, style: const TextStyle(color: AppColors.danger, height: 1.4))
                  else if (_apps == null)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  else if (_apps!.isEmpty)
                    Text(tr('Телевизор не показал ни одного приложения.'),
                        style: const TextStyle(color: AppColors.fgMid))
                  else
                    for (var i = 0; i < _apps!.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _appTile(_apps![i])
                            .animate(delay: (i.clamp(0, 12) * 30).ms)
                            .fadeIn(duration: 200.ms),
                      ),
                ],
              ),
            ),
    );
  }

  Widget _empty(String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.apps_rounded, size: 56, color: AppColors.fgMuted),
            const Gap(16),
            Text(text, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.fgMid, height: 1.5)),
          ]),
        ),
      );

  Future<void> _restorePlay() async {
    final tv = ref.read(currentTvProvider);
    if (tv == null) return;
    setState(() => _playBusy = true);
    var ok = false;
    try {
      ok = await _api.restoreGooglePlay(tv);
    } catch (e) {
      AppLog.error('google play', e);
    }
    if (!mounted) return;
    setState(() {
      _playBusy = false;
      if (ok) _playHidden = false;
    });
    _snack(ok
        ? tr('Google Play снова включён на телевизоре.')
        : tr('Не получилось включить Google Play: прошивка не даёт. Подробности — в отчёте «?».'));
    if (ok) await _load();
  }

  Widget _playCard() => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.bgCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.accent.withValues(alpha: .4)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Google Play выключен'),
              style: GoogleFonts.syne(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.fg)),
          const Gap(8),
          Text(
            tr('Google Play есть в прошивке телевизора, но выключен или скрыт. Его не нужно ставить из файла: достаточно включить.'),
            style: const TextStyle(fontSize: 13, height: 1.45, color: AppColors.fgMid),
          ),
          const Gap(12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _playBusy ? null : _restorePlay,
              icon: _playBusy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.shop_rounded),
              label: Text(tr('Включить Google Play')),
            ),
          ),
        ]),
      );

  Widget _installCard() {
    final busy = _step != null;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBd),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: AppColors.accentDim, borderRadius: BorderRadius.circular(10)),
            child: const Icon(Icons.install_mobile_rounded, color: AppColors.accent, size: 22),
          ),
          const Gap(12),
          Expanded(
            child: Text(tr('Установить приложение из файла'),
                style: GoogleFonts.syne(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.fg)),
          ),
        ]),
        const Gap(10),
        Text(
          tr('Скачайте APK на телефон (например, SmartTube или Кинопоиск для ТВ) и выберите его здесь — TVCleanzer поставит его на телевизор. Нужно для Яндекс ТВ, Сбера и других телевизоров без Google Play. Подходят .apk, .apks и .xapk.'),
          style: const TextStyle(fontSize: 13, height: 1.45, color: AppColors.fgMid),
        ),
        const Gap(12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: busy ? null : _pickAndInstall,
            icon: busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.folder_open_rounded),
            label: Text(busy ? _step! : tr('Выбрать файл APK'), overflow: TextOverflow.ellipsis),
          ),
        ),
        if (_installMsg != null) ...[
          const Gap(10),
          Text(_installMsg!,
              style: TextStyle(fontSize: 13, height: 1.4, color: _installOk ? AppColors.ok : AppColors.danger)),
        ],
        const Gap(8),
        Text(tr('Ставьте приложения только из источников, которым доверяете.'),
            style: const TextStyle(fontSize: 12, color: AppColors.fgMuted)),
      ]),
    );
  }

  Widget _appTile(TvApp a) {
    final busy = _busy.contains(a.pkg);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: AppColors.bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.cardBd),
      ),
      child: Row(children: [
        Icon(a.user ? Icons.download_done_rounded : Icons.tv_rounded,
            size: 20, color: a.user ? AppColors.accent : AppColors.fgMuted),
        const Gap(12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(a.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.fg)),
            Text(a.pkg,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: AppColors.fgMuted)),
          ]),
        ),
        if (busy)
          const Padding(
            padding: EdgeInsets.all(12),
            child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else ...[
          if (a.launchable)
            TextButton(onPressed: () => _open(a), child: Text(tr('Открыть'))),
          if (a.user)
            IconButton(
              tooltip: tr('Удалить'),
              onPressed: () => _uninstall(a),
              icon: const Icon(Icons.delete_outline_rounded, color: AppColors.fgMid),
            ),
        ],
      ]),
    );
  }
}
