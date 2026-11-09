import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointy_castle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── ADB Protocol Constants ───────────────────────────────────────────────────

const int _CNXN = 0x4E584E43;
const int _AUTH = 0x48545541;
const int _OPEN = 0x4E45504F;
const int _OKAY = 0x59414B4F;
const int _CLSE = 0x45534C43;
const int _WRTE = 0x45545257;

const int _AUTH_TOKEN     = 1;
const int _AUTH_SIGNATURE = 2;
const int _AUTH_RSAPUBKEY = 3;

const int _ADB_VERSION = 0x01000000;
const int _MAX_PAYLOAD  = 1 << 20; // 1 MB

// ─── Exceptions ───────────────────────────────────────────────────────────────

class AdbException implements Exception {
  final String message;
  AdbException(this.message);
  @override String toString() => 'AdbException: $message';
}

class AdbAuthException extends AdbException {
  AdbAuthException(super.message);
  @override String toString() => 'AdbAuthException: $message';
}

// ─── Message ──────────────────────────────────────────────────────────────────

class _Msg {
  final int cmd, arg0, arg1;
  final Uint8List data;
  _Msg(this.cmd, this.arg0, this.arg1, [Uint8List? data])
      : data = data ?? Uint8List(0);

  static int _sum(Uint8List buf) {
    int s = 0;
    for (final b in buf) s = (s + b) & 0xFFFFFFFF;
    return s;
  }

  Uint8List encode() {
    final hdr = ByteData(24);
    hdr.setUint32(0,  cmd,          Endian.little);
    hdr.setUint32(4,  arg0,         Endian.little);
    hdr.setUint32(8,  arg1,         Endian.little);
    hdr.setUint32(12, data.length,  Endian.little);
    hdr.setUint32(16, _sum(data),   Endian.little);
    hdr.setUint32(20, cmd ^ 0xFFFFFFFF, Endian.little);
    if (data.isEmpty) return hdr.buffer.asUint8List();
    return Uint8List(24 + data.length)
      ..setAll(0, hdr.buffer.asUint8List())
      ..setAll(24, data);
  }
}

// ─── ADB Client ───────────────────────────────────────────────────────────────

/// Implements the ADB wire protocol over TCP port 5555.
///
/// Usage:
///   final client = AdbClient(host: '192.168.1.100');
///   final props = await client.connect();      // RSA auth, returns device props
///   final out   = await client.shell('pm list packages');
///   client.close();
class AdbClient {
  final String host;
  final int port;

  Socket? _sock;
  final List<int> _buf = [];
  final StreamController<_Msg> _msgCtrl = StreamController<_Msg>.broadcast();
  StreamSubscription? _sockSub;
  int _nextLocalId = 1;

  AdbClient({required this.host, this.port = 5555});

  // ── Public API ───────────────────────────────────────────────────────────────

  /// Connect and authenticate. Returns device properties from CNXN response.
  /// On first connection with a new key, the TV shows "Allow ADB?" — the method
  /// waits up to [pairingTimeout] for the user to approve on the TV screen.
  Future<Map<String, String>> connect({
    Duration timeout        = const Duration(seconds: 10),
    Duration pairingTimeout = const Duration(seconds: 60),
  }) async {
    _sock = await Socket.connect(host, port, timeout: timeout);
    _sock!.setOption(SocketOption.tcpNoDelay, true);
    _sockSub = _sock!.listen(
      (data) {
        _buf.addAll(data);
        _assembleMessages();
      },
      onError: (e) => _msgCtrl.addError(e),
      onDone: () => _msgCtrl.close(),
    );

    final keys = await _loadOrGenerateKeys();

    // ── 1. Send CNXN ─────────────────────────────────────────────────────────
    _send(_Msg(_CNXN, _ADB_VERSION, _MAX_PAYLOAD,
        Uint8List.fromList(utf8.encode('host::ro.product.name=TVCleanzer\x00'))));

    // ── 2. Receive AUTH TOKEN ─────────────────────────────────────────────────
    final auth1 = await _next().timeout(timeout,
        onTimeout: () => throw AdbException('TV did not respond. '
            'Make sure ADB over network is enabled in Developer Options.'));
    if (auth1.cmd != _AUTH || auth1.arg0 != _AUTH_TOKEN) {
      throw AdbAuthException('Expected AUTH TOKEN, got 0x${auth1.cmd.toRadixString(16)}');
    }

    // ── 3. Sign the token ────────────────────────────────────────────────────
    final signer = Signer('SHA-1/RSA')
      ..init(true, PrivateKeyParameter<RSAPrivateKey>(keys.priv));
    final sig = (signer.generateSignature(auth1.data) as RSASignature).bytes;
    _send(_Msg(_AUTH, _AUTH_SIGNATURE, 0, Uint8List.fromList(sig)));

    // ── 4. Response: CNXN (known key) or AUTH TOKEN (unknown key) ────────────
    final resp = await _next().timeout(timeout,
        onTimeout: () => throw AdbAuthException('No auth response from TV.'));

    if (resp.cmd == _CNXN) {
      return _parseCnxn(resp); // Key already trusted → connected
    }

    if (resp.cmd == _AUTH && resp.arg0 == _AUTH_TOKEN) {
      // Unknown key → send public key; TV will show "Allow ADB?" dialog
      final pubKey = _buildAndroidPublicKey(keys.pub);
      _send(_Msg(_AUTH, _AUTH_RSAPUBKEY, 0, pubKey));

      final accepted = await _next().timeout(pairingTimeout,
          onTimeout: () => throw AdbAuthException(
              'Timed out waiting for TV approval. '
              'Please tap "Allow" on the TV screen and try again.'));
      if (accepted.cmd != _CNXN) {
        throw AdbAuthException('TV rejected ADB connection.');
      }
      return _parseCnxn(accepted);
    }

    throw AdbAuthException('Unexpected ADB auth response: 0x${resp.cmd.toRadixString(16)}');
  }

