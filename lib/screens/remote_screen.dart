import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/tv_device.dart';
import '../services/adb_client.dart';
import '../services/adb_package_manager.dart';
import '../services/app_log.dart';
import '../services/demo_tv.dart';
import '../services/mirror.dart';
import '../state/current_tv.dart';
import '../state/remote.dart';
import '../theme/app_theme.dart';
import '../widgets/pressable.dart';

import '../l10n/l10n.dart';
import '../widgets/tv_switcher.dart';
class RemoteScreen extends ConsumerStatefulWidget {
  const RemoteScreen({super.key});
  @override
  ConsumerState<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends ConsumerState<RemoteScreen> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  bool _sending = false;
  bool _pad = false; // touchpad instead of the arrows
  String? _favsFor;
  double? _bright; // 1–255, null until the TV says it has a brightness setting
  List<LauncherApp> _favs = const [];
  int _sleepMin = 0;
  DateTime? _sleepAt;
  String? _busy; // what is being sent to the TV right now
  StreamSubscription<String?>? _mirrorEnded;

  @override
  void initState() {
    super.initState();
    Mirror.sync();
    _mirrorEnded = Mirror.ended.listen((reason) {
      // 'connect|<system error>': the detail helps when someone sends a screenshot
      final why = reason?.split('|').first;
      final detail = reason != null && reason.contains('|') ? reason.substring(reason.indexOf('|') + 1) : '';
      final m = switch (why) {
        'connect' => '${tr('Телефон не достучался до телевизора. Проверьте, что они в одной Wi-Fi сети.')}'
            '${detail.isEmpty ? '' : ' ($detail)'}',
        'token' => tr('Телевизор не принял телефон. Попробуйте ещё раз.'),
        'encoder' => tr('Этот телефон не смог сжать видео экрана.'),
        'closed' => tr('Повтор экрана закончился.'),
        _ => null,
      };
      if (m != null) _snack(m);
    });
  }

