import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/tv_brands.dart';
import '../data/tv_guides.dart';
import '../l10n/l10n.dart';
import '../models/tv_device.dart';
import '../services/adb_client.dart';
import '../services/adb_package_manager.dart';
import '../services/app_log.dart';
import '../services/demo_tv.dart';
import '../services/tv_discovery.dart';
import '../state/current_tv.dart';
import '../theme/app_theme.dart';
import '../widgets/manual_connect.dart';
import 'faq_screen.dart';
import 'home_screen.dart';
import 'pair_screen.dart';
import 'root_shell.dart';
import 'scan_screen.dart';

/// First run (and «Пошаговое подключение»): pick the TV, turn debugging on step by step,
/// and stay here until the TV is connected. The search runs in the background the whole
/// time, so the TV is picked up the moment debugging is on — no «Готово» needed.
class OnboardingScreen extends ConsumerStatefulWidget {
  /// First run: on success go to the app; otherwise just close.
  final bool firstRun;
  const OnboardingScreen({super.key, this.firstRun = false});

  static const _doneKey = 'onboarded';

  /// Shown at start: first run, no TV remembered, not a store-screenshot build.
  static Future<bool> needed({required bool hasTv}) async {
    if (const bool.fromEnvironment('TVC_DEMO_ONLY')) return false;
    try {
      final sp = await SharedPreferences.getInstance();
      if (sp.getBool(_doneKey) ?? false) return false;
      if (hasTv) {
        await sp.setBool(_doneKey, true); // an owner from before the guide
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> markDone() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_doneKey, true);
    } catch (_) {}
  }

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

enum _Page { welcome, brand, platform, unsupported, steps, waiting, done }

/// What the background search sees right now.
enum _Live { idle, noWifi, searching, connecting, approve, rejected }

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  _Page _page = _Page.welcome;
  final List<_Page> _back = [];
  TvBrand? _brand;
  TvGuide? _guide;
  int _step = 0;
  String _query = '';

  _Live _live = _Live.idle;
  bool _vpn = false;
  bool _searching = false;
  final Set<String> _trying = {};
  TvDevice? _tv;
  Timer? _hintTimer;
  bool _showFallback = false;

  @override
  void initState() {
    super.initState();
    if (!widget.firstRun) _page = _Page.brand;
    if (!widget.firstRun) WidgetsBinding.instance.addPostFrameCallback((_) => _startSearch());
  }

  @override
  void dispose() {
    _searching = false;
    _hintTimer?.cancel();
    super.dispose();
  }

  // ── Navigation ──────────────────────────────────────────────────────────

  void _go(_Page p) {
    HapticFeedback.selectionClick();
    setState(() {
      _back.add(_page);
      _page = p;
    });
    if (p == _Page.waiting) {
      _hintTimer?.cancel();
      _showFallback = false;
      _hintTimer = Timer(const Duration(seconds: 25), () {
        if (mounted) setState(() => _showFallback = true);
      });
    }
  }

  bool _goBack() {
    if (_page == _Page.steps && _step > 0) {
      setState(() => _step--);
      return true;
    }
    if (_back.isEmpty || _page == _Page.done) return false;
    setState(() => _page = _back.removeLast());
    return true;
  }

  void _pickBrand(TvBrand b) {
    _brand = b;
    final ids = b.guides.isEmpty ? [for (final g in tvGuides) g.id] : b.guides;
    AppLog.error('onboarding', 'brand ${b.name}');
    if (b.unsupported) {
      _guide = guideById(ids.first);
      _go(_Page.unsupported);
    } else if (ids.length == 1) {
      _pickGuide(guideById(ids.first));
    } else {
      _go(_Page.platform);
    }
  }

  void _pickGuide(TvGuide g) {
    _guide = g;
    _step = 0;
    AppLog.error('onboarding', 'platform ${g.id}');
    _go(g.supported ? _Page.steps : _Page.unsupported);
  }

  // ── Background search ───────────────────────────────────────────────────

