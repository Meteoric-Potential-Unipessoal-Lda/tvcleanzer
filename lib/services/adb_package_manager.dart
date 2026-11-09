import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/tv_device.dart';
import 'adb_client.dart';
import 'package_db.dart';
import 'protection.dart';

// ─── Riverpod Provider ────────────────────────────────────────────────────────

final adbServiceProvider = Provider<AdbPackageManager>(
  (ref) => AdbPackageManager(),
);

// ─── Package DB entry ─────────────────────────────────────────────────────────

class _Entry {
  final String label;
  final PackageVerdict verdict;
  final String reason;
  final int sizeMb;
  _Entry({required this.label, required this.verdict, required this.reason, required this.sizeMb});
}

// ─── AdbPackageManager ────────────────────────────────────────────────────────

/// High-level package operations over ADB TCP (port 5555).
///
/// Each method opens its own [AdbClient] connection, performs the work,
/// then closes. This keeps the API stateless and avoids stale connections.
class AdbPackageManager {
  static Map<String, _Entry>? _db;

  // ── Device info ─────────────────────────────────────────────────────────────

  /// Connect to [ip] via ADB and return a populated [TvDevice].
  Future<TvDevice> getDeviceInfo(String ip) async {
    final adb = AdbClient(host: ip);
    try {
      final cnxnProps = await adb.connect();

      // Basic props + memory in one round trip.
      final propOut = await adb.shell(
          'getprop ro.product.brand; '
          'getprop ro.product.model; '
          'getprop ro.build.version.release; '
          'getprop ro.build.version.sdk; '
          'head -3 /proc/meminfo');

      final lines  = propOut.split('\n').map((l) => l.trim()).toList();
      String at(int i) => i < lines.length ? lines[i] : '';
      final brand  = at(0).isNotEmpty ? at(0) : (cnxnProps['ro.product.brand'] ?? '');
      final model  = at(1).isNotEmpty ? at(1) : (cnxnProps['ro.product.model'] ?? 'Android TV');
      final ver    = at(2).isNotEmpty ? at(2) : (cnxnProps['ro.build.version.release'] ?? '?');
      final sdk    = int.tryParse(at(3)) ?? 0;

      // /proc/meminfo: "MemTotal:  2015332 kB", "MemAvailable:  812340 kB"
      int memKb(String key) {
        for (final l in lines.skip(4)) {
          if (l.startsWith('$key:')) {
            final m = RegExp(r'(\d+)').firstMatch(l);
            if (m != null) return int.parse(m.group(1)!);
          }
        }
        return 0;
      }
      final ramMb     = memKb('MemTotal') ~/ 1024;
      final ramFreeMb = (memKb('MemAvailable') > 0
              ? memKb('MemAvailable')
              : memKb('MemFree')) ~/ 1024;

      return TvDevice.fromAdb(
        ip: ip,
        brand: brand,
        model: model,
        androidVer: ver,
        sdkVersion: sdk,
        ramMb: ramMb,
        ramFreeMb: ramFreeMb,
        cnxnProps: cnxnProps,
      );
    } finally {
      adb.close();
    }
  }

  // ── Scan ────────────────────────────────────────────────────────────────────

  /// Scan [device] for installed packages and classify each using the
  /// bundled packages.json database.
  Future<ScanResult> scan(TvDevice device) async {
    final db  = await _loadDb();
    final adb = AdbClient(host: device.ipAddress);
    try {
      await adb.connect();
      final raw = await adb.shell('pm list packages');
      final pkgs = _parsePackageList(raw);

      // What the TV itself says: its home screens (never touched) and the
      // apps visible in its menu (owner's apps: never pre-selected).
      final homes = _parseComponents(await adb.shell(
          'cmd package query-activities --brief -a android.intent.action.MAIN '
          '-c android.intent.category.HOME 2>/dev/null'));
      final launchable = _parseComponents(await adb.shell(
          'cmd package query-activities --brief -a android.intent.action.MAIN '
          '-c android.intent.category.LEANBACK_LAUNCHER 2>/dev/null; '
          'cmd package query-activities --brief -a android.intent.action.MAIN '
          '-c android.intent.category.LAUNCHER 2>/dev/null'));
      // Memory each package uses right now (what removing it frees).
      final ramKb = _parsePsRss(await adb.shell('ps -A -o RSS,NAME 2>/dev/null || ps'));

      final packages = pkgs.map((name) {
        final entry = db[name];
        var verdict = entry?.verdict ?? PackageVerdict.keep;
        if (Protection.isProtected(name) || homes.contains(name)) {
          verdict = PackageVerdict.system;
        } else if (verdict == PackageVerdict.remove && launchable.contains(name)) {
          verdict = PackageVerdict.caution; // a visible app: the owner decides
        }
        return TvPackage(
          packageName: name,
          label:   entry?.label,
          sizeMb:  (ramKb[name] ?? 0) ~/ 1024,
          verdict: verdict,
          reason:  entry?.reason,
        );
      }).toList()
        ..sort((a, b) {
          const order = {
            PackageVerdict.remove:  0,
            PackageVerdict.caution: 1,
            PackageVerdict.keep:    2,
            PackageVerdict.system:  3,
          };
          final o = (order[a.verdict] ?? 2).compareTo(order[b.verdict] ?? 2);
          return o != 0 ? o : b.sizeMb.compareTo(a.sizeMb);
        });

      return ScanResult(
        device:    device,
        packages:  packages,
        scannedAt: DateTime.now(),
      );
    } finally {
      adb.close();
    }
  }

