import 'dart:async';
import 'dart:convert';

import '../l10n/l10n.dart';
import '../models/tv_device.dart';
import 'adb_client.dart';
import 'demo_tv.dart';
import 'protection.dart';

/// "For developers": a shell on the TV, like `adb shell` on a computer.
/// One session = its own ADB connection with a terminal on the TV, so `cd`,
/// variables and long-running commands (logcat, top) behave as usual.
abstract class TerminalSession {
  /// Cleaned-up text from the TV (colours and cursor codes removed).
  Stream<String> get output;

  /// Sends one command line (Enter included).
  Future<void> run(String line);

  /// Ctrl+C: stops the running command.
  Future<void> interrupt();

  Future<void> close();

  static Future<TerminalSession> open(TvDevice tv) async {
    if (tv.isDemo || tv.ipAddress == DemoTv.host) return _DemoSession();
    final c = AdbClient.open(host: tv.ipAddress, port: tv.port);
    try {
      await c.connect();
      final st = await c.openStream('shell:');
      return _PtySession(st);
    } catch (_) {
      c.close();
      rethrow;
    }
  }
}

/// Removes terminal control codes from the TV's output: colours, cursor moves,
/// window titles; CR before LF and lone CRs.
String cleanTerminal(String s) => s
    .replaceAll(RegExp(r'\x1B\][^\x07\x1B]*(\x07|\x1B\\)'), '')
    .replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '')
    .replaceAll(RegExp(r'\x1B[()][0-9A-Za-z]'), '')
    .replaceAll(RegExp(r'\x1B[=>78]'), '')
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '')
    .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1A\x1C-\x1F]'), '');

class _PtySession implements TerminalSession {
  _PtySession(this._st) {
    // a UTF-8 character can be split between two packets: decode as one stream
    _st.data.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen(
      (t) => _out.add(cleanTerminal(t)),
      onError: (Object e) => _out.addError(e),
      onDone: () {
        _out.add('\n[${tr('сессия закрыта')}]\n');
        _out.close();
      },
    );
  }

  final AdbStream _st;
  final _out = StreamController<String>.broadcast();

  @override
  Stream<String> get output => _out.stream;

  @override
  Future<void> run(String line) => _st.write(utf8.encode('$line\n'));

  @override
  Future<void> interrupt() => _st.write(const [3]);

  @override
  Future<void> close() async => _st.close();
}

/// The built-in demo TV: answers each command like the real one would.
class _DemoSession implements TerminalSession {
  _DemoSession() {
    scheduleMicrotask(() => _out.add('demo:/ \$ '));
  }

  final _out = StreamController<String>.broadcast();
  final _c = DemoAdbClient();

  @override
  Stream<String> get output => _out.stream;

  @override
  Future<void> run(String line) async {
    _out.add('$line\n');
    final t = line.trim();
    if (t.isNotEmpty) {
      final r = t == 'id' ? 'uid=2000(shell) gid=2000(shell)\n' : await _c.shell(t);
      if (r.isNotEmpty) _out.add(r.endsWith('\n') ? r : '$r\n');
    }
    _out.add('demo:/ \$ ');
  }

  @override
  Future<void> interrupt() async => _out.add('^C\ndemo:/ \$ ');

  @override
  Future<void> close() async => _out.close();
}

/// Why a command deserves a second look before it runs (null = nothing special).
/// Not a ban: the owner can still run it, just not by accident.
String? terminalDanger(String cmd) {
  final c = cmd.trim();
  bool has(String re) => RegExp(re, caseSensitive: false).hasMatch(c);
  if (has(r'(^|[;&|]\s*)(su|reboot)\s+(recovery|bootloader|fastboot)|\bwipe\b|MASTER_CLEAR|FACTORY_RESET|\brecovery\s+--wipe')) {
    return tr('сброс или перезагрузка в служебный режим');
  }
  if (has(r'\b(dd|mkfs\S*|format)\b')) return tr('запись прямо на диск телевизора');
  if (has(r'\brm\s+(-\S*[rRf]\S*\s+)+')) return tr('удаление файлов без возможности вернуть');
  if (has(r'\bsettings\s+(delete|reset)\b')) return tr('сброс системных настроек');
  if (has(r'\bsetprop\s+persist\.')) return tr('постоянное изменение свойств прошивки');
  // apps: a system one the TV needs, or removal that can't be undone
  final m = RegExp(r'\bpm\s+(uninstall|disable(?:-user)?|clear|hide|suspend)\b(.*)').firstMatch(c);
  if (m != null) {
    final verb = m.group(1)!;
    final pkgs = RegExp(r'\b[a-zA-Z][\w]*(?:\.[\w]+)+\b').allMatches(m.group(2)!).map((x) => x.group(0)!);
    final sys = pkgs.where(Protection.isProtected).toList();
    if (sys.isNotEmpty) {
      return tr('системное приложение {0}: без него телевизор может не работать', [sys.first]);
    }
    if (verb == 'uninstall' && !m.group(2)!.contains('--user')) {
      return tr('полное удаление приложения: вернуть его можно будет только установкой заново');
    }
    if (verb == 'clear') return tr('данные приложения будут стёрты');
  }
  return null;
}

/// Ready-made commands for the chips above the input line.
const terminalSnippets = <(String, String)>[
  ('Модель', 'getprop ro.product.model; getprop ro.build.version.release'),
  ('Свои приложения', 'pm list packages -3'),
  ('Отключённые', 'pm list packages -d'),
  ('Главный экран', 'cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME'),
  ('Память', 'cat /proc/meminfo | head -3'),
  ('Место', 'df -h /data'),
  ('Кто ест память', 'dumpsys meminfo | head -40'),
  ('Температура', 'cat /sys/class/thermal/thermal_zone*/temp'),
  ('Ошибки (logcat)', 'logcat -d -b crash -t 50'),
  ('Анимации', 'settings get global animator_duration_scale'),
];
