// The Android TV Remote protocol v2 — the one Google's own phone remote speaks to Google TV and
// certified Android TV sets. It needs no developer mode and no USB debugging: the TV shows a
// 6-character code once, the phone keeps its own certificate, and from then on keys, text,
// power, volume and app links go over TLS on port 6466 (pairing on 6467).
//
// Written for TVCleanzer after the open description of the protocol (Aymkdn's wiki
// «Google TV (aka Android TV) Remote Control (v2)») and the MIT-licensed androidtvremote2 by
// tronikos; the messages and the pairing hash are the same, the code is ours. Pure Dart (dart:io +
// pointycastle), no Flutter, so it is tested on a computer against a fake TV
// (test/atv_fake_tv.py, test/atv_remote_test.dart).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// The phone's identity for the TV: a self-signed RSA certificate and its key, both PEM.
/// Made once and kept (the TV remembers it after pairing).
class AtvIdentity {
  final String certPem;
  final String keyPem;
  const AtvIdentity(this.certPem, this.keyPem);

  Map<String, String> toJson() => {'cert': certPem, 'key': keyPem};
  static AtvIdentity? fromJson(Object? j) {
    if (j is! Map) return null;
    final c = j['cert'], k = j['key'];
    return c is String && k is String && c.contains('CERTIFICATE') && k.contains('PRIVATE KEY')
        ? AtvIdentity(c, k)
        : null;
  }

  /// A new 2048-bit RSA key and a self-signed certificate for [name] (10 years). Takes about a
  /// second or two on a phone; run it once and store the result.
  static AtvIdentity generate(String name) {
    final rnd = FortunaRandom();
    final seed = Random.secure();
    rnd.seed(KeyParameter(Uint8List.fromList(List.generate(32, (_) => seed.nextInt(256)))));
    final gen = RSAKeyGenerator()
      ..init(ParametersWithRandom(RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64), rnd));
    final pair = gen.generateKeyPair();
    // ignore: unnecessary_cast (pointycastle 3.x returns the base types)
    final pub = pair.publicKey as RSAPublicKey;
    // ignore: unnecessary_cast
    final priv = pair.privateKey as RSAPrivateKey;

    final now = DateTime.now().toUtc().subtract(const Duration(days: 1));
    final name0 = _seq([
      _set([
        _seq([_oid([2, 5, 4, 3]), _tlv(0x0C, utf8.encode(name))])
      ])
    ]);
    final sigAlg = _seq([_oid([1, 2, 840, 113549, 1, 1, 11]), _tlv(0x05, const [])]);
    final spki = _seq([
      _seq([_oid([1, 2, 840, 113549, 1, 1, 1]), _tlv(0x05, const [])]),
      _bitString(_seq([_int(pub.modulus!), _int(pub.publicExponent!)])),
    ]);
    final serial = BigInt.from(1000 + seed.nextInt(1 << 30));
    final tbs = _seq([
      _tlv(0xA0, _int(BigInt.two)), // [0] EXPLICIT version v3
      _int(serial),
      sigAlg,
      name0,
      _seq([_utcTime(now), _utcTime(now.add(const Duration(days: 3650)))]),
      name0,
      spki,
      // [3] extensions, as Google's remote makes them: basicConstraints CA (path 0) and the name
      _tlv(0xA3, _seq([
        _seq([_oid([2, 5, 29, 19]), _tlv(0x04, _seq([_tlv(0x01, const [0xFF]), _int(BigInt.zero)]))]),
        _seq([_oid([2, 5, 29, 17]), _tlv(0x04, _seq([_tlv(0x82, ascii.encode(_dnsName(name)))]))]),
      ])),
    ]);
    final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
      ..init(true, PrivateKeyParameter<RSAPrivateKey>(priv));
    final sig = signer.generateSignature(Uint8List.fromList(tbs)).bytes;
    final cert = _seq([tbs, sigAlg, _bitString(sig)]);

    final p = priv.p!, q = priv.q!, d = priv.privateExponent!;
    final key = _seq([
      _int(BigInt.zero),
      _int(pub.modulus!),
      _int(pub.publicExponent!),
      _int(d),
      _int(p),
      _int(q),
      _int(d % (p - BigInt.one)),
      _int(d % (q - BigInt.one)),
      _int(q.modInverse(p)),
    ]);
    return AtvIdentity(_pem('CERTIFICATE', cert), _pem('RSA PRIVATE KEY', key));
  }

  SecurityContext context() => SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(certPem))
    ..usePrivateKeyBytes(utf8.encode(keyPem));

  /// The certificate's RSA modulus and exponent (for the pairing hash).
  (BigInt, BigInt) publicNumbers() => rsaOfCertificate(_unpem(certPem));
}

