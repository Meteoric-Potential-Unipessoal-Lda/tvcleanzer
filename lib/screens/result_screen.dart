import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/tv_device.dart';
import '../services/adb_package_manager.dart';
import '../state/history.dart';
import '../theme/app_theme.dart';
import '../widgets/support_card.dart';
import '../widgets/tv_sleep_sheet.dart';

import '../l10n/l10n.dart';
class ResultScreen extends ConsumerStatefulWidget {
  final TvDevice device;
  final CleanResult result;
  const ResultScreen({super.key, required this.device, required this.result});

  @override
  ConsumerState<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends ConsumerState<ResultScreen> {
  bool _rolling = false;      // rollback in progress
  bool _rollbackDone = false; // rollback succeeded
  /// The TV's screen timeout after the cleaning, when it would switch the TV off mid-film:
  /// no screensaver and under an hour («после чистки телек сам отрубается»).
  int? _shortSleepMin;

  @override
  void initState() {
    super.initState();
    _checkSleep();
  }

  Future<void> _checkSleep() async {
    try {
      final s = await ref.read(adbServiceProvider).screenSleep(widget.device);
      if (mounted && !s.screensaver && s.minutes > 0 && s.minutes < 60) {
        setState(() => _shortSleepMin = s.minutes);
      }
    } catch (_) {}
  }

  Widget _sleepCard() => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.warn.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.warn.withValues(alpha: .3)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.bedtime_rounded, color: AppColors.warn, size: 20),
            const Gap(8),
            Expanded(child: Text(tr('Телевизор может гаснуть во время фильма'),
                style: const TextStyle(color: AppColors.fg, fontWeight: FontWeight.w700))),
          ]),
          const Gap(6),
          Text(tr('Экран выключается через {0} мин без нажатий пульта, а заставки нет — тогда телевизор выключается совсем. Поставить 4 часа?', [_shortSleepMin]),
              style: const TextStyle(fontSize: 13, color: AppColors.fgMid, height: 1.4)),
          const Gap(10),
          Row(children: [
            FilledButton(
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                try {
                  await ref.read(adbServiceProvider)
                      .setScreenSleep(widget.device, AdbPackageManager.longScreenOffMin);
                  if (mounted) setState(() => _shortSleepMin = null);
                  messenger.showSnackBar(SnackBar(content: Text(tr('Готово: экран гаснет через 4 ч без пульта.'))));
                } catch (_) {
                  messenger.showSnackBar(SnackBar(content: Text(tr('Не получилось: телевизор не отвечает.'))));
                }
              },
              child: Text(tr('Поставить 4 часа')),
            ),
            const Gap(8),
            TextButton(
              onPressed: () async {
                await showScreenSleepSheet(context, widget.device);
                if (mounted) setState(() => _shortSleepMin = null);
              },
              child: Text(tr('Другое время')),
            ),
          ]),
        ]),
      );

  Future<void> _openOnTv(String pkg) async {
    final messenger = ScaffoldMessenger.of(context);
    var ok = false;
    try {
      ok = await ref.read(adbServiceProvider).openAppSettings(widget.device, pkg);
    } catch (_) {}
    messenger.showSnackBar(SnackBar(content: Text(ok
        ? tr('На телевизоре открылись настройки приложения: выберите «Отключить».')
        : tr('Не получилось открыть настройки на ТВ'))));
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final hasFailures = result.failedPackages.isNotEmpty;

    // Back goes home (not to the stale scan). Navigator.popUntil below pops
    // regardless of canPop, and its own pops arrive here with didPop=true.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, __) {
        if (!didPop && !_rolling) {
          Navigator.of(context).popUntil((r) => r.isFirst);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr('Результат')),
          automaticallyImplyLeading: false,
          actions: [
            if (!_rolling)
              IconButton(
                icon: const Icon(Icons.home_rounded),
                color: AppColors.accent,
                tooltip: tr('На главную'),
                onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
              ),
            const Gap(8),
          ],
        ),
        body: _rolling
            ? _buildRollingBack()
            : _rollbackDone
                ? _buildRollbackSuccess()
                : _buildResult(context, result, hasFailures),
      ),
    );
  }

  Widget _buildResult(BuildContext context, CleanResult result, bool hasFailures) =>
    SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Success icon
        Center(child: Column(children: [
          Container(
            width: 88, height: 88,
            decoration: BoxDecoration(
              color: (hasFailures ? AppColors.warn : AppColors.ok).withValues(alpha: .15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              hasFailures ? Icons.warning_amber_rounded : Icons.check_rounded,
              color: hasFailures ? AppColors.warn : AppColors.ok,
              size: 44,
            ),
          ).animate().scale(begin: const Offset(.6,.6), duration: 500.ms, curve: Curves.elasticOut),
          const Gap(20),
          Text(
            hasFailures ? tr('Частичная очистка') : tr('Телевизор очищен!'),
            style: GoogleFonts.syne(fontSize: 24, fontWeight: FontWeight.w800, color: AppColors.fg),
          ).animate().fadeIn(delay: 200.ms, duration: 400.ms),
          const Gap(8),
          Text(
            hasFailures
              ? tr('{0} убрано, {1} не удалось', [result.removedCount, result.failedPackages.length])
              : tr('{0} приложений скрыто', [result.removedCount]),
            style: const TextStyle(color: AppColors.fgMid),
          ).animate().fadeIn(delay: 300.ms),
        ])),

        const Gap(32),

        // Stats row
        Row(children: [
          _stat(tr('Убрано'), '${result.removedCount}', Icons.delete_outline_rounded, AppColors.danger),
          const Gap(12),
          _stat(tr('Освобождено'), tr('{0} МБ', [result.savedMb]), Icons.storage_rounded, AppColors.accent),
        ]).animate().fadeIn(delay: 400.ms, duration: 400.ms).slideY(begin: .1, end: 0),

        if (result.backupId.isNotEmpty) ...[
          const Gap(12),
          _stat(tr('Сохранено в «Истории»'), tr('можно вернуть'), Icons.history_rounded, AppColors.ok, fullWidth: true)
            .animate().fadeIn(delay: 500.ms),
        ],

        if (_shortSleepMin != null) ...[
          const Gap(16),
          _sleepCard().animate().fadeIn(duration: 300.ms),
        ],

        if (hasFailures) ...[
          const Gap(24),
          Row(children: [
            Container(width: 3, height: 14, decoration: BoxDecoration(
              color: AppColors.warn, borderRadius: BorderRadius.circular(2))),
            const Gap(8),
            Text(tr('НЕ УДАЛОСЬ УБРАТЬ').toUpperCase(), style: const TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.fgMuted, letterSpacing: .08)),
          ]),
          const Gap(6),
          Text(tr('Прошивка не даёт убрать их с телефона. Нажмите «Открыть на ТВ» и на телевизоре выберите «Отключить».'),
              style: const TextStyle(fontSize: 13, height: 1.4, color: AppColors.fgMid)),
          const Gap(10),
          ...result.failedPackages.map((pkg) => Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.bgCard,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.warn.withValues(alpha: .3)),
            ),
            child: Row(children: [
              const Icon(Icons.warning_amber_rounded, color: AppColors.warn, size: 16),
              const Gap(10),
              Expanded(child: Text(pkg, style: const TextStyle(fontSize: 13, color: AppColors.fg))),
              TextButton(
                onPressed: () => _openOnTv(pkg),
                child: Text(tr('Открыть на ТВ')),
              ),
            ]),
          )),
        ],

        // Rollback card
        if (result.backupId.isNotEmpty) ...[
          const Gap(32),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.bgCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.cardBd),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.undo_rounded, color: AppColors.fgMuted, size: 20),
              const Gap(12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Можно отменить'), style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.fg)),
                const Gap(4),
                Text(
                  tr('Список скрытых приложений сохранён во вкладке «История». Вернуть их можно в любой момент, это займёт пару секунд.'),
                  style: const TextStyle(fontSize: 12, color: AppColors.fgMuted, height: 1.5),
                ),
                const Gap(10),
                OutlinedButton.icon(
                  icon: const Icon(Icons.undo_rounded, size: 16),
                  label: Text(tr('Восстановить')),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.fg,
                    side: const BorderSide(color: AppColors.cardBd),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => _confirmRollback(context),
                ),
              ])),
            ]),
          ).animate().fadeIn(delay: 600.ms, duration: 400.ms),
        ],

        const Gap(20),
        const SupportCard().animate().fadeIn(delay: 800.ms, duration: 400.ms),

        const Gap(24),

        SizedBox(width: double.infinity, child: FilledButton.icon(
          icon: const Icon(Icons.home_rounded),
          label: Text(tr('Готово')),
          style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
          onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
        )).animate().fadeIn(delay: 700.ms),

        const Gap(8),
      ]),
    );

  Widget _buildRollingBack() => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const SizedBox(
        width: 64, height: 64,
        child: CircularProgressIndicator(strokeWidth: 3, color: AppColors.warn),
      ),
      const Gap(24),
      Text(tr('Восстанавливаем…'),
        style: GoogleFonts.syne(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.fg)),
      const Gap(8),
      Text(tr('Скрытые приложения возвращаются на телевизор.'),
        textAlign: TextAlign.center,
        style: const TextStyle(color: AppColors.fgMuted)),
    ]).animate().fadeIn(duration: 300.ms),
  );

  Widget _buildRollbackSuccess() => Center(
    child: Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 80, height: 80,
        decoration: BoxDecoration(
          color: AppColors.ok.withValues(alpha: .15),
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.check_rounded, color: AppColors.ok, size: 40),
      ).animate().scale(begin: const Offset(.6,.6), duration: 500.ms, curve: Curves.elasticOut),
      const Gap(20),
      Text(tr('Всё восстановлено!'),
        style: GoogleFonts.syne(fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.fg)),
      const Gap(8),
      Text(tr('Приложения вернулись на телевизор.'),
        textAlign: TextAlign.center,
        style: const TextStyle(color: AppColors.fgMid)),
      const Gap(32),
      FilledButton.icon(
        icon: const Icon(Icons.home_rounded),
        label: Text(tr('На главную')),
        style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
        onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
      ),
    ])),
  );

  Widget _stat(String label, String value, IconData icon, Color color, {bool fullWidth = false}) {
    final child = Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: .2)),
      ),
      child: Row(children: [
        Icon(icon, color: color, size: 22),
        const Gap(10),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, style: GoogleFonts.syne(fontSize: 18, fontWeight: FontWeight.w700, color: color)),
          Text(label, style: const TextStyle(fontSize: 11, color: AppColors.fgMuted)),
        ]),
      ]),
    );
    return fullWidth ? child : Expanded(child: child);
  }

  void _confirmRollback(BuildContext context) {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.bgCard,
      title: Text(tr('Восстановить?')),
      content: Text(
        tr('Скрытые приложения вернутся на телевизор. Текущее состояние очистки будет отменено.')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Отмена'))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.warn),
          onPressed: () {
            Navigator.pop(ctx);
            _performRollback();
          },
          child: Text(tr('Восстановить')),
        ),
      ],
    ));
  }

  Future<void> _performRollback() async {
    setState(() { _rolling = true; });
    try {
      final ok = await ref.read(adbServiceProvider).rollback(widget.device, widget.result.backupId);
      if (!mounted) return;
      if (ok) {
        await ref.read(historyProvider.notifier)
            .markRestoredByBackup(widget.result.backupId);
        if (!mounted) return;
        setState(() { _rolling = false; _rollbackDone = true; });
      } else {
        setState(() { _rolling = false; });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(tr('Не удалось восстановить. Попробуйте снова.')),
            backgroundColor: AppColors.danger,
          ));
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() { _rolling = false; });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('Ошибка: {0}', [e])),
        backgroundColor: AppColors.danger,
      ));
    }
  }
}
