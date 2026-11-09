import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── ADB protocol constants ───────────────────────────────────────────────────

const int _cmdCnxn = 0x4E584E43;
const int _cmdAuth = 0x48545541;
const int _cmdOpen = 0x4E45504F;
const int _cmdOkay = 0x59414B4F;
const int _cmdClse = 0x45534C43;
const int _cmdWrte = 0x45545257;

const int _authToken = 1;
const int _authSignature = 2;
const int _authRsaPublicKey = 3;

const int _adbVersion = 0x01000000; // legacy version → checksums are sent
const int _maxPayload = 1 << 20; // 1 MB

/// DER prefix of a SHA-1 DigestInfo (PKCS#1 v1.5).
const List<int> _sha1DigestInfo = [
  0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e,
  0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14,
];

// ─── Exceptions ───────────────────────────────────────────────────────────────

class AdbException implements Exception {
  final String message;
  AdbException(this.message);
  @override
  String toString() => 'AdbException: $message';
}

class AdbAuthException extends AdbException {
  AdbAuthException(super.message);
  @override
  String toString() => 'AdbAuthException: $message';
}

// ─── Message ──────────────────────────────────────────────────────────────────

class _Msg {
  final int cmd, arg0, arg1;
  final Uint8List data;
  _Msg(this.cmd, this.arg0, this.arg1, [Uint8List? data])
      : data = data ?? Uint8List(0);

  Uint8List encode() {
    var sum = 0;
    for (final b in data) {
      sum = (sum + b) & 0xFFFFFFFF;
    }
    final out = Uint8List(24 + data.length);
    final hdr = ByteData.view(out.buffer, 0, 24);
    hdr.setUint32(0, cmd, Endian.little);
    hdr.setUint32(4, arg0, Endian.little);
    hdr.setUint32(8, arg1, Endian.little);
    hdr.setUint32(12, data.length, Endian.little);
    hdr.setUint32(16, sum, Endian.little);
    hdr.setUint32(20, cmd ^ 0xFFFFFFFF, Endian.little);
    out.setAll(24, data);
    return out;
  }
}

class _Keys {
  final BigInt n, e, d;
  _Keys(this.n, this.e, this.d);
}

Uint8List _cString(String s) => Uint8List.fromList(utf8.encode('$s\x00'));

// ─── ADB client ───────────────────────────────────────────────────────────────

/// Minimal ADB client over TCP (port 5555, "ADB over network").
///
///   final adb = AdbClient(host: '192.168.1.100');
///   await adb.connect();              // RSA auth; TV may ask "Allow debugging?"
///   final out = await adb.shell('pm list packages');
///   adb.close();
///
/// Incoming messages go into a single queue that is read in order, so nothing
/// is lost when several messages arrive in one TCP chunk.
class AdbClient {
  final String host;
  final int port;

  AdbClient({required this.host, this.port = 5555});

