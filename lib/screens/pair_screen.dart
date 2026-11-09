import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/adb_package_manager.dart';
import '../services/app_log.dart';
import '../services/pairing/adb_pairing.dart';
import '../state/current_tv.dart';
import '../theme/app_theme.dart';
import 'home_screen.dart';

/// «Беспроводная отладка» (Android 11+, Google TV, Chromecast): pair once
/// with the 6-digit code, then connect to the port from the main screen.
class PairScreen extends ConsumerStatefulWidget {
  const PairScreen({super.key});
  @override
  ConsumerState<PairScreen> createState() => _PairScreenState();
}

enum _Step { pair, connect }

class _PairScreenState extends ConsumerState<PairScreen> {
  final _pairAddr = TextEditingController();
  final _code = TextEditingController();
  final _connAddr = TextEditingController();
  _Step _step = _Step.pair;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pairAddr.dispose();
    _code.dispose();
    _connAddr.dispose();
    super.dispose();
  }

  static (String, int)? _parse(String raw) {
    final m = RegExp(r'^\s*(\d{1,3}(?:\.\d{1,3}){3})\s*:\s*(\d{2,5})\s*$').firstMatch(raw);
    if (m == null) return null;
    final port = int.parse(m.group(2)!);
    if (port < 1 || port > 65535) return null;
    return (m.group(1)!, port);
  }

  Future<void> _pair() async {
    final addr = _parse(_pairAddr.text);
    final code = _code.text.trim();
    if (addr == null) {
      return setState(() => _error = 'Введите адрес как на экране ТВ, например 192.168.1.20:37155');
    }
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      return setState(() => _error = 'Код — 6 цифр из окна «Подключение по коду».');
    }
    setState(() { _busy = true; _error = null; });
    try {
      await AdbPairing.pair(addr.$1, addr.$2, code);
      if (!mounted) return;
      setState(() {
        _step = _Step.connect;
        _connAddr.text = '${addr.$1}:';
        _connAddr.selection = TextSelection.collapsed(offset: _connAddr.text.length);
      });
    } on PairingException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      AppLog.error('pair', e);
      setState(() => _error = 'Сопряжение не удалось: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect() async {
    final addr = _parse(_connAddr.text);
    if (addr == null) {
      return setState(() => _error = 'Введите IP-адрес и порт с экрана «Беспроводная отладка».');
    }
    setState(() { _busy = true; _error = null; });
    try {
      final tv = await ref.read(adbServiceProvider).getDeviceInfo(addr.$1, port: addr.$2);
      await ref.read(currentTvProvider.notifier).select(tv);
      ref.read(discoveryProvider.notifier).add(tv);
      if (!mounted) return;
      Navigator.pop(context, tv);
    } catch (e) {
      AppLog.error('wireless connect', e);
      setState(() => _error =
          'Не удалось подключиться. Проверьте порт: он на главном экране «Беспроводной отладки» и отличается от порта сопряжения.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pairing = _step == _Step.pair;
    return Scaffold(
      appBar: AppBar(title: const Text('Подключить по коду')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          _StepHeader(n: 1, title: 'Сопряжение', done: !pairing),
          const Gap(8),
          if (pairing) ...[
            const _Hint(
              'На ТВ: Настройки → Для разработчиков → Беспроводная отладка → ВКЛ → '
              '«Подключить устройство с помощью кода». Введите адрес и код из этого окна.'),
            const Gap(16),
            _Field(controller: _pairAddr, label: 'IP-адрес и порт', hint: '192.168.1.20:37155',
                keyboard: const TextInputType.numberWithOptions(decimal: true),
                formatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.:]'))]),
            const Gap(12),
            _Field(controller: _code, label: 'Код', hint: '6 цифр',
                keyboard: TextInputType.number,
                formatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                big: true),
          ],
          const Gap(24),
          _StepHeader(n: 2, title: 'Подключение', done: false, dim: pairing),
          if (!pairing) ...[
            const Gap(8),
            const _Hint(
              'Готово, телефон сопряжён. Окно с кодом можно закрыть. На главном экране '
              '«Беспроводной отладки» указан IP-адрес и порт — введите их.'),
            const Gap(16),
            _Field(controller: _connAddr, label: 'IP-адрес и порт', hint: '192.168.1.20:41023',
                keyboard: const TextInputType.numberWithOptions(decimal: true),
                formatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.:]'))],
                autofocus: true),
          ],
          if (_error != null) ...[
            const Gap(16),
            Text(_error!, style: const TextStyle(color: AppColors.danger, fontSize: 13, height: 1.4)),
          ],
          const Gap(24),
          FilledButton(
            onPressed: _busy ? null : (pairing ? _pair : _connect),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            child: _busy
                ? const SizedBox(width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.bg))
                : Text(pairing ? 'Сопрячь' : 'Подключить'),
          ),
          const Gap(16),
          const Text(
            'Нужно один раз. Для старых ТВ с «Отладкой по сети» (порт 5555) этот шаг не нужен — '
            'они находятся автоматически.',
            style: TextStyle(color: AppColors.fgMuted, fontSize: 12, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _StepHeader extends StatelessWidget {
  const _StepHeader({required this.n, required this.title, required this.done, this.dim = false});
  final int n;
  final String title;
  final bool done;
  final bool dim;
  @override
  Widget build(BuildContext context) {
    final c = dim ? AppColors.fgMuted : AppColors.accent;
    return Row(children: [
      Container(
        width: 28, height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: c, width: 1.5),
            color: done ? AppColors.accent : null),
        child: done
            ? const Icon(Icons.check_rounded, size: 18, color: AppColors.bg)
            : Text('$n', style: TextStyle(color: c, fontWeight: FontWeight.w700)),
      ),
      const Gap(12),
      Text(title, style: GoogleFonts.syne(
          fontSize: 18, fontWeight: FontWeight.w700, color: dim ? AppColors.fgMuted : AppColors.fg)),
    ]);
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(color: AppColors.fgMid, fontSize: 14, height: 1.5));
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller, required this.label, required this.hint,
    required this.keyboard, required this.formatters, this.big = false, this.autofocus = false,
  });
  final TextEditingController controller;
  final String label;
  final String hint;
  final TextInputType keyboard;
  final List<TextInputFormatter> formatters;
  final bool big;
  final bool autofocus;
  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        keyboardType: keyboard,
        inputFormatters: formatters,
        autofocus: autofocus,
        style: big
            ? const TextStyle(fontSize: 28, letterSpacing: 8, fontWeight: FontWeight.w600)
            : null,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          filled: true,
          fillColor: AppColors.bgCard,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        ),
      );
}
