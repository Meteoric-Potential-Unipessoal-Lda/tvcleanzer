import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/tv_device.dart';
import '../services/adb_package_manager.dart';
import '../state/history.dart';
import '../theme/app_theme.dart';
import '../widgets/package_tile.dart';
import 'result_screen.dart';

// ─── Providers ───────────────────────────────────────────────────────────────

final cleanProvider = StateNotifierProvider.family<CleanNotifier, CleanState, _CleanArgs>(
  (ref, args) => CleanNotifier(
    args.device, args.packages, ref.read(adbServiceProvider),
    onDone: (r) => ref.read(historyProvider.notifier)
        .addFromClean(args.device, args.packages, r),
  ),
);

@immutable
class _CleanArgs {
  final TvDevice device;
  final List<TvPackage> packages;
  const _CleanArgs(this.device, this.packages);
  @override bool operator ==(Object o) => o is _CleanArgs && o.device.id == device.id;
  @override int get hashCode => device.id.hashCode;
}

class CleanState {
  final CleanPhase phase;
  final int removed;        // packages removed so far (visual progress)
  final int total;
  final CleanResult? result;
  final String? error;
  const CleanState({required this.phase, this.removed = 0, this.total = 0, this.result, this.error});
}

enum CleanPhase { confirm, cleaning, done, error }

class CleanNotifier extends StateNotifier<CleanState> {
  CleanNotifier(this._device, this._packages, this._api, {this.onDone})
    : super(CleanState(phase: CleanPhase.confirm, total: _packages.length));
  final TvDevice          _device;
  final List<TvPackage>   _packages;
  final AdbPackageManager _api;
  /// Called once with the result, so it lands in History even if the user
  /// closes the result screen.
  final Future<void> Function(CleanResult)? onDone;

  Future<void> startClean() async {
    state = CleanState(phase: CleanPhase.cleaning, total: _packages.length);

    // Kick off the real API call in parallel with visual progress animation.
    final apiFuture = _api.clean(_device, _packages);

    // Animate progress up to ~90% while the API is working.
    // At 350ms/pkg, 7 packages ≈ 2.2s — typical clean takes 2–5s.
    final tickCount = (_packages.length * 0.9).ceil().clamp(1, _packages.length);
    for (int i = 1; i <= tickCount; i++) {
      await Future.delayed(const Duration(milliseconds: 350));
      if (!mounted) return;
      state = CleanState(phase: CleanPhase.cleaning, removed: i, total: _packages.length);
    }

    // Wait for the real result (should be done or close by now).
    try {
      final result = await apiFuture;
      await onDone?.call(result);
      if (!mounted) return;
      state = CleanState(
        phase:   CleanPhase.done,
        result:  result,
        total:   _packages.length,
        removed: _packages.length,
      );
    } catch (e) {
      if (!mounted) return;
      state = CleanState(
        phase: CleanPhase.error,
        error: _friendlyError(e),
        total: _packages.length,
      );
    }
  }

  String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('SocketException') || s.contains('connection')) {
      return 'Связь с телевизором прервалась во время очистки.';
    }
    return 'Ошибка: $s';
  }
}

// ─── Screen ──────────────────────────────────────────────────────────────────

class CleanScreen extends ConsumerWidget {
  final TvDevice device;
  final List<TvPackage> packages;
  const CleanScreen({super.key, required this.device, required this.packages});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = _CleanArgs(device, packages);
    final state = ref.watch(cleanProvider(args));

