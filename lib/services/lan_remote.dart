// The phone's side of the launcher's Wi-Fi remote (launcher 1.40+, LanRemote / LanProto in the
// launcher): pairing with a 6-digit code shown on the TV, then signed command lines. For a TV the
// phone can't reach over ADB and that has no Google «Android TV Remote» service.
// Pure Dart (dart:io + pointycastle) so it is tested against the launcher's own Java code.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

const lanRemotePort = 47292;

class LanError implements Exception {
  /// 'connect' (no launcher listening: an old launcher, the setting off, another network),
  /// 'unknown' (the TV forgot this phone: pair again), 'code' (wrong code), 'tries' (3 wrong
  /// codes), 'busy' (another phone is pairing), 'later' (too many failed pairings, wait),
  /// 'closed'.
  final String kind;
  final String message;
  LanError(this.kind, this.message);
  @override
  String toString() => 'LanError($kind): $message';
}

/// What the TV says it can do right now (its «st» line).
class LanState {
  bool service = false, dpad = false, text = false, mouse = false, muted = false;
  int volume = 0, volumeMax = 0;
  String app = '';
  int api = 0;
  String name = '';

  /// The TV's first «st» line has come (what it can do is known).
  bool known = false;
}

class LanRemote {
  final String host;
  final int port;

  /// This phone's id on the TV (made once and kept with the key).
  final String id;
  final state = LanState();
  void Function()? onChange;
  void Function(Object? why)? onClosed;

  /// «no …» answers (a key the TV can't do without its Home-key service, no text field…).
  void Function(String what)? onRefused;

  Socket? _s;
  final _lines = StreamController<String>();
  StreamIterator<String>? _it;
  String _tvNonce = '';
  Uint8List? _sess;
  int _seq = 0;
  bool _closed = false;
  Timer? _ping;

  LanRemote(this.host, this.id, {this.port = lanRemotePort});

  bool get isOpen => _sess != null && !_closed;

  /// A new random phone id.
  static String newId() {
    final r = Random.secure();
    return base64Url.encode(List.generate(18, (_) => r.nextInt(256))).replaceAll('=', '');
  }

  Future<void> _open(Duration timeout) async {
    try {
      _s = await Socket.connect(host, port, timeout: timeout);
    } on SocketException catch (e) {
      throw LanError('connect', e.message);
    }
    _s!.setOption(SocketOption.tcpNoDelay, true);
    _s!.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen(
        _lines.add,
        onError: (Object e) => _lines.addError(e),
        onDone: () => _lines.close());
    _it = StreamIterator(_lines.stream);
    final hello = await _read(timeout);
    final w = hello.split(' ');
    if (w.length < 4 || w[0] != 'TVC1' || !RegExp(r'^[0-9a-f]{32}$').hasMatch(w[1])) {
      close();
      throw LanError('connect', 'not a TVCleanzer launcher');
    }
    _tvNonce = w[1];
    state.api = int.tryParse(w[2]) ?? 0;
    state.name = Uri.decodeComponent(w[3]);
  }

  Future<String> _read(Duration timeout) async {
    final it = _it!;
    bool has;
    try {
      has = await it.moveNext().timeout(timeout);
    } on TimeoutException {
      close();
      throw LanError('closed', 'no answer from the TV');
    } catch (e) {
      close();
      throw LanError('closed', '$e');
    }
    if (!has) {
      close();
      throw LanError('closed', 'the TV closed the connection');
    }
    return it.current;
  }

  void _raw(String l) {
    final s = _s;
    if (s == null || _closed) throw LanError('closed', 'not connected');
    s.add(utf8.encode('$l\n'));
  }

  /// Connects with the key from an earlier pairing. [LanError] 'unknown': pair again.
  Future<void> connect(List<int> key, {Duration timeout = const Duration(seconds: 6)}) async {
    await _open(timeout);
    final nonce = _hex(_random(16));
    _raw('auth $id $nonce ${_hex(_hmac(key, 'a|$_tvNonce|$nonce|$id'))}');
    final a = await _read(timeout);
    if (a == 'who') {
      close();
      throw LanError('unknown', 'the TV does not know this phone');
    }
    if (!a.startsWith('ok ') || !_same(_unhex(a.substring(3)), _hmac(key, 'o|$_tvNonce|$nonce'))) {
      close();
      throw LanError('closed', 'the TV did not prove its key');
    }
    _start(key, nonce);
  }

  /// Pairs: the TV shows a code, [askCode] gets it from the person (null: cancelled; called again
  /// after a wrong code with the tries left). Returns the key to keep for [connect].
  Future<Uint8List> pair(String phoneName, Future<String?> Function(int triesLeft) askCode,
      {Duration timeout = const Duration(seconds: 6)}) async {
    await _open(timeout);
    final nonce = _hex(_random(16));
    final kp = _ecPair();
    final pubRaw = (kp.publicKey as ECPublicKey).Q!.getEncoded(false);
    final phoneKey = base64.encode(pubRaw);
    _raw('pair $id $nonce $phoneKey ${Uri.encodeComponent(phoneName)}');
    final c = await _read(timeout);
    if (c == 'busy' || c == 'later') {
      close();
      throw LanError(c, c);
    }
    if (!c.startsWith('code ')) {
      close();
      throw LanError('closed', 'unexpected answer: $c');
    }
    final tvKey = c.substring(5);
    final z = _ecdh(kp.privateKey as ECPrivateKey, base64.decode(tvKey));
    final t = '$_tvNonce|$nonce|$id|$phoneKey|$tvKey';
    var left = 3;
    while (true) {
      final code = (await askCode(left))?.replaceAll(RegExp(r'\D'), '');
      if (code == null || code.isEmpty) {
        close();
        throw LanError('closed', 'cancelled');
      }
      final p = _sha256([...z, ...ascii.encode(code)]);
      _raw('code ${_hex(_hmac(p, 'c|$t'))}');
      final a = await _read(const Duration(seconds: 125));
      if (a.startsWith('paired ')) {
        if (!_same(_unhex(a.substring(7)), _hmac(p, 's|$t'))) {
          close();
          throw LanError('closed', 'the TV did not prove the code');
        }
        final key = _hmac(p, 'k|$t');
        _start(key, nonce);
        return key;
      }
      if (a.startsWith('bad ')) {
        left = int.tryParse(a.substring(4)) ?? 0;
        continue;
      }
      close();
      throw LanError(a == 'fail' ? 'tries' : 'closed', a);
    }
  }

