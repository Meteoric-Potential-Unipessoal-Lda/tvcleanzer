import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/tv_device.dart';
import '../state/current_tv.dart';
import '../state/remote.dart';
import '../theme/app_theme.dart';
import '../widgets/pressable.dart';

import '../l10n/l10n.dart';
class RemoteScreen extends ConsumerStatefulWidget {
  const RemoteScreen({super.key});
  @override
  ConsumerState<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends ConsumerState<RemoteScreen> {
  final _text = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _key(TvDevice tv, int code) =>
      ref.read(remoteProvider.notifier).key(tv.id, code);

  Future<void> _sendText(TvDevice tv) async {
    final value = _text.text.trim();
    if (value.isEmpty) return;
    setState(() => _sending = true);
    try {
      await ref.read(remoteProvider.notifier).text(tv.id, value);
      _text.clear();
    } catch (_) {
      // status card shows the error
    }
    if (mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final tv = ref.watch(currentTvProvider);
    final rs = ref.watch(remoteProvider);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Пульт'))),
      body: tv == null
          ? _noTv()
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              child: Column(children: [
                _status(tv, rs),
                const Gap(28),
                _DPad(onKey: (c) => _key(tv, c)),
                const Gap(28),
                Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                  _RoundButton(icon: Icons.arrow_back_rounded, label: tr('Назад'), onTap: () => _key(tv, Keys.back)),
                  _RoundButton(icon: Icons.home_rounded, label: tr('Домой'), onTap: () => _key(tv, Keys.home)),
                  _RoundButton(icon: Icons.menu_rounded, label: tr('Меню'), onTap: () => _key(tv, Keys.menu)),
                ]),
                const Gap(18),
                Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                  _RoundButton(icon: Icons.volume_down_rounded, label: tr('Тише'), onTap: () => _key(tv, Keys.volDown)),
                  _RoundButton(icon: Icons.volume_off_rounded, label: tr('Без звука'), onTap: () => _key(tv, Keys.mute)),
                  _RoundButton(icon: Icons.volume_up_rounded, label: tr('Громче'), onTap: () => _key(tv, Keys.volUp)),
                  _RoundButton(icon: Icons.play_arrow_rounded, label: tr('Пауза'), onTap: () => _key(tv, Keys.playPause)),
                ]),
                const Gap(28),
                _textInput(tv),
              ]).animate().fadeIn(duration: 300.ms),
            ),
    );
  }

  Widget _noTv() => Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.settings_remote_rounded, size: 56, color: AppColors.fgMuted),
            SizedBox(height: 16),
            Text(
              tr('Сначала выберите телевизор на вкладке «Очистка», и телефон станет его пультом.'),
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.fgMid, height: 1.5),
            ),
          ]),
        ),
      );

  Widget _status(TvDevice tv, RemoteState rs) {
    final (color, text) = switch (rs.status) {
      RemoteStatus.idle => (AppColors.fgMuted, tr('Нажмите любую кнопку, чтобы подключиться')),
      RemoteStatus.connecting => (AppColors.warn, tr('Подключаемся…')),
      RemoteStatus.ready => (AppColors.ok, tr('Подключено')),
      RemoteStatus.error => (AppColors.danger, rs.message ?? tr('Нет связи')),
    };
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBd),
      ),
      child: Row(children: [
        const Icon(Icons.tv_rounded, color: AppColors.accent),
        const Gap(12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tv.shortName.isEmpty ? tv.ipAddress : tv.shortName,
                style: GoogleFonts.syne(
                    fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.fg)),
            const Gap(2),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Text(text,
                  key: ValueKey(text),
                  style: TextStyle(fontSize: 12, color: color)),
            ),
          ]),
        ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ]),
    );
  }

  Widget _textInput(TvDevice tv) => Row(children: [
        Expanded(
          child: TextField(
            controller: _text,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _sendText(tv),
            style: const TextStyle(color: AppColors.fg),
            decoration: InputDecoration(
              hintText: tr('Текст на ТВ (латиница)'),
              hintStyle: const TextStyle(color: AppColors.fgMuted),
              filled: true,
              fillColor: AppColors.bgCard,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: AppColors.cardBd),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: AppColors.cardBd),
              ),
            ),
          ),
        ),
        const Gap(10),
        SizedBox(
          height: 50,
          child: FilledButton(
            onPressed: _sending ? null : () => _sendText(tv),
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 16)),
            child: _sending
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send_rounded),
          ),
        ),
      ]);
}

class _DPad extends StatelessWidget {
  final ValueChanged<int> onKey;
  const _DPad({required this.onKey});

  @override
  Widget build(BuildContext context) {
    Widget arrow(IconData icon, int code) => Pressable(
          onTap: () => onKey(code),
          child: SizedBox(
            width: 72,
            height: 72,
            child: Icon(icon, size: 40, color: AppColors.fg),
          ),
        );

    return Container(
      width: 250,
      height: 250,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.bgCard,
        border: Border.all(color: AppColors.cardBd),
        boxShadow: const [
          BoxShadow(color: Color(0x55000000), blurRadius: 30, offset: Offset(0, 12)),
        ],
      ),
      child: Stack(alignment: Alignment.center, children: [
        Align(alignment: Alignment.topCenter, child: arrow(Icons.keyboard_arrow_up_rounded, Keys.up)),
        Align(alignment: Alignment.bottomCenter, child: arrow(Icons.keyboard_arrow_down_rounded, Keys.down)),
        Align(alignment: Alignment.centerLeft, child: arrow(Icons.keyboard_arrow_left_rounded, Keys.left)),
        Align(alignment: Alignment.centerRight, child: arrow(Icons.keyboard_arrow_right_rounded, Keys.right)),
        Pressable(
          onTap: () => onKey(Keys.ok),
          child: Container(
            width: 92,
            height: 92,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.accent,
              boxShadow: [
                BoxShadow(
                    color: AppColors.accent.withValues(alpha: .35),
                    blurRadius: 24,
                    offset: const Offset(0, 6)),
              ],
            ),
            alignment: Alignment.center,
            child: Text('OK',
                style: GoogleFonts.syne(
                    fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.bg)),
          ),
        ),
      ]),
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _RoundButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 58,
          height: 58,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.bgCard,
            border: Border.all(color: AppColors.cardBd),
          ),
          child: Icon(icon, color: AppColors.fg),
        ),
        const Gap(6),
        Text(label, style: const TextStyle(fontSize: 11, color: AppColors.fgMid)),
      ]),
    );
  }
}
