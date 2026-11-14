import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import '../models/tv_device.dart';
import '../theme/app_theme.dart';

import '../l10n/l10n.dart';
class PackageTile extends StatelessWidget {
  final TvPackage pkg;
  final bool dimmed;
  /// null = no checkbox; true/false = selectable row.
  final bool? selected;
  final VoidCallback? onTap;
  const PackageTile({super.key, required this.pkg, this.dimmed = false, this.selected, this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = switch (pkg.verdict) {
      PackageVerdict.remove  => AppColors.danger,
      PackageVerdict.caution => AppColors.warn,
      PackageVerdict.keep    => AppColors.ok,
      PackageVerdict.system  => AppColors.fgMuted,
    };

    final icon = switch (pkg.verdict) {
      PackageVerdict.remove  => Icons.delete_outline_rounded,
      PackageVerdict.caution => Icons.warning_amber_rounded,
      PackageVerdict.keep    => Icons.check_circle_outline_rounded,
      PackageVerdict.system  => Icons.shield_outlined,
    };

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Opacity(
      opacity: dimmed ? .5 : 1,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.bgCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: selected == true ? color.withValues(alpha: .55) : AppColors.cardBd),
        ),
        child: Row(children: [
          // Icon badge
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: color.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 18),
          ),
          const Gap(12),

          // Name + reason
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(pkg.displayName,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.fg),
              maxLines: 1, overflow: TextOverflow.ellipsis),
            if (pkg.reason != null) ...[
              const Gap(2),
              Text(pkg.reason!,
                style: const TextStyle(fontSize: 12, color: AppColors.fgMuted),
                maxLines: 2, overflow: TextOverflow.ellipsis),
            ],
          ])),

          // Size badge
          if (pkg.sizeMb > 0) ...[
            const Gap(8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: color.withValues(alpha: .1),
                borderRadius: BorderRadius.circular(50),
              ),
              child: Text(tr('{0} МБ', [pkg.sizeMb]),
                style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
            ),
          ],
          if (selected != null) ...[
            const Gap(10),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 160),
              transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
              child: Icon(
                selected! ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                key: ValueKey(selected),
                color: selected! ? color : AppColors.fgMuted,
                size: 24,
              ),
            ),
          ],
        ]),
      ),
    ),
    );
  }
}