class AtvError implements Exception {
  /// 'connect' (nothing answers on the ports: no Android TV Remote service, or another network),
  /// 'auth' (the TV does not know this phone: pair first), 'code' (wrong code typed),
  /// 'closed' (the TV hung up).
  final String kind;
  final String message;
  AtvError(this.kind, this.message);
  @override
  String toString() => 'AtvError($kind): $message';
}

/// Ports of the protocol.
const atvRemotePort = 6466, atvPairPort = 6467;

/// Pairing: [start] makes the TV show its code, [finish] sends the code typed on the phone.
class AtvPairing {
  final String host;
  final AtvIdentity id;
  final String clientName;
  final int port;
  SecureSocket? _s;
  _Frames? _f;
  AtvPairing(this.host, this.id, {this.clientName = 'TVCleanzer', this.port = atvPairPort});

  Future<void> start({Duration timeout = const Duration(seconds: 10)}) async {
    try {
      _s = await SecureSocket.connect(host, port,
          context: id.context(), onBadCertificate: (_) => true, timeout: timeout);
    } on SocketException catch (e) {
      throw AtvError('connect', e.message);
    } on HandshakeException catch (e) {
      throw AtvError('connect', e.message);
    }
    _f = _Frames(_s!);
    _send(_outer(10, _msg([_fStr(1, 'atvremote'), _fStr(2, clientName)])));
    // pairing_request_ack → options; options → configuration; configuration_ack → the code is up
    while (true) {
      final m = _Pb(await _f!.next(timeout));
      _checkStatus(m);
      if (m.has(11)) {
        _send(_outer(20, _msg([
          _fMsg(1, _msg([_fVar(1, 3), _fVar(2, 6)])), // input encoding: hexadecimal, 6 symbols
          _fVar(3, 1), // preferred role: input
        ])));
      } else if (m.has(20)) {
        _send(_outer(30, _msg([_fMsg(1, _msg([_fVar(1, 3), _fVar(2, 6)])), _fVar(2, 1)])));
      } else if (m.has(31)) {
        return;
      } else {
        throw AtvError('closed', 'unexpected pairing message');
      }
    }
  }

  /// [code]: the 6 characters on the TV (hex; case and spaces do not matter).
  Future<void> finish(String code, {Duration timeout = const Duration(seconds: 10)}) async {
    final s = _s, f = _f;
    if (s == null || f == null) throw AtvError('closed', 'pairing not started');
    final c = code.replaceAll(RegExp(r'\s'), '').toUpperCase();
    if (!RegExp(r'^[0-9A-F]{6}$').hasMatch(c)) throw AtvError('code', 'the code is 6 characters 0-9 A-F');
    final server = s.peerCertificate;
    if (server == null) throw AtvError('closed', 'no TV certificate');
    final secret = pairingSecret(id.publicNumbers(), rsaOfCertificate(server.der), c);
    if (secret[0] != int.parse(c.substring(0, 2), radix: 16)) throw AtvError('code', 'wrong code');
    _send(_outer(40, _msg([_fBytes(1, secret)])));
    final m = _Pb(await f.next(timeout));
    _checkStatus(m);
    if (!m.has(41)) throw AtvError('code', 'the TV did not accept the code');
    close();
  }

  void close() {
    try {
      _s?.destroy();
    } catch (_) {}
    _s = null;
    _f = null;
  }

  void _send(List<int> body) => _s!.add(_frame(body));

  static void _checkStatus(_Pb m) {
    final st = m.int1(2) ?? 200;
    if (st == 200) return;
    throw AtvError(st == 402 ? 'code' : 'closed', 'pairing status $st');
  }

  static List<int> _outer(int field, List<int> payload) =>
      _msg([_fVar(1, 2), _fVar(2, 200), _fMsg(field, payload)]);
}

/// SHA-256 over the phone's and the TV's RSA numbers and the last 4 code characters; its first
/// byte must equal the first 2 code characters (that is how a mistyped code is caught).
Uint8List pairingSecret((BigInt, BigInt) client, (BigInt, BigInt) server, String code) {
  final d = SHA256Digest();
  void put(List<int> b) => d.update(Uint8List.fromList(b), 0, b.length);
  put(_hexBytes(client.$1.toRadixString(16)));
  put(_hexBytes('0${client.$2.toRadixString(16)}'));
  put(_hexBytes(server.$1.toRadixString(16)));
  put(_hexBytes('0${server.$2.toRadixString(16)}'));
  put(_hexBytes(code.substring(2)));
  final out = Uint8List(32);
  d.doFinal(out, 0);
  return out;
}

