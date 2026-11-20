import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'mirror_relay.dart';

/// «Повтор экрана»: the phone's screen and sound on the TV, received by the launcher's
/// MirrorActivity.
///  - Android: MediaProjection → H.264 → TCP (MirrorService), three roads to the TV.
///  - iPhone: the ReplayKit broadcast upload extension (ios/Broadcast) sends the same stream;
///    we only hand it the TV's address through the app group and open the system sheet.
///    The app is asleep while another app is on screen, so there is no ADB road there.
class Mirror {
  static const _ch = MethodChannel('tvcleanzer/mirror');
  static const port = 7300;

  static bool get supported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);
  static bool get ios => !kIsWeb && Platform.isIOS;

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
        _relay?.close();
        _relay = null;
        _ended.add(c.arguments as String?);
      }
      return null;
    });
  }

  static String newToken() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  static MirrorRelay? _relay;
  static Timer? _poll;

  /// Asks the phone's permission and starts sending; null when the owner said no. On Android
  /// the result carries the phone's address and port for the TV to dial back; on iPhone the
  /// system sheet is open and the extension starts when the owner taps «Начать вещание».
  /// [texts]: messages the iPhone extension shows, in the owner's language.
  static Future<({String? phone, int phonePort})?> start({
    required String host,
    required int adbPort,
    required String token,
    required bool hd,
    required bool audio,
    required String title,
    required String stopLabel,
    Map<String, String> texts = const {},
  }) async {
    _wire();
    if (running.value) return (phone: null, phonePort: 0);
    if (ios) {
      final r = await _ch.invokeMethod<Object?>('start', {
        'host': host,
        'port': port,
        'token': token,
        'hd': hd,
        'audio': audio,
        ...texts,
      });
      if (r == null) return null;
      _watchIos();
      return (phone: null, phonePort: 0);
    }
    _relay?.close();
    _relay = null;
    try {
      _relay = await MirrorRelay.start(host: host, adbPort: adbPort, tvPort: port);
    } catch (_) {}
    final r = await _ch.invokeMethod<Object?>('start', {
      'host': host,
      'port': port,
      'relayPort': _relay?.port ?? 0,
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
    if (r == true) {
      // already running
      running.value = true;
      return (phone: null, phonePort: 0);
    }
    running.value = false;
    _relay?.close();
    _relay = null;
    return null;
  }

  /// iPhone: the extension's heartbeat in the app group says whether it is sending.
  static void _watchIos() {
    _poll?.cancel();
    var seen = false;
    final since = DateTime.now();
    _poll = Timer.periodic(const Duration(seconds: 2), (t) async {
      Map? s;
      try {
        s = await _ch.invokeMethod<Map>('state');
      } catch (_) {}
      final on = s?['running'] == true;
      if (on) {
        seen = true;
        running.value = true;
        return;
      }
      if (seen) {
        t.cancel();
        running.value = false;
        final reason = s?['reason'];
        _ended.add(reason is String ? reason : null);
      } else if (DateTime.now().difference(since) > const Duration(seconds: 90)) {
        t.cancel(); // the owner never started the broadcast
      }
    });
  }

  static Future<void> stop() async {
    _wire();
    await _ch.invokeMethod<void>('stop');
    if (!ios) running.value = false;
    _relay?.close();
    _relay = null;
  }

  /// After the app comes back: the service may have ended meanwhile.
  static Future<void> sync() async {
    if (!supported) return;
    _wire();
    try {
      running.value = await _ch.invokeMethod<bool>('running') ?? false;
      if (ios && running.value) _watchIos();
    } catch (_) {}
  }
}