  Socket? _sock;
  StreamSubscription<Uint8List>? _sockSub;
  final List<int> _buf = [];
  final Queue<_Msg> _inbox = Queue<_Msg>();
  Completer<void>? _waiter;
  Object? _sockError;
  bool _sockClosed = false;
  int _nextLocalId = 1;
  int _peerMaxData = 4096; // from the TV's CNXN; safe default for old adbd

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Connects and authenticates; returns the device banner properties.
  /// The first time this phone connects, the TV shows an "Allow debugging?"
  /// dialog; we wait up to [pairingTimeout] for the user to accept it.
  Future<Map<String, String>> connect({
    Duration timeout = const Duration(seconds: 10),
    Duration pairingTimeout = const Duration(seconds: 60),
  }) async {
    final keys = await _keys();

    _sock = await Socket.connect(host, port, timeout: timeout);
    _sock!.setOption(SocketOption.tcpNoDelay, true);
    _sockSub = _sock!.listen(
      _onData,
      onError: (Object e) {
        _sockError = e;
        _wake();
      },
      onDone: () {
        _sockClosed = true;
        _wake();
      },
      cancelOnError: true,
    );

    _send(_Msg(_cmdCnxn, _adbVersion, _maxPayload, _cString('host::')));

    var msg = await _read(timeout,
        'TV did not respond. Make sure network debugging is enabled.');
    if (msg.cmd == _cmdCnxn) return _parseCnxn(msg); // auth disabled on TV
    if (msg.cmd != _cmdAuth || msg.arg0 != _authToken) {
      throw AdbAuthException(
          'Expected AUTH token, got 0x${msg.cmd.toRadixString(16)}');
    }

    // Known key → TV answers CNXN. Unknown key → TV sends a new token.
    _send(_Msg(_cmdAuth, _authSignature, 0, _sign(msg.data, keys)));
    msg = await _read(timeout, 'No auth response from TV.');
    if (msg.cmd == _cmdCnxn) return _parseCnxn(msg);

    if (msg.cmd == _cmdAuth && msg.arg0 == _authToken) {
      _send(_Msg(_cmdAuth, _authRsaPublicKey, 0, _androidPublicKey(keys)));
      msg = await _read(pairingTimeout,
          'Timed out waiting for approval on the TV. Tap "Allow" and try again.');
      if (msg.cmd == _cmdCnxn) return _parseCnxn(msg);
      throw AdbAuthException('TV rejected the connection.');
    }

    throw AdbAuthException(
        'Unexpected auth response: 0x${msg.cmd.toRadixString(16)}');
  }

  /// Runs [command] via the `shell:` service and returns its full output.
  /// [timeout] is an inactivity timeout between messages.
  Future<String> shell(String command,
      {Duration timeout = const Duration(seconds: 30)}) async {
    final localId = _nextLocalId++;
    _send(_Msg(_cmdOpen, localId, 0, _cString('shell:$command')));

    int? remoteId;
    final out = BytesBuilder(copy: false);
    while (true) {
      final m = await _read(timeout, 'Shell command timed out: $command');
      if (m.arg1 != localId) continue; // belongs to another stream
      switch (m.cmd) {
        case _cmdOkay:
          remoteId ??= m.arg0;
        case _cmdWrte:
          remoteId ??= m.arg0;
          out.add(m.data);
          _send(_Msg(_cmdOkay, localId, remoteId));
        case _cmdClse:
          if (remoteId == null) {
            throw AdbException('TV refused the command: $command');
          }
          return utf8.decode(out.takeBytes(), allowMalformed: true);
      }
    }
  }

  /// Runs [command] via the `exec:` service and streams [input] to its stdin,
  /// e.g. `cmd package install -S <size>` with the APK bytes (Android 7+).
  /// Returns everything the command printed.
  Future<String> execWithInput(String command, Uint8List input,
      {Duration timeout = const Duration(seconds: 60)}) async {
    final localId = _nextLocalId++;
    _send(_Msg(_cmdOpen, localId, 0, _cString('exec:$command')));
    final out = BytesBuilder(copy: false);

    // Wait for the stream to open.
    int? remoteId;
    while (remoteId == null) {
      final m = await _read(timeout, 'Command timed out: $command');
      if (m.arg1 != localId) continue;
      if (m.cmd == _cmdOkay) {
        remoteId = m.arg0;
      } else if (m.cmd == _cmdClse) {
        throw AdbException('TV refused the command: $command');
      }
    }

    // Send the data chunk by chunk; every WRTE must be acknowledged with OKAY.
    final chunk = min(_peerMaxData, 64 * 1024);
    var off = 0;
    while (off < input.length) {
      final end = min(off + chunk, input.length);
      _send(_Msg(_cmdWrte, localId, remoteId, Uint8List.sublistView(input, off, end)));
      off = end;
      while (true) {
        final m = await _read(timeout, 'Upload timed out: $command');
        if (m.arg1 != localId) continue;
        if (m.cmd == _cmdOkay) break;
        if (m.cmd == _cmdWrte) {
          out.add(m.data);
          _send(_Msg(_cmdOkay, localId, remoteId));
        } else if (m.cmd == _cmdClse) {
          return utf8.decode(out.takeBytes(), allowMalformed: true); // ended early
        }
      }
    }

    // Read the command's answer until the TV closes the stream.
    while (true) {
      final m = await _read(timeout, 'Command timed out: $command');
      if (m.arg1 != localId) continue;
      if (m.cmd == _cmdWrte) {
        out.add(m.data);
        _send(_Msg(_cmdOkay, localId, remoteId));
      } else if (m.cmd == _cmdClse) {
        return utf8.decode(out.takeBytes(), allowMalformed: true);
      }
    }
  }

