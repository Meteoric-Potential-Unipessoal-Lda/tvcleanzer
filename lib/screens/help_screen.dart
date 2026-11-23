import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/adb_package_manager.dart';
import '../services/app_log.dart';
import '../services/package_db.dart';
import '../services/support.dart';
import '../state/current_tv.dart';
import '../theme/app_theme.dart';

import '../l10n/l10n.dart';
import '../widgets/support_card.dart';
import 'faq_screen.dart';
import '../data/tv_guides.dart';
/// "How do I turn on debugging?" — step by step for each kind of TV.
class HelpScreen extends StatefulWidget {
  const HelpScreen({super.key});
  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  int _i = 0;

  @override
  Widget build(BuildContext context) {
    final g = tvGuides[_i];
    return Scaffold(
      appBar: AppBar(title: Text(tr('Как включить отладку'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          Text(tr('Выберите свой телевизор:'),
              style: const TextStyle(color: AppColors.fgMid, fontSize: 13)),
          const Gap(10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (var i = 0; i < tvGuides.length; i++)
              ChoiceChip(
                label: Text(tvGuides[i].brand),
                selected: i == _i,
                onSelected: (_) {
                  HapticFeedback.selectionClick();
                  setState(() => _i = i);
                },
                selectedColor: AppColors.accentDim,
                labelStyle: TextStyle(
                  color: i == _i ? AppColors.accent : AppColors.fg,
                  fontWeight: i == _i ? FontWeight.w700 : FontWeight.w500,
                ),
                side: BorderSide(color: i == _i ? AppColors.accent : AppColors.cardBd),
                backgroundColor: AppColors.bgCard,
                showCheckmark: false,
              ),
          ]),
          const Gap(20),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: Column(
              key: ValueKey(_i),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(g.brand,
                    style: GoogleFonts.syne(
                        fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.fg)),
                const Gap(2),
                Text(g.hint, style: const TextStyle(color: AppColors.fgMuted, fontSize: 13)),
                const Gap(16),
                for (var s = 0; s < g.steps.length; s++)
                  _step(s + 1, g.steps[s], g.supported)
                      .animate(delay: (s * 60).ms)
                      .fadeIn(duration: 220.ms)
                      .slideX(begin: .05, end: 0),
                if (g.note != null) ...[
                  const Gap(6),
                  _note(g.note!, g.supported ? AppColors.warn : AppColors.danger),
                ],
                if (g.supported) ...[
                  const Gap(18),
                  _note(
                    tr('Телефон и телевизор должны быть в одной Wi-Fi сети. При первом подключении на ТВ появится «Разрешить отладку?» — отметьте «Всегда разрешать» и нажмите «Разрешить».'),
                    AppColors.accent,
                  ),
                ],
                const Gap(10),
                TextButton.icon(
                  icon: const Icon(Icons.public_rounded, size: 18),
                  label: Text(tr('Инструкции на сайте {0}', [Support.siteShort])),
                  onPressed: () => SupportCard.openLink(context, Support.siteUrl(g.web ?? '#guides')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _step(int n, String text, bool supported) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: supported ? AppColors.accentDim : AppColors.cardBd,
              shape: BoxShape.circle,
            ),
            child: Text('$n',
                style: TextStyle(
                    color: supported ? AppColors.accent : AppColors.fgMid,
                    fontWeight: FontWeight.w700)),
          ),
          const Gap(12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(text,
                  style: const TextStyle(color: AppColors.fg, fontSize: 15, height: 1.45)),
            ),
          ),
        ]),
      );

  Widget _note(String text, Color color) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: .25)),
        ),
        child: Text(text, style: TextStyle(color: color, fontSize: 13, height: 1.45)),
      );
}

/// Bottom sheet behind the "?" button: guide + problem report.
Future<void> showHelpSheet(BuildContext context, WidgetRef ref) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: AppColors.bgCard,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 40, height: 4, decoration: BoxDecoration(
              color: AppColors.cardBd, borderRadius: BorderRadius.circular(2))),
          const Gap(12),
          ListTile(
            leading: const Icon(Icons.quiz_rounded, color: AppColors.accent),
            title: Text(tr('Частые вопросы')),
            subtitle: Text(tr('Подключение, очистка, лаунчер — ответы сразу')),
            onTap: () {
              Navigator.pop(ctx);
              Navigator.push(context, MaterialPageRoute(builder: (_) => const FaqScreen()));
            },
          ),
          ListTile(
            leading: const Icon(Icons.menu_book_rounded, color: AppColors.accent),
            title: Text(tr('Как включить отладку на ТВ')),
            subtitle: Text(tr('Пошагово для вашего бренда')),
            onTap: () {
              Navigator.pop(ctx);
              Navigator.push(context, MaterialPageRoute(builder: (_) => const HelpScreen()));
            },
          ),
          ListTile(
            leading: const Icon(Icons.healing_rounded, color: AppColors.danger),
            title: Text(tr('Чёрный экран после чистки?')),
            subtitle: Text(tr('Как вернуть главный экран и настройки')),
            onTap: () {
              Navigator.pop(ctx);
              SupportCard.openLink(context, Support.siteUrl('#g-rescue'));
            },
          ),
          ListTile(
            leading: const Icon(Icons.public_rounded, color: AppColors.accent),
            title: Text(tr('Сайт {0}', [Support.siteShort])),
            subtitle: Text(tr('Инструкции, новости и все версии приложения')),
            onTap: () {
              Navigator.pop(ctx);
              SupportCard.openLink(context, Support.siteUrl());
            },
          ),
          ListTile(
            leading: const Icon(Icons.bug_report_rounded, color: AppColors.warn),
            title: Text(tr('Сообщить о проблеме')),
            subtitle: Text(tr('Скопирует модель ТВ и журнал ошибок')),
            onTap: () async {
              final tv = ref.read(currentTvProvider);
              var text = AppLog.report(tv: tv);
              if (tv != null) {
                // what the launcher's Home-key service did last (why Home or an input ended where it did)
                text += await ref
                    .read(adbServiceProvider)
                    .launcherServiceLog(tv)
                    .timeout(const Duration(seconds: 8), onTimeout: () => '');
              }
              await Clipboard.setData(ClipboardData(text: text));
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(tr('Скопировано. Вставьте в чат TVCleanzer в Telegram и допишите, что случилось.')),
                  duration: const Duration(seconds: 5),
                ));
              }
            },
          ),
          const Gap(4),
          const SupportCard(compact: true),
          const Gap(6),
          Text(
              tr('TVCleanzer {0} · база {1}версия {2} · на основе CleanYourTV (MIT)', [appVersion, PackageDb.count > 0 ? tr('{0} приложений, ', [PackageDb.count]) : '', PackageDb.version]),
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.fgMuted, fontSize: 11)),
        ]),
      ),
    ),
  );
}