  /// Run a shell command and return its full stdout output.
  Future<String> shell(String command, {Duration timeout = const Duration(seconds: 30)}) async {
    final localId  = _nextLocalId++;
    _send(_Msg(_OPEN, localId, 0,
        Uint8List.fromList(utf8.encode('shell:$command\x00'))));

    // Wait for OKAY (TV assigns its remote ID to this channel)
    final okay = await _stream
        .firstWhere((m) => m.cmd == _OKAY && m.arg1 == localId)
        .timeout(timeout, onTimeout: () => throw AdbException('OPEN timed out for: $command'));
    final remoteId = okay.arg0;

    final output = StringBuffer();
    await for (final msg in _stream.timeout(timeout,
        onTimeout: (s) => s.addError(AdbException('shell read timed out')))) {
      if (msg.cmd == _WRTE && msg.arg1 == localId) {
        output.write(utf8.decode(msg.data, allowMalformed: true));
        _send(_Msg(_OKAY, localId, remoteId));
      } else if (msg.cmd == _CLSE && msg.arg1 == localId) {
        _send(_Msg(_CLSE, localId, remoteId));
        break;
      }
    }
    return output.toString();
  }

  void close() {
    _sockSub?.cancel();
    _sock?.destroy();
    _sock = null;
    if (!_msgCtrl.isClosed) _msgCtrl.close();
  }

  // ── Socket / message plumbing ─────────────────────────────────────────────

  void _send(_Msg msg) {
    _sock?.add(msg.encode());
  }

  void _assembleMessages() {
    while (true) {
      if (_buf.length < 24) break;
      // Peek at data_len without consuming
      final hdr     = ByteData.view(Uint8List.fromList(_buf.sublist(0, 24)).buffer);
      final dataLen = hdr.getUint32(12, Endian.little);
      if (_buf.length < 24 + dataLen) break;

      final cmd  = hdr.getUint32(0,  Endian.little);
      final arg0 = hdr.getUint32(4,  Endian.little);
      final arg1 = hdr.getUint32(8,  Endian.little);
      _buf.removeRange(0, 24);
      final data = Uint8List.fromList(_buf.sublist(0, dataLen));
      if (dataLen > 0) _buf.removeRange(0, dataLen);

      if (!_msgCtrl.isClosed) _msgCtrl.add(_Msg(cmd, arg0, arg1, data));
    }
  }

  Stream<_Msg> get _stream => _msgCtrl.stream;

  Future<_Msg> _next() => _stream.first;

  Map<String, String> _parseCnxn(_Msg msg) {
    final raw = utf8.decode(msg.data, allowMalformed: true).replaceAll('\x00', '');
    final props = <String, String>{};
    // Format: "device::key=val;key=val;..."
    final body = raw.contains('::') ? raw.split('::').last : raw;
    for (final part in body.split(';')) {
      final eq = part.indexOf('=');
      if (eq > 0) props[part.substring(0, eq).trim()] = part.substring(eq + 1).trim();
    }
    return props;
  }

  // ── RSA Key Management ────────────────────────────────────────────────────

  static const _kN  = 'adb_rsa_n';
  static const _kE  = 'adb_rsa_e';
  static const _kD  = 'adb_rsa_d';
  static const _kP  = 'adb_rsa_p';
  static const _kQ  = 'adb_rsa_q';

