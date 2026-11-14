import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/tv_device.dart';
import '../services/adb_package_manager.dart';
import '../services/app_log.dart';
import '../state/history.dart';
import '../theme/app_theme.dart';
import '../widgets/package_tile.dart';
import 'clean_screen.dart';

import '../l10n/l10n.dart';
// ─── Providers ───────────────────────────────────────────────────────────────

final scanProvider = StateNotifierProvider.autoDispose.family<ScanNotifier, ScanState, TvDevice>(
  (ref, device) => ScanNotifier(device, ref.read(adbServiceProvider)),
);

class ScanState {
  final ScanPhase phase;
  final ScanResult? result;
  final String? error;
  const ScanState({required this.phase, this.result, this.error});
}

enum ScanPhase { idle, scanning, done, error }

class ScanNotifier extends StateNotifier<ScanState> {
  ScanNotifier(this._device, this._api) : super(const ScanState(phase: ScanPhase.idle));
  final TvDevice           _device;
  final AdbPackageManager  _api;

  Future<void> startScan() async {
    state = const ScanState(phase: ScanPhase.scanning);
    try {
      final result = await _api.scan(_device);
      if (!mounted) return;
      state = ScanState(phase: ScanPhase.done, result: result);
    } catch (e) {
      AppLog.error('scan ${_device.ipAddress}', e);
      if (!mounted) return;
      state = ScanState(phase: ScanPhase.error, error: _friendlyError(e));
    }
  }

  String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('SocketException') || s.contains('connection')) {
      return tr('Нет связи с телевизором. Убедитесь, что телефон и телевизор в одной Wi-Fi сети.');
    }
    if (s.contains('timeout') || s.contains('Timeout') || s.contains('timed out')) {
      return tr('Телевизор не отвечает. Проверьте, что на телевизоре включена отладка по сети, и попробуйте снова.');
    }
    return tr('Ошибка: {0}', [s]);
  }
}

// ─── Screen ──────────────────────────────────────────────────────────────────

