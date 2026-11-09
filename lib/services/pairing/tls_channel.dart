import 'package:flutter/services.dart';

/// Byte stream over a TLS 1.3 connection opened natively (Android:
/// SSLSocket, iOS: Network.framework) — needed only because dart:io has no
/// TLS "exporter" (exportKeyingMaterial), which adb pairing requires.
abstract class PairingTransport {
  Future<Uint8List> exportKeyingMaterial(Uint8List label, int length);
  Future<void> write(Uint8List data);
  Future<Uint8List> read(int length);
  Future<void> close();
}

class NativeTlsChannel implements PairingTransport {
  static const _ch = MethodChannel('tvcleanzer/tls');
  final int _id;
  NativeTlsChannel._(this._id);

  /// Opens TCP + TLS 1.3 to [host]:[port], presenting our certificate.
  static Future<NativeTlsChannel> open(String host, int port,
      {required Uint8List certDer, required Uint8List keyPkcs8, required Uint8List keyPkcs1}) async {
    final id = await _ch.invokeMethod<int>('open', {
      'host': host,
      'port': port,
      'cert': certDer,
      'pkcs8': keyPkcs8,
      'pkcs1': keyPkcs1,
    });
    return NativeTlsChannel._(id!);
  }

  @override
  Future<Uint8List> exportKeyingMaterial(Uint8List label, int length) async =>
      (await _ch.invokeMethod<Uint8List>('ekm', {'id': _id, 'label': label, 'length': length}))!;

  @override
  Future<void> write(Uint8List data) => _ch.invokeMethod('write', {'id': _id, 'data': data});

  @override
  Future<Uint8List> read(int length) async =>
      (await _ch.invokeMethod<Uint8List>('read', {'id': _id, 'length': length}))!;

  @override
  Future<void> close() async {
    try {
      await _ch.invokeMethod('close', {'id': _id});
    } catch (_) {}
  }
}