  @override
  void dispose() {
    _mirrorEnded?.cancel();
    _speech.cancel();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _key(TvDevice tv, int code) =>
      ref.read(remoteProvider.notifier).key(tv.id, code);

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  /// The launcher's favourites, for quick launch (only with our launcher on the TV).
  void _loadFavs(TvDevice tv) {
    if (_favsFor == tv.id) return;
    _favsFor = tv.id;
    _bright = null;
    ref.read(remoteProvider.notifier).brightness(tv.id).then((v) {
      if (mounted && _favsFor == tv.id && v != null && v >= 0 && v <= 255) {
        setState(() => _bright = v.clamp(1, 255).toDouble());
      }
    }).catchError((_) {});
    ref.read(adbServiceProvider).launcherState(tv).then((s) {
      final f = s.apps.where((a) => a.fav >= 0 && !a.hidden).toList()..sort((a, b) => a.fav.compareTo(b.fav));
      if (mounted && _favsFor == tv.id) setState(() => _favs = f);
    }).catchError((_) {});
  }

  Future<void> _sendText(TvDevice tv) async {
    final value = _text.text.trim();
    if (value.isEmpty) return;
    setState(() => _sending = true);
    try {
      await ref.read(remoteProvider.notifier).text(tv.id, value);
      _text.clear();
    } on NeedsLauncher {
      _snack(tr('Русский текст передаётся через лаунчер TVCleanzer: установите или обновите его на вкладке «Лаунчер».'));
    } catch (_) {
      // status card shows the error
    }
    if (mounted) setState(() => _sending = false);
  }

  // ── «Сказать голосом»: the phone's own speech recognizer fills the text field ──
  final _speech = SpeechToText();
  bool? _speechReady;
  bool _listening = false;

  Future<void> _voice(TvDevice tv) async {
    if (_listening) {
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    try {
      _speechReady ??= await _speech.initialize(
        onError: (_) {
          if (mounted) setState(() => _listening = false);
        },
        onStatus: (s) {
          if ((s == 'done' || s == 'notListening') && mounted) setState(() => _listening = false);
        },
      );
    } catch (e) {
      AppLog.error('speech init', e);
      _speechReady = false;
    }
    if (_speechReady != true) {
      _speechReady = null; // ask again next time: the owner may allow it in the settings
      _snack(tr('Голосовой ввод недоступен: разрешите микрофон и распознавание речи в настройках телефона.'));
      return;
    }
    HapticFeedback.selectionClick();
    setState(() => _listening = true);
    try {
      await _speech.listen(
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: true,
          listenMode: ListenMode.search,
          pauseFor: const Duration(seconds: 3),
          listenFor: const Duration(seconds: 30),
        ),
        onResult: (r) {
          if (!mounted) return;
          final words = r.recognizedWords;
          _text.value = TextEditingValue(text: words, selection: TextSelection.collapsed(offset: words.length));
          if (r.finalResult) {
            setState(() => _listening = false);
            // what people say into a TV remote is a search: find it in the app on screen
            // (YouTube took no typed Russian text, tester 22.11); ➤ still types it if needed
            if (words.trim().isNotEmpty) _search(tv, keep: true);
          }
        },
      );
    } catch (e) {
      AppLog.error('speech listen', e);
      if (mounted) setState(() => _listening = false);
    }
  }

  Future<void> _search(TvDevice tv, {bool keep = false}) async {
    final value = _text.text.trim();
    if (value.isEmpty) {
      _key(tv, 84); // the Search key: the TV's own search screen
      return;
    }
    await _run(tr('Ищем на ТВ…'), () => ref.read(adbServiceProvider).tvSearch(tv, value));
    if (!keep) _text.clear();
  }

  /// Runs a one-off TV command with a «busy» line; errors become a snackbar.
  Future<void> _run(String label, Future<void> Function() job) async {
    if (_busy != null) return;
    setState(() => _busy = label);
    try {
      await job();
    } catch (e) {
      _snack(e is AdbException ? e.message : tr('Нет связи с телевизором. Проверьте, что он включён и в той же Wi-Fi сети.'));
    }
    if (mounted) setState(() => _busy = null);
  }

  Future<void> _castPhoto(TvDevice tv) async {
    final img = await ImagePicker().pickImage(
        source: ImageSource.gallery, maxWidth: 1920, maxHeight: 1920, imageQuality: 88);
    if (img == null) return;
    final bytes = await img.readAsBytes();
    await _run(tr('Отправляем на ТВ…'),
        () => ref.read(adbServiceProvider).castFile(tv, Stream.value(bytes), bytes.length, video: false));
  }

  /// Any size: the file goes to the TV straight from the phone's storage, piece by piece.
  Future<void> _castVideo(TvDevice tv) async {
    final v = await ImagePicker().pickVideo(source: ImageSource.gallery);
    if (v == null) return;
    final len = await v.length();
    await _run(tr('Отправляем на ТВ…'), () => ref.read(adbServiceProvider).castFile(tv, v.openRead(), len,
            video: true, onProgress: (sent) {
          if (mounted) {
            setState(() => _busy = '${tr('Отправляем на ТВ…')} ${(sent * 100 / len).round()}%');
          }
        }, onSaving: () {
          // a big film takes a while to settle on the TV after 100 %
          if (mounted) setState(() => _busy = tr('Сохраняем на телевизоре…'));
        }));
  }

  Future<void> _castLink(TvDevice tv) async {
    final c = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Ссылка')),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(hintText: tr('Ссылка на видео или сайт')),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Отмена'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: Text(tr('Открыть на ТВ'))),
        ],
      ),
    );
    var u = (url ?? '').trim();
    if (u.isEmpty) return;
    if (!u.contains('://')) u = 'https://$u';
    await _run(tr('Открываем на ТВ…'), () async {
      if (!await ref.read(adbServiceProvider).openUrl(tv, u)) {
        throw AdbException(tr('На телевизоре нет приложения, которое откроет эту ссылку.'));
      }
    });
  }

  Future<void> _screenshot(TvDevice tv) async {
    Uint8List? png;
    await _run(tr('Снимаем экран ТВ…'), () async => png = await ref.read(adbServiceProvider).screenshot(tv));
    final shot = png;
    if (shot == null || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: AppColors.bgCard,
        insetPadding: const EdgeInsets.all(12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            child: InteractiveViewer(child: Image.memory(shot, fit: BoxFit.contain)),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Builder(
              builder: (bctx) => FilledButton.icon(
                onPressed: () => _shareShot(bctx, shot),
                icon: Icon(Platform.isWindows ? Icons.save_alt_rounded : Icons.ios_share_rounded),
                label: Text(Platform.isWindows ? tr('Сохранить') : tr('Поделиться')),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  /// The TV screenshot to Telegram, the gallery… (phones) or a file (Windows).
  Future<void> _shareShot(BuildContext ctx, Uint8List png) async {
    final name = 'tv-${DateTime.now().toIso8601String().substring(0, 19).replaceAll(':', '-')}.png';
    try {
      if (Platform.isWindows) {
        final uri = await FilePicker.saveFile(fileName: name, bytes: png, mimeType: 'image/png');
        if (uri == null) return;
        final path = uri.scheme == 'file' ? uri.toFilePath() : uri.toString();
        final f = File(path);
        if (!await f.exists() || await f.length() == 0) await f.writeAsBytes(png);
        _snack(tr('Сохранено: {0}', [path]));
        return;
      }
      final box = ctx.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(ShareParams(
        files: [XFile.fromData(png, mimeType: 'image/png', name: name)],
        fileNameOverrides: [name],
        sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      ));
    } catch (_) {
      _snack(tr('Не получилось сохранить снимок.'));
    }
  }

  /// «Повтор экрана»: the phone's screen (and sound) live on the TV.
  Future<void> _mirror(TvDevice tv) async {
    if (Mirror.running.value) {
      await Mirror.stop();
      return;
    }
    var hd = false, audio = true;
    final go = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AppColors.bgCard,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(tr('Повтор экрана'),
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.fg)),
              const Gap(8),
              Text(tr('Всё, что на экране телефона, появится на телевизоре. Телефон спросит разрешение на запись экрана.'),
                  style: const TextStyle(fontSize: 13, color: AppColors.fgMid, height: 1.4)),
              const Gap(16),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: false, label: Text(tr('Плавнее'))),
                  ButtonSegment(value: true, label: Text(tr('Чётче'))),
                ],
                selected: {hd},
                onSelectionChanged: (v) => set(() => hd = v.first),
              ),
              const Gap(4),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: audio,
                onChanged: (v) => set(() => audio = v),
                title: Text(tr('Со звуком'), style: const TextStyle(color: AppColors.fg)),
                subtitle: Text(Mirror.ios ? tr('Звук игр и видео пойдёт на телевизор') : tr('Звук игр и видео пойдёт на телевизор (Android 10 и новее)'),
                    style: const TextStyle(fontSize: 12, color: AppColors.fgMuted)),
              ),
              Text(tr('Платные кинотеатры и банки прячут свой экран: на ТВ там будет чёрный.'),
                  style: const TextStyle(fontSize: 11.5, color: AppColors.fgMuted)),
              const Gap(14),
              FilledButton.icon(
                onPressed: () => Navigator.pop(ctx, true),
                icon: const Icon(Icons.cast_rounded),
                label: Text(tr('Показать на ТВ')),
              ),
            ]),
          ),
        ),
      ),
    );
    if (go != true || !mounted) return;
    if (tv.ipAddress == DemoTv.host) {
      _snack(tr('В демо-режиме повтор экрана не работает: подключите настоящий телевизор.'));
      return;
    }
    final token = Mirror.newToken();
    final adb = ref.read(adbServiceProvider);
    var ready = false;
    await _run(tr('Готовим телевизор…'), () async {
      if (await adb.launcherVersion(tv) < 43) {
        throw AdbException(tr('Обновите лаунчер на ТВ: повтор экрана есть в новой версии.'));
      }
      ready = true;
    });
    if (!ready || !mounted) return;
    if (Mirror.ios) {
      // iPhone: the TV listens first (a minute), then the system sheet starts the extension
      var listening = false;
      await _run(tr('Готовим телевизор…'), () async {
        if (!await adb.startMirror(tv, port: Mirror.port, token: token)) {
          throw AdbException(tr('Обновите лаунчер на ТВ: повтор экрана есть в новой версии.'));
        }
        listening = true;
      });
      if (!listening || !mounted) return;
      final ok = await Mirror.start(
        host: tv.ipAddress,
        adbPort: tv.port,
        token: token,
        hd: hd,
        audio: audio,
        title: tr('Экран телефона на телевизоре'),
        stopLabel: tr('Остановить'),
        texts: {
          'errStart': tr('Сначала нажмите «Повтор экрана» в TVCleanzer.'),
          'errConnect': tr('Телефон не достучался до телевизора. Проверьте, что они в одной Wi-Fi сети.'),
          'errToken': tr('Телевизор не принял телефон. Попробуйте ещё раз.'),
          'msgClosed': tr('Повтор экрана закончился.'),
          'msgStopped': tr('Повтор экрана остановлен.'),
        },
      );
      if (ok == null) {
        ref.read(adbServiceProvider).closeMirror(tv);
        return;
      }
      _snack(tr('Выберите TVCleanzer и нажмите «Начать вещание». Остановить — здесь или красной плашкой вверху экрана.'));
      return;
    }
    // the phone's permission first: it opens our port, then the TV is told where to find us
    final r = await Mirror.start(
      host: tv.ipAddress,
      adbPort: tv.port,
      token: token,
      hd: hd,
      audio: audio,
      title: tr('Экран телефона на телевизоре'),
      stopLabel: tr('Остановить'),
    );
    if (r == null || !mounted) return;
    var shown = false;
    await _run(tr('Готовим телевизор…'), () async {
      if (!await adb.startMirror(tv, port: Mirror.port, token: token, phone: r.phone, phonePort: r.phonePort)) {
        await Mirror.stop();
        throw AdbException(tr('Обновите лаунчер на ТВ: повтор экрана есть в новой версии.'));
      }
      shown = true;
    });
    if (!shown) return;
    _snack(tr('Экран телефона на телевизоре. Остановить — здесь, в уведомлении или кнопкой «Назад» на пульте ТВ.'));
  }

  /// Power: over ADB, or Wake-on-LAN when the TV sleeps too deep to answer.
  Future<void> _power(TvDevice tv) async {
    final r = await ref.read(remoteProvider.notifier).power(tv.id);
    switch (r) {
      case PowerResult.sent:
        break;
      case PowerResult.wol:
        _snack(tr('Телевизор не отвечал: отправили ему сигнал включения по сети. Если не включился, в настройках ТВ включите «Включение по сети» (Wake on LAN).'));
      case PowerResult.unreachable:
        _snack(tr('Телевизор не отвечает. Включите его обычным пультом один раз: после этого телефон научится его будить.'));
    }
  }

  Future<void> _sleep(TvDevice tv) async {
    final options = [15, 30, 60, 90, 120];
    final pick = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: AppColors.bgCard,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(tr('Таймер сна'),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.fg)),
          ),
          for (final m in options)
            ListTile(
              leading: const Icon(Icons.bedtime_rounded, color: AppColors.accent),
              title: Text(tr('Выключить через {0} мин', ['$m']), style: const TextStyle(color: AppColors.fg)),
              onTap: () => Navigator.pop(ctx, m),
            ),
          if (_sleepAt != null)
            ListTile(
              leading: const Icon(Icons.close_rounded, color: AppColors.warn),
              title: Text(tr('Отменить таймер'), style: const TextStyle(color: AppColors.fg)),
              onTap: () => Navigator.pop(ctx, 0),
            ),
          const Gap(8),
        ]),
      ),
    );
    if (pick == null) return;
    await _run(tr('Ставим таймер…'), () async {
      await ref.read(adbServiceProvider).sleepTimer(tv, pick);
      setState(() {
        _sleepMin = pick;
        _sleepAt = pick == 0 ? null : DateTime.now().add(Duration(minutes: pick));
      });
      _snack(pick == 0 ? tr('Таймер сна отменён.') : tr('Телевизор выключится через {0} мин.', ['$pick']));
    });
  }

  /// The phone's own volume keys turn the TV up and down (Android: iOS keeps them).
  KeyEventResult _onKey(TvDevice tv, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return e.logicalKey == LogicalKeyboardKey.audioVolumeUp || e.logicalKey == LogicalKeyboardKey.audioVolumeDown
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (e.logicalKey == LogicalKeyboardKey.audioVolumeUp) {
      _key(tv, Keys.volUp);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.audioVolumeDown) {
      _key(tv, Keys.volDown);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final tv = ref.watch(currentTvProvider);
    final rs = ref.watch(remoteProvider);
    if (tv != null) _loadFavs(tv);
    final body = tv == null
        ? _noTv()
        : SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(children: [
              _status(tv, rs),
              if (_busy != null) ...[
                const Gap(10),
                Row(children: [
                  const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  const Gap(10),
                  Expanded(child: Text(_busy!, style: const TextStyle(fontSize: 13, color: AppColors.fgMid))),
                ]),
              ],
              const Gap(16),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: false, icon: const Icon(Icons.gamepad_rounded), label: Text(tr('Кнопки'))),
                  ButtonSegment(value: true, icon: const Icon(Icons.touch_app_rounded), label: Text(tr('Сенсорная панель'))),
                ],
                selected: {_pad},
                onSelectionChanged: (v) => setState(() => _pad = v.first),
              ),
              const Gap(18),
              _pad ? _TouchPad(onKey: (c) => _key(tv, c), onLongOk: () => ref.read(remoteProvider.notifier).longKey(tv.id, Keys.ok)) : _DPad(onKey: (c) => _key(tv, c)),
              const Gap(24),
              Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                _RoundButton(icon: Icons.arrow_back_rounded, label: tr('Назад'), onTap: () => _key(tv, Keys.back)),
                _RoundButton(icon: Icons.home_rounded, label: tr('Домой'), onTap: () => _key(tv, Keys.home)),
                _RoundButton(icon: Icons.menu_rounded, label: tr('Меню'), onTap: () => _key(tv, Keys.menu)),
                _RoundButton(icon: Icons.power_settings_new_rounded, label: tr('Питание'),
                    onTap: () => _power(tv), color: AppColors.danger),
              ]),
              const Gap(18),
              Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                _RoundButton(icon: Icons.volume_down_rounded, label: tr('Тише'), onTap: () => _key(tv, Keys.volDown)),
                _RoundButton(icon: Icons.volume_off_rounded, label: tr('Без звука'), onTap: () => _key(tv, Keys.mute)),
                _RoundButton(icon: Icons.volume_up_rounded, label: tr('Громче'), onTap: () => _key(tv, Keys.volUp)),
                _RoundButton(icon: Icons.input_rounded, label: tr('Источник'), onTap: () => _key(tv, Keys.input)),
              ]),
              const Gap(18),
              Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                _RoundButton(icon: Icons.skip_previous_rounded, label: '', onTap: () => _key(tv, Keys.prev), small: true),
                _RoundButton(icon: Icons.fast_rewind_rounded, label: '', onTap: () => _key(tv, Keys.rewind), small: true),
                _RoundButton(icon: Icons.play_arrow_rounded, label: '', onTap: () => _key(tv, Keys.playPause), small: true),
                _RoundButton(icon: Icons.fast_forward_rounded, label: '', onTap: () => _key(tv, Keys.forward), small: true),
                _RoundButton(icon: Icons.skip_next_rounded, label: '', onTap: () => _key(tv, Keys.next), small: true),
              ]),
              const Gap(18),
              Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                _RoundButton(icon: Icons.view_carousel_rounded, label: tr('Запущенные'), onTap: () => ref.read(remoteProvider.notifier).recents(tv.id).catchError((_) {})),
                _RoundButton(icon: Icons.settings_rounded, label: tr('Настройки'), onTap: () => _key(tv, Keys.settings)),
                _RoundButton(icon: Icons.bedtime_rounded,
                    label: _sleepAt == null ? tr('Таймер сна') : tr('{0} мин', ['$_sleepMin']),
                    onTap: () => _sleep(tv)),
                _RoundButton(icon: Icons.screenshot_monitor_rounded, label: tr('Снимок'), onTap: () => _screenshot(tv)),
              ]),
              if (_bright != null) ...[const Gap(14), _brightRow(tv)],
              if (_favs.isNotEmpty) ...[const Gap(24), _favRow(tv)],
              const Gap(24),
              _textInput(tv),
              const Gap(6),
              Text(tr('🎤 — скажите, и это найдётся в приложении на экране (YouTube, VK Видео…). ➤ — набрать текст на телевизоре.'),
                  style: const TextStyle(fontSize: 11.5, color: AppColors.fgMuted)),
              const Gap(24),
              _castRow(tv),
            ]).animate().fadeIn(duration: 300.ms),
          );
    return Scaffold(
      appBar: AppBar(title: Text(tr('Пульт'))),
      body: tv == null
          ? body
          : Focus(autofocus: true, focusNode: _focus, onKeyEvent: (_, e) => _onKey(tv, e), child: body),
    );
  }

  Widget _section(String title) => Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(title.toUpperCase(),
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: .8, color: AppColors.fgMuted)),
        ),
      );

  /// Screen brightness: sent when the finger lets go (one command, not a hundred).
  Widget _brightRow(TvDevice tv) => Column(children: [
        Row(children: [
          const Icon(Icons.brightness_low_rounded, color: AppColors.fgMid, size: 20),
          Expanded(
            child: Slider(
              min: 1,
              max: 255,
              value: _bright!,
              onChanged: (v) => setState(() => _bright = v),
              onChangeEnd: (v) => ref.read(remoteProvider.notifier).setBrightness(tv.id, v.round()).catchError((_) {}),
            ),
          ),
          const Icon(Icons.brightness_high_rounded, color: AppColors.fgMid, size: 20),
        ]),
        Text(tr('Яркость экрана. Некоторые телевизоры берут её только из своих настроек изображения.'),
            textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, color: AppColors.fgMuted)),
      ]);

  Widget _favRow(TvDevice tv) => Column(children: [
        _section(tr('Избранное')),
        SizedBox(
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _favs.length,
            separatorBuilder: (_, __) => const Gap(8),
            itemBuilder: (_, i) {
              final a = _favs[i];
              return ActionChip(
                avatar: const Icon(Icons.play_circle_outline_rounded, size: 18, color: AppColors.accent),
                label: Text(a.label),
                onPressed: () => _run(tr('Открываем на ТВ…'), () async {
                  if (!await ref.read(adbServiceProvider).openApp(tv, a.pkg)) {
                    throw AdbException(tr('Не удалось открыть {0}', [a.label]));
                  }
                }),
              );
            },
          ),
        ),
      ]);

  Widget _castRow(TvDevice tv) => Column(children: [
        _section(tr('Трансляция с телефона')),
        if (Mirror.supported) ...[
          ValueListenableBuilder<bool>(
            valueListenable: Mirror.running,
            builder: (_, on, __) => SizedBox(
              width: double.infinity,
              height: 54,
              child: on
                  ? FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
                      onPressed: () => _mirror(tv),
                      icon: const Icon(Icons.stop_screen_share_rounded),
                      label: Text(tr('Остановить повтор экрана')),
                    )
                  : FilledButton.icon(
                      onPressed: () => _mirror(tv),
                      icon: const Icon(Icons.screen_share_rounded),
                      label: Text(tr('Повтор экрана')),
                    ),
            ),
          ),
          const Gap(10),
        ],
        Row(children: [
          Expanded(child: _CastButton(icon: Icons.photo_rounded, label: tr('Фото'), onTap: () => _castPhoto(tv))),
          const Gap(10),
          Expanded(child: _CastButton(icon: Icons.movie_rounded, label: tr('Видео'), onTap: () => _castVideo(tv))),
          const Gap(10),
          Expanded(child: _CastButton(icon: Icons.link_rounded, label: tr('Ссылка'), onTap: () => _castLink(tv))),
        ]),
      ]);

  Widget _noTv() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.settings_remote_rounded, size: 56, color: AppColors.fgMuted),
            const SizedBox(height: 16),
            Text(
              tr('Сначала выберите телевизор на вкладке «Очистка», и телефон станет его пультом.'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.fgMid, height: 1.5),
            ),
          ]),
        ),
      );

  Widget _status(TvDevice tv, RemoteState rs) {
    final (color, text) = switch (rs.status) {
      RemoteStatus.idle => (AppColors.fgMuted, tr('Нажмите любую кнопку, чтобы подключиться')),
      RemoteStatus.connecting => (AppColors.warn, tr('Подключаемся…')),
      RemoteStatus.ready => (AppColors.ok, tr('Подключено')),
      RemoteStatus.error => (AppColors.danger, rs.message ?? tr('Нет связи')),
    };
    final sw = TvBanner.canSwitch(ref);
    final card = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBd),
      ),
      child: Row(children: [
        const Icon(Icons.tv_rounded, color: AppColors.accent),
        const Gap(12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tv.shortName.isEmpty ? tv.ipAddress : tv.shortName,
                style: GoogleFonts.syne(
                    fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.fg)),
            const Gap(2),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Text(text,
                  key: ValueKey(text),
                  style: TextStyle(fontSize: 12, color: color)),
            ),
          ]),
        ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        // several TVs: tap the card to send the keys to another one
        if (sw) ...[const Gap(10), const Icon(Icons.unfold_more_rounded, color: AppColors.fgMid)],
      ]),
    );
    return Material(
      color: AppColors.bgCard,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: sw ? () => TvBanner.pick(context, ref) : null, child: card),
    );
  }

  Widget _textInput(TvDevice tv) => Row(children: [
        Expanded(
          child: TextField(
            controller: _text,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _sendText(tv),
            style: const TextStyle(color: AppColors.fg),
            decoration: InputDecoration(
              hintText: _listening ? tr('Говорите…') : tr('Текст или поиск на ТВ'),
              suffixIcon: IconButton(
                tooltip: tr('Сказать голосом'),
                onPressed: () => _voice(tv),
                icon: Icon(_listening ? Icons.mic_rounded : Icons.mic_none_rounded,
                    color: _listening ? AppColors.accent : AppColors.fgMid),
              ),
              hintStyle: const TextStyle(color: AppColors.fgMuted),
              filled: true,
              fillColor: AppColors.bgCard,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: AppColors.cardBd),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: AppColors.cardBd),
              ),
            ),
          ),
        ),
        const Gap(8),
        SizedBox(
          height: 50,
          child: IconButton.filledTonal(
            tooltip: tr('Поиск на ТВ'),
            onPressed: () => _search(tv),
            icon: const Icon(Icons.search_rounded),
          ),
        ),
        const Gap(8),
        SizedBox(
          height: 50,
          child: FilledButton(
            onPressed: _sending ? null : () => _sendText(tv),
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 16)),
            child: _sending
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send_rounded),
          ),
        ),
      ]);
}