  Future<({RSAPrivateKey priv, RSAPublicKey pub})> _loadOrGenerateKeys() async {
    final sp = await SharedPreferences.getInstance();
    final nS = sp.getString(_kN);
    if (nS != null) {
      final n = BigInt.parse(nS,            radix: 36);
      final e = BigInt.parse(sp.getString(_kE)!, radix: 36);
      final d = BigInt.parse(sp.getString(_kD)!, radix: 36);
      final p = BigInt.parse(sp.getString(_kP)!, radix: 36);
      final q = BigInt.parse(sp.getString(_kQ)!, radix: 36);
      return (priv: RSAPrivateKey(n, d, p, q), pub: RSAPublicKey(n, e));
    }

    // Generate new 2048-bit RSA key pair
    final rng = SecureRandom('Fortuna')
      ..seed(KeyParameter(Uint8List.fromList(
          List.generate(32, (_) => Random.secure().nextInt(256)))));

    final gen = RSAKeyGenerator()
      ..init(ParametersWithRandom(
          RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64), rng));

    final pair = gen.generateKeyPair();
    final pub  = pair.publicKey  as RSAPublicKey;
    final priv = pair.privateKey as RSAPrivateKey;

    await sp.setString(_kN, priv.n!.toRadixString(36));
    await sp.setString(_kE, pub.exponent!.toRadixString(36));
    await sp.setString(_kD, priv.d!.toRadixString(36));
    await sp.setString(_kP, priv.p!.toRadixString(36));
    await sp.setString(_kQ, priv.q!.toRadixString(36));

    return (priv: priv, pub: pub);
  }

  // ── Android ADB Public Key Format ─────────────────────────────────────────
  //
  // Encodes RSAPublicKey as the AOSP RSAPublicKey C struct:
  //   int      len;       // number of uint32_t in n[] = 64 for 2048-bit key
  //   uint32_t n0inv;     // -n[0]^-1 mod 2^32  (Montgomery parameter)
  //   uint32_t n[64];     // modulus, little-endian 32-bit words
  //   uint32_t rr[64];    // R^2 mod n, R=2^2048, little-endian words
  //   int      exponent;  // 65537
  //
  // Then base64-encoded + " user@host\0" suffix.

  Uint8List _buildAndroidPublicKey(RSAPublicKey pub) {
    const int W = 64; // words for 2048-bit key

    final n = pub.n!;
    final e = pub.exponent!.toInt();

    // Extract n as W little-endian 32-bit words
    final nW = List<int>.filled(W, 0);
    var tmp = n;
    for (int i = 0; i < W; i++) {
      nW[i] = (tmp & BigInt.parse('0xFFFFFFFF')).toInt();
      tmp >>= 32;
    }

    // n0inv = -n[0]^-1 mod 2^32  (Newton's method, 5 iterations)
    final n0inv = _n0inv(nW[0]);

    // rr = (2^2048)^2 mod n = 2^4096 mod n
    final R  = BigInt.one << 2048;
    final rr = (R * R) % n;
    final rrW = List<int>.filled(W, 0);
    var tmp2 = rr;
    for (int i = 0; i < W; i++) {
      rrW[i] = (tmp2 & BigInt.parse('0xFFFFFFFF')).toInt();
      tmp2 >>= 32;
    }

    // Assemble struct (4 + 4 + W*4 + W*4 + 4 = 524 bytes for 2048-bit)
    final bd = ByteData(4 + 4 + W * 4 + W * 4 + 4);
    int off = 0;
    bd.setInt32 (off, W,     Endian.little); off += 4; // len
    bd.setUint32(off, n0inv, Endian.little); off += 4; // n0inv
    for (final w in nW)  { bd.setUint32(off, w, Endian.little); off += 4; }
    for (final w in rrW) { bd.setUint32(off, w, Endian.little); off += 4; }
    bd.setInt32 (off, e,     Endian.little);            // exponent

    final b64  = base64.encode(bd.buffer.asUint8List());
    final full = '$b64 TVCleanzer@phone\x00';
    return Uint8List.fromList(utf8.encode(full));
  }

  /// -n0^-1 mod 2^32  using 5 Newton iterations (BigInt to avoid overflow).
  int _n0inv(int n0) {
    final N = BigInt.from(n0);
    final M = BigInt.from(1) << 32; // 2^32
    BigInt x = BigInt.one;
    for (int i = 0; i < 5; i++) {
      x = (x * (BigInt.two - N * x)) % M;
      if (x.isNegative) x += M;
    }
    final neg = (M - x) % M;
    return neg.toInt();
  }
}
