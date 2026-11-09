import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/tv_device.dart';
import '../services/adb_package_manager.dart';
import '../theme/app_theme.dart';
import '../widgets/package_tile.dart';
import 'clean_screen.dart';

// ─── Providers ───────────────────────────────────────────────────────────────

final scanProvider = StateNotifierProvider.family<ScanNotifier, ScanState, TvDevice>(
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
      if (!mounted) return;
      state = ScanState(phase: ScanPhase.error, error: _friendlyError(e));
    }
  }

  String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('SocketException') || s.contains('connection')) {
      return 'Нет связи с телевизором. Убедитесь, что телефон и телевизор в одной Wi-Fi сети.';
    }
    if (s.contains('timeout') || s.contains('Timeout')) {
      return 'Телевизор не отвечает. Проверьте, что на телевизоре включена отладка по сети, и попробуйте снова.';
    }
    return 'Ошибка: $s';
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
      SizedBox(
        width: 72, height: 72,
        child: CircularProgressIndicator(
          strokeWidth: 3, color: AppColors.accent,
        ),
      ),
      const Gap(24),
      Text('Анализируем телевизор…',
        style: GoogleFonts.syne(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.fg)),
      const Gap(8),
      Text('Это займёт несколько секунд',
        style: TextStyle(color: AppColors.fgMuted)),
    ]).animate().fadeIn(duration: 400.ms),
  );

  Widget _buildResults(ScanResult result) {
    final toRemove = result.toRemove;
    final toKeep   = result.packages
        .where((p) => p.verdict == PackageVerdict.keep || p.verdict == PackageVerdict.system)
        .toList();

    return Column(children: [
      // Summary banner
      Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppColors.accentDim,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.accent.withOpacity(.25)),
        ),
        child: Row(children: [
          const Text('🧹', style: TextStyle(fontSize: 32)),
          const Gap(14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${toRemove.length} приложений можно убрать',
              style: GoogleFonts.syne(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.fg)),
            Text('Освободится около ${result.totalSaveMb} МБ',
              style: TextStyle(color: AppColors.fgMid, fontSize: 13)),
          ])),
        ]),
      ).animate().fadeIn(duration: 300.ms).slideY(begin: .15, end: 0),

      // Package list
      Expanded(child: ListView(padding: const EdgeInsets.symmetric(horizontal: 16), children: [
        if (toRemove.isNotEmpty) ...[
          _sectionHeader('Безопасно убрать', AppColors.danger),
          const Gap(8),
          ...toRemove.asMap().entries.map((e) =>
            PackageTile(pkg: e.value)
              .animate(delay: (e.key * 50).ms)
              .fadeIn(duration: 250.ms)
              .slideX(begin: .05, end: 0, duration: 250.ms),
          ),
          const Gap(16),
        ],
        if (toKeep.isNotEmpty) ...[
          _sectionHeader('Оставить', AppColors.ok),
          const Gap(8),
          ...toKeep.map((p) => PackageTile(pkg: p, dimmed: true)),
          const Gap(16),
        ],
        if (toRemove.isEmpty && toKeep.isEmpty)
          _buildNothingFound(),
      ])),

      // CTA
      if (toRemove.isNotEmpty)
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SizedBox(width: double.infinity, child: FilledButton.icon(
              icon: const Icon(Icons.cleaning_services_rounded),
              label: Text('Очистить · освободить ${result.totalSaveMb} МБ'),
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
              onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => CleanScreen(
                  device: widget.device,
                  packages: toRemove,
                ))),
            )),
          ),
        ),
    ]);
  }

  Widget _buildNothingFound() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48),
    child: Column(children: [
      const Text('✅', style: TextStyle(fontSize: 48)),
      const Gap(16),
      Text('Телевизор чистый!',
        style: GoogleFonts.syne(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.fg)),
      const Gap(8),
      Text('Мусорных приложений не обнаружено.',
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
        Text('Не удалось подключиться',
          style: GoogleFonts.syne(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.fg)),
        const Gap(8),
        Text(error,
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.fgMid)),
        const Gap(24),
        FilledButton(
          onPressed: () => ref.read(scanProvider(widget.device).notifier).startScan(),
          child: const Text('Попробовать снова'),
        ),
      ]),
    ),
  );

  Widget _sectionHeader(String label, Color color) => Row(children: [
    Container(width: 3, height: 14, decoration: BoxDecoration(
      color: color, borderRadius: BorderRadius.circular(2),
    )),
    const Gap(8),
    Text(label.toUpperCase(), style: TextStyle(
      fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: .08, color: AppColors.fgMuted,
    )),
  ]);
}