/// What the TV says about itself.
class AtvState {
  bool on = false;
  String app = '';
  int? volume, volumeMax;
  bool muted = false;
  String model = '', vendor = '';
}

/// The remote itself (port 6466, the paired certificate).
class AtvRemote {
  final String host;
  final AtvIdentity id;
  final int port;
  final state = AtvState();

  /// Something in [state] changed.
  void Function()? onChange;

  /// The connection ended (the TV slept, Wi-Fi blinked); a new [connect] is needed.
  void Function(Object? why)? onClosed;

  SecureSocket? _s;
  _Frames? _f;
  int _features = 0;
  int _imeCounter = 0, _fieldCounter = 0;
  final _ready = Completer<void>();
  bool _closed = false;

  AtvRemote(this.host, this.id, {this.port = atvRemotePort});

  bool get isOpen => _s != null && !_closed;

  /// Connects and waits for the TV to say it is ready. [AtvError] 'auth' means: pair first.
  Future<void> connect({Duration timeout = const Duration(seconds: 8)}) async {
    try {
      _s = await SecureSocket.connect(host, port,
          context: id.context(), onBadCertificate: (_) => true, timeout: timeout);
    } on HandshakeException catch (e) {
      throw AtvError('auth', e.message); // the TV refused our certificate: not paired
    } on SocketException catch (e) {
      throw AtvError('connect', e.message);
    } on TlsException catch (e) {
      throw AtvError('auth', e.message);
    }
    _f = _Frames(_s!);
    unawaited(_loop());
    try {
      await _ready.future.timeout(timeout);
    } on TimeoutException {
      close();
      throw AtvError('closed', 'the TV did not start the remote');
    } on AtvError {
      close();
      rethrow;
    }
  }

  Future<void> _loop() async {
    Object? why;
    try {
      while (!_closed) {
        final raw = await _f!.next(const Duration(seconds: 16)); // the TV pings every 5 s
        _handle(_Pb(raw));
      }
    } catch (e) {
      why = e;
      // the TV closes the TLS link of an unpaired phone right after the handshake
      if (!_ready.isCompleted) {
        _ready.completeError(AtvError(e is AtvError && e.kind == 'closed' ? 'auth' : 'closed', '$e'));
      }
    }
    final was = !_closed;
    close();
    if (was) onClosed?.call(why);
  }

  void _handle(_Pb m) {
    if (m.has(1)) {
      final cfg = _Pb(m.bytes(1)!);
      final info = cfg.has(2) ? _Pb(cfg.bytes(2)!) : null;
      state.model = info?.str(1) ?? '';
      state.vendor = info?.str(2) ?? '';
      // ping 1, key 2, ime 4, power 32, volume 64, app link 512 — what both sides support
      _features = (cfg.int1(1) ?? 0) & (1 | 2 | 4 | 32 | 64 | 512);
      _send(_msg([
        _fMsg(1, _msg([
          _fVar(1, _features),
          _fMsg(2, _msg([_fVar(3, 1), _fStr(4, '1'), _fStr(5, 'atvremote'), _fStr(6, '1.0.0')])),
        ]))
      ]));
    } else if (m.has(2)) {
      _send(_msg([_fMsg(2, _msg([_fVar(1, _features)]))]));
    } else if (m.has(8)) {
      _send(_msg([_fMsg(9, _msg([_fVar(1, _Pb(m.bytes(8)!).int1(1) ?? 0)]))]));
    } else if (m.has(40)) {
      state.on = _Pb(m.bytes(40)!).int1(1) == 1;
      if (!_ready.isCompleted) _ready.complete();
      onChange?.call();
    } else if (m.has(20)) {
      final ai = _Pb(m.bytes(20)!);
      if (ai.has(1)) {
        state.app = _Pb(ai.bytes(1)!).str(12) ?? state.app;
        onChange?.call();
      }
    } else if (m.has(21)) {
      final b = _Pb(m.bytes(21)!);
      _imeCounter = b.int1(1) ?? _imeCounter;
      _fieldCounter = b.int1(2) ?? _fieldCounter;
    } else if (m.has(50)) {
      final v = _Pb(m.bytes(50)!);
      state.volumeMax = v.int1(6);
      state.volume = v.int1(7);
      state.muted = v.int1(8) == 1;
      onChange?.call();
    }
  }

