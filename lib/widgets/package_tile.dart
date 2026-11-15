import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

    final lines = (pkg.reason ?? '').split('\n');
    final about = lines.first;
    final count = lines.length > 1 ? lines[1] : null;

    return GestureDetector(
      onTap: onTap,
      onLongPress: () => showPackageInfo(context, pkg),
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
          // Icon badge: tap = what is this app
          GestureDetector(
            onTap: () => showPackageInfo(context, pkg),
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                color: color.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: color, size: 18),
            ),
          ),
          const Gap(12),

          // Name + reason
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(pkg.displayName,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.fg),
              maxLines: 1, overflow: TextOverflow.ellipsis),
            if (about.isNotEmpty) ...[
              const Gap(3),
              Text(about,
                style: const TextStyle(fontSize: 13, color: AppColors.fgMid, height: 1.3),
                maxLines: 4, overflow: TextOverflow.ellipsis),
            ],
            if (count != null) ...[
              const Gap(2),
              Text(count, style: const TextStyle(fontSize: 11, color: AppColors.fgMuted)),
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

/// What the app is, what happens if it goes, and how to get it back.
void showPackageInfo(BuildContext context, TvPackage pkg) {
  final (color, verdict) = switch (pkg.verdict) {
    PackageVerdict.remove  => (AppColors.danger, tr('Можно убрать: телевизор без этого работает')),
    PackageVerdict.caution => (AppColors.warn, tr('На ваше усмотрение: уберите, только если не пользуетесь этой функцией')),
    PackageVerdict.keep    => (AppColors.ok, tr('Лучше оставить')),
    PackageVerdict.system  => (AppColors.fgMid, tr('Системное: TVCleanzer его не трогает')),
  };
  final lines = (pkg.reason ?? '').split('\n');
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.bgCard,
    builder: (c) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(pkg.displayName,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.fg)),
          const Gap(4),
          GestureDetector(
            onLongPress: () => Clipboard.setData(ClipboardData(text: pkg.packageName)),
            child: SelectableText(pkg.packageName,
                style: const TextStyle(fontSize: 12, color: AppColors.fgMuted, fontFamily: 'monospace')),
          ),
          const Gap(14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
                color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(8)),
            child: Text(verdict, style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.w600)),
          ),
          if (lines.first.isNotEmpty) ...[
            const Gap(12),
            Text(lines.first, style: const TextStyle(fontSize: 15, color: AppColors.fg, height: 1.4)),
          ],
          if (lines.length > 1) ...[
            const Gap(8),
            Text(lines[1], style: const TextStyle(fontSize: 12, color: AppColors.fgMid)),
          ],
          if (pkg.sizeMb > 0) ...[
            const Gap(4),
            Text(tr('Занимает {0} МБ', [pkg.sizeMb]), style: const TextStyle(fontSize: 12, color: AppColors.fgMid)),
          ],
          if (pkg.verdict == PackageVerdict.remove || pkg.verdict == PackageVerdict.caution) ...[
            const Gap(12),
            Text(tr('Всё скрытое можно вернуть из «Истории»'),
                style: const TextStyle(fontSize: 12, color: AppColors.fgMid)),
          ],
          const Gap(8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('Понятно'))),
          ),
        ]),
      ),
    ),
  );
}