    return PopScope(
      canPop: state.phase == CleanPhase.confirm ||
              state.phase == CleanPhase.done     ||
              state.phase == CleanPhase.error,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Очистка'),
          leading: state.phase == CleanPhase.cleaning
              ? const SizedBox.shrink()
              : const BackButton(),
        ),
        body: switch (state.phase) {
          CleanPhase.confirm  => _buildConfirm(context, ref, args),
          CleanPhase.cleaning => _buildCleaning(state),
          CleanPhase.done     => _buildDone(context, state),
          CleanPhase.error    => _buildError(context, state.error!, ref, args),
        },
      ),
    );
  }

  Widget _buildConfirm(BuildContext context, WidgetRef ref, _CleanArgs args) {
    final totalMb = packages.fold(0, (s, p) => s + p.sizeMb);
    return Column(children: [
      Expanded(child: ListView(padding: const EdgeInsets.all(16), children: [
        // Warning card
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.warn.withValues(alpha: .1),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.warn.withValues(alpha: .3)),
          ),
          child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.info_outline_rounded, color: AppColors.warn, size: 20),
            Gap(10),
            Expanded(child: Text(
              'Приложения будут скрыты, а не удалены навсегда. '
              'Восстановить их можно в любой момент.',
              style: TextStyle(color: AppColors.warn, fontSize: 13, height: 1.5),
            )),
          ]),
        ).animate().fadeIn(duration: 300.ms),

        const Gap(20),

        Text('${packages.length} приложений будут скрыты',
          style: GoogleFonts.syne(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.fg)),
        if (totalMb > 0) ...[
          const Gap(4),
          Text('Освободится ~$totalMb МБ',
            style: const TextStyle(color: AppColors.fgMuted, fontSize: 13)),
        ],
        const Gap(16),

        ...packages.asMap().entries.map((e) =>
          PackageTile(pkg: e.value)
            .animate(delay: (e.key * 40).ms)
            .fadeIn(duration: 200.ms)
            .slideX(begin: .04, end: 0, duration: 200.ms),
        ),
      ])),

      SafeArea(child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Row(children: [
          Expanded(child: OutlinedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          )),
          const Gap(12),
          Expanded(flex: 2, child: FilledButton.icon(
            icon: const Icon(Icons.cleaning_services_rounded),
            label: const Text('Очистить'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              backgroundColor: AppColors.danger,
            ),
            onPressed: () => ref.read(cleanProvider(args).notifier).startClean(),
          )),
        ]),
      )),
    ]);
  }

  Widget _buildCleaning(CleanState state) {
    final progress = state.total > 0 ? state.removed / state.total : 0.0;
    return Center(
      child: Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 80, height: 80,
          child: CircularProgressIndicator(
            value: progress, strokeWidth: 4, color: AppColors.accent,
            backgroundColor: AppColors.accentDim,
          ),
        ),
        const Gap(24),
        Text('${(progress * 100).round()}%',
          style: GoogleFonts.syne(fontSize: 32, fontWeight: FontWeight.w800, color: AppColors.fg)),
        const Gap(8),
        Text(
          state.removed < state.total
            ? 'Убираем ${state.removed + 1} из ${state.total}…'
            : 'Завершаем…',
          style: const TextStyle(color: AppColors.fgMid),
        ),
        const Gap(4),
        if (state.removed < state.total && state.removed < packages.length)
          Text(packages[state.removed].displayName,
            style: const TextStyle(color: AppColors.fgMuted, fontSize: 12),
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ]).animate().fadeIn(duration: 400.ms)),
    );
  }

  Widget _buildDone(BuildContext context, CleanState state) {
    // Auto-navigate to result screen
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted && state.result != null) {
        Navigator.pushReplacement(context, MaterialPageRoute(
          builder: (_) => ResultScreen(device: device, result: state.result!),
        ));
      }
    });
    return const SizedBox.shrink();
  }

  Widget _buildError(BuildContext context, String error, WidgetRef ref, _CleanArgs args) =>
    Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.error_outline_rounded, color: AppColors.danger, size: 48),
      const Gap(16),
      Text('Ошибка очистки',
        style: GoogleFonts.syne(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.fg)),
      const Gap(8),
      Text(error, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.fgMid, fontSize: 13)),
      const Gap(24),
      Row(mainAxisSize: MainAxisSize.min, children: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Назад')),
        const Gap(12),
        FilledButton(
          onPressed: () => ref.read(cleanProvider(args).notifier).startClean(),
          child: const Text('Повторить'),
        ),
      ]),
    ])));
}