  /// "com.pkg/.Activity" lines -> package names.
  static Set<String> _parseComponents(String out) {
    final re = RegExp(r'^\s*([A-Za-z0-9_.]+)/');
    return out
        .split('\n')
        .map((l) => re.firstMatch(l)?.group(1))
        .whereType<String>()
        .toSet();
  }

  /// RSS (KB) per package from `ps -A -o RSS,NAME` (Android 8+) or plain `ps`.
  static Map<String, int> _parsePsRss(String out) {
    final res = <String, int>{};
    final short = RegExp(r'^\s*(\d+)\s+(\S+)\s*$');
    for (final line in out.split('\n')) {
      int? kb;
      String? name;
      final m = short.firstMatch(line);
      if (m != null) {
        kb = int.tryParse(m.group(1)!);
        name = m.group(2);
      } else {
        final p = line.trim().split(RegExp(r'\s+'));
        if (p.length >= 9) {
          kb = int.tryParse(p[4]);
          name = p.last;
        }
      }
      if (kb == null || name == null) continue;
      final pkg = name.split(':').first;
      res[pkg] = (res[pkg] ?? 0) + kb;
    }
    return res;
  }

  // ── Boost ──────────────────────────────────────────────────────────────────

  static const _animKeys = [
    'window_animation_scale',
    'transition_animation_scale',
    'animator_duration_scale',
  ];

  /// Faster animations (0.5x), close background apps, trim app caches.
  /// Measures free RAM and /data before and after. Animation values are
  /// returned so History can put them back.
  Future<BoostResult> boost(TvDevice device) async {
    final adb = AdbClient(host: device.ipAddress);
    try {
      await adb.connect();
      final before = await _mem(adb);
      final dataBefore = await _dataFreeKb(adb);

      final old = <String, String>{};
      for (final k in _animKeys) {
        final v = (await adb.shell('settings get global $k')).trim();
        if (v != '0.5') {
          old[k] = v;
          await adb.shell('settings put global $k 0.5');
        }
      }
      await adb.shell('am kill-all');
      await adb.shell('pm trim-caches 999G', timeout: const Duration(seconds: 60));
      await Future.delayed(const Duration(seconds: 2));

      final after = await _mem(adb);
      final dataAfter = await _dataFreeKb(adb);
      return BoostResult(
        ramTotalMb: before.$1 ~/ 1024,
        ramBeforeMb: before.$2 ~/ 1024,
        ramAfterMb: after.$2 ~/ 1024,
        cacheFreedMb: dataAfter > dataBefore ? (dataAfter - dataBefore) ~/ 1024 : 0,
        oldSettings: old,
        completedAt: DateTime.now(),
      );
    } finally {
      adb.close();
    }
  }

  /// Puts animation settings back as they were before boost().
  Future<void> undoBoost(TvDevice device, Map<String, String> old) async {
    final adb = AdbClient(host: device.ipAddress);
    try {
      await adb.connect();
      for (final e in old.entries) {
        if (!RegExp(r'^[a-z_]+$').hasMatch(e.key)) continue;
        final v = e.value;
        if (v.isEmpty || v == 'null' || !RegExp(r'^[0-9.]+$').hasMatch(v)) {
          await adb.shell('settings delete global ${e.key}');
        } else {
          await adb.shell('settings put global ${e.key} $v');
        }
      }
    } finally {
      adb.close();
    }
  }

