import 'dart:math';
import 'dart:typed_data';

import '../models/tv_device.dart';
import 'adb_client.dart';

/// A pretend Android TV that lives inside the app. Lets people (and app store
/// reviewers) try every screen without a TV: the same scan, clean, boost,
/// launcher and remote code runs, only the shell answers come from here.
class DemoTv {
  static const host = 'demo.tv';

  static TvDevice device() => TvDevice.fromAdb(
        ip: host,
        brand: 'Demo',
        model: 'Android TV',
        androidVer: '12',
        sdkVersion: 31,
        ramMb: _memTotalKb ~/ 1024,
        ramFreeMb: _state._memAvailKb ~/ 1024,
      );

  static const _memTotalKb = 2027520;

  // package -> RSS in KB while running
  static const _system = <String, int>{
    'android': 0,
    'com.android.systemui': 96000,
    'com.android.tv.settings': 41000,
    'com.android.providers.settings': 0,
    'com.android.bluetooth': 22000,
    'com.android.packageinstaller': 0,
    'com.android.shell': 0,
    'com.android.vending': 61000,
    'com.google.android.gms': 164000,
    'com.google.android.gsf': 0,
    'com.google.android.webview': 0,
    'com.google.android.leanback.ime': 18000,
    'com.google.android.tv.remote.service': 15000,
    'com.google.android.tungsten.setupwraith': 0,
    'com.google.android.apps.tv.launcherx': 212000,
    'com.mediatek.tvinput': 27000,
  };
  static const _junk = <String, int>{
    'com.google.android.tvrecommendations': 64000,
    'tv.samba.ssm': 38000,
    'fusion.android.tv.demo': 31000,
    'com.android.adservices.api': 22000,
    'com.qterics.da.product': 18000,
    'com.google.android.feedback': 12000,
    'com.google.android.partnersetup': 9000,
    'com.android.ondevicepersonalization.services': 8000,
    'com.android.federatedcompute.services': 7000,
    'com.google.android.tv.bugreportsender': 6000,
    'com.google.android.play.games': 0,
    'com.google.android.syncadapters.calendar': 0,
    'com.android.printspooler': 0,
    'com.android.tv.feedbackconsent': 0,
    'com.google.android.onetimeinitializer': 0,
    'android.autoinstalls.config.google.gtvpai': 0,
  };
  static const _features = <String, int>{
    'com.google.android.katniss': 48000,
    'com.google.android.apps.tv.dreamx': 42000,
    'com.google.android.apps.mediashell': 55000,
    'com.google.android.videos': 0,
    'com.google.android.youtube.tvmusic': 0,
    'com.google.android.marvin.talkback': 0,
    'com.netflix.ninja': 36000,
    'com.amazon.amazonvideo.livingroom': 0,
  };
  static const _apps = <String, int>{
    'com.google.android.youtube.tv': 180000,
    'org.videolan.vlc': 0,
    'com.spotify.tv.android': 0,
  };
  static const _labels = <String, String>{
    'com.google.android.youtube.tv': 'YouTube',
    'com.netflix.ninja': 'Netflix',
    'com.amazon.amazonvideo.livingroom': 'Prime Video',
    'com.google.android.youtube.tvmusic': 'YouTube Music',
    'com.google.android.videos': 'Google TV',
    'org.videolan.vlc': 'VLC',
    'com.spotify.tv.android': 'Spotify',
    'com.android.vending': 'Google Play',
    'com.android.tv.settings': 'Settings',
  };
  static const _launchable = [
    'com.google.android.youtube.tv', 'com.netflix.ninja', 'com.amazon.amazonvideo.livingroom',
    'com.google.android.youtube.tvmusic', 'com.google.android.videos', 'org.videolan.vlc',
    'com.spotify.tv.android', 'com.android.vending', 'com.android.tv.settings',
  ];

  static final _state = _DemoState();

  /// Starts the demo TV over from scratch (nothing removed, stock launcher).
  static void reset() => _state.reset();
}

class _DemoState {
  _DemoState() { reset(); }

  final removed = <String>{};
  final settings = <String, String>{};
  final secure = <String, String>{};
  bool launcherInstalled = false;
  String home = 'com.google.android.apps.tv.launcherx/.MainActivity';
  List<String> favorites = [];
  Set<String> hidden = {};
  Set<String> kidsApps = {};
  bool kids = false;
  bool pin = false;
  bool wallpaper = false;
  int _extraFreeKb = 0;
  int dataFreeKb = 5120000;

