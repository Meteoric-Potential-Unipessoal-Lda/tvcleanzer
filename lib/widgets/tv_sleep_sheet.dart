import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';

import '../l10n/l10n.dart';
import '../models/tv_device.dart';
import '../services/adb_package_manager.dart';
import '../services/app_log.dart';
import '../theme/app_theme.dart';

/// «Экран и сон»: after how long without the remote the TV's screen goes dark. With no
/// screensaver Android puts the TV to sleep then — owners saw it switch itself off during a
/// film after a cleaning (an IPTV player or a browser does not keep the screen on).
Future<void> showScreenSleepSheet(BuildContext context, TvDevice tv) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.bgCard,
      builder: (_) => _ScreenSleepSheet(tv: tv),
    );

/// The choices, in minutes (-1 = never).
const sleepChoices = [10, 30, 60, 120, 240, -1];

/// «10 мин», «2 ч», «Никогда».
String sleepLabel(int m) => m < 0
    ? tr('Никогда')
    : m < 60 || m % 60 != 0
        ? tr('{0} мин', [m])
        : tr('{0} ч', [m ~/ 60]);

class _ScreenSleepSheet extends ConsumerStatefulWidget {
  const _ScreenSleepSheet({required this.tv});
  final TvDevice tv;
  @override
  ConsumerState<_ScreenSleepSheet> createState() => _ScreenSleepSheetState();
}

class _ScreenSleepSheetState extends ConsumerState<_ScreenSleepSheet> {
  int? _minutes;
  bool _saver = false;
  String? _error;
  int? _busy;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await ref.read(adbServiceProvider).screenSleep(widget.tv);
      if (!mounted) return;
      setState(() {
        _minutes = s.minutes;
        _saver = s.screensaver;
        _error = null;
      });
    } catch (e) {
      AppLog.error('screen sleep', e);
      if (mounted) setState(() => _error = tr('Телевизор не отвечает. Проверьте, что он включён и в той же Wi-Fi сети.'));
    }
  }

  Future<void> _set(int m) async {
    setState(() => _busy = m);
    try {
      await ref.read(adbServiceProvider).setScreenSleep(widget.tv, m);
    } catch (e) {
      AppLog.error('screen sleep', e);
    }
    if (!mounted) return;
    setState(() => _busy = null);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final m = _minutes;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Экран и сон'),
              style: GoogleFonts.syne(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.fg)),
          const Gap(6),
          Text(tr('Через сколько без нажатий пульта гаснет экран. Видео-приложения обычно не дают ему погаснуть, но некоторые (IPTV, браузер) — дают: если телевизор гаснет во время фильма, поставьте 2–4 часа.'),
              style: const TextStyle(fontSize: 13, color: AppColors.fgMid, height: 1.4)),
          const Gap(14),
          if (_error != null)
            Text(_error!, style: const TextStyle(color: AppColors.danger))
          else if (m == null)
            const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
          else ...[
            Text(
              m == 0
                  ? tr('Сейчас: не удалось узнать')
                  : m < 0
                      ? tr('Сейчас: экран не гаснет')
                      : tr('Сейчас: через {0}', [sleepLabel(m)]),
              style: const TextStyle(color: AppColors.fg, fontWeight: FontWeight.w600),
            ),
            const Gap(4),
            Text(
              _saver
                  ? tr('Потом включается заставка.')
                  : tr('Заставки нет — по этому таймеру телевизор выключается.'),
              style: TextStyle(fontSize: 13, color: _saver ? AppColors.fgMuted : AppColors.warn),
            ),
            const Gap(12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final c in sleepChoices)
                ChoiceChip(
                  label: _busy == c
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(sleepLabel(c)),
                  selected: m == c,
                  onSelected: _busy != null ? null : (_) => _set(c),
                ),
            ]),
            if (m < 0) ...[
              const Gap(10),
              Text(tr('«Никогда»: экран не погаснет, даже если телевизор забыли выключить.'),
                  style: const TextStyle(fontSize: 12, color: AppColors.fgMuted, height: 1.4)),
            ],
          ],
        ]),
      ),
    );
  }
}
