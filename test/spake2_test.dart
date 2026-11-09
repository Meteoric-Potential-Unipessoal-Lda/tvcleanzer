import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvcleanzer/services/pairing/spake2.dart';

// Vectors from tools/spake2_ref.py (reference port of BoringSSL spake25519):
// alice random = 64 x 0x01, bob random = 64 x 0x02, password = code + bytes 0..63.
Uint8List _hex(String s) => Uint8List.fromList(
    List.generate(s.length ~/ 2, (i) => int.parse(s.substring(i * 2, i * 2 + 2), radix: 16)));

Uint8List _pw(String code) =>
    Uint8List.fromList([...code.codeUnits, ...List.generate(64, (i) => i)]);

void main() {
  const vectors = [
    [
      '123456',
      'cfc1ccbefa04f6d6bded0d2af27082965c4c89aac1ee7c85b7658f2648f6790b',
      '8ecdbde133080ab06407064880d41a4684f760450eca6755373a5d5a536d8b00',
      'e488fac770204ad4cd1a319228a9095003bcaedda1660e357dc2237f68646e4e698f5a404ed45d17f33f2c71eb2073f031eeb998fb3604ae5919d15058c4e993',
    ],
    [
      '000000',
      'ea47bdc1ab6412ec74b8a4bd7411c049835ab9fb82e41663c5032decddd8f478',
      'f8c8e6a49b72dbc89a8853e9713e044cf4c0b7fcca701721d8368200698568fa',
      '619a5dfa212552a4677567b079fb5b08b39b74df2e9041209e9e00c2f19ad302ceec2f3d15246fc235a0449120641645d71b520b80ce05db453ae747599660a4',
    ],
  ];

  for (final v in vectors) {
    test('SPAKE2 matches the BoringSSL reference (code ${v[0]})', () {
      final alice = Spake2.adbClient(_pw(v[0]), random: Uint8List(64)..fillRange(0, 64, 1));
      expect(alice.message, _hex(v[1]));
      expect(alice.finish(_hex(v[2])), _hex(v[3]));

      final bob = Spake2(
        alice: false,
        myName: Spake2.serverName,
        theirName: Spake2.clientName,
        password: _pw(v[0]),
        random: Uint8List(64)..fillRange(0, 64, 2),
      );
      expect(bob.message, _hex(v[2]));
      expect(bob.finish(alice.message), _hex(v[3]));
    });
  }

  test('wrong code gives a different key', () {
    final alice = Spake2.adbClient(_pw('123456'));
    final bob = Spake2(
      alice: false,
      myName: Spake2.serverName,
      theirName: Spake2.clientName,
      password: _pw('654321'),
    );
    expect(alice.finish(bob.message), isNot(equals(bob.finish(alice.message))));
  });
}
