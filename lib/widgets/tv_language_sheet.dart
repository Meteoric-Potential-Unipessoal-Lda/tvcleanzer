import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';

import '../l10n/l10n.dart';
import '../models/tv_device.dart';
import '../services/adb_package_manager.dart';
import '../services/app_log.dart';
import '../theme/app_theme.dart';

/// «Язык и клавиатура ТВ»: the TV's keyboard and system language from the phone. A Chinese
/// Xiaomi came back in Chinese after a reset and searched only in Chinese (MFTR0): the owner
/// had no computer and could not read the TV's menu.
Future<void> showTvLanguageSheet(BuildContext context, TvDevice tv) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.bgCard,
      builder: (_) => _TvLanguageSheet(tv: tv),
    );

/// Languages offered for the TV: tag and the language's own name.
const tvLanguages = <(String, String)>[
  ('ru-RU', 'Русский'),
  ('en-US', 'English'),
  ('uk-UA', 'Українська'),
  ('be-BY', 'Беларуская'),
  ('kk-KZ', 'Қазақ тілі'),
  ('uz-UZ', 'Oʻzbekcha'),
  ('ky-KG', 'Кыргызча'),
  ('hy-AM', 'Հայերեն'),
  ('az-AZ', 'Azərbaycan'),
  ('ka-GE', 'ქართული'),
  ('de-DE', 'Deutsch'),
  ('es-ES', 'Español'),
  ('pt-PT', 'Português'),
  ('fr-FR', 'Français'),
  ('it-IT', 'Italiano'),
  ('pl-PL', 'Polski'),
  ('tr-TR', 'Türkçe'),
  ('ro-RO', 'Română'),
  ('zh-CN', '中文'),
];

class _TvLanguageSheet extends ConsumerStatefulWidget {
  const _TvLanguageSheet({required this.tv});
  final TvDevice tv;
  @override
  ConsumerState<_TvLanguageSheet> createState() => _TvLanguageSheetState();
}

class _TvLanguageSheetState extends ConsumerState<_TvLanguageSheet> {
  List<String>? _keyboards;
  Set<String> _enabled = {};
  String _current = '';
  String _locale = '';
  String? _error;
  String? _busy; // what is being changed right now
  String? _msg;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = ref.read(adbServiceProvider);
    try {
      final k = await api.keyboards(widget.tv);
      final l = await api.tvLocale(widget.tv);
      if (!mounted) return;
      setState(() {
        _keyboards = k.all;
        _enabled = k.enabled;
        _current = k.current;
        _locale = l;
        _error = null;
      });
    } catch (e) {
      AppLog.error('tv language', e);
      if (mounted) setState(() => _error = tr('Телевизор не отвечает. Проверьте, что он включён и в той же Wi-Fi сети.'));
    }
  }

  Future<void> _setKeyboard(String id) async {
    setState(() { _busy = id; _msg = null; });
    var ok = false;
    try {
      ok = await ref.read(adbServiceProvider).setKeyboard(widget.tv, id);
    } catch (e) {
      AppLog.error('keyboard', e);
    }
    if (!mounted) return;
    setState(() {
      _busy = null;
      _msg = ok ? tr('Готово: на телевизоре теперь {0}.', [AdbPackageManager.keyboardName(id)])
                : tr('Телевизор не принял эту клавиатуру. Выберите другую.');
    });
    _load();
  }

  Future<void> _setLocale(String tag) async {
    setState(() { _busy = tag; _msg = null; });
    var err = '';
    try {
      err = await ref.read(adbServiceProvider).setTvLocale(widget.tv, tag);
    } catch (e) {
      AppLog.error('locale', e);
      err = tr('Телевизор не отвечает. Проверьте, что он включён и в той же Wi-Fi сети.');
    }
    if (!mounted) return;
    setState(() {
      _busy = null;
      _msg = err.isEmpty
          ? tr('Готово. Если часть меню осталась на прежнем языке — значит, в прошивке нет перевода; помогает перезагрузка телевизора.')
          : err;
    });
    _load();
  }

  bool _sameLang(String a, String b) => a.isNotEmpty && a.split('-').first == b.split('-').first;

  @override
  Widget build(BuildContext context) {
    final kbs = _keyboards;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * .85),
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
          Text(tr('Язык и клавиатура ТВ'),
              style: GoogleFonts.syne(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.fg)),
          const Gap(4),
          Text(tr('Если поиск на телевизоре печатает только иероглифы или меню на чужом языке — выберите здесь.'),
              style: const TextStyle(fontSize: 13, color: AppColors.fgMid, height: 1.4)),
          if (_msg != null) ...[
            const Gap(12),
            Text(_msg!, style: const TextStyle(fontSize: 13, color: AppColors.accent, height: 1.4)),
          ],
          if (_error != null) ...[
            const Gap(16),
            Text(_error!, style: const TextStyle(color: AppColors.danger)),
          ] else if (kbs == null) ...[
            const Gap(24),
            const Center(child: CircularProgressIndicator()),
          ] else ...[
            const Gap(18),
            _header(tr('Клавиатура')),
            if (kbs.isEmpty)
              Text(tr('Телевизор не показал свои клавиатуры.'), style: const TextStyle(color: AppColors.fgMid)),
            for (final id in kbs)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(AdbPackageManager.keyboardName(id), style: const TextStyle(color: AppColors.fg)),
                subtitle: Text(_enabled.contains(id) || id == _current ? id : '$id · ${tr('выключена')}',
                    style: const TextStyle(fontSize: 11, color: AppColors.fgMuted)),
                trailing: _busy == id
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : id == _current
                        ? const Icon(Icons.check_circle_rounded, color: AppColors.accent)
                        : null,
                onTap: _busy != null || id == _current ? null : () => _setKeyboard(id),
              ),
            Text(tr('Русской нет в списке? Поставьте клавиатуру с русским языком (например, Gboard) на вкладке «Приложения» → «Установить приложение из файла».'),
                style: const TextStyle(fontSize: 12, color: AppColors.fgMuted, height: 1.4)),
            const Gap(18),
            _header(tr('Язык системы')),
            Text(
              _locale.isEmpty
                  ? tr('Сейчас: не удалось узнать')
                  : tr('Сейчас: {0}', [_locale]),
              style: const TextStyle(fontSize: 12, color: AppColors.fgMuted),
            ),
            const Gap(4),
            Text(tr('Меняет наш TVCleanzer Launcher (0.59+), главным экраном он при этом может не быть.'),
                style: const TextStyle(fontSize: 12, color: AppColors.fgMuted, height: 1.4)),
            const Gap(8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final (tag, name) in tvLanguages)
                ChoiceChip(
                  label: _busy == tag
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(name),
                  selected: _sameLang(_locale, tag),
                  onSelected: _busy != null ? null : (_) => _setLocale(tag),
                ),
            ]),
          ],
        ]),
      ),
    );
  }

  Widget _header(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(t.toUpperCase(),
            style: const TextStyle(fontSize: 12, letterSpacing: .8, color: AppColors.fgMuted, fontWeight: FontWeight.w700)),
      );
}
