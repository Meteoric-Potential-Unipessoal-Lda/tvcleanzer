// 1.3.158: the remote without ADB. When the TV can't be reached over ADB (debugging switched off
// again, a box that forgets the phone), the remote goes through
//  · Google's «Android TV Remote» protocol (Google TV and certified Android TV), or
//  · our launcher's Wi-Fi remote (launcher 1.40+), for boxes without Google's service.
// Each is paired once with a code shown on the TV; what pairing gives is kept in [NoAdbStore].
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'atv_remote.dart';
import 'lan_remote.dart';

export 'atv_remote.dart' show AtvError;
export 'lan_remote.dart' show LanError;

enum AltKind { atv, lan }

/// Where pairings are kept (SharedPreferences in the app, a map in tests).
abstract class NoAdbStore {
  String? get(String key);
  Future<void> set(String key, String? value);
}

/// One open remote link without ADB.
class AltLink {
  final AltKind kind;
  final AtvRemote? atv;
  final LanRemote? lan;

  /// The link ended (TV asleep, Wi-Fi changed).
  void Function()? onClosed;

  /// A key or text the TV could not do this way (LAN without the Home-key service): what.
  void Function(String what)? onRefused;

  /// What the TV can do (LAN: its «st» line changed).
  void Function()? onChange;

  AltLink.atv(AtvRemote r)
      : kind = AltKind.atv,
        atv = r,
        lan = null {
    r.onClosed = (_) => onClosed?.call();
    r.onChange = () => onChange?.call();
  }

  AltLink.lan(LanRemote r)
      : kind = AltKind.lan,
        atv = null,
        lan = r {
    r.onClosed = (_) => onClosed?.call();
    r.onRefused = (w) => onRefused?.call(w);
    r.onChange = () => onChange?.call();
  }

  bool get isOpen => atv?.isOpen ?? lan!.isOpen;

  /// Arrows, OK, Back and text work this way (LAN: only with the Home-key service on the TV).
  bool get canNavigate => kind == AltKind.atv || lan!.state.dpad;

  /// The mouse goes through the launcher's Wi-Fi remote (with the Home-key service).
  bool get canMouse => kind == AltKind.lan && lan!.state.mouse;

  /// Android key codes (the remote's Keys).
  void key(int code) {
    if (atv != null) {
      atv!.key(code);
      return;
    }
    final n = lanKeyNames[code];
    if (n == null) {
      onRefused?.call('k $code');
      return;
    }
    lan!.key(n);
  }

  void longKey(int code) {
    if (atv != null) {
      atv!.key(code, direction: 1);
      Timer(const Duration(milliseconds: 700), () {
        if (atv!.isOpen) atv!.key(code, direction: 2);
      });
      return;
    }
    key(code); // the launcher has no long press: a plain one
  }

  void text(String t) {
    if (atv != null) {
      atv!.text(t);
    } else {
      lan!.text(t);
    }
  }

  /// Opens an app on the TV.
  void launch(String package) {
    if (atv != null) {
      atv!.openLink('market://launch?id=$package');
    } else {
      lan!.launch(package);
    }
  }

  void mouse(String line) => lan?.mouse(line);

  void close() {
    atv?.close();
    lan?.close();
  }
}

/// The remote's Android key codes as the launcher's Wi-Fi remote names them.
const lanKeyNames = <int, String>{
  3: 'home', 4: 'back', 19: 'up', 20: 'down', 21: 'left', 22: 'right', 23: 'ok', 66: 'ok',
  24: 'volup', 25: 'voldown', 164: 'mute', 85: 'playpause', 126: 'play', 127: 'pause', 86: 'stop',
  87: 'next', 88: 'prev', 89: 'rew', 90: 'ff', 26: 'power', 223: 'power', 176: 'settings',
  187: 'recents', 83: 'notifications',
};

class NoAdb {
  NoAdb(this.store, {this.atvPort = atvRemotePort, this.atvPairPort0 = atvPairPort, this.lanPort = lanRemotePort});
  final NoAdbStore store;
  final int atvPort, atvPairPort0, lanPort;

