import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/tv_device.dart';
import '../services/adb_client.dart';
import '../services/wake_on_lan.dart';
import 'current_tv.dart';

import '../l10n/l10n.dart';
enum RemoteStatus { idle, connecting, ready, error }

/// Non-Latin text needs TVCleanzer Launcher 0.42+ on the TV.
class NeedsLauncher implements Exception {
  const NeedsLauncher();
}

/// What the Power button did.
enum PowerResult { sent, wol, unreachable }

class RemoteState {
  final RemoteStatus status;
  final String? message;
  const RemoteState(this.status, [this.message]);
}

/// Android key codes used by the remote.
class Keys {
  static const up = 19, down = 20, left = 21, right = 22, ok = 23;
  static const back = 4, home = 3, menu = 82;
  static const volUp = 24, volDown = 25, mute = 164, playPause = 85;
  static const power = 26, input = 178, recents = 187, settings = 176;
  static const rewind = 89, forward = 90, prev = 88, next = 87;
  static const paste = 279;
}

/// Keeps one ADB connection open to the current TV and sends key presses
/// over it one after another (ADB shell commands must not overlap).
final remoteProvider =
    StateNotifierProvider<RemoteController, RemoteState>((ref) {
  final c = RemoteController();
  ref.listen<TvDevice?>(currentTvProvider, (prev, next) {
    if (prev?.id != next?.id) c.reset();
  });
  ref.onDispose(c.close);
  return c;
});

class RemoteController extends StateNotifier<RemoteState> {
  RemoteController() : super(const RemoteState(RemoteStatus.idle));

  AdbClient? _client;
  String? _ip;
  Future<void> _chain = Future.value();

  /// Presses waiting for the TV. They all go, none is dropped: while the TV is
  /// still busy with the previous command they pile up here and then leave
  /// together as one `input keyevent 22 22 22` (one start of the TV's key tool
  /// instead of three — on older TVs each start takes about a second).
  final List<int> _keys = [];
  bool _keysQueued = false;

  /// `cmd input` (Android 12+, no app start on the TV: fast) or the old `input`.
  bool? _cmdInput;

  /// Fire-and-forget key press.
  void key(String ip, int code) {
    if (_keys.length >= 20) return; // a stuck TV: don't build an endless queue
    _keys.add(code);
    if (_keysQueued) return;
    _keysQueued = true;
    _enqueue(ip, () {
      _keysQueued = false;
      final batch = List<int>.of(_keys);
      _keys.clear();
      return batch.isEmpty ? null : 'keyevent ${batch.join(' ')}';
    }, input: true).catchError((_) {}); // shown via state
  }

  /// Power: the key over ADB; when the TV no longer answers (deep standby), a Wake-on-LAN
  /// packet to the network card we learned while it was on.
  /// Power. An awake TV is put to sleep with SLEEP (223), not POWER: on some TVs an injected
  /// POWER restarts the TV instead of standby (Kivi, bug #12). If SLEEP did nothing, POWER as
  /// before. A sleeping TV that still answers gets WAKEUP (224), then POWER if it stayed asleep.
  /// Runs in its own session and returns at once: a TV going to sleep may drop the connection.
  static String get powerCmd {
    const p = Keys.power;
    const job = 'w=\$(dumpsys power 2>/dev/null | grep -m1 -o "mWakefulness=[A-Za-z]*"); '
        'case "\$w" in *Awake*|*Dreaming*) input keyevent 223; sleep 2; '
        'dumpsys power 2>/dev/null | grep -q "mWakefulness=Awake" && input keyevent $p;; '
        '*) input keyevent 224; sleep 1; '
        'dumpsys power 2>/dev/null | grep -q "mWakefulness=Awake" || input keyevent $p;; esac';
    return "if command -v setsid >/dev/null 2>&1; then setsid sh -c '$job' >/dev/null 2>&1 < /dev/null & "
        "else nohup sh -c '$job' >/dev/null 2>&1 < /dev/null & fi";
  }

  Future<PowerResult> power(String ip) async {
    try {
      await _enqueue(ip, () => powerCmd);
      return PowerResult.sent;
    } catch (_) {
      return await WakeOnLan.wake(ip) ? PowerResult.wol : PowerResult.unreachable;
    }
  }

  /// The TV's screen brightness 0–255 (`settings system screen_brightness`); null when the
  /// firmware does not keep one.
  Future<int?> brightness(String ip) async {
    int? v;
    await _enqueue(ip, () => 'settings get system screen_brightness',
        onOut: (out) => v = int.tryParse(out.trim()));
    return v;
  }

  /// Sets it (manual mode first: automatic brightness would undo it). Many TVs take their
  /// backlight from the picture settings instead and ignore this.
  Future<void> setBrightness(String ip, int value) => _enqueue(ip,
      () => 'settings put system screen_brightness_mode 0; settings put system screen_brightness ${value.clamp(1, 255)}');

