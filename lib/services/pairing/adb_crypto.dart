import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Crypto helpers for Wireless debugging: our RSA key as an X.509
/// certificate and PKCS#1/#8 keys (TLS client identity), HKDF and AES-GCM
/// for the pairing protocol. Small hand-written DER encoder: no extra deps.
class AdbCrypto {
  AdbCrypto._();

  // ── RSA key material ──────────────────────────────────────────────────────

  /// Recovers p and q from (n, e, d) — we only stored n, e, d.
  static (BigInt, BigInt) recoverPrimes(BigInt n, BigInt e, BigInt d) {
    final k = d * e - BigInt.one;
    var t = k;
    var s = 0;
    while (t.isEven) {
      t = t >> 1;
      s++;
    }
    for (var g = 2; g < 1000; g++) {
      var x = BigInt.from(g).modPow(t, n);
      for (var i = 0; i < s; i++) {
        final y = (x * x) % n;
        if (y == BigInt.one && x != BigInt.one && x != n - BigInt.one) {
          final p = (x - BigInt.one).gcd(n);
          final q = n ~/ p;
          return p > q ? (p, q) : (q, p);
        }
        x = y;
      }
    }
    throw StateError('could not factor RSA modulus');
  }

  /// PKCS#1 RSAPrivateKey DER.
  static Uint8List pkcs1(BigInt n, BigInt e, BigInt d) {
    final (p, q) = recoverPrimes(n, e, d);
    return _seq([
      _int(BigInt.zero), _int(n), _int(e), _int(d), _int(p), _int(q),
      _int(d % (p - BigInt.one)), _int(d % (q - BigInt.one)), _int(q.modInverse(p)),
    ]);
  }

  /// PKCS#8 PrivateKeyInfo DER.
  static Uint8List pkcs8(BigInt n, BigInt e, BigInt d) => _seq([
        _int(BigInt.zero),
        _seq([_oid([1, 2, 840, 113549, 1, 1, 1]), _null()]),
        _tlv(0x04, pkcs1(n, e, d)),
      ]);

  /// Self-signed X.509 v3 certificate (SHA256withRSA), CN=TVCleanzer.
  /// Returns (certificateDer, tbsDer) — tbs only for tests.
  static (Uint8List, Uint8List) selfSignedCert(BigInt n, BigInt e, BigInt d, {DateTime? now}) {
    final t = (now ?? DateTime.now().toUtc()).subtract(const Duration(days: 1));
    final name = _seq([
      _tlv(0x31, _seq([_oid([2, 5, 4, 3]), _tlv(0x0c, utf8.encode('TVCleanzer'))])),
    ]);
    final sigAlg = _seq([_oid([1, 2, 840, 113549, 1, 1, 11]), _null()]);
    final spki = _seq([
      _seq([_oid([1, 2, 840, 113549, 1, 1, 1]), _null()]),
      _bitString(_seq([_int(n), _int(e)])),
    ]);
    final serial = BigInt.from(Random.secure().nextInt(1 << 30)) << 32 |
        BigInt.from(Random.secure().nextInt(1 << 30));
    final tbs = _seq([
      _tlv(0xa0, _int(BigInt.two)), // v3
      _int(serial),
      sigAlg,
      name,
      _seq([_utcTime(t), _utcTime(DateTime.utc(2049, 12, 31, 23, 59, 59))]),
      name,
      spki,
    ]);
    final sig = signSha256(tbs, n, d);
    return (_seq([tbs, sigAlg, _bitString(sig)]), tbs);
  }

  /// RSASSA-PKCS1-v1_5 with SHA-256.
  static Uint8List signSha256(Uint8List data, BigInt n, BigInt d) {
    final k = (n.bitLength + 7) ~/ 8;
    final digest = SHA256Digest().process(data);
    const prefix = [
      0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01,
      0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20,
    ];
    final t = [...prefix, ...digest];
    final em = Uint8List(k);
    em[1] = 0x01;
    for (var i = 2; i < k - t.length - 1; i++) {
      em[i] = 0xff;
    }
    em.setAll(k - t.length, t);
    return _toBytes(_fromBytes(em).modPow(d, n), k);
  }

