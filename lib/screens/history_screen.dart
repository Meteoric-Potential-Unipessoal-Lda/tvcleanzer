import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/tv_device.dart';
import '../services/adb_package_manager.dart';
import '../state/history.dart';
import '../theme/app_theme.dart';

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});
  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  final Set<String> _busy = {};

  @override
  Widget build(BuildContext context) {
    final records = ref.watch(historyProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('История')),
      body: records.isEmpty
          ? _empty()
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              itemCount: records.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _card(records[i])
                    .animate(delay: (i * 50).ms)
                    .fadeIn(duration: 250.ms)
                    .slideY(begin: .08, end: 0, duration: 250.ms),
              ),
            ),
    );
  }

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.history_rounded, size: 56, color: AppColors.fgMuted),
            const Gap(16),
            Text('Пока пусто',
                style: GoogleFonts.syne(
                    fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.fg)),
            const Gap(8),
            const Text(
              'После очистки здесь появится список скрытых приложений. '
              'Их можно вернуть в любой момент.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.fgMid, height: 1.5),
            ),
          ]),
        ),
      );

  Widget _card(CleanRecord r) {
    final busy = _busy.contains(r.id);
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
            decoration: BoxDecoration(
              color: AppColors.accentDim,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.tv_rounded, color: AppColors.accent, size: 22),
          ),
          const Gap(12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r.tvName,
                  style: GoogleFonts.syne(
                      fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.fg)),
              Text(_fmt(r.date),
                  style: const TextStyle(fontSize: 12, color: AppColors.fgMuted)),
            ]),
          ),
          _badge(r),
        ]),
        if (r.savedMb > 0) ...[
          const Gap(8),
          Text('Освобождено около ${r.savedMb} МБ',
              style: const TextStyle(fontSize: 13, color: AppColors.fgMid)),
        ],
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 8),
            iconColor: AppColors.fgMid,
            collapsedIconColor: AppColors.fgMuted,
            title: Text('Приложения (${r.packages.length})',
                style: const TextStyle(fontSize: 13, color: AppColors.fg)),
            children: [
              for (final p in r.packages)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(children: [
                    const Icon(Icons.circle, size: 6, color: AppColors.fgMuted),
                    const Gap(8),
                    Expanded(
                      child: Text(r.labelOf(p),
                          style: const TextStyle(fontSize: 13, color: AppColors.fgMid)),
                    ),
                  ]),
                ),
            ],
          ),
        ),
        if (!r.restored)
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.undo_rounded, size: 18),
              label: Text(busy ? 'Возвращаем…' : 'Вернуть всё'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.fg,
                side: const BorderSide(color: AppColors.cardBd),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed: busy ? null : () => _confirm(r),
            ),
          ),
      ]),
    );
  }

  Widget _badge(CleanRecord r) {
    final color = r.restored ? AppColors.ok : AppColors.danger;
    final text = r.restored ? 'Возвращено' : 'Скрыто ${r.packages.length}';
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(50),
        border: Border.all(color: color.withValues(alpha: .3)),
      ),
      child: Text(text,
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
    );
  }

  void _confirm(CleanRecord r) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgCard,
        title: const Text('Вернуть приложения?'),
        content: Text(
            'На телевизор «${r.tvName}» вернутся ${r.packages.length} скрытых приложений. '
            'Телевизор должен быть включён и в той же Wi-Fi сети.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _restore(r);
            },
            child: const Text('Вернуть'),
          ),
        ],
      ),
    );
  }

  Future<void> _restore(CleanRecord r) async {
    setState(() => _busy.add(r.id));
    String message;
    try {
      final tv = TvDevice.fromAdb(ip: r.tvIp, brand: '', model: '', androidVer: '');
      final ok = await ref.read(adbServiceProvider).rollback(tv, r.backupId);
      if (ok) {
        await ref.read(historyProvider.notifier).markRestored(r.id);
        message = 'Готово: приложения вернулись на телевизор.';
      } else {
        message = 'Часть приложений вернуть не удалось. Попробуйте ещё раз.';
      }
    } catch (_) {
      message = 'Телевизор не отвечает. Проверьте, что он включён и в той же Wi-Fi сети.';
    }
    if (!mounted) return;
    setState(() => _busy.remove(r.id));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  static String _fmt(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.day)}.${two(d.month)}.${d.year}, ${two(d.hour)}:${two(d.minute)}';
  }
}