  /// [code] is an Android key code (KEYCODE_HOME 3, BACK 4, DPAD_UP 19 …). [direction]: 3 a press,
  /// 1 held down, 2 let go.
  void key(int code, {int direction = 3}) =>
      _send(_msg([_fMsg(10, _msg([_fVar(1, code), _fVar(2, direction)]))]));

  /// Types [text] into the field in focus on the TV (its keyboard must be up).
  void text(String text) {
    if (text.isEmpty) return;
    final n = text.runes.length - 1; // in characters, as the TV counts them
    _send(_msg([
      _fMsg(21, _msg([
        _fVar(1, _imeCounter),
        _fVar(2, _fieldCounter),
        _fMsg(3, _msg([_fVar(1, 1), _fMsg(2, _msg([_fVar(1, n), _fVar(2, n), _fStr(3, text)]))])),
      ]))
    ]));
  }

  /// Opens a link on the TV: https://… (the app that handles it) or market://details?id=… .
  void openLink(String link) => _send(_msg([_fMsg(90, _msg([_fStr(1, link)]))]));

  bool get canType => _features & 4 != 0;

  void _send(List<int> body) {
    final s = _s;
    if (s == null || _closed) throw AtvError('closed', 'not connected');
    s.add(_frame(body));
  }

  void close() {
    _closed = true;
    try {
      _s?.destroy();
    } catch (_) {}
    _s = null;
  }
}

// ── wire format: varint length + protobuf ────────────────────────────────────────────────

List<int> _frame(List<int> body) => [..._varint(body.length), ...body];

class _Frames {
  final _buf = BytesBuilder(copy: false);
  final _queue = <Uint8List>[];
  Completer<void>? _wait;
  bool _done = false;
  Object? _error;

  _Frames(Stream<List<int>> s) {
    s.listen((d) {
      _buf.add(d);
      _cut();
      _wake();
    }, onError: (Object e) {
      _error = e;
      _done = true;
      _wake();
    }, onDone: () {
      _done = true;
      _wake();
    }, cancelOnError: true);
  }