  /// (MemTotal, MemAvailable) in KB.
  static Future<(int, int)> _mem(AdbClient adb) async {
    final out = await adb.shell('head -3 /proc/meminfo');
    int kb(String key) {
      final m = RegExp('^$key:\\s+(\\d+)', multiLine: true).firstMatch(out);
      return m == null ? 0 : int.parse(m.group(1)!);
    }
    final avail = kb('MemAvailable');
    return (kb('MemTotal'), avail > 0 ? avail : kb('MemFree'));
  }

  static Future<int> _dataFreeKb(AdbClient adb) async {
    final out = await adb.shell('df -k /data');
    final m = RegExp(r'^\S+\s+(\d+)\s+(\d+)\s+(\d+)', multiLine: true).firstMatch(out);
    return m == null ? 0 : int.parse(m.group(3)!);
  }

  // ── Clean ───────────────────────────────────────────────────────────────────

  /// Uninstall [packages] from [device] using `pm uninstall -k --user 0`.
  /// Returns a [CleanResult]. The [CleanResult.backupId] stores a JSON list
  /// of removed package names so rollback can restore them.
  Future<CleanResult> clean(TvDevice device, List<TvPackage> packages) async {
    final adb = AdbClient(host: device.ipAddress);
    final failed  = <String>[];
    final removed = <String>[];

    try {
      await adb.connect();
      for (final pkg in packages) {
        try {
          final out = await adb.shell('pm uninstall -k --user 0 ${pkg.packageName}');
          if (out.toLowerCase().contains('success')) {
            removed.add(pkg.packageName);
          } else {
            failed.add(pkg.packageName);
          }
        } catch (_) {
          failed.add(pkg.packageName);
        }
      }
    } finally {
      adb.close();
    }

    final savedMb = packages
        .where((p) => removed.contains(p.packageName))
        .fold(0, (s, p) => s + p.sizeMb);

    return CleanResult(
      removedCount:   removed.length,
      savedMb:        savedMb,
      backupId:       jsonEncode(removed), // JSON list → used by rollback
      failedPackages: failed,
      completedAt:    DateTime.now(),
    );
  }

  // ── Rollback ─────────────────────────────────────────────────────────────────

  /// Restore previously removed packages. [backupId] is the JSON list of
  /// package names produced by [clean].
  Future<bool> rollback(TvDevice device, String backupId) async {
    if (backupId.isEmpty) return false;

    List<String> pkgs;
    try {
      pkgs = (jsonDecode(backupId) as List).cast<String>();
    } catch (_) {
      return false;
    }
    if (pkgs.isEmpty) return true;

    final adb = AdbClient(host: device.ipAddress);
    int failures = 0;
    try {
      await adb.connect();
      for (final name in pkgs) {
        try {
          final out = await adb.shell('pm install-existing $name');
          if (!out.toLowerCase().contains('success')) failures++;
        } catch (_) {
          failures++;
        }
      }
    } finally {
      adb.close();
    }
    return failures == 0;
  }

  // ── Launcher ──────────────────────────────────────────────────────────────

  /// Package name of the TV's current home screen app, or null when the
  /// system has no default and asks the user every time.
  Future<String?> currentLauncher(TvDevice device) async {
    final adb = AdbClient(host: device.ipAddress);
    try {
      await adb.connect();
      final out = await adb.shell(
          'cmd package resolve-activity --brief '
          '-a android.intent.action.MAIN -c android.intent.category.HOME '
          '2>/dev/null || pm resolve-activity --brief '
          '-a android.intent.action.MAIN -c android.intent.category.HOME');
      final comp = out
          .split('\n')
          .map((l) => l.trim())
          .lastWhere((l) => l.contains('/'), orElse: () => '');
      if (comp.isEmpty || comp.startsWith('android/')) return null; // chooser
      return comp.split('/').first;
    } finally {
      adb.close();
    }
  }

  // ── TVCleanzer Launcher ───────────────────────────────────────────────────

  static const launcherPkg = 'com.tvcleanzer.launcher';
  static const launcherHome = '$launcherPkg/.HomeActivity';
  static const _homeKeyService = '$launcherPkg/$launcherPkg.HomeKeyService';

  Future<bool> isLauncherInstalled(TvDevice device) async {
    final adb = AdbClient(host: device.ipAddress);
    try {
      await adb.connect();
      final out = await adb.shell('pm path $launcherPkg');
      return out.contains('package:');
    } finally {
      adb.close();
    }
  }