class ScanScreen extends ConsumerStatefulWidget {
  final TvDevice device;
  const ScanScreen({super.key, required this.device});
  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen> {
  Set<String>? _selected;   // packages ticked for cleaning
  ScanResult? _seen;        // result the selection was made for
  bool _boosting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(scanProvider(widget.device).notifier).startScan();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(scanProvider(widget.device));

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.shortName),
        leading: const BackButton(),
      ),
      body: switch (state.phase) {
        ScanPhase.scanning => _buildScanning(),
        ScanPhase.done     => _buildResults(state.result!),
        ScanPhase.error    => _buildError(state.error!),
        ScanPhase.idle     => const SizedBox.shrink(),
      },
    );
  }

  Widget _buildScanning() => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const SizedBox(
        width: 72, height: 72,
        child: CircularProgressIndicator(strokeWidth: 3, color: AppColors.accent),
      ),
      const Gap(24),
      Text(tr('Анализируем телевизор…'),
        style: GoogleFonts.syne(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.fg)),
      const Gap(8),
      Text(tr('Сверяем с 463 проверенными списками'),
        style: TextStyle(color: AppColors.fgMuted)),
    ]).animate().fadeIn(duration: 400.ms),
  );

  void _toggle(String pkg) {
    HapticFeedback.selectionClick();
    setState(() {
      final s = _selected!;
      s.contains(pkg) ? s.remove(pkg) : s.add(pkg);
    });
  }

  Widget _buildResults(ScanResult result) {
    if (!identical(_seen, result)) {
      _seen = result;
      _selected = result.toRemove.map((p) => p.packageName).toSet();
    }
    final selected = _selected!;
    final toRemove  = result.toRemove;
    final toCaution = result.toCaution;
    final toKeep    = result.packages
        .where((p) => p.verdict == PackageVerdict.keep || p.verdict == PackageVerdict.system)
        .toList();
    final chosen = result.packages.where((p) => selected.contains(p.packageName)).toList();
    final chosenMb = chosen.fold(0, (s, p) => s + p.sizeMb);

    return Column(children: [
      Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 16), children: [
        _summary(toRemove.length, toCaution.length),
        const Gap(12),
        _boostCard(),
        const Gap(20),
        if (toRemove.isNotEmpty) ...[
          _sectionHeader(tr('Рекомендуем убрать'), AppColors.danger, '${toRemove.length}'),
          const Gap(8),
          ...toRemove.asMap().entries.map((e) =>
            PackageTile(
              pkg: e.value,
              selected: selected.contains(e.value.packageName),
              onTap: () => _toggle(e.value.packageName),
            ).animate(delay: (e.key.clamp(0, 12) * 40).ms)
              .fadeIn(duration: 220.ms)
              .slideX(begin: .05, end: 0, duration: 220.ms),
          ),
          const Gap(16),
        ],
        if (toCaution.isNotEmpty) ...[
          _sectionHeader(tr('На ваше усмотрение'), AppColors.warn, '${toCaution.length}'),
          const Gap(4),
          Text(tr('Функции и приложения: голос, трансляция, сервисы видео. Отметьте, только если точно не пользуетесь.'),
              style: TextStyle(fontSize: 12, color: AppColors.fgMuted, height: 1.4)),
          const Gap(8),
          ...toCaution.map((p) => PackageTile(
                pkg: p,
                selected: selected.contains(p.packageName),
                onTap: () => _toggle(p.packageName),
              )),
          const Gap(16),
        ],
        if (toKeep.isNotEmpty)
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              iconColor: AppColors.fgMid,
              collapsedIconColor: AppColors.fgMuted,
              title: _sectionHeader(tr('Не трогаем'), AppColors.ok, '${toKeep.length}'),
              subtitle: Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(tr('Система, входы HDMI, пульт, главный экран и ваши приложения'),
                    style: TextStyle(fontSize: 12, color: AppColors.fgMuted)),
              ),
              children: [for (final p in toKeep.take(200)) PackageTile(pkg: p, dimmed: true)],
            ),
          ),
        if (toRemove.isEmpty && toCaution.isEmpty) _buildNothingFound(),
      ])),

      if (chosen.isNotEmpty)
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SizedBox(width: double.infinity, child: FilledButton.icon(
              icon: const Icon(Icons.cleaning_services_rounded),
              label: Text(chosenMb > 0
                  ? tr('Убрать {0} · освободить ~{1} МБ', [chosen.length, chosenMb])
                  : tr('Убрать {0}', [chosen.length])),
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
              onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => CleanScreen(
                  device: widget.device,
                  packages: chosen,
                ))),
            )),
          ),
        ).animate().fadeIn(duration: 200.ms).slideY(begin: .3, end: 0),
    ]);
  }

  Widget _summary(int remove, int caution) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: AppColors.accentDim,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppColors.accent.withValues(alpha: .25)),
    ),
    child: Row(children: [
      const Text('🧹', style: TextStyle(fontSize: 32)),
      const Gap(14),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(remove > 0 ? tr('{0} лишних приложений', [remove]) : tr('Явного мусора нет'),
          style: GoogleFonts.syne(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.fg)),
        const Gap(2),
        Text(caution > 0 ? tr('Ещё {0} — на ваше усмотрение', [caution]) : tr('Всё скрытое можно вернуть из «Истории»'),
          style: const TextStyle(color: AppColors.fgMid, fontSize: 13)),
      ])),
    ]),
  ).animate().fadeIn(duration: 300.ms).slideY(begin: .15, end: 0);

  Widget _boostCard() => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: [Color(0x332E2A5C), Color(0x1A00CFA8)],
        begin: Alignment.topLeft, end: Alignment.bottomRight,
      ),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppColors.cardBd),
    ),
    child: Row(children: [
      Container(
        width: 44, height: 44,
        decoration: BoxDecoration(
          color: const Color(0x33A78BFA),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.bolt_rounded, color: Color(0xFFC4B5FD)),
      ),
      const Gap(12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('Ускорить телевизор'),
            style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.fg, fontSize: 15)),
        SizedBox(height: 2),
        Text(tr('Быстрее анимации, свободнее память, чище кэш. С замером до и после.'),
            style: TextStyle(fontSize: 12, color: AppColors.fgMid, height: 1.35)),
      ])),
      const Gap(8),
      _boosting
          ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
          : FilledButton(
              onPressed: _boost,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFA78BFA),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
              child: Text(tr('Пуск')),
            ),
    ]),
  ).animate().fadeIn(delay: 100.ms, duration: 300.ms);

  Future<void> _boost() async {
    setState(() => _boosting = true);
    try {
      final r = await ref.read(adbServiceProvider).boost(widget.device);
      await ref.read(historyProvider.notifier).addBoost(widget.device, r);
      if (!mounted) return;
      setState(() => _boosting = false);
      HapticFeedback.mediumImpact();
      showModalBottomSheet(
        context: context,
        backgroundColor: AppColors.bgCard,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        builder: (_) => _BoostSheet(result: r),
      );
    } catch (e) {
      AppLog.error('boost ${widget.device.ipAddress}', e);
      if (!mounted) return;
      setState(() => _boosting = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('Не получилось: телевизор не отвечает.'))));
    }
  }

  Widget _buildNothingFound() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 32),
    child: Column(children: [
      const Text('✅', style: TextStyle(fontSize: 48)),
      const Gap(16),
      Text(tr('Телевизор чистый!'),
        style: GoogleFonts.syne(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.fg)),
      const Gap(8),
      Text(tr('Мусорных приложений не обнаружено. Попробуйте «Ускорить».'),
        textAlign: TextAlign.center,
        style: TextStyle(color: AppColors.fgMid)),
    ]),
  );

  Widget _buildError(String error) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.wifi_off_rounded, color: AppColors.danger, size: 48),
        const Gap(16),
        Text(tr('Не удалось подключиться'),
          style: GoogleFonts.syne(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.fg)),
        const Gap(8),
        Text(error,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.fgMid)),
        const Gap(24),
        FilledButton(
          onPressed: () => ref.read(scanProvider(widget.device).notifier).startScan(),
          child: Text(tr('Попробовать снова')),
        ),
      ]),
    ),
  );

  Widget _sectionHeader(String label, Color color, String count) => Row(children: [
    Container(width: 3, height: 14, decoration: BoxDecoration(
      color: color, borderRadius: BorderRadius.circular(2),
    )),
    const Gap(8),
    Text(label.toUpperCase(), style: const TextStyle(
      fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: .8, color: AppColors.fgMuted,
    )),
    const Gap(6),
    Text(count, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
  ]);
}

