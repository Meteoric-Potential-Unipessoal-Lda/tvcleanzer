import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/tv_device.dart';
import '../services/adb_package_manager.dart';
import '../services/tv_names.dart';
import '../theme/app_theme.dart';
import '../screens/home_screen.dart';
import '../screens/scan_screen.dart';
import '../screens/terminal_screen.dart';
import '../state/current_tv.dart';

import '../l10n/l10n.dart';
/// «Переименовать»: the owner's own name for the TV; empty = the model name again.
Future<void> renameTv(BuildContext context, WidgetRef ref, TvDevice d) async {
  final ctl = TextEditingController(text: TvNames.of(d.ipAddress) ?? '');
  final name = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(tr('Переименовать')),
      content: TextField(
        controller: ctl,
        autofocus: true,
        maxLength: 40,
        decoration: InputDecoration(hintText: d.modelName),
        onSubmitted: (v) => Navigator.pop(c, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('Отмена'))),
        TextButton(onPressed: () => Navigator.pop(c, ctl.text), child: Text(tr('Готово'))),
      ],
    ),
  );
  if (name == null) return;
  await TvNames.set(d.ipAddress, name);
  ref.read(tvNamesRevProvider.notifier).state++;
}

class TvCard extends ConsumerWidget {
  final TvDevice device;
  const TvCard({super.key, required this.device});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(tvNamesRevProvider); // a rename shows at once
    final hasRam = device.ramMb > 0;
    final ramPct = hasRam
        ? (1 - device.ramFreeMb / device.ramMb).clamp(0.0, 1.0)
        : 0.0;

    Future<void> open() async {
      final discovery = ref.read(discoveryProvider.notifier);
      ref.read(currentTvProvider.notifier).select(device);
      await Navigator.push(context,
          MaterialPageRoute(builder: (_) => ScanScreen(device: device)));
      await discovery.refresh(device);
    }

    return Material(
      color: AppColors.bgCard,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.hardEdge,
      child: InkWell(
        onTap: open,
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.cardBd),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Header row
            Row(children: [
              Container(
                width: 44, height: 44, decoration: BoxDecoration(
                  color: AppColors.accentDim,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.tv_rounded, color: AppColors.accent, size: 24),
              ),
              const Gap(12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(device.shortName,
                  style: GoogleFonts.syne(
                    fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.fg)),
                Text(device.isDemo ? tr('Демо-режим: без настоящего телевизора') : device.ipAddress,
                  style: TextStyle(fontSize: 12,
                      color: device.isDemo ? AppColors.accent : AppColors.fgMuted)),
              ])),
              if (device.isDemo)
                const Icon(Icons.chevron_right_rounded, color: AppColors.fgMuted)
              else
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert_rounded, color: AppColors.fgMuted),
                  tooltip: tr('Ещё'),
                  onSelected: (v) async {
                    if (v == 'remove') ref.read(discoveryProvider.notifier).remove(device);
                    if (v == 'rename' && context.mounted) await renameTv(context, ref, device);
                    if (v == 'terminal') {
                      Navigator.push(context,
                          MaterialPageRoute(builder: (_) => TerminalScreen(device: device)));
                    }
                    if (v == 'adb_off') {
                      final yes = await showDialog<bool>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: Text(tr('Выключить отладку на телевизоре?')),
                          content: Text(tr('Так безопаснее: к телевизору больше никто не подключится по сети. Чтобы снова пользоваться TVCleanzer, включите отладку на ТВ так же, как в первый раз.')),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Отмена'))),
                            TextButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('Выключить'))),
                          ],
                        ),
                      );
                      if (yes != true) return;
                      await ref.read(adbServiceProvider).disableAdb(device);
                      await ref.read(discoveryProvider.notifier).remove(device);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(tr('Отладка на телевизоре выключена'))));
                      }
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'rename', child: Text(tr('Переименовать'))),
                    PopupMenuItem(value: 'terminal', child: Text(tr('Терминал (для разработчиков)'))),
                    PopupMenuItem(value: 'adb_off', child: Text(tr('Выключить отладку на ТВ'))),
                    PopupMenuItem(value: 'remove', child: Text(tr('Убрать из списка'))),
                  ],
                ),
            ]),

            const Gap(14),

            // Android version badge
            Row(children: [
              _chip('Android ${device.androidVer}'),
              const Gap(6),
              _chip('SDK ${device.sdkVersion}'),
            ]),

            const Gap(14),

            // RAM bar
            if (hasRam) Row(children: [
              Text(tr('ОЗУ'), style: const TextStyle(fontSize: 12, color: AppColors.fgMuted)),
              const Gap(8),
              Expanded(child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: ramPct,
                  minHeight: 6,
                  backgroundColor: AppColors.cardBd,
                  color: ramPct > .8 ? AppColors.danger
                       : ramPct > .6 ? AppColors.warn
                       : AppColors.accent,
                ),
              )),
              const Gap(8),
              Text(tr('{0} МБ свободно', [device.ramFreeMb]),
                style: const TextStyle(fontSize: 11, color: AppColors.fgMid)),
            ]),

            if (hasRam) const Gap(14),

            // CTA
            SizedBox(width: double.infinity, child: FilledButton.icon(
              icon: const Icon(Icons.search_rounded, size: 18),
              label: Text(tr('Сканировать')),
              onPressed: open,
            )),
            if (device.isDemo) ...[
              const Gap(8),
              SizedBox(width: double.infinity, child: OutlinedButton.icon(
                icon: const Icon(Icons.logout_rounded, size: 18),
                label: Text(tr('Выйти из демо')),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.fg,
                  side: const BorderSide(color: AppColors.cardBd),
                ),
                onPressed: () => ref.read(discoveryProvider.notifier).exitDemo(),
              )),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _chip(String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: AppColors.accentDim,
      borderRadius: BorderRadius.circular(50),
      border: Border.all(color: AppColors.accent.withValues(alpha: .2)),
    ),
    child: Text(label,
      style: const TextStyle(fontSize: 11, color: AppColors.accent, fontWeight: FontWeight.w500)),
  );
}
