import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../models/tv_device.dart';
import '../services/tv_names.dart';
import '../screens/home_screen.dart';
import '../state/current_tv.dart';
import '../theme/app_theme.dart';

/// Card at the top of the tabs that work with one TV (Launcher, Apps; Remote has its own):
/// which TV they act on, and with several TVs found a tap switches to another.
/// (A chat question: "TV box and TV both found — which one gets the launcher?")
class TvBanner extends ConsumerWidget {
  const TvBanner({super.key});

  static String nameOf(TvDevice d) => d.isDemo
      ? tr('Демо-телевизор')
      : (d.shortName.isEmpty ? d.ipAddress : d.shortName);

  /// More than one TV to choose from.
  static bool canSwitch(WidgetRef ref) {
    final tv = ref.watch(currentTvProvider);
    return ref.watch(discoveryProvider).devices.any((d) => tv == null || d.id != tv.id);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(tvNamesRevProvider); // a rename shows at once
    final tv = ref.watch(currentTvProvider);
    if (tv == null) return const SizedBox.shrink();
    final sw = canSwitch(ref);
    return Material(
      color: AppColors.bgCard,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: sw ? () => pick(context, ref) : null,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.cardBd),
          ),
          child: Row(children: [
            const Icon(Icons.tv_rounded, color: AppColors.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(nameOf(tv),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.fg)),
                const SizedBox(height: 2),
                Text(sw ? tr('Нажмите, чтобы выбрать другой телевизор') : (tv.isDemo ? tr('Без настоящего телевизора') : tv.ipAddress),
                    style: const TextStyle(fontSize: 12, color: AppColors.fgMuted)),
              ]),
            ),
            if (sw) const Icon(Icons.unfold_more_rounded, color: AppColors.fgMid),
          ]),
        ),
      ),
    );
  }

  /// List of the TVs found; the chosen one becomes the current TV for every tab.
  static Future<void> pick(BuildContext context, WidgetRef ref) async {
    final current = ref.read(currentTvProvider);
    final devices = ref.read(discoveryProvider).devices;
    final chosen = await showModalBottomSheet<TvDevice>(
      context: context,
      backgroundColor: AppColors.bgCard,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(tr('С каким телевизором работать?'),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.fg)),
          ),
          for (final d in devices)
            ListTile(
              leading: Icon(Icons.tv_rounded, color: d.id == current?.id ? AppColors.accent : AppColors.fgMuted),
              title: Text(nameOf(d), style: const TextStyle(color: AppColors.fg)),
              subtitle: Text(d.isDemo ? tr('Без настоящего телевизора') : d.ipAddress,
                  style: const TextStyle(fontSize: 12, color: AppColors.fgMuted)),
              trailing: d.id == current?.id ? const Icon(Icons.check_rounded, color: AppColors.accent) : null,
              onTap: () => Navigator.pop(c, d),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (chosen != null && chosen.id != current?.id) {
      await ref.read(currentTvProvider.notifier).select(chosen);
    }
  }
}