/// Before/after numbers with a counting animation.
class _BoostSheet extends StatelessWidget {
  final BoostResult result;
  const _BoostSheet({required this.result});

  @override
  Widget build(BuildContext context) {
    final r = result;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 40, height: 4, decoration: BoxDecoration(
              color: AppColors.cardBd, borderRadius: BorderRadius.circular(2))),
          const Gap(20),
          const Icon(Icons.bolt_rounded, color: Color(0xFFC4B5FD), size: 44)
              .animate().scale(begin: const Offset(.5, .5), duration: 500.ms, curve: Curves.elasticOut),
          const Gap(10),
          Text(tr('Телевизор ускорен'),
              style: GoogleFonts.syne(fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.fg)),
          const Gap(20),
          Row(children: [
            _metric(tr('Было'), r.ramBeforeMb, AppColors.fgMid),
            const Icon(Icons.arrow_forward_rounded, color: AppColors.fgMuted),
            _metric(tr('Стало'), r.ramAfterMb, AppColors.accent, animate: true),
          ]),
          const Gap(6),
          Text(r.ramTotalMb > 0
              ? tr('свободной памяти из {0} МБ', [r.ramTotalMb])
              : tr('свободной памяти'),
              style: const TextStyle(color: AppColors.fgMuted, fontSize: 12)),
          const Gap(18),
          Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
            if (r.ramGainMb > 0) _chip(tr('+{0} МБ памяти', [r.ramGainMb]), AppColors.accent),
            if (r.cacheFreedMb > 0) _chip(tr('−{0} МБ кэша', [r.cacheFreedMb]), const Color(0xFFC4B5FD)),
            if (r.oldSettings.isNotEmpty) _chip(tr('анимации ×2 быстрее'), AppColors.warn),
          ]),
          const Gap(14),
          Text(tr('Анимации можно вернуть во вкладке «История».'),
              style: TextStyle(color: AppColors.fgMuted, fontSize: 12)),
          const Gap(16),
          SizedBox(width: double.infinity, child: FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('Отлично')),
          )),
        ]),
      ),
    );
  }

  Widget _metric(String label, int mb, Color color, {bool animate = false}) => Expanded(
    child: Column(children: [
      Text(label, style: const TextStyle(color: AppColors.fgMuted, fontSize: 12)),
      const Gap(4),
      TweenAnimationBuilder<int>(
        tween: IntTween(begin: animate ? (mb * .6).round() : mb, end: mb),
        duration: const Duration(milliseconds: 1100),
        curve: Curves.easeOutCubic,
        builder: (_, v, __) => Text(tr('{0} МБ', [v]),
            style: GoogleFonts.syne(fontSize: 26, fontWeight: FontWeight.w800, color: color)),
      ),
    ]),
  );

  Widget _chip(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(50),
      border: Border.all(color: color.withValues(alpha: .3)),
    ),
    child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 13)),
  );
}
