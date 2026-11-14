import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/tv_device.dart';
import '../theme/app_theme.dart';
import '../screens/scan_screen.dart';
import '../state/current_tv.dart';

import '../l10n/l10n.dart';
class TvCard extends ConsumerWidget {
  final TvDevice device;
  const TvCard({super.key, required this.device});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasRam = device.ramMb > 0;
    final ramPct = hasRam
        ? (1 - device.ramFreeMb / device.ramMb).clamp(0.0, 1.0)
        : 0.0;

    void open() {
      ref.read(currentTvProvider.notifier).select(device);
      Navigator.push(context,
          MaterialPageRoute(builder: (_) => ScanScreen(device: device)));
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
              const Icon(Icons.chevron_right_rounded, color: AppColors.fgMuted),
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
              Text(tr('ОЗУ'), style: TextStyle(fontSize: 12, color: AppColors.fgMuted)),
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