  Future<void> _startSearch() async {
    if (_searching) return;
    _searching = true;
    while (mounted && _searching && _tv == null) {
      final vpn = await TvDiscovery.vpnActive();
      final cands = await TvDiscovery.candidates();
      if (!mounted) return;
      if (cands.isEmpty) {
        setState(() {
          _vpn = vpn;
          _live = _Live.noWifi;
        });
        await Future<void>.delayed(const Duration(seconds: 3));
        continue;
      }
      if (_live == _Live.idle || _live == _Live.noWifi) setState(() => _live = _Live.searching);
      if (_vpn != vpn) setState(() => _vpn = vpn);
      final open = await TvDiscovery.openPorts(cands);
      for (final (ip, port) in open) {
        if (_trying.add('$ip:$port')) unawaited(_connect(ip, port));
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    }
  }

  Future<void> _connect(String ip, int port) async {
    if (!mounted || _tv != null) return;
    if (_live != _Live.approve) setState(() => _live = _Live.connecting);
    try {
      final tv = await ref
          .read(adbServiceProvider)
          .getDeviceInfo(ip, port: port, onAwaitingApproval: () {
            if (mounted && _tv == null) setState(() => _live = _Live.approve);
          })
          .timeout(const Duration(seconds: 75));
      await _connected(tv);
    } catch (e) {
      AppLog.error('onboarding connect $ip', e);
      if (!mounted || _tv != null) return;
      setState(() => _live = e is AdbAuthException ? _Live.rejected : _Live.searching);
      // let the next passes try this host again, not every 3 seconds
      Future<void>.delayed(const Duration(seconds: 12), () => _trying.remove('$ip:$port'));
    }
  }

  Future<void> _connected(TvDevice tv) async {
    if (!mounted || _tv != null) return;
    _searching = false;
    _hintTimer?.cancel();
    await ref.read(currentTvProvider.notifier).select(tv);
    ref.read(discoveryProvider.notifier).add(tv);
    await OnboardingScreen.markDone();
    HapticFeedback.mediumImpact();
    if (!mounted) return;
    setState(() {
      _tv = tv;
      _back.clear();
      _page = _Page.done;
    });
  }

  Future<void> _pair() async {
    final tv = await Navigator.push<TvDevice>(context, MaterialPageRoute(builder: (_) => const PairScreen()));
    if (tv != null) await _connected(tv);
  }

  Future<void> _manual() async {
    final tv = await showManualConnect(context);
    if (tv != null) await _connected(tv);
  }

  Future<void> _report() async {
    final text = AppLog.report(tv: ref.read(currentTvProvider));
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(tr('Скопировано. Вставьте в чат TVCleanzer в Telegram и допишите, что случилось.')),
      duration: const Duration(seconds: 5),
    ));
  }

  Future<void> _finish() async {
    await OnboardingScreen.markDone();
    if (!mounted) return;
    if (widget.firstRun) {
      Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const RootShell()), (_) => false);
    } else {
      Navigator.pop(context, _tv);
    }
  }

  Future<void> _demo() async {
    await OnboardingScreen.markDone();
    if (!mounted) return;
    final d = DemoTv.device();
    ref.read(discoveryProvider.notifier).add(d);
    await ref.read(currentTvProvider.notifier).select(d);
    if (!mounted) return;
    final nav = Navigator.of(context);
    if (widget.firstRun) {
      nav.pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const RootShell()), (_) => false);
    } else {
      nav.pop();
    }
    nav.push(MaterialPageRoute(builder: (_) => ScanScreen(device: d)));
  }

  // ── UI ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final showBack = _page != _Page.welcome && _page != _Page.done &&
        (_back.isNotEmpty || (_page == _Page.steps && _step > 0) || !widget.firstRun);
    return PopScope(
      canPop: _back.isEmpty && !(_page == _Page.steps && _step > 0),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goBack();
      },
      child: Scaffold(
        appBar: _page == _Page.welcome
            ? null
            : AppBar(
                automaticallyImplyLeading: false,
                leading: showBack
                    ? IconButton(
                        icon: const Icon(Icons.arrow_back_rounded),
                        tooltip: tr('Назад'),
                        onPressed: () {
                          if (!_goBack()) Navigator.maybePop(context);
                        },
                      )
                    : null,
                title: Text(tr('Подключение телевизора')),
              ),
        body: SafeArea(
          child: Column(children: [
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: KeyedSubtree(key: ValueKey('$_page$_step'), child: _body()),
              ),
            ),
            if (_page != _Page.welcome && _page != _Page.done && _page != _Page.unsupported) _liveBar(),
          ]),
        ),
      ),
    );
  }

  Widget _body() => switch (_page) {
        _Page.welcome => _welcome(),
        _Page.brand => _brandPage(),
        _Page.platform => _platformPage(),
        _Page.unsupported => _unsupportedPage(),
        _Page.steps => _stepsPage(),
        _Page.waiting => _waitingPage(),
        _Page.done => _donePage(),
      };

  Widget _title(String t) => Text(t,
      style: GoogleFonts.syne(fontSize: 24, fontWeight: FontWeight.w800, color: AppColors.fg, height: 1.2));

  Widget _para(String t, {Color color = AppColors.fgMid, double size = 15}) =>
      Text(t, style: TextStyle(color: color, fontSize: size, height: 1.5));

  Widget _welcome() => ListView(
        padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
        children: [
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Image.asset('assets/icon/icon.png', width: 88, height: 88),
            ),
          ).animate().scale(begin: const Offset(.7, .7), duration: 500.ms, curve: Curves.easeOutBack),
          const Gap(28),
          _title(tr('Подключим телевизор')),
          const Gap(12),
          _para(tr('Пара минут: выберите свой телевизор, включите на нём отладку по подсказкам — и TVCleanzer подключится сам.')),
          const Gap(12),
          _para(tr('Телефон и телевизор — в одной сети, VPN на телефоне выключен.'), color: AppColors.fgMuted, size: 14),
          if (Platform.isIOS) ...[
            const Gap(8),
            _para(tr('iPhone спросит доступ к устройствам в локальной сети — разрешите: так он найдёт телевизор.'),
                color: AppColors.fgMuted, size: 14),
          ],
          const Gap(32),
          FilledButton.icon(
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
            icon: const Icon(Icons.tv_rounded),
            label: Text(tr('Начать')),
            onPressed: () {
              _go(_Page.brand);
              _startSearch();
            },
          ),
          const Gap(10),
          TextButton.icon(
            icon: const Icon(Icons.play_circle_outline_rounded, size: 18),
            label: Text(tr('Нет телевизора рядом? Попробовать демо')),
            onPressed: _demo,
          ),
        ],
      );

  Widget _brandPage() {
    final brands = tvBrands().where((b) => b.matches(_query)).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: [
        _title(tr('Какой у вас телевизор?')),
        const Gap(14),
        TextField(
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search_rounded),
            hintText: tr('Найти марку'),
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          ),
          onChanged: (v) => setState(() => _query = v),
        ),
        const Gap(14),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final b in brands)
            ActionChip(
              label: Text(b.name),
              onPressed: () => _pickBrand(b),
              backgroundColor: AppColors.bgCard,
              side: const BorderSide(color: AppColors.cardBd),
              labelStyle: TextStyle(
                  color: b.unsupported ? AppColors.fgMuted : AppColors.fg, fontWeight: FontWeight.w600),
            ),
          if (brands.isEmpty)
            ActionChip(
              label: Text(tr('Другая марка')),
              onPressed: () => _pickBrand(tvBrands().last),
            ),
        ]),
      ],
    );
  }

  Widget _platformPage() {
    final b = _brand!;
    final ids = b.guides.isEmpty ? [for (final g in tvGuides) g.id] : b.guides;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: [
        _title(tr('Какой у него главный экран?')),
        const Gap(6),
        _para(b.name, color: AppColors.fgMuted, size: 14),
        if (b.tip != null) ...[
          const Gap(12),
          _noteBox(b.tip!, AppColors.warn),
        ],
        const Gap(14),
        for (final id in ids) _guideCard(guideById(id)),
        const Gap(4),
        // most TVs are plain Android TV: its steps work on most of the others too
        TextButton(
          onPressed: () => _pickGuide(guideById(ids.firstWhere((i) => guideById(i).supported, orElse: () => 'androidTv'))),
          child: Text(tr('Не знаю')),
        ),
      ],
    );
  }

  Widget _guideCard(TvGuide g) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Material(
          color: AppColors.bgCard,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16), side: const BorderSide(color: AppColors.cardBd)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _pickGuide(g),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                Icon(g.supported ? Icons.tv_rounded : Icons.block_rounded,
                    color: g.supported ? AppColors.accent : AppColors.fgMuted),
                const Gap(14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(g.brand,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.fg)),
                    const Gap(4),
                    Text(guideLooks(g.id), style: const TextStyle(fontSize: 13, height: 1.4, color: AppColors.fgMid)),
                  ]),
                ),
                const Icon(Icons.chevron_right_rounded, color: AppColors.fgMuted),
              ]),
            ),
          ),
        ),
      );

  Widget _unsupportedPage() {
    final g = _guide!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      children: [
        const Icon(Icons.block_rounded, size: 48, color: AppColors.danger),
        const Gap(16),
        _title(tr('С этим телевизором TVCleanzer не работает')),
        const Gap(12),
        for (final s in g.steps) ...[_para(s), const Gap(8)],
        const Gap(16),
        OutlinedButton(
          onPressed: () => setState(() {
            _back.clear();
            _page = _Page.brand;
          }),
          child: Text(tr('Выбрать другой телевизор')),
        ),
        const Gap(8),
        TextButton.icon(
          icon: const Icon(Icons.play_circle_outline_rounded, size: 18),
          label: Text(tr('Нет телевизора рядом? Попробовать демо')),
          onPressed: _demo,
        ),
      ],
    );
  }

  Widget _stepsPage() {
    final g = _guide!;
    final n = g.steps.length;
    final last = _step >= n - 1;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        Text(g.brand, style: const TextStyle(color: AppColors.fgMuted, fontSize: 13)),
        const Gap(6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: (_step + 1) / n,
            minHeight: 6,
            backgroundColor: AppColors.cardBd,
            color: AppColors.accent,
          ),
        ),
        const Gap(8),
        Text(tr('Шаг {0} из {1}', [_step + 1, n]),
            style: const TextStyle(color: AppColors.accent, fontWeight: FontWeight.w700)),
        const Gap(18),
        Text(g.steps[_step], style: const TextStyle(color: AppColors.fg, fontSize: 19, height: 1.45)),
        if (last)
          for (final n in _notes(g)) ...[
            const Gap(18),
            _noteBox(n, AppColors.warn),
          ],
        const Gap(28),
        FilledButton(
          style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
          onPressed: () {
            HapticFeedback.selectionClick();
            if (last) {
              _go(_Page.waiting);
            } else {
              setState(() => _step++);
            }
          },
          child: Text(last ? tr('Отладка включена') : tr('Дальше')),
        ),
      ],
    );
  }

  /// The notes for this brand and platform: no TCL advice for a Haier owner.
  List<String> _notes(TvGuide g) =>
      _brand?.notesFor(g) ?? [if (g.note != null && g.noteForAll) g.note!];

  Widget _noteBox(String text, Color color) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: .25)),
        ),
        child: Text(text, style: TextStyle(color: color, fontSize: 14, height: 1.45)),
      );

  Widget _waitingPage() {
    final g = _guide;
    final canPair = Platform.isAndroid || Platform.isIOS;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      children: [
        _title(tr('Ищем телевизор…')),
        const Gap(10),
        _para(tr('Как только отладка включится, TVCleanzer подключится сам. Держите телевизор включённым.')),
        const Gap(20),
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 300),
          crossFadeState: _showFallback ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          firstChild: Center(
            child: TextButton(
              onPressed: () => setState(() => _showFallback = true),
              child: Text(tr('Не находится?')),
            ),
          ),
          secondChild: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr('Не находится?'),
                style: GoogleFonts.syne(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.fg)),
            const Gap(10),
            _check(Icons.wifi_rounded, tr('Телефон и телевизор — в одной сети, VPN на телефоне выключен.')),
            _check(Icons.router_rounded,
                tr('Если роутер раздаёт две сети (2,4 и 5 ГГц), подключите телефон и телевизор к одной из них.')),
            if (g != null)
              for (final n in _notes(g)) _check(Icons.info_outline_rounded, n),
            const Gap(8),
            if (canPair && g?.id != 'xiaomiCn')
              OutlinedButton.icon(
                icon: const Icon(Icons.pin_rounded, size: 18),
                label: Text(tr('Google TV / Android 11+: подключить по коду')),
                onPressed: _pair,
              ),
            const Gap(8),
            OutlinedButton.icon(
              icon: const Icon(Icons.dialpad_rounded, size: 18),
              label: Text(tr('Ввести IP телевизора')),
              onPressed: _manual,
            ),
            const Gap(4),
            _para(tr('IP телевизора есть в его настройках: «Сеть» → ваша сеть → «IP-адрес».'),
                color: AppColors.fgMuted, size: 13),
            const Gap(12),
            TextButton.icon(
              icon: const Icon(Icons.replay_rounded, size: 18),
              label: Text(tr('Пройти шаги ещё раз')),
              onPressed: () => setState(() {
                _step = 0;
                _page = _Page.steps;
              }),
            ),
            TextButton.icon(
              icon: const Icon(Icons.quiz_rounded, size: 18),
              label: Text(tr('Частые вопросы')),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const FaqScreen())),
            ),
            TextButton.icon(
              icon: const Icon(Icons.bug_report_rounded, size: 18),
              label: Text(tr('Сообщить о проблеме')),
              onPressed: _report,
            ),
          ]),
        ),
      ],
    );
  }

  Widget _check(IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 20, color: AppColors.accent),
          const Gap(10),
          Expanded(child: _para(text, size: 14)),
        ]),
      );

  Widget _donePage() {
    final tv = _tv!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
      children: [
        const Icon(Icons.check_circle_rounded, size: 72, color: AppColors.ok)
            .animate()
            .scale(begin: const Offset(.5, .5), duration: 500.ms, curve: Curves.elasticOut),
        const Gap(20),
        Center(child: _title(tr('Телевизор подключён'))),
        const Gap(8),
        Center(child: _para(tv.shortName.isEmpty ? tv.modelName : tv.shortName)),
        const Gap(32),
        FilledButton(
          style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
          onPressed: _finish,
          child: Text(tr('Дальше')),
        ),
      ],
    );
  }

  /// Always at the bottom: what the search sees, and what to do about it.
  Widget _liveBar() {
    final (IconData icon, Color color, String text) = switch (_live) {
      _Live.noWifi => (Icons.wifi_off_rounded, AppColors.danger,
          tr('Телефон не в Wi‑Fi. Подключите его к той же сети, что и телевизор.')),
      _Live.connecting => (Icons.sync_rounded, AppColors.accent, tr('Нашли телевизор, подключаемся…')),
      _Live.approve => (Icons.touch_app_rounded, AppColors.warn,
          tr('Это TVCleanzer. Отметьте «Всегда разрешать с этого компьютера» и нажмите «ОК» — тогда вопрос больше не появится.')),
      _Live.rejected => (Icons.block_rounded, AppColors.danger,
          tr('Телевизор отказал в подключении. Скоро спросим снова — на телевизоре нажмите «ОК».')),
      _ => (Icons.search_rounded, AppColors.fgMid, tr('Ищем телевизоры в сети…')),
    };
    final title = _live == _Live.approve ? tr('Телевизор спрашивает «Разрешить отладку?»') : null;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: .35)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_live == _Live.searching || _live == _Live.connecting)
          SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: color))
        else
          Icon(icon, size: 20, color: color),
        const Gap(12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            if (title != null)
              Text(title, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 14)),
            Text(text, style: TextStyle(color: _live == _Live.searching ? AppColors.fgMid : color, fontSize: 13, height: 1.4)),
            if (_vpn)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(tr('На телефоне включён VPN — выключите его на время подключения.'),
                    style: const TextStyle(color: AppColors.warn, fontSize: 13, height: 1.4)),
              ),
          ]),
        ),
      ]),
    ).animate(key: ValueKey(_live)).fadeIn(duration: 200.ms);
  }
}
