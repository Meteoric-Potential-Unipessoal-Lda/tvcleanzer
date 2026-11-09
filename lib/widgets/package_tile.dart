import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import '../models/tv_device.dart';
import '../theme/app_theme.dart';

class PackageTile extends StatelessWidget {
  final TvPackage pkg;
  final bool dimmed;
  const PackageTile({super.key, required this.pkg, this.dimmed = false});

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

    return Opacity(
      opacity: dimmed ? .5 : 1,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.bgCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.cardBd),
        ),
        child: Row(children: [
          // Icon badge
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: color.withOpacity(.12),
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
                color: color.withOpacity(.1),
                borderRadius: BorderRadius.circular(50),
              ),
              child: Text('${pkg.sizeMb} МБ',
                style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
            ),
          ],
        ]),
      ),
    );
  }
}