  void _start(List<int> key, String nonce) {
    _sess = _hmac(key, 'sess|$_tvNonce|$nonce');
    _seq = 0;
    unawaited(_loop());
    _ping = Timer.periodic(const Duration(seconds: 15), (_) {
      if (isOpen) send('p');
    });
  }

  Future<void> _loop() async {
    Object? why;
    try {
      while (!_closed && await _it!.moveNext()) {
        _handle(_it!.current);
      }
    } catch (e) {
      why = e;
    }
    final was = !_closed;
    close();
    if (was) onClosed?.call(why);
  }

  void _handle(String l) {
    if (l.startsWith('st ')) {
      state.known = true;
      for (final kv in l.substring(3).split(' ')) {
        final i = kv.indexOf('=');
        if (i < 0) continue;
        final k = kv.substring(0, i), v = kv.substring(i + 1);
        switch (k) {
          case 'svc':
            state.service = v == '1';
          case 'dpad':
            state.dpad = v == '1';
          case 'text':
            state.text = v == '1';
          case 'mouse':
            state.mouse = v == '1';
          case 'muted':
            state.muted = v == '1';
          case 'vol':
            final p = v.split('/');
            state.volume = int.tryParse(p[0]) ?? 0;
            state.volumeMax = p.length > 1 ? int.tryParse(p[1]) ?? 0 : 0;
          case 'app':
            state.app = v == '-' ? '' : v;
        }
      }
      onChange?.call();
    } else if (l.startsWith('no ')) {
      onRefused?.call(l.substring(3));
    } else if (l == 'err mac') {
      close();
    }
  }

  /// One command line, signed (see the launcher's LanRemote for the list).
  void send(String cmd) {
    final s = _sess;
    if (s == null || _closed) throw LanError('closed', 'not connected');
    if (cmd.contains('\n')) throw ArgumentError('one line');
    _seq++;
    final tag = _hex(_hmac(s, '$_seq|$cmd').sublist(0, 8));
    _raw('$cmd #$tag');
  }

  /// Keys: home back up down left right ok recents notifications power settings playpause play
  /// pause stop next prev ff rew volup voldown mute.
  void key(String name) => send('k $name');

  /// Replaces the text of the field in focus; [enter] sends it (Android 11+).
  void text(String t, {bool enter = false}) => send('${enter ? 'tx' : 't'} ${Uri.encodeComponent(t)}');
  void launch(String package) => send('a $package');
  void openLink(String url) => send('u ${Uri.encodeComponent(url)}');
  void setVolume(int v) => send('v $v');
  void refresh() => send('?');

  /// The mouse: the same lines as over ADB (m dx dy, c, l, s dx dy, e).
  void mouse(String line) => send(line);

  void close() {
    _closed = true;
    _ping?.cancel();
    try {
      _s?.destroy();
    } catch (_) {}
    _s = null;
  }
}

// ── crypto ────────────────────────────────────────────────────────────────────────────────

final _domain = ECDomainParameters('secp256r1');

FortunaRandom _fortuna() {
  final r = Random.secure();
  return FortunaRandom()..seed(KeyParameter(Uint8List.fromList(List.generate(32, (_) => r.nextInt(256)))));
}

Uint8List _random(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

AsymmetricKeyPair<PublicKey, PrivateKey> _ecPair() {
  final g = ECKeyGenerator()..init(ParametersWithRandom(ECKeyGeneratorParameters(_domain), _fortuna()));
  return g.generateKeyPair();
}

Uint8List _ecdh(ECPrivateKey mine, List<int> theirRaw) {
  if (theirRaw.length != 65 || theirRaw[0] != 4) throw LanError('closed', 'bad TV key');
  final q = _domain.curve.decodePoint(theirRaw);
  if (q == null || q.isInfinity) throw LanError('closed', 'bad TV key');
  final a = ECDHBasicAgreement()..init(mine);
  final x = a.calculateAgreement(ECPublicKey(q, _domain));
  final out = Uint8List(32);
  var v = x;
  for (var i = 31; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v >>= 8;
  }
  return out;
}

Uint8List _hmac(List<int> key, String msg) {
  final m = HMac(SHA256Digest(), 64)..init(KeyParameter(Uint8List.fromList(key)));
  final b = Uint8List.fromList(utf8.encode(msg));
  m.update(b, 0, b.length);
  final out = Uint8List(32);
  m.doFinal(out, 0);
  return out;
}

Uint8List _sha256(List<int> b) => SHA256Digest().process(Uint8List.fromList(b));

String _hex(List<int> b) => [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

List<int> _unhex(String s) {
  if (!RegExp(r'^([0-9a-f]{2})*$').hasMatch(s)) return const [];
  return [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}