  /// «Запущенные»: many TVs do nothing on the Recents key, so our launcher (0.47+) shows its
  /// own row of recent apps; the Recents key only where the launcher is older or missing.
  Future<void> recents(String ip) async {
    var opened = false;
    await _enqueue(ip, () => 'appops set com.tvcleanzer.launcher GET_USAGE_STATS allow >/dev/null 2>&1; '
        'am start -n com.tvcleanzer.launcher/.RecentsActivity 2>&1',
        onOut: (out) => opened = !out.contains('Error') && !out.contains('does not exist'));
    if (!opened) key(ip, Keys.recents);
  }

  /// A long press (the TV's «options» on a tile).
  void longKey(String ip, int code) =>
      _enqueue(ip, () => 'keyevent --longpress $code', input: true).catchError((_) {});

  /// Types text into the focused field on the TV. Latin goes through `input text`; any
  /// other letters (Russian…) through the TV's clipboard — our launcher (0.42+) puts them
  /// there — and the Paste key.
  Future<void> text(String ip, String value) async {
    if (RegExp(r'^[\x20-\x7E]*$').hasMatch(value)) {
      final escaped = value
          .replaceAll("'", "'\\''")
          .replaceAll(' ', '%s');
      return _enqueue(ip, () => "text '$escaped'", input: true);
    }
    var pasted = false;
    await _enqueue(ip, () => "am broadcast -n com.tvcleanzer.launcher/.ConfigReceiver "
        "-a com.tvcleanzer.launcher.PASTE --es text '${value.replaceAll("'", "'\\''")}'",
        onOut: (out) => pasted = out.contains('result=1'));
    if (!pasted) throw const NeedsLauncher();
    await _enqueue(ip, () => 'keyevent ${Keys.paste}', input: true);
  }

  /// Runs commands one after another (ADB shell commands must not overlap).
  /// [cmd] is built when its turn comes, so key presses that arrive meanwhile join it.
  Future<void> _enqueue(String ip, String? Function() cmd,
      {bool input = false, void Function(String out)? onOut}) {
    final f = _chain.then((_) async {
      final c = cmd();
      if (c != null) {
        final out = await _run(ip, c, input: input);
        onOut?.call(out);
      }
    });
    _chain = f.catchError((_) {});
    return f;
  }

  Future<String> _run(String ip, String cmd, {bool input = false}) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        if (_client == null || _ip != ip) {
          _drop();
          _set(const RemoteState(RemoteStatus.connecting));
          // [ip] is a TvDevice.id: "host" or "host:port" (wireless debugging).
          final i = ip.lastIndexOf(':');
          final c = i < 0
              ? AdbClient.open(host: ip)
              : AdbClient.open(host: ip.substring(0, i), port: int.parse(ip.substring(i + 1)));
          await c.connect();
          _client = c;
          _ip = ip;
          // the TV's network cards, for switching it on later (Wake-on-LAN)
          try {
            final macs = await c.shell(
                'cat /sys/class/net/eth0/address /sys/class/net/wlan0/address 2>/dev/null',
                timeout: const Duration(seconds: 4));
            await WakeOnLan.remember(ip, macs);
          } catch (_) {}
          _set(const RemoteState(RemoteStatus.ready));
        }
        if (!input) {
          return await _client!.shell(cmd, timeout: const Duration(seconds: 8));
        }
        if (_cmdInput != false) {
          // Android 12+ runs `cmd input` inside the system: no tool to start, no delay.
          // Older TVs answer with an error (and do nothing): use `input` from then on.
          final out = await _client!.shell('cmd input $cmd 2>&1', timeout: const Duration(seconds: 8));
          final ok = !RegExp(r'unknown|error|exception|not found|can.t find|usage|no shell command', caseSensitive: false)
              .hasMatch(out);
          _cmdInput = ok;
          if (ok) return out;
        }
        return await _client!.shell('input $cmd', timeout: const Duration(seconds: 10));
      } catch (e) {
        _drop(); // stale connection (TV slept, Wi-Fi changed) — retry once
        if (attempt == 1) {
          _set(RemoteState(RemoteStatus.error,
              tr('Нет связи с телевизором. Проверьте, что он включён и в той же Wi-Fi сети.')));
          rethrow;
        }
      }
    }
    throw StateError('unreachable');
  }

  /// Forget the connection (e.g. another TV was selected).
  void reset() {
    _drop();
    _set(const RemoteState(RemoteStatus.idle));
  }

  void close() => _drop();

  void _drop() {
    _client?.close();
    _client = null;
    _ip = null;
    _cmdInput = null; // another TV (or the same after an update) may differ
  }

  void _set(RemoteState s) {
    if (mounted) state = s;
  }
}