  /// Installs [apk] on the TV, makes it the home screen, applies [skin] and
  /// presses Home so the user sees it. Needs Android 7+ on the TV.
  /// [onStep] reports progress for the UI.
  Future<void> installLauncher(TvDevice device, Uint8List apk, String skin,
      {void Function(String step)? onStep}) async {
    final adb = AdbClient(host: device.ipAddress);
    try {
      onStep?.call('Подключаемся к телевизору…');
      await adb.connect();
      final sdk = int.tryParse(
              (await adb.shell('getprop ro.build.version.sdk')).trim()) ??
          device.sdkVersion;
      if (sdk > 0 && sdk < 24) {
        throw AdbException(
            'Нужен Android 7 или новее на телевизоре (сейчас SDK $sdk).');
      }

      onStep?.call('Устанавливаем лаунчер…');
      final res = await adb.execWithInput(
          'cmd package install -r -S ${apk.length}', apk,
          timeout: const Duration(seconds: 90));
      if (!res.contains('Success')) {
        throw AdbException('Установка не удалась: ${res.trim()}');
      }

      onStep?.call('Делаем главным экраном…');
      // Android 10+: the HOME role; older: preferred home activity.
      if (sdk >= 29) {
        final r = await adb.shell('cmd role add-role-holder android.app.role.HOME $launcherPkg');
        if (r.toLowerCase().contains('exception')) {
          await adb.shell('cmd package set-home-activity $launcherHome');
        }
      } else {
        await adb.shell('cmd package set-home-activity $launcherHome');
      }
      // Firmwares that force their own launcher on Home: our accessibility
      // service catches the Home key. Re-adding it rebinds after an update.
      await _setHomeKeyService(adb, enabled: false);
      await _setHomeKeyService(adb, enabled: true);
      await adb.shell(_applyCommand(skin));
      await adb.shell('input keyevent 3');
    } finally {
      adb.close();
    }
  }

  /// Sends settings to the installed launcher (it redraws immediately).
  Future<void> applyLauncherSkin(TvDevice device, String skin) async {
    final adb = AdbClient(host: device.ipAddress);
    try {
      await adb.connect();
      await adb.shell(_applyCommand(skin));
    } finally {
      adb.close();
    }
  }

  /// Removes TVCleanzer Launcher; the TV falls back to its own home screen.
  Future<void> uninstallLauncher(TvDevice device) async {
    final adb = AdbClient(host: device.ipAddress);
    try {
      await adb.connect();
      await _setHomeKeyService(adb, enabled: false);
      await adb.shell('pm uninstall $launcherPkg');
      await adb.shell('input keyevent 3');
    } finally {
      adb.close();
    }
  }

  /// Apps, favourites, hidden and kids lists from the installed launcher.
  Future<LauncherState> launcherState(TvDevice device) async {
    final adb = AdbClient(host: device.ipAddress);
    try {
      await adb.connect();
      final out = await adb.shell('content query --uri content://com.tvcleanzer.launcher.state/apps');
      final set = await adb.shell('content query --uri content://com.tvcleanzer.launcher.state/settings');
      final re = RegExp(r'pkg=([^,]+), fav=(-?\d+), hidden=(\d+), kids=(\d+), label=(.*)$');
      final apps = <LauncherApp>[];
      for (final line in out.split('\n')) {
        final m = re.firstMatch(line.trim());
        if (m == null) continue;
        apps.add(LauncherApp(
          pkg: m.group(1)!,
          label: m.group(5)!.trim(),
          fav: int.parse(m.group(2)!),
          hidden: m.group(3) == '1',
          kids: m.group(4) == '1',
        ));
      }
      if (apps.isEmpty) {
        throw AdbException('Лаунчер не ответил. Обновите его на ТВ кнопкой «Обновить лаунчер».');
      }
      final kv = <String, String>{};
      for (final m in RegExp(r'key=(\w+), value=(\S+)').allMatches(set)) {
        kv[m.group(1)!] = m.group(2)!;
      }
      return LauncherState(
        apps: apps,
        kids: kv['kids'] == '1',
        hasPin: kv['pin'] == '1',
        hasWallpaper: kv['wallpaper'] == '1',
      );
    } finally {
      adb.close();
    }
  }