class _DPad extends StatelessWidget {
  final ValueChanged<int> onKey;
  const _DPad({required this.onKey});

  @override
  Widget build(BuildContext context) {
    Widget arrow(IconData icon, int code) => Pressable(
          onTap: () => onKey(code),
          child: SizedBox(
            width: 72,
            height: 72,
            child: Icon(icon, size: 40, color: AppColors.fg),
          ),
        );

    return Container(
      width: 250,
      height: 250,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.bgCard,
        border: Border.all(color: AppColors.cardBd),
        boxShadow: const [
          BoxShadow(color: Color(0x55000000), blurRadius: 30, offset: Offset(0, 12)),
        ],
      ),
      child: Stack(alignment: Alignment.center, children: [
        Align(alignment: Alignment.topCenter, child: arrow(Icons.keyboard_arrow_up_rounded, Keys.up)),
        Align(alignment: Alignment.bottomCenter, child: arrow(Icons.keyboard_arrow_down_rounded, Keys.down)),
        Align(alignment: Alignment.centerLeft, child: arrow(Icons.keyboard_arrow_left_rounded, Keys.left)),
        Align(alignment: Alignment.centerRight, child: arrow(Icons.keyboard_arrow_right_rounded, Keys.right)),
        Pressable(
          onTap: () => onKey(Keys.ok),
          child: Container(
            width: 92,
            height: 92,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.accent,
              boxShadow: [
                BoxShadow(
                    color: AppColors.accent.withValues(alpha: .35),
                    blurRadius: 24,
                    offset: const Offset(0, 6)),
              ],
            ),
            alignment: Alignment.center,
            child: Text('OK',
                style: GoogleFonts.syne(
                    fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.bg)),
          ),
        ),
      ]),
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;
  final bool small;
  const _RoundButton({required this.icon, required this.label, required this.onTap, this.color, this.small = false});

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: small ? 48 : 58,
          height: small ? 48 : 58,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.bgCard,
            border: Border.all(color: AppColors.cardBd),
          ),
          child: Icon(icon, color: color ?? AppColors.fg),
        ),
        if (label.isNotEmpty) ...[
          const Gap(6),
          Text(label, style: const TextStyle(fontSize: 11, color: AppColors.fgMid)),
        ],
      ]),
    );
  }
}

