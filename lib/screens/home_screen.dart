import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/tv_device.dart';
import '../services/adb_package_manager.dart';
import '../services/demo_tv.dart';
import '../services/tv_discovery.dart';
import '../state/current_tv.dart';
import '../theme/app_theme.dart';
import '../widgets/tv_card.dart';
import 'help_screen.dart';
import 'pair_screen.dart';
import 'scan_screen.dart';

import '../l10n/l10n.dart';
// ─── Providers ───────────────────────────────────────────────────────────────

/// Singleton TvDiscovery — reuses the shared AdbPackageManager instance.
final tvDiscoveryProvider = Provider<TvDiscovery>(
  (ref) => TvDiscovery(ref.read(adbServiceProvider)),
);

final discoveryProvider = StateNotifierProvider<DiscoveryNotifier, DiscoveryState>(
  (ref) => DiscoveryNotifier(ref),
);

class DiscoveryState {
  final List<TvDevice> devices;
  final bool scanning;
  final String? error;
  const DiscoveryState({this.devices = const [], this.scanning = false, this.error});
}

class DiscoveryNotifier extends StateNotifier<DiscoveryState> {
  DiscoveryNotifier(this._ref) : super(const DiscoveryState());
  final Ref _ref;

  /// Adds a TV connected another way (wireless debugging by code).
  void add(TvDevice d) {
    state = DiscoveryState(
      devices: [d, ...state.devices.where((e) => e.id != d.id)],
      scanning: state.scanning,
      error: state.error,
    );
  }

  Future<void> startScan() async {
    // Wireless-debugging TVs aren't on port 5555: keep the one we paired with.
    final cur = _ref.read(currentTvProvider);
    state = DiscoveryState(scanning: true, devices: [if (cur != null && (cur.isWireless || cur.isDemo)) cur]);
    final discovery = _ref.read(tvDiscoveryProvider);
    try {
      await for (final d in discovery.discover()) {
        if (!mounted) return;
        // Avoid duplicates by IP
        final existing = state.devices.any((e) => e.ipAddress == d.ipAddress);
        final current = _ref.read(currentTvProvider);
        if (current == null || current.isDemo || (current.ipAddress == d.ipAddress && !current.isWireless)) {
          _ref.read(currentTvProvider.notifier).select(d); // Remote & Launcher use it
        }
        if (!existing) {
          state = DiscoveryState(devices: [...state.devices, d], scanning: true);
        }
      }
    } catch (e) {
      if (!mounted) return;
      state = DiscoveryState(devices: state.devices, scanning: false, error: e.toString());
      return;
    }
    if (!mounted) return;
    state = DiscoveryState(devices: state.devices, scanning: false);
  }
}