  void reset() {
    removed.clear();
    settings
      ..clear()
      ..addAll({'window_animation_scale': '1.0', 'transition_animation_scale': '1.0'});
    secure.clear();
    launcherInstalled = false;
    home = 'com.google.android.apps.tv.launcherx/.MainActivity';
    favorites = ['com.google.android.youtube.tv', 'com.netflix.ninja', 'org.videolan.vlc'];
    hidden = {};
    kidsApps = {};
    kids = false;
    pin = false;
    wallpaper = false;
    _extraFreeKb = 0;
    dataFreeKb = 5120000;
  }

  Map<String, int> get all => {
        ...DemoTv._system, ...DemoTv._junk, ...DemoTv._features, ...DemoTv._apps,
        if (launcherInstalled) 'com.tvcleanzer.launcher': 9000,
      };

  Iterable<String> get installed => all.keys.where((p) => !removed.contains(p));

  int get _memAvailKb {
    // what removed packages no longer use, plus what boost freed
    final freed = all.entries.where((e) => removed.contains(e.key)).fold(0, (s, e) => s + e.value);
    return 431000 + freed + _extraFreeKb;
  }
}

/// [AdbClient] stand-in that answers like a real TV would.
class DemoAdbClient extends AdbClient {
  DemoAdbClient() : super(host: DemoTv.host);

  static final _rnd = Random();
  _DemoState get _s => DemoTv._state;

  Future<void> _lag([int base = 40]) =>
      Future.delayed(Duration(milliseconds: base + _rnd.nextInt(base)));

  @override
  Future<Map<String, String>> connect({
    Duration timeout = const Duration(seconds: 10),
    Duration pairingTimeout = const Duration(seconds: 60),
  }) async {
    await _lag(250);
    return {
      'ro.product.brand': 'Demo',
      'ro.product.model': 'Android TV',
      'ro.build.version.release': '12',
      'ro.build.version.sdk': '31',
    };
  }

  @override
  void close() {}

  @override
  Future<String> execWithInput(String command, Uint8List input,
      {Duration timeout = const Duration(seconds: 60)}) async {
    await _lag(600);
    if (command.startsWith('cmd package install')) {
      _s.launcherInstalled = true;
      return 'Success\n';
    }
    if (command.contains('wallpaper.jpg')) _s.wallpaper = true;
    return '';
  }