  static String pem(String label, Uint8List der) {
    final b64 = base64.encode(der);
    final lines = <String>[];
    for (var i = 0; i < b64.length; i += 64) {
      lines.add(b64.substring(i, min(i + 64, b64.length)));
    }
    return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
  }

  // ── Pairing primitives ────────────────────────────────────────────────────

  /// HKDF-SHA256 (RFC 5869), empty salt = zeros.
  static Uint8List hkdfSha256(Uint8List ikm, Uint8List info, int length, {Uint8List? salt}) {
    Uint8List hmac(Uint8List key, Uint8List data) {
      final m = HMac(SHA256Digest(), 64)..init(KeyParameter(key));
      return m.process(data);
    }
    final prk = hmac(salt == null || salt.isEmpty ? Uint8List(32) : salt, ikm);
    final out = BytesBuilder();
    var prev = Uint8List(0);
    for (var i = 1; out.length < length; i++) {
      prev = hmac(prk, Uint8List.fromList([...prev, ...info, i]));
      out.add(prev);
    }
    return Uint8List.sublistView(out.toBytes(), 0, length);
  }

  /// AES-128-GCM; output = ciphertext ‖ 16-byte tag.
  static Uint8List aesGcm(bool encrypt, Uint8List key, Uint8List nonce, Uint8List data) {
    final c = GCMBlockCipher(AESEngine())
      ..init(encrypt, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
    return c.process(data);
  }

  /// adb's nonce: 64-bit little-endian counter, padded to 12 bytes.
  static Uint8List counterNonce(int counter) {
    final b = ByteData(12)..setUint64(0, counter, Endian.little);
    return b.buffer.asUint8List();
  }

  // ── DER ───────────────────────────────────────────────────────────────────

  static Uint8List _tlv(int tag, List<int> value) {
    final len = value.length;
    List<int> l;
    if (len < 0x80) {
      l = [len];
    } else {
      final bytes = <int>[];
      var v = len;
      while (v > 0) {
        bytes.insert(0, v & 0xff);
        v >>= 8;
      }
      l = [0x80 | bytes.length, ...bytes];
    }
    return Uint8List.fromList([tag, ...l, ...value]);
  }

  static Uint8List _seq(List<Uint8List> items) =>
      _tlv(0x30, items.expand((e) => e).toList());

  static Uint8List _int(BigInt v) {
    var b = v == BigInt.zero ? Uint8List(1) : _toBytes(v, (v.bitLength + 7) ~/ 8);
    if (b[0] & 0x80 != 0) b = Uint8List.fromList([0, ...b]);
    return _tlv(0x02, b);
  }

  static Uint8List _null() => Uint8List.fromList([0x05, 0x00]);

  static Uint8List _bitString(Uint8List data) => _tlv(0x03, [0, ...data]);

  static Uint8List _oid(List<int> parts) {
    final out = <int>[40 * parts[0] + parts[1]];
    for (final p in parts.skip(2)) {
      final bytes = <int>[p & 0x7f];
      var v = p >> 7;
      while (v > 0) {
        bytes.insert(0, 0x80 | (v & 0x7f));
        v >>= 7;
      }
      out.addAll(bytes);
    }
    return _tlv(0x06, out);
  }

  static Uint8List _utcTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    final s = '${two(t.year % 100)}${two(t.month)}${two(t.day)}'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}Z';
    return _tlv(0x17, ascii.encode(s));
  }

  static BigInt _fromBytes(List<int> b) {
    var r = BigInt.zero;
    for (final x in b) {
      r = (r << 8) | BigInt.from(x);
    }
    return r;
  }

  static Uint8List _toBytes(BigInt v, int len) {
    final out = Uint8List(len);
    final mask = BigInt.from(0xff);
    for (var i = len - 1; i >= 0; i--) {
      out[i] = (v & mask).toInt();
      v = v >> 8;
    }
    return out;
  }
}