  void close() {
    _sockSub?.cancel();
    _sock?.destroy();
    _sock = null;
    _sockClosed = true;
    _wake();
  }

  // ── Socket plumbing ─────────────────────────────────────────────────────────

  void _send(_Msg msg) => _sock?.add(msg.encode());

  void _onData(Uint8List chunk) {
    _buf.addAll(chunk);
    while (_buf.length >= 24) {
      final hdr = ByteData.sublistView(Uint8List.fromList(_buf.sublist(0, 24)));
      final cmd = hdr.getUint32(0, Endian.little);
      final magic = hdr.getUint32(20, Endian.little);
      final len = hdr.getUint32(12, Endian.little);
      if (magic != (cmd ^ 0xFFFFFFFF) || len > _maxPayload) {
        _sockError = AdbException('Corrupted ADB stream');
        _wake();
        close();
        return;
      }
      if (_buf.length < 24 + len) break;
      final data = Uint8List.fromList(_buf.sublist(24, 24 + len));
      _buf.removeRange(0, 24 + len);
      _inbox.add(_Msg(cmd, hdr.getUint32(4, Endian.little),
          hdr.getUint32(8, Endian.little), data));
    }
    _wake();
  }

  void _wake() {
    final w = _waiter;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<_Msg> _read(Duration timeout, String timeoutMessage) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (_inbox.isNotEmpty) return _inbox.removeFirst();
      if (_sockError != null) throw AdbException('Connection error: $_sockError');
      if (_sockClosed) throw AdbException('TV closed the connection.');
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) throw AdbException(timeoutMessage);
      final w = _waiter = Completer<void>();
      try {
        await w.future.timeout(left);
      } on TimeoutException {
        throw AdbException(timeoutMessage);
      } finally {
        _waiter = null;
      }
    }
  }

  Map<String, String> _parseCnxn(_Msg msg) {
    if (msg.arg1 > 0) _peerMaxData = msg.arg1;
    // Banner: "device::ro.product.name=…;ro.product.model=…;features=…"
    final raw =
        utf8.decode(msg.data, allowMalformed: true).replaceAll('\x00', '');
    final body = raw.contains('::') ? raw.split('::').last : raw;
    final props = <String, String>{};
    for (final part in body.split(';')) {
      final eq = part.indexOf('=');
      if (eq > 0) {
        props[part.substring(0, eq).trim()] = part.substring(eq + 1).trim();
      }
    }
    return props;
  }

  // ── Signing ─────────────────────────────────────────────────────────────────
  //
  // adbd verifies with RSA_verify(NID_sha1, token, …): the 20-byte token is
  // used AS the digest, it must not be hashed again. So we build the
  // PKCS#1 v1.5 block by hand: 00 01 FF…FF 00 DigestInfo(SHA-1) token.

  static Uint8List _sign(Uint8List token, _Keys k) {
    const len = 256; // 2048-bit key
    final t = [..._sha1DigestInfo, ...token];
    final em = Uint8List(len);
    em[1] = 0x01;
    final sep = len - t.length - 1;
    for (var i = 2; i < sep; i++) {
      em[i] = 0xFF;
    }
    em.setAll(sep + 1, t);
    return _toBytes(_fromBytes(em).modPow(k.d, k.n), len);
  }

  static BigInt _fromBytes(List<int> bytes) {
    var r = BigInt.zero;
    for (final b in bytes) {
      r = (r << 8) | BigInt.from(b);
    }
    return r;
  }

  static Uint8List _toBytes(BigInt v, int len) {
    final out = Uint8List(len);
    final mask = BigInt.from(0xFF);
    for (var i = len - 1; i >= 0; i--) {
      out[i] = (v & mask).toInt();
      v >>= 8;
    }
    return out;
  }

  // ── Keys ────────────────────────────────────────────────────────────────────
  //
  // One RSA-2048 key per phone install, kept in SharedPreferences. The TV
  // remembers it after "Always allow", so later connections need no dialog.

  static const _kN = 'adb_rsa_n';
  static const _kE = 'adb_rsa_e';
  static const _kD = 'adb_rsa_d';

  static Future<_Keys>? _keysFuture;

  /// Creates the RSA key ahead of time (first launch: a few seconds of work in
  /// a background isolate), so the first TV connection is fast.
  static Future<void> warmUp() => _keys();

  /// Whether this install already has its ADB key.
  static Future<bool> hasKeys() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return sp.getString(_kN) != null;
    } catch (_) {
      return false;
    }
  }

  static Future<_Keys> _keys() =>
      _keysFuture ??= _loadOrGenerateKeys().catchError((Object e) {
        _keysFuture = null;
        throw e;
      });

  static Future<_Keys> _loadOrGenerateKeys() async {
    final sp = await SharedPreferences.getInstance();
    final n = sp.getString(_kN), e = sp.getString(_kE), d = sp.getString(_kD);
    if (n != null && e != null && d != null) {
      return _Keys(BigInt.parse(n, radix: 36), BigInt.parse(e, radix: 36),
          BigInt.parse(d, radix: 36));
    }
    // Key generation takes a few seconds in pure Dart — keep it off the UI thread.
    final parts = await Isolate.run(_generateKeyPair);
    await sp.setString(_kN, parts[0].toRadixString(36));
    await sp.setString(_kE, parts[1].toRadixString(36));
    await sp.setString(_kD, parts[2].toRadixString(36));
    return _Keys(parts[0], parts[1], parts[2]);
  }

  static List<BigInt> _generateKeyPair() {
    final seed = Random.secure();
    final rng = FortunaRandom()
      ..seed(KeyParameter(
          Uint8List.fromList(List.generate(32, (_) => seed.nextInt(256)))));
    final gen = RSAKeyGenerator()
      ..init(ParametersWithRandom(
          RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64), rng));
    final pair = gen.generateKeyPair();
    final priv = pair.privateKey as RSAPrivateKey;
    return [priv.modulus!, BigInt.from(65537), priv.privateExponent!];
  }

  // ── Android public key format ───────────────────────────────────────────────
  //
  // AOSP RSAPublicKey struct, little-endian:
  //   uint32 len (=64 words) | uint32 n0inv | uint32 n[64] | uint32 rr[64] | uint32 e
  // base64-encoded, followed by " user@host" and a NUL.

  static Uint8List _androidPublicKey(_Keys k) {
    const words = 64;
    final mask = BigInt.from(0xFFFFFFFF);
    final rr = (BigInt.one << 4096) % k.n; // R^2 mod n, R = 2^2048

    final bd = ByteData(4 + 4 + words * 4 * 2 + 4);
    var off = 0;
    void put(int v) {
      bd.setUint32(off, v, Endian.little);
      off += 4;
    }

    put(words);
    put(_n0inv((k.n & mask).toInt()));
    var t = k.n;
    for (var i = 0; i < words; i++, t >>= 32) {
      put((t & mask).toInt());
    }
    t = rr;
    for (var i = 0; i < words; i++, t >>= 32) {
      put((t & mask).toInt());
    }
    put(k.e.toInt());

    return _cString('${base64.encode(bd.buffer.asUint8List())} TVCleanzer@phone');
  }

  /// -n0^-1 mod 2^32 (Newton iteration, 5 rounds = 32 bits).
  static int _n0inv(int n0) {
    final n = BigInt.from(n0);
    final m = BigInt.one << 32;
    var x = BigInt.one;
    for (var i = 0; i < 5; i++) {
      x = (x * (BigInt.two - n * x)) % m;
    }
    return ((m - x) % m).toInt();
  }
}