  void _wake() {
    final w = _wait;
    _wait = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  void _cut() {
    var all = _buf.takeBytes();
    var off = 0;
    while (true) {
      var len = 0, shift = 0, i = off;
      var complete = false;
      while (i < all.length) {
        final b = all[i++];
        len |= (b & 0x7f) << shift;
        shift += 7;
        if (b & 0x80 == 0) {
          complete = true;
          break;
        }
      }
      if (!complete || all.length - i < len) break;
      _queue.add(Uint8List.sublistView(all, i, i + len));
      off = i + len;
    }
    if (off < all.length) _buf.add(Uint8List.sublistView(all, off));
  }

  Future<Uint8List> next(Duration timeout) async {
    final end = DateTime.now().add(timeout);
    while (_queue.isEmpty) {
      if (_done) throw AtvError('closed', 'connection closed${_error != null ? ': $_error' : ''}');
      final left = end.difference(DateTime.now());
      if (left <= Duration.zero) throw AtvError('closed', 'no answer from the TV');
      _wait = Completer<void>();
      await _wait!.future.timeout(left, onTimeout: () {});
    }
    return _queue.removeAt(0);
  }
}

List<int> _varint(int v) {
  final out = <int>[];
  var x = v;
  while (true) {
    if (x < 0x80) {
      out.add(x);
      return out;
    }
    out.add((x & 0x7f) | 0x80);
    x >>= 7;
  }
}

List<int> _msg(List<List<int>> fields) => [for (final f in fields) ...f];
List<int> _fVar(int n, int v) => [..._varint(n << 3), ..._varint(v)];
List<int> _fBytes(int n, List<int> b) => [..._varint(n << 3 | 2), ..._varint(b.length), ...b];
List<int> _fStr(int n, String s) => _fBytes(n, utf8.encode(s));
List<int> _fMsg(int n, List<int> m) => _fBytes(n, m);

/// A decoded protobuf message: the last value of each field (varints as int, the rest as bytes).
class _Pb {
  final _v = <int, Object>{};
  _Pb(List<int> b) {
    var i = 0;
    int vi() {
      var r = 0, s = 0;
      while (true) {
        final x = b[i++];
        r |= (x & 0x7f) << s;
        s += 7;
        if (x & 0x80 == 0) return r;
      }
    }

    while (i < b.length) {
      final key = vi(), n = key >> 3, t = key & 7;
      if (t == 0) {
        _v[n] = vi();
      } else if (t == 2) {
        final l = vi();
        _v[n] = b.sublist(i, i + l);
        i += l;
      } else if (t == 5) {
        i += 4;
      } else if (t == 1) {
        i += 8;
      } else {
        break;
      }
    }
  }
  bool has(int n) => _v.containsKey(n);
  int? int1(int n) => _v[n] is int ? _v[n] as int : null;
  List<int>? bytes(int n) => _v[n] is List<int> ? _v[n] as List<int> : null;
  String? str(int n) => bytes(n) == null ? null : utf8.decode(bytes(n)!, allowMalformed: true);
}

// ── DER (just what a certificate needs) ───────────────────────────────────────────────────

List<int> _len(int n) {
  if (n < 0x80) return [n];
  final b = <int>[];
  var x = n;
  while (x > 0) {
    b.insert(0, x & 0xff);
    x >>= 8;
  }
  return [0x80 | b.length, ...b];
}

List<int> _tlv(int tag, List<int> v) => [tag, ..._len(v.length), ...v];
List<int> _seq(List<List<int>> items) => _tlv(0x30, [for (final i in items) ...i]);
List<int> _set(List<List<int>> items) => _tlv(0x31, [for (final i in items) ...i]);
List<int> _bitString(List<int> b) => _tlv(0x03, [0, ...b]);

List<int> _int(BigInt v) {
  var b = _unsigned(v);
  if (b.isEmpty) b = [0];
  if (b[0] & 0x80 != 0) b = [0, ...b];
  return _tlv(0x02, b);
}

List<int> _unsigned(BigInt v) {
  final out = <int>[];
  var x = v;
  while (x > BigInt.zero) {
    out.insert(0, (x & BigInt.from(0xff)).toInt());
    x >>= 8;
  }
  return out;
}

List<int> _oid(List<int> parts) {
  final out = <int>[parts[0] * 40 + parts[1]];
  for (final p in parts.skip(2)) {
    final b = <int>[p & 0x7f];
    var x = p >> 7;
    while (x > 0) {
      b.insert(0, (x & 0x7f) | 0x80);
      x >>= 7;
    }
    out.addAll(b);
  }
  return _tlv(0x06, out);
}

List<int> _utcTime(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  final s = '${two(t.year % 100)}${two(t.month)}${two(t.day)}${two(t.hour)}${two(t.minute)}${two(t.second)}Z';
  return _tlv(0x17, ascii.encode(s));
}

/// A DNS-safe form of the device name for the certificate's alt name.
String _dnsName(String n) {
  final s = n.toLowerCase().replaceAll(RegExp(r'[^a-z0-9-]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  return s.isEmpty ? 'atvremote' : s;
}

String _pem(String label, List<int> der) {
  final b = base64.encode(der);
  final lines = [for (var i = 0; i < b.length; i += 64) b.substring(i, min(i + 64, b.length))];
  return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
}

Uint8List _unpem(String pem) => base64.decode(pem
    .split('\n')
    .where((l) => l.isNotEmpty && !l.startsWith('-----'))
    .join());

List<int> _hexBytes(String hex) {
  final h = hex.length.isOdd ? '0$hex' : hex;
  return [for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)];
}

/// Modulus and exponent of the RSA key in an X.509 certificate (DER).
(BigInt, BigInt) rsaOfCertificate(List<int> der) {
  // Certificate → tbsCertificate → (skip [0] version, serial, sigAlg, issuer, validity, subject)
  // → subjectPublicKeyInfo → BIT STRING → RSAPublicKey (n, e)
  final cert = _Der(der, 0).children();
  final tbs = cert[0].children();
  var k = 0;
  if (tbs[0].tag == 0xA0) k = 1;
  final spki = tbs[k + 5].children();
  final bits = spki[1].value;
  final rsa = _Der(bits, 1).children();
  return (_big(rsa[0].value), _big(rsa[1].value));
}

BigInt _big(List<int> b) {
  var r = BigInt.zero;
  for (final x in b) {
    r = (r << 8) | BigInt.from(x);
  }
  return r;
}

class _Der {
  final List<int> buf;
  late final int tag, start, end;
  _Der(this.buf, int off) {
    tag = buf[off];
    var i = off + 1;
    var l = buf[i++];
    if (l & 0x80 != 0) {
      final n = l & 0x7f;
      l = 0;
      for (var j = 0; j < n; j++) {
        l = (l << 8) | buf[i++];
      }
    }
    start = i;
    end = i + l;
  }
  List<int> get value => buf.sublist(start, end);
  int get total => end;
  List<_Der> children() {
    final out = <_Der>[];
    var i = start;
    while (i < end) {
      final d = _Der(buf, i);
      out.add(d);
      i = d.end;
    }
    return out;
  }
}
