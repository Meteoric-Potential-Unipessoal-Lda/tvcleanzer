import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:tvcleanzer/services/pairing/adb_crypto.dart';
import 'package:tvcleanzer/services/pairing/adb_pairing.dart';
import 'package:tvcleanzer/services/pairing/spake2.dart';
import 'package:tvcleanzer/services/pairing/tls_channel.dart';

Uint8List _hex(String s) => Uint8List.fromList(
    List.generate(s.length ~/ 2, (i) => int.parse(s.substring(i * 2, i * 2 + 2), radix: 16)));

/// A TV that speaks the adb pairing protocol (server side), in memory.
class _FakeTv implements PairingTransport {
  _FakeTv(this.code);
  final String code;
  final ekm = Uint8List.fromList(List.generate(64, (i) => 200 - i));
  final _toClient = <int>[];
  final _fromClient = <int>[];
  Spake2? _spake;
  Uint8List? _aes;
  Uint8List? clientKey; // what the TV learned

  @override
  Future<Uint8List> exportKeyingMaterial(Uint8List label, int length) async {
    expect(utf8.decode(label), 'adb-label\x00');
    return ekm;
  }

  @override
  Future<void> write(Uint8List data) async {
    _fromClient.addAll(data);
    while (_fromClient.length >= 6) {
      final h = ByteData.sublistView(Uint8List.fromList(_fromClient.sublist(0, 6)));
      final size = h.getUint32(2, Endian.big);
      if (_fromClient.length < 6 + size) return;
      final type = h.getUint8(1);
      final body = Uint8List.fromList(_fromClient.sublist(6, 6 + size));
      _fromClient.removeRange(0, 6 + size);
      if (type == 0) {
        _spake = Spake2(
          alice: false,
          myName: Spake2.serverName,
          theirName: Spake2.clientName,
          password: Uint8List.fromList([...ascii.encode(code), ...ekm]),
        );
        _aes = AdbCrypto.hkdfSha256(_spake!.finish(body),
            Uint8List.fromList(ascii.encode('adb pairing_auth aes-128-gcm key')), 16);
        _toClient.addAll(AdbPairing.packet(0, _spake!.message));
      } else {
        final info = AdbCrypto.aesGcm(false, _aes!, AdbCrypto.counterNonce(0), body); // throws on wrong code
        clientKey = info;
        final reply = Uint8List(AdbPairing.peerInfoSize)..[0] = 1; // device GUID
        reply.setAll(1, ascii.encode('adb-FAKE1234'));
        _toClient.addAll(AdbPairing.packet(1, AdbCrypto.aesGcm(true, _aes!, AdbCrypto.counterNonce(0), reply)));
      }
    }
  }

  @override
  Future<Uint8List> read(int length) async {
    if (_toClient.length < length) throw StateError('TV closed the connection');
    final out = Uint8List.fromList(_toClient.sublist(0, length));
    _toClient.removeRange(0, length);
    return out;
  }

  @override
  Future<void> close() async {}
}

void main() {
  test('HKDF-SHA256 matches RFC 5869 test case 3', () {
    final okm = AdbCrypto.hkdfSha256(Uint8List(22)..fillRange(0, 22, 0x0b), Uint8List(0), 42);
    expect(okm, _hex('8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8'));
  });

  test('AES-128-GCM matches NIST test case 2', () {
    final out = AdbCrypto.aesGcm(true, Uint8List(16), Uint8List(12), Uint8List(16));
    expect(out, _hex('0388dace60b6a392f328c2b971b2fe78ab6e47d42cec13bdf53a67b21257bddf'));
    expect(AdbCrypto.aesGcm(false, Uint8List(16), Uint8List(12), out), Uint8List(16));
  });

  test('certificate from our RSA key is valid DER and correctly signed', () {
    final rnd = FortunaRandom()
      ..seed(KeyParameter(Uint8List.fromList(List.generate(32, (_) => Random(7).nextInt(256)))));
    final gen = RSAKeyGenerator()
      ..init(ParametersWithRandom(RSAKeyGeneratorParameters(BigInt.from(65537), 1024, 64), rnd));
    final pair = gen.generateKeyPair();
    final priv = pair.privateKey as RSAPrivateKey;
    final pub = pair.publicKey as RSAPublicKey;
    final n = priv.modulus!, d = priv.privateExponent!, e = BigInt.from(65537);

    final (p, q) = AdbCrypto.recoverPrimes(n, e, d);
    expect(p * q, n);
    expect({p, q}, {priv.p, priv.q});

    final (cert, tbs) = AdbCrypto.selfSignedCert(n, e, d);
    final top = ASN1Parser(cert).nextObject() as ASN1Sequence;
    expect(top.elements!.length, 3);

    final verifier = Signer('SHA-256/RSA')..init(false, PublicKeyParameter<RSAPublicKey>(pub));
    final sig = AdbCrypto.signSha256(tbs, n, d);
    expect(verifier.verifySignature(tbs, RSASignature(sig)), isTrue);

    expect(ASN1Parser(AdbCrypto.pkcs8(n, e, d)).nextObject(), isA<ASN1Sequence>());
    expect(AdbCrypto.pem('CERTIFICATE', cert), startsWith('-----BEGIN CERTIFICATE-----\n'));
  });

  test('pairing with a fake TV: the TV gets our public key', () async {
    final tv = _FakeTv('482913');
    final pub = Uint8List.fromList(ascii.encode('QUFBQQ== TVCleanzer@phone\x00'));
    final reply = await AdbPairing.run(tv, '482913', pub);
    expect(reply[0], 1);
    expect(tv.clientKey![0], 0);
    expect(tv.clientKey!.sublist(1, 1 + pub.length), pub);
  });

  test('wrong code fails', () async {
    final tv = _FakeTv('482913');
    final pub = Uint8List.fromList(ascii.encode('QUFBQQ== TVCleanzer@phone\x00'));
    // The fake TV cannot decrypt our PeerInfo and "drops" the connection.
    await expectLater(AdbPairing.run(tv, '111111', pub), throwsA(anything));
  });
}
