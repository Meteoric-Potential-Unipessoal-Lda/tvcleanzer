import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';

import '../l10n/l10n.dart';
import '../services/support.dart';
import '../services/tip_jar.dart';
import '../theme/app_theme.dart';

/// A quiet line about the author (Telegram), and «Поддержать автора» where donations are allowed.
class SupportCard extends StatelessWidget {
  final bool compact;
  const SupportCard({super.key, this.compact = false});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: TipJar.instance,
        builder: (context, _) => _build(context),
      );

  /// Store builds: tips through the store; other builds: Boosty / Buy Me a Coffee.
  static bool get _canSupport =>
      Support.storeBuild ? TipJar.instance.products.isNotEmpty : Support.canDonate;

  Widget _build(BuildContext context) {
    final author = InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _open(context, Support.telegram),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.send_rounded, size: 14, color: AppColors.fgMuted),
          const Gap(6),
          Flexible(
            child: Text(tr('Автор — {0} · {1}', [tr(Support.author), Support.telegramShort]),
                style: const TextStyle(fontSize: 12, color: AppColors.fgMuted)),
          ),
        ]),
      ),
    );
    if (!_canSupport) return Center(child: author);
    return Container(
      padding: EdgeInsets.all(compact ? 10 : 14),
      decoration: BoxDecoration(
        color: AppColors.bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.cardBd),
      ),
      child: Column(children: [
        if (!compact) ...[
          Text(tr('TVCleanzer бесплатный и без рекламы. Если он вам помог — можно поддержать автора.'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: AppColors.fgMid, height: 1.4)),
          const Gap(10),
        ],
        OutlinedButton.icon(
          icon: const Icon(Icons.favorite_rounded, size: 16, color: AppColors.danger),
          label: Text(tr('Поддержать автора')),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.fg,
            side: const BorderSide(color: AppColors.cardBd),
            visualDensity: VisualDensity.compact,
          ),
          onPressed: () => Support.storeBuild ? _tips(context) : _donate(context),
        ),
        const Gap(4),
        author,
      ]),
    );
  }

  /// Opens a link outside the app; if nothing can open it, copies it and says so.
  static Future<void> openLink(BuildContext context, String url) => _open(context, url);

  static Future<void> _open(BuildContext context, String url) async {
    HapticFeedback.selectionClick();
    if (!await Support.open(url)) {
      await Clipboard.setData(ClipboardData(text: url));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr('Ссылка скопирована: {0}', [url]))));
      }
    }
  }

  static void _tips(BuildContext context) {
    final jar = TipJar.instance;
    final seen = jar.thanks;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.bgCard,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: ListenableBuilder(
            listenable: jar,
            builder: (c, _) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Поддержать автора'),
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.fg)),
              const Gap(6),
              Text(
                  jar.thanks > seen
                      ? tr('Спасибо! Это очень помогает делать TVCleanzer дальше.')
                      : tr('Чаевые разработчику: ничего не открывают и не продлеваются — просто спасибо за приложение.'),
                  style: TextStyle(fontSize: 13, color: jar.thanks > seen ? AppColors.ok : AppColors.fgMid, height: 1.4)),
              const Gap(12),
              Row(children: [
                for (final p in jar.products) ...[
                  Expanded(
                    child: FilledButton(
                      onPressed: jar.busy ? null : () => jar.buy(p),
                      child: Text(p.price),
                    ),
                  ),
                  if (p != jar.products.last) const Gap(8),
                ],
              ]),
              const Gap(8),
            ]),
          ),
        ),
      ),
    );
  }

  static void _donate(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.bgCard,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Поддержать автора'),
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.fg)),
            const Gap(6),
            Text(tr('Спасибо! Любая сумма помогает делать TVCleanzer дальше.'),
                style: const TextStyle(fontSize: 13, color: AppColors.fgMid)),
            const Gap(8),
            for (final (name, url) in Support.donations)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.favorite_border_rounded, color: AppColors.accent),
                title: Text(name, style: const TextStyle(color: AppColors.fg)),
                trailing: const Icon(Icons.open_in_new_rounded, size: 18, color: AppColors.fgMuted),
                onTap: () {
                  Navigator.pop(c);
                  _open(context, url);
                },
              ),
          ]),
        ),
      ),
    );
  }
}
