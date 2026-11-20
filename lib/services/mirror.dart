import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// «Повтор экрана»: the phone's screen and sound on the TV (Android: MediaProjection →
/// H.264 → TCP → the launcher's MirrorActivity). iPhone needs a ReplayKit broadcast
/// extension: not yet.
class Mirror {
  static const _ch = MethodChannel('tvcleanzer/mirror');
  static const port = 7300;

  static bool get supported => !kIsWeb && Platform.isAndroid;

  /// On while the phone is sending its screen.
  static final running = ValueNotifier<bool>(false);

  static final _ended = StreamController<String?>.broadcast();

  /// Why mirroring ended: null = stopped on the phone; 'closed' (the TV closed it or the
  /// Wi-Fi dropped), 'connect|<system error>', 'token', 'encoder', 'denied'.
  static Stream<String?> get ended => _ended.stream;

  static bool _wired = false;
  static void _wire() {
    if (_wired) return;
    _wired = true;
    _ch.setMethodCallHandler((c) async {
      if (c.method == 'stopped') {
        running.value = false;
        _ended.add(c.arguments as String?);
      }
      return null;
    });
  }

  static String newToken() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  /// Asks the phone's permission and starts sending; null when the owner said no. The result
  /// carries the phone's address and port for the TV to dial back (some TVs let nothing in).
  static Future<({String? phone, int phonePort})?> start({
    required String host,
    required String token,
    required bool hd,
    required bool audio,
    required String title,
    required String stopLabel,
  }) async {
    _wire();
    final r = await _ch.invokeMethod<Object?>('start', {
      'host': host,
      'port': port,
      'token': token,
      'maxSize': hd ? 1920 : 1280,
      'bitrate': hd ? 10000000 : 5000000,
      'audio': audio,
      'title': title,
      'stopLabel': stopLabel,
    });
    if (r is Map) {
      running.value = true;
      return (phone: r['phone'] as String?, phonePort: (r['phonePort'] as num?)?.toInt() ?? 0);
    }
    if (r == true) { // already running
      running.value = true;
      return (phone: null, phonePort: 0);
    }
    running.value = false;
    return null;
  }

  static Future<void> stop() async {
    _wire();
    await _ch.invokeMethod<void>('stop');
    running.value = false;
  }

  /// After the app comes back: the service may have ended meanwhile.
  static Future<void> sync() async {
    if (!supported) return;
    _wire();
    try {
      running.value = await _ch.invokeMethod<bool>('running') ?? false;
    } catch (_) {}
  }
}
