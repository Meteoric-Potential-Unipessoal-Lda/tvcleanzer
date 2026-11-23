import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A TV that answers on the network before debugging is on (connection guide, stage 2).
class SeenTv {
  final String ip;

  /// 'android' (Google Cast / Android TV remote service), 'samsung' (Tizen), 'lg' (webOS),
  /// 'roku'.
  final String kind;
  final String? name;
  final String? maker;
  final String? model;

  /// Port 5555 already open: the normal search connects to it.
  final bool adb;
  const SeenTv(this.ip, this.kind, {this.name, this.maker, this.model, this.adb = false});

  bool get notAndroid => kind != 'android';

  /// «Sony BRAVIA 4K», else the name the owner gave it, else the platform.
  String get title {
    final mm = [maker, model].whereType<String>().where((s) => s.trim().isNotEmpty).join(' ').trim();
    if (mm.isNotEmpty) return mm;
    if (name != null && name!.trim().isNotEmpty) return name!.trim();
    return switch (kind) { 'samsung' => 'Samsung', 'lg' => 'LG', 'roku' => 'Roku', _ => 'Android TV' };
  }

  /// For the brand list: Samsung and LG are known even without a maker string.
  String? get brandHint => maker ?? switch (kind) { 'samsung' => 'Samsung', 'lg' => 'LG', _ => null };

  @override
  String toString() => '$kind${adb ? '+adb' : ''} ${maker ?? ''} ${model ?? ''}'.trim();
}

/// Knocks on the ports TVs keep open for casting and their remote apps: an Android TV with
/// debugging off still answers on Google Cast (8009) or the Android TV remote (6466), Samsung
/// on 8001, LG on 3000, Roku on 8060. Plain TCP and HTTP, no plugin, no multicast — so it
/// works on iPhones without Apple's multicast entitlement too.
class TvSniffer {
  static const castHttp = 8008, cast = 8009, atvRemote = 6466, samsung = 8001, lg = 3000, roku = 8060, adb = 5555;
  static const _knockTimeout = Duration(milliseconds: 600);
  static const _httpTimeout = Duration(seconds: 2);

  /// true: open; false: refused (the host is there); null: silence.
  static Future<bool?> knock(String ip, int port) async {
    try {
      final s = await Socket.connect(ip, port, timeout: _knockTimeout);
      s.destroy();
      return true;
    } on SocketException catch (e) {
      final code = e.osError?.errorCode;
      // ECONNREFUSED: Linux/Android 111, macOS/iOS 61, Windows 10061
      if (code == 111 || code == 61 || code == 10061) return false;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Every TV among [hosts] that answers on a TV port. [concurrency] hosts at a time
  /// (6 sockets each: iPhones allow 256 open files).
  static Future<List<SeenTv>> sniff(List<String> hosts, {int concurrency = 24}) async {
    final out = <SeenTv>[];
    for (var i = 0; i < hosts.length; i += concurrency) {
      final part = hosts.sublist(i, i + concurrency > hosts.length ? hosts.length : i + concurrency);
      final found = await Future.wait(part.map(probe));
      out.addAll(found.whereType<SeenTv>());
    }
    return out;
  }

  static Future<SeenTv?> probe(String ip) async {
    final r = await Future.wait([
      knock(ip, cast), knock(ip, atvRemote), knock(ip, samsung), knock(ip, lg), knock(ip, roku), knock(ip, adb),
    ]);
    final hasAdb = r[5] == true;
    if (r[2] == true) {
      final info = _parseSamsung(await _get('http://$ip:$samsung/api/v2/'));
      if (info != null || r[0] != true) {
        return SeenTv(ip, 'samsung', name: info?.$1, maker: 'Samsung', model: info?.$2, adb: hasAdb);
      }
    }
    if (r[3] == true && r[0] != true && r[1] != true) return SeenTv(ip, 'lg', maker: 'LG', adb: hasAdb);
    if (r[4] == true) {
      final info = parseRoku(await _get('http://$ip:$roku/query/device-info'));
      return SeenTv(ip, 'roku', name: info?.$1, maker: info?.$2 ?? 'Roku', model: info?.$3, adb: hasAdb);
    }
    if (r[0] == true || r[1] == true) {
      final info = parseEureka(await _get('http://$ip:$castHttp/setup/eureka_info?params=name,device_info'));
      // a Cast speaker or display is not a TV
      if (info != null && isSpeaker(info.$3)) return null;
      return SeenTv(ip, 'android', name: info?.$1, maker: info?.$2, model: info?.$3, adb: hasAdb);
    }
    return null;
  }

  static Future<String?> _get(String url) async {
    final c = HttpClient()..connectionTimeout = _httpTimeout;
    try {
      final req = await c.getUrl(Uri.parse(url)).timeout(_httpTimeout);
      final res = await req.close().timeout(_httpTimeout);
      if (res.statusCode != 200) return null;
      return await res.transform(utf8.decoder).join().timeout(_httpTimeout);
    } catch (_) {
      return null;
    } finally {
      c.close(force: true);
    }
  }

  static String? _s(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;

  /// Google Cast `eureka_info`: (name, manufacturer, model).
  static (String?, String?, String?)? parseEureka(String? body) {
    if (body == null) return null;
    try {
      final j = jsonDecode(body);
      if (j is! Map) return null;
      final di = j['device_info'];
      final d = di is Map ? di : const {};
      return (_s(j['name']), _s(d['manufacturer']), _s(d['model_name']));
    } catch (_) {
      return null;
    }
  }

  /// Samsung `/api/v2/`: (name, model).
  static (String?, String?)? _parseSamsung(String? body) => parseSamsung(body);
  static (String?, String?)? parseSamsung(String? body) {
    if (body == null) return null;
    try {
      final j = jsonDecode(body);
      final d = j is Map ? j['device'] : null;
      if (d is! Map) return null;
      return (_s(d['name']), _s(d['modelName']));
    } catch (_) {
      return null;
    }
  }

  /// Roku `device-info` XML: (name, vendor, model).
  static (String?, String?, String?)? parseRoku(String? body) {
    if (body == null) return null;
    String? tag(String t) => _s(RegExp('<$t>([^<]*)</$t>').firstMatch(body)?.group(1));
    final r = (tag('user-device-name') ?? tag('friendly-device-name'), tag('vendor-name'), tag('model-name'));
    return r.$1 == null && r.$2 == null && r.$3 == null ? null : r;
  }

  static bool isSpeaker(String? model) {
    final m = (model ?? '').toLowerCase();
    return const ['home', 'nest', 'speaker', 'audio', 'hub', 'soundbar'].any(m.contains);
  }
}