  @override
  Future<String> shell(String command,
      {Duration timeout = const Duration(seconds: 30)}) async {
    await _lag();
    final c = command.trim();
    final s = _s;

    String meminfo() =>
        'MemTotal:        ${DemoTv._memTotalKb} kB\n'
        'MemFree:         ${s._memAvailKb ~/ 3} kB\n'
        'MemAvailable:    ${s._memAvailKb} kB\n';

    if (c.startsWith('getprop ro.product.brand')) {
      return 'Demo\nAndroid TV\n12\n31\n${meminfo()}';
    }
    if (c == 'getprop ro.build.version.sdk') return '31\n';
    if (c.startsWith('head -3 /proc/meminfo')) return meminfo();
    if (c.startsWith('df -k /data')) {
      return 'Filesystem 1K-blocks Used Available Use% Mounted on\n'
          '/dev/block/dm-5 12058624 ${12058624 - s.dataFreeKb} ${s.dataFreeKb} 58% /data\n';
    }
    if (c == 'pm list packages') {
      return s.installed.map((p) => 'package:$p').join('\n');
    }
    if (c.startsWith('cmd package query-activities') && c.contains('category.HOME')) {
      return [
        'com.google.android.apps.tv.launcherx/.MainActivity',
        'com.google.android.tungsten.setupwraith/.RecoveryActivity',
        if (s.launcherInstalled) 'com.tvcleanzer.launcher/.HomeActivity',
      ].map((l) => '  $l').join('\n');
    }
    if (c.startsWith('cmd package query-activities')) {
      return DemoTv._launchable
          .where((p) => !s.removed.contains(p))
          .map((p) => '  $p/.MainActivity')
          .join('\n');
    }
    if (c.startsWith('ps')) {
      final b = StringBuffer('RSS NAME\n');
      s.all.forEach((p, kb) {
        if (kb > 0 && !s.removed.contains(p)) b.writeln('$kb $p');
      });
      return b.toString();
    }
    if (c.startsWith('pm uninstall -k --user 0 ')) {
      await _lag(150);
      s.removed.add(c.split(' ').last);
      return 'Success\n';
    }
    if (c.startsWith('pm install-existing ') || c.startsWith('cmd package install-existing ')) {
      final p = c.split(' ').last;
      s.removed.remove(p);
      return 'Package $p installed for user: 0\n';
    }
    if (c == 'pm uninstall com.tvcleanzer.launcher') {
      s.launcherInstalled = false;
      s.home = 'com.google.android.apps.tv.launcherx/.MainActivity';
      return 'Success\n';
    }
    if (c.startsWith('settings get global ')) return '${s.settings[c.split(' ').last] ?? 'null'}\n';
    if (c.startsWith('settings put global ')) {
      final p = c.split(' ');
      s.settings[p[3]] = p[4];
      return '';
    }
    if (c.startsWith('settings delete global ')) {
      s.settings.remove(c.split(' ').last);
      return '';
    }
    if (c.startsWith('settings get secure ')) return '${s.secure[c.split(' ').last] ?? 'null'}\n';
    if (c.startsWith('settings put secure ')) {
      final p = c.split(' ');
      s.secure[p[3]] = p.sublist(4).join(' ').replaceAll("'", '');
      return '';
    }
    if (c.startsWith('settings delete secure ')) {
      s.secure.remove(c.split(' ').last);
      return '';
    }
    if (c == 'am kill-all') {
      await _lag(300);
      s._extraFreeKb = min(s._extraFreeKb + 186000, 400000);
      return '';
    }
    if (c.startsWith('pm trim-caches')) {
      await _lag(500);
      s.dataFreeKb += 655360;
      return '';
    }
    if (c.contains('resolve-activity') && c.contains('category.HOME')) return '${s.home}\n';
    if (c == 'pm path com.tvcleanzer.launcher') {
      return s.launcherInstalled ? 'package:/data/app/com.tvcleanzer.launcher/base.apk\n' : '';
    }
    if (c.startsWith('cmd role add-role-holder android.app.role.HOME ') ||
        c.startsWith('cmd package set-home-activity ')) {
      final p = c.split(' ').last.split('/').first;
      if (p == 'com.tvcleanzer.launcher' && s.launcherInstalled) {
        s.home = 'com.tvcleanzer.launcher/.HomeActivity';
      }
      return '';
    }
    if (c.startsWith('am broadcast') && c.contains('com.tvcleanzer.launcher.APPLY')) {
      _applyBroadcast(c);
      return 'Broadcast completed: result=0\n';
    }
    if (c.startsWith('content query') && c.endsWith('/apps')) return _appsRows();
    if (c.startsWith('content query') && c.endsWith('/settings')) {
      return 'Row: 0 key=kids, value=${s.kids ? 1 : 0}\n'
          'Row: 1 key=pin, value=${s.pin ? 1 : 0}\n'
          'Row: 2 key=wallpaper, value=${s.wallpaper ? 1 : 0}\n';
    }
    // input keyevent / input text / getprop … — a TV just does it
    return '';
  }

  String _appsRows() {
    final b = StringBuffer();
    var i = 0;
    for (final p in DemoTv._launchable) {
      if (_s.removed.contains(p)) continue;
      final fav = _s.favorites.indexOf(p);
      b.writeln('Row: ${i++} pkg=$p, fav=$fav, hidden=${_s.hidden.contains(p) ? 1 : 0}, '
          'kids=${_s.kidsApps.contains(p) ? 1 : 0}, label=${DemoTv._labels[p] ?? p}');
    }
    return b.toString();
  }

  void _applyBroadcast(String c) {
    List<String> list(String key) {
      final m = RegExp('--esa $key (\\S+)').firstMatch(c);
      if (m == null) return const [];
      final v = m.group(1)!;
      return v == '""' ? [] : v.split(',');
    }
    if (c.contains('--esa favorites ')) _s.favorites = list('favorites');
    if (c.contains('--esa hidden ')) _s.hidden = list('hidden').toSet();
    if (c.contains('--esa kidsApps ')) _s.kidsApps = list('kidsApps').toSet();
    if (RegExp(r'--es pin \d+').hasMatch(c)) _s.pin = true;
    final k = RegExp(r'--ez kids (true|false)').firstMatch(c);
    if (k != null) _s.kids = k.group(1) == 'true' && _s.pin;
    if (c.contains('--es wallpaper none')) _s.wallpaper = false;
    if (c.contains('--es wallpaper set')) _s.wallpaper = true;
  }
}