// ─── Screen ──────────────────────────────────────────────────────────────────

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});
  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  void initState() {
    super.initState();
    // Auto-start discovery on first load
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(discoveryProvider.notifier).startScan();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(discoveryProvider);

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          _buildAppBar(),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList(delegate: SliverChildListDelegate([
              const Gap(8),
              _buildSearchStatus(state),
              const Gap(24),
              if (state.devices.isNotEmpty) ...[
                _sectionLabel(tr('Телевизоры в сети')),
                const Gap(12),
                ...state.devices.asMap().entries.map((e) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: TvCard(device: e.value)
                    .animate(delay: (e.key * 80).ms)
                    .fadeIn(duration: 300.ms)
                    .slideY(begin: .15, end: 0, duration: 300.ms),
                )),
              ],
              if (!state.scanning && state.devices.isEmpty)
                _buildEmpty(state.error),
              if (!state.devices.any((d) => d.isDemo)) ...[
                const Gap(8),
                Center(child: TextButton.icon(
                  icon: const Icon(Icons.play_circle_outline_rounded, size: 18),
                  label: Text(tr('Нет телевизора рядом? Попробовать демо')),
                  onPressed: _openDemo,
                )),
              ],
              const Gap(24),
            ])),
          ),
        ],
      ),
    );
  }

  /// Pairing by code needs the native TLS channel (Android, iOS only for now).
  static bool get _canPair => Platform.isAndroid || Platform.isIOS;

  /// The built-in demo TV: every screen works without a real TV.
  void _openDemo() {
    final d = DemoTv.device();
    ref.read(discoveryProvider.notifier).add(d);
    ref.read(currentTvProvider.notifier).select(d);
    Navigator.push(context, MaterialPageRoute(builder: (_) => ScanScreen(device: d)));
  }

  void _openPair() => Navigator.push(context,
      MaterialPageRoute(builder: (_) => const PairScreen()));

  SliverAppBar _buildAppBar() => SliverAppBar(
    pinned: true,
    expandedHeight: 110,
    flexibleSpace: FlexibleSpaceBar(
      title: Text('TVCleanzer',
        style: GoogleFonts.syne(
          fontWeight: FontWeight.w800,
          fontSize: 22,
          color: AppColors.fg,
          letterSpacing: -.5,
        ),
      ),
      titlePadding: const EdgeInsetsDirectional.only(start: 16, bottom: 16),
    ),
    actions: [
      if (_canPair)
        IconButton(
          icon: const Icon(Icons.pin_rounded),
          color: AppColors.fgMid,
          tooltip: tr('Подключить по коду'),
          onPressed: _openPair,
        ),
      IconButton(
        icon: const Icon(Icons.help_outline_rounded),
        color: AppColors.fgMid,
        tooltip: tr('Помощь'),
        onPressed: () => showHelpSheet(context, ref),
      ),
      IconButton(
        icon: const Icon(Icons.refresh_rounded),
        color: AppColors.accent,
        tooltip: tr('Найти снова'),
        onPressed: () => ref.read(discoveryProvider.notifier).startScan(),
      ),
      const Gap(8),
    ],
  );

  Widget _buildSearchStatus(DiscoveryState state) {
    if (!state.scanning) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.accentDim,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.accent.withValues(alpha: .25)),
      ),
      child: Row(children: [
        const SizedBox(
          width: 18, height: 18,
          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent),
        ),
        const Gap(12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            state.devices.isEmpty
              ? tr('Ищем телевизоры в сети…')
              : tr('Продолжаем поиск…'),
            style: const TextStyle(color: AppColors.accent, fontWeight: FontWeight.w500),
          ),
          const Gap(4),
          Text(
            tr('Если на телевизоре появится запрос отладки — отметьте «Всегда разрешать» и нажмите «Разрешить».'),
            style: const TextStyle(color: AppColors.fgMid, fontSize: 12, height: 1.4),
          ),
        ])),
        if (state.devices.isNotEmpty)
          Text(tr('{0} найдено', [state.devices.length]),
            style: const TextStyle(color: AppColors.accent, fontSize: 12)),
      ]),
    ).animate().fadeIn(duration: 300.ms);
  }

  Widget _sectionLabel(String text) => Text(
    text.toUpperCase(),
    style: const TextStyle(
      fontSize: 11, fontWeight: FontWeight.w600,
      letterSpacing: .08, color: AppColors.fgMuted,
    ),
  );

  Widget _buildEmpty([String? error]) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48),
    child: Column(children: [
      const Text('📺', style: TextStyle(fontSize: 48)),
      const Gap(16),
      Text(tr('Телевизоры не найдены'),
        style: GoogleFonts.syne(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.fg)),
      const Gap(8),
      if (error != null)
        Text(error,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.danger, fontSize: 13))
      else
        Text(
          tr('Включите отладку по сети на телевизоре:\nНастройки → Параметры разработчика →\nОтладка по ADB (сеть) → ВКЛ'),
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.fgMid, fontSize: 14, height: 1.6),
        ),
      const Gap(24),
      FilledButton.icon(
        icon: const Icon(Icons.refresh_rounded),
        label: Text(tr('Искать снова')),
        onPressed: () => ref.read(discoveryProvider.notifier).startScan(),
      ),
      if (_canPair) ...[
        const Gap(8),
        OutlinedButton.icon(
          icon: const Icon(Icons.pin_rounded, size: 18),
          label: Text(tr('Google TV / Android 11+: подключить по коду')),
          onPressed: _openPair,
        ),
      ],
      const Gap(4),
      TextButton.icon(
        icon: const Icon(Icons.menu_book_rounded, size: 18),
        label: Text(tr('Как включить отладку на моём ТВ?')),
        onPressed: () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => const HelpScreen())),
      ),
    ]),
  );
}
