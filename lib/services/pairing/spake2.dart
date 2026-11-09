import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// SPAKE2 over Ed25519, byte-compatible with BoringSSL's spake25519 as used
/// by `adb pair` (Android 11+ Wireless debugging). Ported from BoringSSL
/// crypto/curve25519/spake25519.cc (Apache-2.0); the reference/test vectors
/// come from tools/spake2_ref.py.
///
/// Plain BigInt arithmetic: slow-ish (tens of ms) but pairing runs once.
class Spake2 {
  static final BigInt _p = (BigInt.one << 255) - BigInt.from(19);
  static final BigInt _l = (BigInt.one << 252) +
      BigInt.parse('27742317777372353535851937790883648493');
  static final BigInt _d =
      (BigInt.from(-121665) * BigInt.from(121666).modInverse(_p)) % _p;
  static final BigInt _sqrtM1 =
      BigInt.two.modPow((_p - BigInt.one) ~/ BigInt.from(4), _p);

  static final _Pt _base = () {
    final y = (BigInt.from(4) * BigInt.from(5).modInverse(_p)) % _p;
    return _Pt(_xRecover(y), y);
  }();
  static final _Pt _m = _Pt(
    BigInt.parse('31406539342727633121250288103050113562375374900226415211311216773867585644232'),
    BigInt.parse('21177308356423958466833845032658859666296341766942662650232962324899758529114'),
  );
  static final _Pt _n = _Pt(
    BigInt.parse('49918732221787544735331783592030787422991506689877079631459872391322455579424'),
    BigInt.parse('54629554431565467720832445949441049581317094546788069926228343916274969994000'),
  );

  /// Names used by adb (with the trailing NUL, 16 bytes each).
  static final Uint8List clientName = Uint8List.fromList('adb pair client\x00'.codeUnits);
  static final Uint8List serverName = Uint8List.fromList('adb pair server\x00'.codeUnits);

  final bool _alice;
  final Uint8List _myName, _theirName;
  late final BigInt _priv;
  late final BigInt _w;
  late final Uint8List _passwordHash;

  /// Our 32-byte message to send to the peer.
  late final Uint8List message;

  /// [random] (64 bytes) only for tests; normally from a secure RNG.
  Spake2({
    required bool alice,
    required Uint8List myName,
    required Uint8List theirName,
    required Uint8List password,
    Uint8List? random,
  })  : _alice = alice,
        _myName = myName,
        _theirName = theirName {
    final rnd = random ?? _secureRandom(64);
    _priv = ((_le(rnd) % _l) * BigInt.from(8)) % (BigInt.one << 256);
    _passwordHash = SHA512Digest().process(password);
    var w = _le(_passwordHash) % _l;
    // BoringSSL "password scalar hack": make w a multiple of 8 by adding l, 2l, 4l
    if ((w & BigInt.one) != BigInt.zero) w += _l;
    if ((w & BigInt.two) != BigInt.zero) w += _l * BigInt.two;
    if ((w & BigInt.from(4)) != BigInt.zero) w += _l * BigInt.from(4);
    _w = w;
    final p = _mul(_base, _priv);
    final mask = _mul(alice ? _m : _n, _w);
    message = _encode(_add(p, mask));
  }

  /// adb client side (alice).
  factory Spake2.adbClient(Uint8List password, {Uint8List? random}) => Spake2(
        alice: true,
        myName: clientName,
        theirName: serverName,
        password: password,
        random: random,
      );

  /// Shared 64-byte key from the peer's message. Throws on a bad point.
  Uint8List finish(Uint8List theirMsg) {
    if (theirMsg.length != 32) throw ArgumentError('SPAKE2 message must be 32 bytes');
    final q = _decode(theirMsg);
    final mask = _mul(_alice ? _n : _m, _w);
    final dh = _mul(_add(q, _neg(mask)), _priv);
    final h = SHA512Digest();
    void up(Uint8List b) {
      final len = ByteData(8)..setUint64(0, b.length, Endian.little);
      h.update(len.buffer.asUint8List(), 0, 8);
      h.update(b, 0, b.length);
    }
    if (_alice) {
      up(_myName); up(_theirName); up(message); up(theirMsg);
    } else {
      up(_theirName); up(_myName); up(theirMsg); up(message);
    }
    up(_encode(dh));
    up(_passwordHash);
    final out = Uint8List(64);
    h.doFinal(out, 0);
    return out;
  }

  // ── Ed25519 (affine, readable rather than fast) ───────────────────────────

  static BigInt _xRecover(BigInt y) {
    final xx = ((y * y - BigInt.one) * (_d * y * y + BigInt.one).modInverse(_p)) % _p;
    var x = xx.modPow((_p + BigInt.from(3)) ~/ BigInt.from(8), _p);
    if ((x * x - xx) % _p != BigInt.zero) x = (x * _sqrtM1) % _p;
    if ((x * x - xx) % _p != BigInt.zero) throw const FormatException('point not on curve');
    if (x.isOdd) x = _p - x;
    return x;
  }

  static _Pt _add(_Pt a, _Pt b) {
    final t = (_d * a.x * b.x * a.y * b.y) % _p;
    final x = ((a.x * b.y + b.x * a.y) * (BigInt.one + t).modInverse(_p)) % _p;
    final y = ((a.y * b.y + a.x * b.x) * ((BigInt.one - t) % _p).modInverse(_p)) % _p;
    return _Pt(x, y);
  }

  static _Pt _neg(_Pt a) => _Pt((_p - a.x) % _p, a.y);

  static _Pt _mul(_Pt pt, BigInt k) {
    var r = _Pt(BigInt.zero, BigInt.one);
    var q = pt;
    while (k > BigInt.zero) {
      if (k.isOdd) r = _add(r, q);
      q = _add(q, q);
      k = k >> 1;
    }
    return r;
  }

  static Uint8List _encode(_Pt pt) {
    final b = _toLe(pt.y, 32);
    if (pt.x.isOdd) b[31] |= 0x80;
    return b;
  }

  static _Pt _decode(Uint8List s) {
    final y = _le(s) & ((BigInt.one << 255) - BigInt.one);
    if (y >= _p) throw const FormatException('bad point');
    var x = _xRecover(y);
    if ((x.isOdd ? 1 : 0) != (s[31] >> 7)) x = _p - x;
    return _Pt(x, y);
  }

  static BigInt _le(List<int> b) {
    var r = BigInt.zero;
    for (var i = b.length - 1; i >= 0; i--) {
      r = (r << 8) | BigInt.from(b[i]);
    }
    return r;
  }

  static Uint8List _toLe(BigInt v, int len) {
    final out = Uint8List(len);
    final mask = BigInt.from(0xff);
    for (var i = 0; i < len; i++) {
      out[i] = (v & mask).toInt();
      v = v >> 8;
    }
    return out;
  }

  static Uint8List _secureRandom(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }
}

class _Pt {
  final BigInt x, y;
  const _Pt(this.x, this.y);
}