class _CastButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _CastButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        child: Container(
          height: 74,
          decoration: BoxDecoration(
            color: AppColors.bgCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.cardBd),
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, color: AppColors.accent),
            const Gap(6),
            Text(label, style: const TextStyle(fontSize: 12.5, color: AppColors.fg)),
          ]),
        ),
      );
}

/// Touchpad: a swipe moves the focus (longer swipes, more steps), a tap is OK, a long
/// press is a long OK (the TV's «options» on a tile).
class _TouchPad extends StatefulWidget {
  final ValueChanged<int> onKey;
  final VoidCallback onLongOk;
  const _TouchPad({required this.onKey, required this.onLongOk});

  @override
  State<_TouchPad> createState() => _TouchPadState();
}

class _TouchPadState extends State<_TouchPad> {
  static const _step = 48.0; // finger travel per key press
  static const _slop = 12.0; // less than this is a tap, not a swipe
  Offset _acc = Offset.zero;
  Offset? _dot;
  int? _pointer;
  Offset _start = Offset.zero;
  bool _moved = false, _longDone = false;
  Timer? _long;

  @override
  void dispose() {
    _long?.cancel();
    super.dispose();
  }

  void _move(Offset d) {
    _acc += d;
    while (_acc.dx.abs() >= _step || _acc.dy.abs() >= _step) {
      if (_acc.dx.abs() >= _acc.dy.abs()) {
        final right = _acc.dx > 0;
        widget.onKey(right ? Keys.right : Keys.left);
        _acc = Offset(_acc.dx + (right ? -_step : _step), 0);
      } else {
        final down = _acc.dy > 0;
        widget.onKey(down ? Keys.down : Keys.up);
        _acc = Offset(0, _acc.dy + (down ? -_step : _step));
      }
      HapticFeedback.selectionClick();
    }
  }

