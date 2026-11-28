import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import '../models/tv_device.dart';
import '../services/app_log.dart';
import '../services/terminal.dart';
import '../theme/app_theme.dart';

/// "For developers": a shell on the TV. Hidden in the TV card's menu, behind a warning.
class TerminalScreen extends StatefulWidget {
  final TvDevice device;
  const TerminalScreen({super.key, required this.device});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

enum _St { gate, connecting, ready, error }

class _TerminalScreenState extends State<TerminalScreen> with WidgetsBindingObserver {
  static const _ackKey = 'terminal_ack';
  static const _maxChars = 120000;
  static const _bg = Color(0xFF05080F);
  static const _mono = TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: ['Menlo', 'Courier New', 'Courier'],
    fontSize: 12.5,
    height: 1.35,
    color: Color(0xFFD7E2EE),
  );

  _St _st = _St.connecting;
  bool _agree = false;
  String? _error;
  TerminalSession? _session;
  StreamSubscription<String>? _sub;
  final _buf = StringBuffer();
  String _text = '';
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  List<String> _history = [];
  int _histPos = -1;

  String get _histKey => 'terminal_history_${widget.device.id}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  /// Folder the shell was in (from its prompt "host:/path $"), kept across reconnects.
  String? _cwd;
  bool _foreground = true;
  int _retries = 0;