  /// Sends any subset of launcher settings in one broadcast.
  Future<void> applyLauncher(TvDevice device, {
    List<String>? favorites,
    Set<String>? hidden,
    Set<String>? kidsApps,
    bool? kids,
    String? pin,
  }) async {
    String list(Iterable<String> v) {
      final ok = v.where((p) => RegExp(r'^[A-Za-z0-9_.]+$').hasMatch(p)).toList();
      return ok.isEmpty ? '""' : ok.join(',');
    }
    final b = StringBuffer('am broadcast -n $launcherPkg/.ConfigReceiver -a com.tvcleanzer.launcher.APPLY');
    if (favorites != null) b.write(' --esa favorites ${list(favorites)}');
    if (hidden != null) b.write(' --esa hidden ${list(hidden)}');
    if (kidsApps != null) b.write(' --esa kidsApps ${list(kidsApps)}');
    if (pin != null && RegExp(r'^\d{4,8}$').hasMatch(pin)) b.write(' --es pin $pin');
    if (kids != null) b.write(' --ez kids $kids');
    final adb = AdbClient(host: device.ipAddress);
    try {
      await adb.connect();
      await adb.shell(b.toString());
    } finally {
      adb.close();
    }
  }

  static const _launcherFiles = '/sdcard/Android/data/$launcherPkg/files';

  /// Uploads a JPEG as the launcher background.
  Future<void> setWallpaper(TvDevice device, Uint8List jpeg) async {
    final adb = AdbClient(host: device.ipAddress);
    try {
      await adb.connect();
      await adb.execWithInput(
          "sh -c 'mkdir -p $_launcherFiles && cat > $_launcherFiles/wallpaper.jpg'", jpeg,
          timeout: const Duration(seconds: 90));
      await adb.shell('am broadcast -n $launcherPkg/.ConfigReceiver '
          '-a com.tvcleanzer.launcher.APPLY --es wallpaper set');
    } finally {
      adb.close();
    }
  }

  Future<void> removeWallpaper(TvDevice device) async {
    final adb = AdbClient(host: device.ipAddress);
    try {
      await adb.connect();
      await adb.shell('am broadcast -n $launcherPkg/.ConfigReceiver '
          '-a com.tvcleanzer.launcher.APPLY --es wallpaper none');
    } finally {
      adb.close();
    }
  }

  /// Adds/removes our service in `enabled_accessibility_services`, keeping
  /// whatever other services the TV already has there.
  Future<void> _setHomeKeyService(AdbClient adb, {required bool enabled}) async {
    final raw = (await adb.shell('settings get secure enabled_accessibility_services')).trim();
    final list = (raw.isEmpty || raw == 'null' ? <String>[] : raw.split(':'))
        .where((s) => s.isNotEmpty && s != _homeKeyService)
        .toList();
    if (enabled) list.add(_homeKeyService);
    if (list.isEmpty) {
      await adb.shell('settings delete secure enabled_accessibility_services');
    } else {
      await adb.shell("settings put secure enabled_accessibility_services '${list.join(':')}'");
      await adb.shell('settings put secure accessibility_enabled 1');
    }
  }

  static String _applyCommand(String skin) =>
      'am broadcast -n $launcherPkg/.ConfigReceiver '
      '-a com.tvcleanzer.launcher.APPLY --es skin $skin';

  // ── Package DB ───────────────────────────────────────────────────────────────

  /// Forget the cached database (after PackageDb.refresh found a newer one).
  static void resetDb() => _db = null;

  static Future<Map<String, _Entry>> _loadDb() async {
    if (_db != null) return _db!;

    final list = await PackageDb.load();
    _db = {};
    for (final m in list) {
      final name = m['packageName'] as String? ?? '';
      if (name.isEmpty) continue;
      _db![name] = _Entry(
        label:   m['label']   as String? ?? '',
        verdict: _parseVerdict(m['verdict'] as String? ?? 'keep'),
        reason:  m['reason']  as String? ?? '',
        sizeMb:  (m['sizeMb'] as num?)?.toInt() ?? 0,
      );
    }
    return _db!;
  }

  static PackageVerdict _parseVerdict(String v) => switch (v) {
    'remove'  => PackageVerdict.remove,
    'caution' => PackageVerdict.caution,
    'system'  => PackageVerdict.system,
    _         => PackageVerdict.keep,
  };

  static List<String> _parsePackageList(String raw) =>
      raw.split('\n')
          .map((l) => l.trim())
          .where((l) => l.startsWith('package:'))
          .map((l) => l.substring('package:'.length).trim())
          .where((s) => s.isNotEmpty)
          .toList();
}
