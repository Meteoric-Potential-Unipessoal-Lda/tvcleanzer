import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gap/gap.dart';

import '../l10n/l10n.dart';
import '../models/tv_device.dart';
import '../screens/home_screen.dart';
import '../screens/pair_screen.dart' show AddrFormatter;
import '../services/adb_package_manager.dart';
import '../services/app_log.dart';
import '../services/manual_tvs.dart';
import '../state/current_tv.dart';
import '../theme/app_theme.dart';

/// "Enter the TV's IP": for TVs with network debugging on port 5555 that the search does not
/// reach (another subnet, a mesh node, a wider network). Returns the connected TV.
Future<TvDevice?> showManualConnect(BuildContext context) => showModalBottomSheet<TvDevice>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.bgCard,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => const _ManualConnect(),
    );

class _ManualConnect extends ConsumerStatefulWidget {
  const _ManualConnect();
  @override
  ConsumerState<_ManualConnect> createState() => _ManualConnectState();
}

class _ManualConnectState extends ConsumerState<_ManualConnect> {
  final _addr = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _addr.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final a = ManualTvs.parse(_addr.text);
    if (a == null) {
      return setState(() => _error = tr('Введите IP-адрес телевизора, например 192.168.1.50'));
    }
    setState(() { _busy = true; _error = null; });
    try {
      final tv = await ref
          .read(adbServiceProvider)
          .getDeviceInfo(a.$1, port: a.$2)
          .timeout(const Duration(seconds: 80));
      await ManualTvs.remember(a.$1, a.$2);
      await ref.read(currentTvProvider.notifier).select(tv);
      ref.read(discoveryProvider.notifier).add(tv);
      if (mounted) Navigator.pop(context, tv);
    } catch (e) {
      AppLog.error('manual connect ${a.$2}', e);
      if (mounted) {
        setState(() => _error = tr('Не удалось подключиться к {0}. Проверьте адрес, что отладка включена и что на экране телевизора нажали «Разрешить».', [_addr.text.trim()]));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Center(
              child: Container(width: 40, height: 4,
                  decoration: BoxDecoration(color: AppColors.cardBd, borderRadius: BorderRadius.circular(2))),
            ),
            const Gap(14),
            Text(tr('Ввести IP телевизора'),
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.fg)),
            const Gap(6),
            Text(
                tr('Если поиск не находит телевизор, хотя отладка включена. IP есть на ТВ: Настройки → Об устройстве → Статус (или Сеть).'),
                style: const TextStyle(fontSize: 13, color: AppColors.fgMid, height: 1.4)),
            const Gap(16),
            TextField(
              controller: _addr,
              autofocus: true,
              enabled: !_busy,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [AddrFormatter()],
              onSubmitted: (_) => _busy ? null : _connect(),
              style: const TextStyle(fontSize: 18, color: AppColors.fg, letterSpacing: .5),
              decoration: InputDecoration(
                labelText: tr('IP-адрес'),
                hintText: '192.168.1.50',
                helperText: tr('Порт 5555 подставится сам. Для другого порта: адрес:порт'),
                helperMaxLines: 2,
              ),
            ),
            if (_busy) ...[
              const Gap(12),
              Text(tr('На экране телевизора может появиться «Разрешить отладку?» — отметьте «Всегда разрешать» и нажмите «Разрешить».'),
                  style: const TextStyle(fontSize: 13, color: AppColors.accent, height: 1.4)),
            ],
            if (_error != null) ...[
              const Gap(12),
              Text(_error!, style: const TextStyle(fontSize: 13, color: AppColors.danger, height: 1.4)),
            ],
            const Gap(18),
            FilledButton(
              onPressed: _busy ? null : _connect,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              child: _busy
                  ? const SizedBox(width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.bg))
                  : Text(tr('Подключить')),
            ),
          ]),
        ),
      );
}
