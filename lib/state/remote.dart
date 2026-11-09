import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/tv_device.dart';
import '../services/adb_client.dart';
import 'current_tv.dart';

enum RemoteStatus { idle, connecting, ready, error }

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
}

/// Keeps one ADB connection open to the current TV and sends key presses
/// over it one after another (ADB shell commands must not overlap).
final remoteProvider =
    StateNotifierProvider<RemoteController, RemoteState>((ref) {
  final c = RemoteController();
  ref.listen<TvDevice?>(currentTvProvider, (prev, next) {
    if (prev?.ipAddress != next?.ipAddress) c.reset();
  });
  ref.onDispose(c.close);
  return c;
});

class RemoteController extends StateNotifier<RemoteState> {
  RemoteController() : super(const RemoteState(RemoteStatus.idle));

  AdbClient? _client;
  String? _ip;
  Future<void> _chain = Future.value();
  int _pending = 0;

  /// Fire-and-forget key press. Extra presses are dropped while the TV is
  /// still busy with several earlier ones, so the remote never "runs away".
  void key(String ip, int code) {
    if (_pending >= 3) return;
    _enqueue(ip, 'input keyevent $code').catchError((_) {}); // shown via state
  }

  /// Types ASCII text into the focused field on the TV.
  Future<void> text(String ip, String value) {
    final escaped = value
        .replaceAll("'", "'\\''")
        .replaceAll(' ', '%s');
    return _enqueue(ip, "input text '$escaped'");
  }

  Future<void> _enqueue(String ip, String cmd) {
    _pending++;
    final f = _chain.then((_) => _run(ip, cmd)).whenComplete(() => _pending--);
    _chain = f.catchError((_) {});
    return f;
  }

  Future<void> _run(String ip, String cmd) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        if (_client == null || _ip != ip) {
          _drop();
          _set(const RemoteState(RemoteStatus.connecting));
          final c = AdbClient(host: ip);
          await c.connect();
          _client = c;
          _ip = ip;
          _set(const RemoteState(RemoteStatus.ready));
        }
        await _client!.shell(cmd, timeout: const Duration(seconds: 8));
        return;
      } catch (e) {
        _drop(); // stale connection (TV slept, Wi-Fi changed) — retry once
        if (attempt == 1) {
          _set(const RemoteState(RemoteStatus.error,
              'Нет связи с телевизором. Проверьте, что он включён и в той же Wi-Fi сети.'));
          rethrow;
        }
      }
    }
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
  }

  void _set(RemoteState s) {
    if (mounted) state = s;
  }
}