  /// The phone drops the connection when the app goes to the background (HyperOS, iOS…):
  /// coming back reconnects on its own, in the same folder, with the screen kept.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground && _st == _St.error && _session == null) _connect(quiet: true);
  }

  void _lost() {
    _sub?.cancel();
    _sub = null;
    final s = _session;
    _session = null;
    s?.close();
    if (!mounted) return;
    setState(() => _st = _St.error);
    // still on screen: try again right away (a couple of times), otherwise on return
    if (_foreground && _retries < 2) {
      _retries++;
      Future<void>.delayed(const Duration(milliseconds: 800), () {
        if (mounted && _session == null && _foreground) _connect(quiet: true);
      });
    }
  }

  Future<void> _start() async {
    final sp = await SharedPreferences.getInstance();
    _history = sp.getStringList(_histKey) ?? [];
    if (sp.getBool(_ackKey) != true) {
      if (mounted) setState(() => _st = _St.gate);
      return;
    }
    await _connect();
  }

  bool _connecting = false;
  Future<void> _connect({bool quiet = false}) async {
    if (_connecting) return;
    _connecting = true;
    setState(() {
      _st = _St.connecting;
      _error = null;
    });
    try {
      final s = await TerminalSession.open(widget.device, cwd: _cwd);
      if (!mounted) {
        await s.close();
        return;
      }
      _session = s;
      _retries = 0;
      if (quiet && _text.isNotEmpty) _append('\n[${tr('связь восстановлена')}]\n');
      _sub = s.output.listen(_append, onError: (Object e) => _lost(), onDone: _lost);
      setState(() => _st = _St.ready);
      _focus.requestFocus();
    } catch (e) {
      AppLog.error('terminal', e);
      if (mounted) {
        setState(() {
          _st = _St.error;
          _error = e.toString();
        });
      }
    } finally {
      _connecting = false;
    }
  }

  static final _prompt = RegExp(r'[\w.-]+:(/[^\s$#]*) ?[$#] ?$');

  void _append(String s) {
    if (s.isEmpty) return;
    final p = _prompt.firstMatch(s.trimRight().split('\n').last);
    if (p != null) _cwd = p.group(1);
    _buf.write(s);
    var t = _buf.toString();
    if (t.length > _maxChars) {
      t = t.substring(t.length - _maxChars);
      _buf
        ..clear()
        ..write(t);
    }
    if (!mounted) return;
    setState(() => _text = t);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _send([String? preset]) async {
    final line = terminalPlain(preset ?? _input.text).trimRight();
    final s = _session;
    if (s == null || _st != _St.ready) return;
    if (line.trim().isNotEmpty) {
      final why = terminalDanger(line);
      if (why != null && !await _confirm(line, why)) return;
      _history.remove(line);
      _history.add(line);
      if (_history.length > 60) _history.removeAt(0);
      _histPos = -1;
      SharedPreferences.getInstance().then((sp) => sp.setStringList(_histKey, _history));
      // what the owner typed goes into the problem report: "it broke" is then explainable
      AppLog.error('terminal', line);
    }
    if (preset == null) _input.clear();
    try {
      await s.run(line);
    } catch (e) {
      _append('\n[${tr('связь с телевизором потеряна')}]\n');
      _lost();
    }
    _focus.requestFocus();
  }

  /// Enter (or a pasted block with line breaks) sends every finished line, one after another.
  bool _sending = false;
  Future<void> _onInput(String v) async {
    if (!v.contains('\n') || _sending) return;
    final parts = v.replaceAll('\r', '').split('\n');
    final rest = parts.removeLast();
    _input.value = TextEditingValue(text: rest, selection: TextSelection.collapsed(offset: rest.length));
    // 1.3.199: a whole «?» report pasted in (a Yandex TV owner did it twice): every line ran as a
    // command, and the screen filled with errors. Not sent; one command is asked for instead.
    if (parts.length > 2 && _looksLikeReport(parts)) {
      _input.clear();
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(tr('Это текст отчёта, а не команда. Вставьте одну команду.'))));
      return;
    }
    _sending = true;
    try {
      for (final line in parts) {
        await _send(line);
      }
    } finally {
      _sending = false;
    }
  }

  static bool _looksLikeReport(List<String> lines) {
    final text = lines.join('\n');
    if (text.contains('TVCleanzer') && (text.contains('---') || text.contains('Android'))) return true;
    final stamped = RegExp(r'^\d\d:\d\d:\d\d ');
    return lines.where(stamped.hasMatch).length >= 2;
  }

  Future<bool> _confirm(String line, String why) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('Осторожно')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Эта команда — {0}.', [why])),
          const Gap(10),
          Text(line, style: _mono.copyWith(color: AppColors.warn)),
          const Gap(10),
          Text(tr('Выполнить её на телевизоре?')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Отмена'))),
          TextButton(onPressed: () => Navigator.pop(c, true),
              child: Text(tr('Выполнить'), style: const TextStyle(color: AppColors.warn))),
        ],
      ),
    );
    return yes == true;
  }

  void _histBack() {
    if (_history.isEmpty) return;
    _histPos = _histPos <= 0 ? _history.length - 1 : _histPos - 1;
    _input.text = _history[_histPos];
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
  }

  Future<void> _copyAll() async {
    await Clipboard.setData(ClipboardData(text: _text));
    _toast(tr('Вывод скопирован'));
  }

  Future<void> _copyReport() async {
    final tail = _text.length > 3000 ? _text.substring(_text.length - 3000) : _text;
    await Clipboard.setData(ClipboardData(
        text: '${AppLog.report(tv: widget.device)}--- ${tr('терминал')} ---\n$tail'));
    _toast(tr('Отчёт с выводом терминала скопирован: вставьте его в чат'));
  }

  void _toast(String s) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _session?.close();
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Терминал'), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          Text(widget.device.shortName.isEmpty ? widget.device.ipAddress : widget.device.shortName,
              style: const TextStyle(fontSize: 12, color: AppColors.fgMuted)),
        ]),
        actions: _st == _St.gate
            ? null
            : [
                IconButton(tooltip: tr('Скопировать вывод'), icon: const Icon(Icons.copy_all_rounded), onPressed: _copyAll),
                IconButton(tooltip: tr('Отчёт для чата'), icon: const Icon(Icons.bug_report_outlined), onPressed: _copyReport),
                IconButton(
                    tooltip: tr('Очистить экран'),
                    icon: const Icon(Icons.cleaning_services_outlined),
                    onPressed: () => setState(() {
                          _buf.clear();
                          _text = '';
                        })),
              ],
      ),
      body: SafeArea(child: _st == _St.gate ? _gate() : _terminal()),
    );
  }

  Widget _gate() => ListView(padding: const EdgeInsets.all(20), children: [
        const Icon(Icons.warning_amber_rounded, color: AppColors.warn, size: 48),
        const Gap(14),
        Text(tr('Для разработчиков'),
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.fg)),
        const Gap(12),
        Text(
          tr('Терминал отправляет команды на телевизор напрямую, как «adb shell» с компьютера. TVCleanzer их не проверяет и не может отменить: неверная команда может сломать прошивку или стереть данные.'),
          style: const TextStyle(fontSize: 15, height: 1.45, color: AppColors.fgMid),
        ),
        const Gap(10),
        Text(
          tr('Пользуйтесь, только если понимаете, что делаете. Всё — на ваш страх и риск.'),
          style: const TextStyle(fontSize: 15, height: 1.45, color: AppColors.fgMid),
        ),
        const Gap(18),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _agree,
          onChanged: (v) => setState(() => _agree = v == true),
          title: Text(tr('Я понимаю и беру ответственность на себя'),
              style: const TextStyle(fontSize: 14, color: AppColors.fg)),
          controlAffinity: ListTileControlAffinity.leading,
        ),
        const Gap(10),
        FilledButton(
          onPressed: !_agree
              ? null
              : () async {
                  final sp = await SharedPreferences.getInstance();
                  await sp.setBool(_ackKey, true);
                  await _connect();
                },
          child: Text(tr('Открыть терминал')),
        ),
      ]);

  Widget _terminal() {
    final ready = _st == _St.ready;
    return Column(children: [
      Expanded(
        child: Stack(children: [
          Positioned.fill(
            child: SingleChildScrollView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: SelectableText(_text.isEmpty && _st == _St.connecting ? tr('Подключаемся…') : _text, style: _mono),
            ),
          ),
          if (_st == _St.error)
            Positioned(
              left: 12, right: 12, bottom: 12,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.bgCard,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.warn.withValues(alpha: .4)),
                ),
                child: Row(children: [
                  Expanded(
                    child: Text(
                      _error == null ? tr('Связь прервалась. Подключаемся снова…') : tr('Не удалось подключиться к телевизору.'),
                      style: const TextStyle(fontSize: 13, color: AppColors.fg),
                    ),
                  ),
                  TextButton(onPressed: _connect, child: Text(tr('Подключиться снова'))),
                ]),
              ),
            ),
        ]),
      ),
      // ready-made commands: no typing long lines on a phone
      SizedBox(
        height: 40,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          children: [
            for (final (label, cmd) in terminalSnippets)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: ActionChip(
                  label: Text(tr(label), style: const TextStyle(fontSize: 12)),
                  onPressed: ready ? () => _send(cmd) : null,
                ),
              ),
          ],
        ),
      ),
      Container(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.cardBd)),
        ),
        child: Row(children: [
          IconButton(
            tooltip: tr('Остановить команду (Ctrl+C)'),
            icon: const Icon(Icons.stop_circle_outlined, color: AppColors.warn),
            onPressed: ready ? () => _session?.interrupt() : null,
          ),
          Expanded(
            child: TextField(
              controller: _input,
              focusNode: _focus,
              enabled: ready,
              style: _mono.copyWith(fontSize: 14),
              autocorrect: false,
              enableSuggestions: false,
              smartQuotesType: SmartQuotesType.disabled,
              smartDashesType: SmartDashesType.disabled,
              textCapitalization: TextCapitalization.none,
              // several lines may be pasted at once: each one goes as its own command
              // (a one-line field glued them into one, and grep got "--brief" as its option)
              minLines: 1,
              maxLines: 4,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              onChanged: _onInput,
              decoration: InputDecoration(
                isDense: true,
                hintText: tr('команда, например: pm list packages'),
                hintStyle: const TextStyle(fontSize: 13, color: AppColors.fgMuted),
                prefixText: '\$ ',
                prefixStyle: _mono.copyWith(color: AppColors.accent, fontSize: 14),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
          IconButton(
            tooltip: tr('Предыдущая команда'),
            icon: const Icon(Icons.history_rounded),
            onPressed: ready && _history.isNotEmpty ? _histBack : null,
          ),
          IconButton(
            tooltip: tr('Выполнить'),
            icon: const Icon(Icons.send_rounded, color: AppColors.accent),
            onPressed: ready ? () => _send() : null,
          ),
        ]),
      ),
    ]);
  }
}