  void _down(PointerDownEvent e) {
    if (_pointer != null) return; // one finger
    _pointer = e.pointer;
    _start = e.localPosition;
    _acc = Offset.zero;
    _moved = false;
    _longDone = false;
    _long?.cancel();
    _long = Timer(const Duration(milliseconds: 550), () {
      if (_moved || _pointer == null) return;
      _longDone = true;
      HapticFeedback.mediumImpact();
      widget.onLongOk();
    });
    setState(() => _dot = e.localPosition);
  }

  void _update(PointerMoveEvent e) {
    if (e.pointer != _pointer) return;
    if (!_moved && (e.localPosition - _start).distance > _slop) {
      _moved = true;
      _long?.cancel();
    }
    if (_moved) _move(e.delta);
    setState(() => _dot = e.localPosition);
  }

  void _up(PointerEvent e, {bool cancel = false}) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    _long?.cancel();
    if (!cancel && !_moved && !_longDone) {
      HapticFeedback.lightImpact();
      widget.onKey(Keys.ok);
    }
    setState(() => _dot = null);
  }

  /// Raw pointer events plus an eager recognizer: the pad takes the finger at once, so the
  /// page around it no longer scrolls up and down when the remote is taller than the screen.
  @override
  Widget build(BuildContext context) => RawGestureDetector(
        gestures: {
          EagerGestureRecognizer: GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
            () => EagerGestureRecognizer(),
            (_) {},
          ),
        },
        child: Listener(
          onPointerDown: _down,
          onPointerMove: _update,
          onPointerUp: _up,
          onPointerCancel: (e) => _up(e, cancel: true),
        child: Container(
          height: 250,
          width: double.infinity,
          decoration: BoxDecoration(
            color: AppColors.bgCard,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: AppColors.cardBd),
          ),
          child: Stack(children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(tr('Проведите пальцем — стрелки, коснитесь — ОК'),
                    textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: AppColors.fgMuted)),
              ),
            ),
            if (_dot != null)
              Positioned(
                left: _dot!.dx - 22,
                top: _dot!.dy - 22,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: AppColors.accent.withValues(alpha: .35)),
                ),
              ),
          ]),
        ),
        ),
      );
}
