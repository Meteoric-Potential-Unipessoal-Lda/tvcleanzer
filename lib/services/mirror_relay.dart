import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'adb_client.dart';

/// The third road for «Повтор экрана», for TVs whose firewall lets nothing in to an app's port
/// (Vladimir's TV dropped port 7300): the phone's mirror service connects to this loopback
/// port, and we carry its bytes over the ADB connection that already works — adbd on the TV
/// opens localhost:7300 (`tcp:` service), where the launcher's MirrorActivity listens.
class MirrorRelay {
  MirrorRelay._(this._srv, this._host, this._port, this._tvPort);

  final ServerSocket _srv;
  final String _host;
  final int _port;
  final int _tvPort;
  final _links = <void Function()>[];
  bool _closed = false;

  int get port => _srv.port;

  static Future<MirrorRelay> start({required String host, required int adbPort, required int tvPort}) async {
    final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final r = MirrorRelay._(srv, host, adbPort, tvPort);
    srv.listen(r._carry, onError: (_) {});
    return r;
  }

  Future<void> _carry(Socket local) async {
    if (_closed) {
      local.destroy();
      return;
    }
    final adb = AdbClient.open(host: _host, port: _port);
    AdbStream? st;
    StreamSubscription<Uint8List>? up, down;
    var done = false;
    void end() {
      if (done) return;
      done = true;
      up?.cancel();
      down?.cancel();
      st?.close();
      adb.close();
      local.destroy();
    }

    _links.add(end);
    try {
      local.setOption(SocketOption.tcpNoDelay, true);
      await adb.connect();
      // fails while the TV screen is not listening yet: the phone tries again
      final s = st = await adb.openStream('tcp:$_tvPort', timeout: const Duration(seconds: 5));
      down = s.data.listen((d) => local.add(d), onDone: end, onError: (_) => end());
      up = local.listen((d) async {
        up?.pause(); // one piece at a time: Wi-Fi sets the pace, the phone skips frames
        try {
          await s.write(d, chunk: 256 * 1024);
        } catch (_) {
          end();
          return;
        }
        up?.resume();
      }, onDone: end, onError: (_) => end(), cancelOnError: true);
    } catch (_) {
      end();
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _srv.close();
    for (final e in List.of(_links)) {
      e();
    }
    _links.clear();
  }
}
