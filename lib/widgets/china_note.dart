import 'package:flutter/material.dart';
import 'package:gap/gap.dart';

import '../l10n/l10n.dart';
import '../theme/app_theme.dart';

/// Shown before cleaning a Chinese Xiaomi firmware ([AdbPackageManager.chinaXiaomi]):
/// what we leave alone there and how to get a TV back that hangs on its logo.
class ChinaXiaomiNote extends StatelessWidget {
  const ChinaXiaomiNote({super.key});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.danger.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.danger.withValues(alpha: .3)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.warning_amber_rounded, color: AppColors.danger, size: 20),
          const Gap(10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Китайская прошивка Xiaomi'),
                  style: const TextStyle(color: AppColors.fg, fontWeight: FontWeight.w700, fontSize: 14)),
              const Gap(4),
              Text(
                tr('Такие прошивки хрупкие: приложения Xiaomi мы не трогаем и ничего не отмечаем заранее. Убирайте по одному-два и перезагружайте телевизор после каждого раза.'),
                style: const TextStyle(color: AppColors.fgMid, fontSize: 13, height: 1.45),
              ),
              const Gap(6),
              Text(
                tr('Если телевизор завис на логотипе: выньте вилку, зажмите на пульте ОК и «Назад» и вставьте вилку — откроется меню восстановления. Там «Reboot», а если не помогло — «Wipe user data» (сбросит настройки).'),
                style: const TextStyle(color: AppColors.fgMid, fontSize: 13, height: 1.45),
              ),
            ]),
          ),
        ]),
      );
}
