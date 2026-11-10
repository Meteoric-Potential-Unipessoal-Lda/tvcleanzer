import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show MissingPluginException, PlatformException;
import 'package:pointycastle/export.dart' show InvalidCipherTextException;

import '../adb_client.dart';
import 'adb_crypto.dart';
import 'spake2.dart';
import 'tls_channel.dart';

class PairingException implements Exception {
  final String message;
  PairingException(this.message);
  @override
  String toString() => message;
}

/// `adb pair` client: SPAKE2 over a TLS 1.3 connection, then an encrypted
/// exchange of public keys. After it, the TV trusts our key for
/// Wireless debugging. See docs: claude/tvcleanzer/wireless_pairing.md.
class AdbPairing {
  static const _version = 1;
  static const _typeSpake2 = 0;
  static const _typePeerInfo = 1;
  static const peerInfoSize = 8192;
  static final _ekmLabel = Uint8List.fromList(ascii.encode('adb-label\x00'));
  static final _hkdfInfo = Uint8List.fromList(ascii.encode('adb pairing_auth aes-128-gcm key'));

  /// Pairs with the TV at [host]:[port] using the 6-digit [code].
  static Future<void> pair(String host, int port, String code) async {
    final id = await AdbClient.tlsIdentity();
    final NativeTlsChannel ch;
    try {
      ch = await NativeTlsChannel.open(host, port,
          certDer: id.certDer, keyPkcs8: id.pkcs8, keyPkcs1: id.pkcs1);
    } on MissingPluginException {
      throw PairingException(
          'На компьютере подключение по коду пока не работает. Включите на ТВ «Отладку по сети» '
          '(порт 5555) — такой ТВ найдётся сам — или подключите ТВ по коду с телефона.');
    } on PlatformException catch (e) {
      throw PairingException(e.code == 'unsupported'
          ? (e.message ?? 'Этот телефон не поддерживает сопряжение по коду.')
          : 'Не удалось подключиться к $host:$port. Проверьте адрес и порт в окне с кодом.');
    }
    try {
      await run(ch, code, id.publicKey);
    } on PlatformException {
      // The TV drops the connection when the code is wrong or the window closed.
      throw PairingException('Сопряжение не удалось. Проверьте код и что окно с кодом ещё открыто на ТВ.');
    } finally {
      await ch.close();
    }
  }

  /// The protocol itself, over any transport (tests use a fake TV).
  static Future<Uint8List> run(PairingTransport t, String code, Uint8List publicKey,
      {Uint8List? random}) async {
    final ekm = await t.exportKeyingMaterial(_ekmLabel, 64);
    final spake = Spake2.adbClient(
        Uint8List.fromList([...ascii.encode(code.trim()), ...ekm]), random: random);

    await t.write(packet(_typeSpake2, spake.message));
    final theirMsg = await _readPacket(t, _typeSpake2);
    final key = spake.finish(theirMsg);
    final aesKey = AdbCrypto.hkdfSha256(key, _hkdfInfo, 16);

    final info = Uint8List(peerInfoSize); // type 0 = ADB RSA public key
    info.setRange(1, 1 + publicKey.length.clamp(0, peerInfoSize - 1), publicKey);
    await t.write(packet(_typePeerInfo, AdbCrypto.aesGcm(true, aesKey, AdbCrypto.counterNonce(0), info)));

    final enc = await _readPacket(t, _typePeerInfo);
    try {
      final theirs = AdbCrypto.aesGcm(false, aesKey, AdbCrypto.counterNonce(0), enc);
      if (theirs.length != peerInfoSize) throw PairingException('Телевизор прислал странный ответ.');
      return theirs;
    } on InvalidCipherTextException {
      throw PairingException('Неверный код. Проверьте шесть цифр на экране телевизора.');
    } on ArgumentError {
      throw PairingException('Неверный код. Проверьте шесть цифр на экране телевизора.');
    }
  }

  static Uint8List packet(int type, Uint8List payload) {
    final b = ByteData(6)
      ..setUint8(0, _version)
      ..setUint8(1, type)
      ..setUint32(2, payload.length, Endian.big);
    return Uint8List.fromList([...b.buffer.asUint8List(), ...payload]);
  }

  static Future<Uint8List> _readPacket(PairingTransport t, int type) async {
    final h = ByteData.sublistView(await t.read(6));
    final size = h.getUint32(2, Endian.big);
    if (h.getUint8(1) != type || size > 2 * peerInfoSize) {
      throw PairingException('Телевизор прервал сопряжение. Проверьте код и попробуйте снова.');
    }
    return t.read(size);
  }
}