  static const _idKey = 'noadb_atv_id', _lanIdKey = 'noadb_lan_id';

  /// The phone's certificate for Google's protocol: made once (a second or two, off the UI
  /// thread), then kept.
  Future<AtvIdentity> identity() async {
    final have = _decode(store.get(_idKey));
    final id = AtvIdentity.fromJson(have);
    if (id != null) return id;
    final made = await Isolate.run(() => AtvIdentity.generate('TVCleanzer'));
    await store.set(_idKey, jsonEncode(made.toJson()));
    return made;
  }

  String lanId() {
    var id = store.get(_lanIdKey);
    if (id == null || !RegExp(r'^[A-Za-z0-9_-]{8,64}$').hasMatch(id)) {
      id = LanRemote.newId();
      store.set(_lanIdKey, id);
    }
    return id;
  }

  bool atvPaired(String host) => store.get('noadb_atv_$host') == '1';
  List<int>? lanKey(String host) {
    final k = store.get('noadb_lan_$host');
    if (k == null) return null;
    try {
      final b = base64.decode(k);
      return b.length == 32 ? b : null;
    } catch (_) {
      return null;
    }
  }

  /// Connects with what was paired before; null when nothing paired answers.
  Future<AltLink?> connect(String host, {Duration timeout = const Duration(seconds: 4)}) async {
    if (atvPaired(host)) {
      final r = AtvRemote(host, await identity(), port: atvPort);
      try {
        await r.connect(timeout: timeout);
        return AltLink.atv(r);
      } on AtvError catch (e) {
        if (e.kind == 'auth') await store.set('noadb_atv_$host', null); // the TV forgot the phone
      } catch (_) {}
    }
    final k = lanKey(host);
    if (k != null) {
      final r = LanRemote(host, lanId(), port: lanPort);
      try {
        await r.connect(k, timeout: timeout);
        return AltLink.lan(r);
      } on LanError catch (e) {
        if (e.kind == 'unknown') await store.set('noadb_lan_$host', null);
      } catch (_) {}
    }
    return null;
  }

  /// What can be paired at [host]: Google's service first (every key, any Android version),
  /// else our launcher's Wi-Fi remote; null when neither answers.
  Future<AltKind?> probe(String host, {Duration timeout = const Duration(milliseconds: 1500)}) async {
    final r = await Future.wait([_open(host, atvPairPort0, timeout), _open(host, lanPort, timeout)]);
    if (r[0]) return AltKind.atv;
    if (r[1]) return AltKind.lan;
    return null;
  }

  static Future<bool> _open(String host, int port, Duration timeout) async {
    try {
      final s = await Socket.connect(host, port, timeout: timeout);
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Google's pairing: [askCode] is called once the TV shows its code (6 characters, 0-9 A-F);
  /// null cancels. Throws [AtvError] ('code' for a wrong one).
  Future<AltLink> pairAtv(String host, Future<String?> Function() askCode) async {
    final id = await identity();
    final p = AtvPairing(host, id, port: atvPairPort0);
    try {
      await p.start();
      final code = await askCode();
      if (code == null) throw AtvError('closed', 'cancelled');
      await p.finish(code);
    } finally {
      p.close();
    }
    await store.set('noadb_atv_$host', '1');
    final r = AtvRemote(host, id, port: atvPort);
    await r.connect();
    return AltLink.atv(r);
  }

  /// The launcher's pairing: [askCode] gets the 6 digits shown on the TV (called again after a
  /// wrong one with the tries left). Throws [LanError].
  Future<AltLink> pairLan(String host, String phoneName, Future<String?> Function(int triesLeft) askCode) async {
    final r = LanRemote(host, lanId(), port: lanPort);
    final key = await r.pair(phoneName, askCode);
    await store.set('noadb_lan_$host', base64.encode(key));
    return AltLink.lan(r);
  }

  static Object? _decode(String? s) {
    if (s == null) return null;
    try {
      return jsonDecode(s);
    } catch (_) {
      return null;
    }
  }
}
