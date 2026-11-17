import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/launcher_look.dart';
import '../models/tv_device.dart';
import 'adb_client.dart';
import 'app_log.dart';
import 'package_db.dart';
import 'protection.dart';

import '../l10n/l10n.dart';
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
  Future<TvDevice> getDeviceInfo(String ip, {int port = 5555}) async {
    final adb = AdbClient.open(host: ip, port: port);
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
        port: port,
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
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      final raw = await adb.shell('pm list packages');
      // Disabled packages are already hidden (by TVCleanzer on Sber/Yandex, or by the owner).
      final disabled = _parsePackageList(await adb.shell('pm list packages -d 2>/dev/null')).toSet();
      final pkgs = _parsePackageList(raw).where((p) => !disabled.contains(p)).toList();

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
          label:   entry == null ? null : tr(entry.label),
          sizeMb:  (ramKb[name] ?? 0) ~/ 1024,
          verdict: verdict,
          reason:  entry == null ? null : trReason(entry.reason),
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
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
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
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
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

  /// Firmwares where removed apps must be disabled instead of uninstalled for
  /// user 0: Sber StarOS (its platform service re-installs "mandatory" apps
  /// after an uninstall, usually at the next boot) and Yandex TV / YaOS (the
  /// tested method on CVTE boards). CleanYourTV sber-salute-tv-*, artel, sunwind.
  static bool usesDisable(Iterable<String> installed) => installed.any((p) =>
      p == 'ru.sberdevices.services' || p == 'com.yandex.tv.services');

  /// Remove [packages] from [device]: `pm uninstall -k --user 0`, or
  /// `pm disable-user --user 0` on Sber/Yandex firmwares (falls back to the
  /// other method if the first one is refused). Returns a [CleanResult]. The
  /// [CleanResult.backupId] stores a JSON list of removed package names so
  /// rollback can restore them (rollback both re-installs and re-enables).
  Future<CleanResult> clean(TvDevice device, List<TvPackage> packages) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    final failed  = <String>[];
    final removed = <String>[];

    // Every refusal goes to the log, so a problem report says why.
    Future<bool> uninstall(String p) async {
      final out = (await adb.shell('pm uninstall -k --user 0 $p')).trim();
      if (out.toLowerCase().contains('success')) return true;
      AppLog.error('uninstall $p', out.isEmpty ? 'no answer' : out);
      return false;
    }
    // Some firmwares answer "disabled-user" and quietly keep the app enabled,
    // so the state is read back before it counts.
    Future<bool> disable(String p) async {
      final out = (await adb.shell('pm disable-user --user 0 $p')).trim();
      if (out.toLowerCase().contains('new state: disabled')) {
        final st = await adb.shell('pm list packages -d $p');
        if (_parsePackageList(st).contains(p)) return true;
        AppLog.error('disable $p', 'reported disabled, still enabled');
        return false;
      }
      AppLog.error('disable $p', out.isEmpty ? 'no answer' : out);
      return false;
    }

    try {
      await adb.connect();
      final installed = _parsePackageList(await adb.shell('pm list packages'));
      final viaDisable = usesDisable(installed);
      final dream = (await adb.shell('settings get secure screensaver_components')).trim();
      for (final pkg in packages) {
        final name = pkg.packageName;
        try {
          // One method refused (Xiaomi keeps some ad apps from being
          // uninstalled, but lets them be disabled): try the other one.
          final ok = viaDisable
              ? (await disable(name) || await uninstall(name))
              : (await uninstall(name) || await disable(name));
          (ok ? removed : failed).add(name);
        } catch (_) {
          failed.add(name);
        }
      }
      // The firmware's screensaver was removed: switch to our clock, otherwise
      // StarOS re-enables its own screensaver at boot while it stays selected.
      final dreamPkg = dream.split(',').first.split('/').first;
      if (removed.contains(dreamPkg) && installed.contains(launcherPkg)) {
        final v = await adb.shell('dumpsys package $launcherPkg | grep -m1 versionCode');
        if ((int.tryParse(RegExp(r'versionCode=(\d+)').firstMatch(v)?.group(1) ?? '') ?? 0) >= 5) {
          await adb.shell('settings put secure screensaver_components $launcherPkg/.ClockDream');
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

    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    int failures = 0;
    try {
      await adb.connect();
      for (final name in pkgs) {
        try {
          // Uninstalled for user 0 → install-existing; disabled (Sber/Yandex) → enable.
          final out = (await adb.shell('pm install-existing $name')).toLowerCase();
          final back = out.contains('success') || out.contains('installed for user');
          final en = (await adb.shell('pm enable $name')).toLowerCase();
          if (!back && !en.contains('new state: enabled')) failures++;
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
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
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
          .lastWhere((l) => _component.hasMatch(l), orElse: () => '');
      if (comp.isEmpty || comp.startsWith('android/')) return null; // chooser
      return comp.split('/').first;
    } finally {
      adb.close();
    }
  }

  // ── TVCleanzer Launcher ───────────────────────────────────────────────────

  static const launcherPkg = 'com.tvcleanzer.launcher';
  static const launcherHome = '$launcherPkg/.HomeActivity';
  /// versionCode of the launcher APK bundled in this app (launcher/AndroidManifest.xml).
  static const bundledLauncherVersion = 22;
  static const _homeKeyService = '$launcherPkg/$launcherPkg.HomeKeyService';

  Future<bool> isLauncherInstalled(TvDevice device) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      final out = await adb.shell('pm path $launcherPkg');
      return out.contains('package:');
    } finally {
      adb.close();
    }
  }

  /// Installs [apk] on the TV, makes it the home screen, applies [skin] and
  /// presses Home so the user sees it. Android 7+; Android 5–6 experimental.
  /// [onStep] reports progress for the UI.
  Future<LauncherBind> installLauncher(TvDevice device, Uint8List apk, String skin,
      {LauncherLook? look, void Function(String step)? onStep}) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      onStep?.call(tr('Подключаемся к телевизору…'));
      await adb.connect();
      final sdk = int.tryParse(
              (await adb.shell('getprop ro.build.version.sdk')).trim()) ??
          device.sdkVersion;
      // Android 5–6 (SDK 21–23): experimental. No `cmd package` there, so the APK goes the
      // old way (copy + pm install) and Home is held only by our Home-key service.
      if (sdk > 0 && sdk < 21) {
        throw AdbException(
            tr('Нужен Android 5 или новее на телевизоре (сейчас SDK {0}).', [sdk]));
      }

      onStep?.call(tr('Устанавливаем лаунчер…'));
      final res = await _installOne(adb, apk, const Duration(seconds: 90), flags: '-r');
      if (!res.contains('Success')) throw AdbException(_installError(res));

      await adb.shell(_applyCommand(skin, look));
      return await _bind(adb, sdk, onStep: onStep);
    } finally {
      adb.close();
    }
  }

  /// "Make it the home screen again" without reinstalling (Launcher tab).
  /// [googleTvHard]: the owner said "yes" to switching Google TV Home off (see [_bind]).
  Future<LauncherBind> rebindLauncher(TvDevice device,
      {void Function(String step)? onStep, bool googleTvHard = false}) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      final sdk = int.tryParse((await adb.shell('getprop ro.build.version.sdk')).trim()) ?? device.sdkVersion;
      return await _bind(adb, sdk, onStep: onStep, googleTvHard: googleTvHard);
    } finally {
      adb.close();
    }
  }

  /// Stock home screens we may take off the TV (for user 0, restorable) when the firmware
  /// keeps bringing them back: Android TV / Leanback launchers and Xiaomi PatchWall
  /// (it opens itself at every power-on, CleanYourTV xiaomi-mi-tv-4a). Never Google TV's
  /// launcherx (Home falls to a recovery screen), never Yandex/Sber homes (their apps live there).
  static const _removableHomes = [
    'com.google.android.tvlauncher',
    'com.google.android.leanbacklauncher',
    'com.mitv.tvhome.atv',
  ];

  /// "pkg/.Activity" and nothing else (some firmwares print errors with slashes).
  static final _component = RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+/[A-Za-z0-9_.$]+$');

  static String? _pkgOf(String comp) => comp.contains('/') ? comp.split('/').first : null;

  Future<String> _resolvedHome(AdbClient adb) async {
    final out = await adb.shell('cmd package resolve-activity --brief '
        '-a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null');
    return out.split('\n').map((l) => l.trim()).lastWhere((l) => _component.hasMatch(l), orElse: () => '');
  }

  Future<String?> _frontPackage(AdbClient adb) async {
    final out = await adb.shell('dumpsys activity activities 2>/dev/null | grep -m2 -E "mResumedActivity|topResumedActivity"');
    final m = RegExp(r'\s([A-Za-z0-9_.]+)/[A-Za-z0-9_.$]+').firstMatch(out);
    return m?.group(1);
  }

  /// Home key -> is our launcher in front? Two tries (some TVs take a moment).
  Future<bool> _homeOpensOurs(AdbClient adb) async {
    for (var i = 0; i < 2; i++) {
      await adb.shell('input keyevent 3');
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      var front = await _frontPackage(adb);
      // Android's "open with" list instead of a home screen (Haier MatrixTV: the HOME
      // role did not stick): pick our launcher there with "Always", like the owner would.
      if (front == 'android' && await _pickHomeInChooser(adb)) front = await _frontPackage(adb);
      if (front != launcherPkg) continue;
      // Yandex TV puts its own home over ours a few seconds later: look again.
      await Future<void>.delayed(const Duration(milliseconds: 4000));
      if (await _frontPackage(adb) == launcherPkg) return true;
    }
    await _logHomeState(adb);
    return false;
  }

  /// Words of the chooser's "Always" button, when the firmware renamed its id.
  static final _alwaysWord = RegExp(r'^(всегда|завжди|always|siempre|sempre|immer|toujours)$', caseSensitive: false);

  /// Centre of the first on-screen element (uiautomator dump) whose text or
  /// resource-id passes [match]; null when there is none.
  static (int, int)? uiPoint(String xml, bool Function(String text, String id) match) {
    final node = RegExp(r'<node\b[^>]*>');
    String attr(String n, String a) => RegExp('\\b$a="([^"]*)"').firstMatch(n)?.group(1) ?? '';
    for (final m in node.allMatches(xml)) {
      final n = m.group(0)!;
      if (!match(attr(n, 'text').trim(), attr(n, 'resource-id'))) continue;
      final b = RegExp(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]').firstMatch(attr(n, 'bounds'));
      if (b == null) continue;
      final x1 = int.parse(b.group(1)!), y1 = int.parse(b.group(2)!);
      final x2 = int.parse(b.group(3)!), y2 = int.parse(b.group(4)!);
      if (x2 <= x1 || y2 <= y1) continue;
      return ((x1 + x2) ~/ 2, (y1 + y2) ~/ 2);
    }
    return null;
  }

  /// In Android's home chooser: our launcher, then "Always". True when it was tapped.
  Future<bool> _pickHomeInChooser(AdbClient adb) async {
    Future<String> dump() => adb.shell('uiautomator dump /data/local/tmp/tvc_ui.xml >/dev/null 2>&1; '
        'cat /data/local/tmp/tvc_ui.xml 2>/dev/null; rm -f /data/local/tmp/tvc_ui.xml');
    try {
      final item = uiPoint(await dump(), (t, _) => t == 'TVCleanzer');
      if (item == null) {
        AppLog.error('home chooser', 'no TVCleanzer in the list');
        return false;
      }
      await adb.shell('input tap ${item.$1} ${item.$2}');
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (await _frontPackage(adb) != 'android') return true; // that tap already opened it
      final always = uiPoint(await dump(),
          (t, id) => id == 'android:id/button_always' || _alwaysWord.hasMatch(t));
      if (always == null) {
        AppLog.error('home chooser', 'no "Always" button');
        return false;
      }
      await adb.shell('input tap ${always.$1} ${always.$2}');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      return true;
    } catch (e) {
      AppLog.error('home chooser', e);
      return false;
    }
  }

  /// For «?» reports: what the TV did with Home and whether our Home-key service runs.
  Future<void> _logHomeState(AdbClient adb) async {
    try {
      final front = await _frontPackage(adb);
      final acc = (await adb.shell('settings get secure enabled_accessibility_services')).trim();
      final bound = (await adb.shell(
              'dumpsys accessibility 2>/dev/null | grep -iE "bound services|enabled services|crashed" | head -4'))
          .replaceAll(RegExp(r'\s+'), ' ');
      final res = await _resolvedHome(adb);
      AppLog.error('home', 'front=$front; resolves=${res.isEmpty ? '-' : res}; acc=$acc; $bound');
    } catch (_) {}
  }

  /// Makes our launcher the home screen and checks it with a real Home press:
  ///  1. HOME role / preferred home + our Home-key service;
  ///  2. still not ours: take the stock Android TV launcher or PatchWall off the TV
  ///     (restorable; only after our launcher is confirmed to open), then check again.
  Future<LauncherBind> _bind(AdbClient adb, int sdk,
      {void Function(String step)? onStep, bool googleTvHard = false}) async {
    final b = await _bindOnce(adb, sdk, onStep: onStep, googleTvHard: googleTvHard);
    if (b != LauncherBind.failed && b != LauncherBind.needsGoogleTvHard) await _syncStockOff(adb);
    return b;
  }

  /// Tells our launcher whether the TV's own home screen is switched off (also on TVs
  /// pinned by 1.3.17–1.3.22, which did it without asking): then its settings warn to
  /// remove it only with TVCleanzer, never in the TV's settings (black screen otherwise).
  Future<void> _syncStockOff(AdbClient adb) async {
    try {
      final disabled = _parsePackageList(await adb.shell('pm list packages -d')).toSet();
      final present = _parsePackageList(await adb.shell('pm list packages')).toSet();
      final all = _parsePackageList(await adb.shell('pm list packages -u')).toSet();
      final off = [..._removableHomes, ..._googleTvHomes]
          .any((p) => disabled.contains(p) || (all.contains(p) && !present.contains(p)));
      await adb.shell('am broadcast -n $launcherPkg/.ConfigReceiver -a com.tvcleanzer.launcher.APPLY --ez stockOff $off');
    } catch (e) {
      AppLog.error('stockOff', e);
    }
  }

  Future<LauncherBind> _bindOnce(AdbClient adb, int sdk,
      {void Function(String step)? onStep, bool googleTvHard = false}) async {
    onStep?.call(tr('Делаем главным экраном…'));
    if (sdk >= 29) {
      final r = await adb.shell('cmd role add-role-holder android.app.role.HOME $launcherPkg 2>&1');
      if (r.trim().isNotEmpty) AppLog.error('home role', r.trim());
      if (r.toLowerCase().contains('exception')) await adb.shell('cmd package set-home-activity $launcherHome');
    } else {
      await adb.shell('cmd package set-home-activity $launcherHome');
    }
    // Firmwares that force their own launcher on Home: our accessibility service catches the
    // Home key. It must not only be listed but really running ("bound").
    await _ensureHomeKeyService(adb);

    onStep?.call(tr('Проверяем кнопку «Домой»…'));
    final resolved = _pkgOf(await _resolvedHome(adb));
    if (await _homeOpensOurs(adb) && resolved == launcherPkg) {
      // Xiaomi: Home is ours now, but PatchWall still opens itself at every power-on
      // (past the HOME role). Take it off too; checked, and put back if Home breaks.
      return await _dropPatchWall(adb, sdk, onStep) ? LauncherBind.hard : LauncherBind.role;
    }

    // Our launcher must open at all before anything is taken away.
    await adb.shell('am start -n $launcherHome');
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    if (await _frontPackage(adb) != launcherPkg) return LauncherBind.failed;

    final installed = _parsePackageList(await adb.shell('pm list packages')).toSet();
    final stock = _removableHomes.where(installed.contains).toList();
    final googleTv = installed.contains('com.google.android.apps.tv.launcherx');
    if (stock.isNotEmpty && !googleTv) {
      onStep?.call(tr('Закрепляем лаунчер…'));
      final viaDisable = usesDisable(installed);
      final removed = <String>[];
      for (final p in stock) {
        final out = viaDisable
            ? await adb.shell('pm disable-user --user 0 $p')
            : await adb.shell('pm uninstall -k --user 0 $p');
        if (out.toLowerCase().contains('success') || out.contains('new state: disabled')) removed.add(p);
      }
      if (sdk >= 29) {
        await adb.shell('cmd role add-role-holder android.app.role.HOME $launcherPkg');
      } else {
        await adb.shell('cmd package set-home-activity $launcherHome');
      }
      if (await _homeOpensOurs(adb)) return LauncherBind.hard;
      // Did not help: never leave the TV without its own launcher.
      for (final p in removed) {
        await adb.shell('pm install-existing $p');
        await adb.shell('pm enable $p');
      }
    }
    // Google TV whose firmware never starts our Home-key service (TCL Android 11/12 reports:
    // "enabled" but not "bound", even after off/on) keeps its launcherx on Home and after
    // every power-on. Only with the owner's explicit "yes" ([googleTvHard], after a warning):
    // switch launcherx off together with the setup screen that would take Home after it
    // (restorable; what CleanYourTV google-tv lists do), kept only if Home really opens ours.
    // Never on its own: a Philips owner removed our launcher in the TV's settings afterwards
    // and was left with a black screen (nothing turned Google TV Home back on).
    final unbound = googleTv && !await _homeKeyBound(adb);
    if (unbound && googleTvHard) {
      onStep?.call(tr('Закрепляем лаунчер…'));
      final off = <String>[];
      for (final p in _googleTvHomes.where(installed.contains)) {
        final out = await adb.shell('pm disable-user --user 0 $p 2>&1');
        if (out.contains('new state: disabled')) {
          off.add(p);
        } else {
          AppLog.error('google tv home $p', out.trim());
        }
      }
      if (off.isNotEmpty) {
        await adb.shell('cmd role add-role-holder android.app.role.HOME $launcherPkg');
        // the launcher then warns in its settings: remove it only with TVCleanzer ([_syncStockOff])
        if (await _homeOpensOurs(adb)) return LauncherBind.hard;
        for (final p in off) {
          await adb.shell('pm enable $p');
        }
      }
    }
    // Google TV, Yandex, Sber…: the stock home stays; our service sends Home to us.
    await adb.shell('input keyevent 3');
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    if (await _frontPackage(adb) == launcherPkg) return LauncherBind.service;
    return unbound && !googleTvHard ? LauncherBind.needsGoogleTvHard : LauncherBind.failed;
  }

  static const _patchWall = 'com.mitv.tvhome.atv';

  /// Google TV's home and its setup screen: switched off only when nothing else keeps
  /// Home on our launcher (see [_bind]); always switched back on with our launcher removed.
  static const _googleTvHomes = [
    'com.google.android.apps.tv.launcherx',
    'com.google.android.tungsten.setupwraith',
  ];

  Future<bool> _dropPatchWall(AdbClient adb, int sdk, void Function(String step)? onStep) async {
    final installed = _parsePackageList(await adb.shell('pm list packages')).toSet();
    if (!installed.contains(_patchWall) || installed.contains('com.google.android.apps.tv.launcherx')) return false;
    onStep?.call(tr('Убираем PatchWall…'));
    final out = await adb.shell('pm uninstall -k --user 0 $_patchWall');
    if (!out.toLowerCase().contains('success')) return false;
    if (sdk >= 29) {
      await adb.shell('cmd role add-role-holder android.app.role.HOME $launcherPkg');
    } else {
      await adb.shell('cmd package set-home-activity $launcherHome');
    }
    if (await _homeOpensOurs(adb)) return true;
    await adb.shell('pm install-existing $_patchWall');
    return false;
  }

  /// Puts back stock home screens taken off by [_bind] (when our launcher is removed).
  Future<void> _restoreStockHomes(AdbClient adb) async {
    final all = _parsePackageList(await adb.shell('pm list packages -u 2>/dev/null')).toSet();
    final now = _parsePackageList(await adb.shell('pm list packages -e')).toSet();
    for (final p in [..._removableHomes, ..._googleTvHomes]) {
      if (!all.contains(p) || now.contains(p)) continue;
      await adb.shell('pm install-existing $p');
      await adb.shell('pm enable $p');
    }
  }

  /// Sends settings to the installed launcher (it redraws immediately).
  Future<void> applyLauncherSkin(TvDevice device, String skin) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      await adb.shell(_applyCommand(skin));
    } finally {
      adb.close();
    }
  }

  /// Removes TVCleanzer Launcher; the TV falls back to its own home screen.
  Future<void> uninstallLauncher(TvDevice device) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      await _restoreStockHomes(adb);
      await _setHomeKeyService(adb, enabled: false);
      await adb.shell('pm uninstall $launcherPkg');
      await adb.shell('input keyevent 3');
    } finally {
      adb.close();
    }
  }

  /// Apps, favourites, hidden and kids lists from the installed launcher.
  Future<LauncherState> launcherState(TvDevice device) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
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
        throw AdbException(tr('Лаунчер не ответил. Обновите его на ТВ кнопкой «Обновить лаунчер».'));
      }
      final kv = <String, String>{};
      for (final m in RegExp(r'key=(\w+), value=(.*)$', multiLine: true).allMatches(set)) {
        kv[m.group(1)!] = m.group(2)!.trim();
      }
      return LauncherState(
        apps: apps,
        kids: kv['kids'] == '1',
        hasPin: kv['pin'] == '1',
        hasWallpaper: kv['wallpaper'] == '1',
        version: int.tryParse(kv['version'] ?? '') ?? 0,
        settings: kv,
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
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      await adb.shell(b.toString());
    } finally {
      adb.close();
    }
  }

  static const _launcherFiles = '/sdcard/Android/data/$launcherPkg/files';

  /// Uploads a photo as the launcher background.
  ///
  /// 1. The bytes go to /data/local/tmp with exec-in (closing the stream gives
  ///    `cat` its end-of-file) and the size is checked.
  /// 2. Launcher 0.4+ on Android 10+ takes it through its content provider
  ///    (`content write`) into its private files: no scoped-storage surprises.
  ///    Otherwise it is copied into the launcher's external files dir.
  Future<void> setWallpaper(TvDevice device, Uint8List jpeg) async {
    const tmp = '/data/local/tmp/tvcleanzer_wall.jpg';
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      var sent = false;
      for (var attempt = 0; attempt < 2 && !sent; attempt++) {
        await adb.execIn('cat > $tmp', jpeg);
        final size = int.tryParse((await adb.shell('wc -c < $tmp')).trim().split(RegExp(r'\s+')).first);
        sent = size == jpeg.length;
      }
      if (!sent) {
        await adb.shell('rm -f $tmp');
        throw AdbException(tr('Фото не дошло до телевизора целиком. Попробуйте ещё раз.'));
      }
      final sdk = int.tryParse((await adb.shell('getprop ro.build.version.sdk')).trim()) ?? 0;
      var stored = false;
      if (sdk >= 29) {
        final out = await adb.shell(
            'content write --uri content://$launcherPkg.state/wallpaper < $tmp && echo TVC_OK');
        stored = out.contains('TVC_OK');
      }
      if (!stored) {
        final out = await adb.shell('mkdir -p $_launcherFiles && cp $tmp $_launcherFiles/wallpaper.jpg '
            '&& chmod 666 $_launcherFiles/wallpaper.jpg && echo TVC_OK');
        stored = out.contains('TVC_OK');
      }
      await adb.shell('rm -f $tmp');
      if (!stored) {
        throw AdbException(tr('Телевизор не дал сохранить фото. Обновите лаунчер на ТВ и попробуйте снова.'));
      }
      await adb.shell('am broadcast -n $launcherPkg/.ConfigReceiver '
          '-a com.tvcleanzer.launcher.APPLY --es wallpaper set');
    } finally {
      adb.close();
    }
  }

  Future<void> removeWallpaper(TvDevice device) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      await adb.shell('am broadcast -n $launcherPkg/.ConfigReceiver '
          '-a com.tvcleanzer.launcher.APPLY --es wallpaper none');
    } finally {
      adb.close();
    }
  }

  // ── Photo frame (launcher 0.15+) ─────────────────────────────────────────

  static const photoDream = '$launcherPkg/.PhotoDream';

  Future<void> _broadcast(AdbClient adb, String extras) =>
      adb.shell('am broadcast -n $launcherPkg/.ConfigReceiver -a com.tvcleanzer.launcher.APPLY $extras');

  /// Sends photos (already scaled on the phone) one by one: /data/local/tmp, then into the
  /// launcher (content write on Android 10+, its external files dir before that).
  Future<void> addPhotos(TvDevice device, List<Uint8List> jpegs,
      {void Function(int done, int total)? onProgress}) async {
    const tmp = '/data/local/tmp/tvcleanzer_photo.jpg';
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      final sdk = int.tryParse((await adb.shell('getprop ro.build.version.sdk')).trim()) ?? 0;
      var stored = 0;
      for (var i = 0; i < jpegs.length; i++) {
        onProgress?.call(i, jpegs.length);
        final jpeg = jpegs[i];
        var sent = false;
        for (var attempt = 0; attempt < 2 && !sent; attempt++) {
          await adb.execIn('cat > $tmp', jpeg);
          final size = int.tryParse((await adb.shell('wc -c < $tmp')).trim().split(RegExp(r'\s+')).first);
          sent = size == jpeg.length;
        }
        if (!sent) continue;
        var ok = false;
        if (sdk >= 29) {
          ok = (await adb.shell('content write --uri content://$launcherPkg.state/photo < $tmp && echo TVC_OK'))
              .contains('TVC_OK');
        }
        if (!ok) {
          final name = 'p${DateTime.now().millisecondsSinceEpoch}_$i.jpg';
          ok = (await adb.shell('mkdir -p $_launcherFiles/photos && cp $tmp $_launcherFiles/photos/$name '
                  '&& chmod 666 $_launcherFiles/photos/$name && echo TVC_OK'))
              .contains('TVC_OK');
        }
        if (ok) stored++;
      }
      await adb.shell('rm -f $tmp');
      await _broadcast(adb, '--es photos added');
      onProgress?.call(jpegs.length, jpegs.length);
      if (stored == 0) {
        throw AdbException(tr('Телевизор не дал сохранить фото. Обновите лаунчер на ТВ и попробуйте снова.'));
      }
    } finally {
      adb.close();
    }
  }

  Future<void> clearPhotos(TvDevice device) => _apply(device, '--es photos clear');

  Future<void> setPhotoOptions(TvDevice device, {int? seconds, bool? homePhotos}) => _apply(device,
      [if (seconds != null) '--ei photoSec $seconds', if (homePhotos != null) '--ez homePhotos $homePhotos'].join(' '));

  Future<void> _apply(TvDevice device, String extras) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      await _broadcast(adb, extras);
    } finally {
      adb.close();
    }
  }

  /// The TV's screensaver component ('' = firmware default).
  Future<String> currentDream(TvDevice device) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      final d = (await adb.shell('settings get secure screensaver_components')).trim();
      return d == 'null' ? '' : d;
    } finally {
      adb.close();
    }
  }

  /// Makes the photo frame the TV's screensaver; the previous one is kept by the launcher.
  Future<void> enablePhotoFrame(TvDevice device) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      var cur = (await adb.shell('settings get secure screensaver_components')).trim();
      if (cur == 'null') cur = '';
      if (!cur.contains('PhotoDream')) {
        final prev = RegExp(r'^[A-Za-z0-9_.]+/[A-Za-z0-9_.$]+$').hasMatch(cur) ? cur : '';
        await _broadcast(adb, "--es prevDream '$prev'");
      }
      await adb.shell('settings put secure screensaver_components $photoDream');
      await adb.shell('settings put secure screensaver_enabled 1');
    } finally {
      adb.close();
    }
  }

  /// When the screensaver starts, in minutes (Android TV: system screen_off_timeout); 0 = unknown.
  Future<int> screensaverDelayMin(TvDevice device) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      final ms = int.tryParse((await adb.shell('settings get system screen_off_timeout')).trim()) ?? 0;
      return ms <= 0 ? 0 : (ms / 60000).round();
    } finally {
      adb.close();
    }
  }

  Future<void> setScreensaverDelayMin(TvDevice device, int minutes) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      await adb.shell('settings put system screen_off_timeout ${minutes * 60000}');
    } finally {
      adb.close();
    }
  }

  /// Starts the screensaver right now (SystemUI's "start now"). False if the TV refused.
  Future<bool> startScreensaverNow(TvDevice device) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      final out = await adb.shell('am start -n com.android.systemui/.Somnambulator 2>&1');
      return !out.contains('Error') && !out.contains('Exception');
    } finally {
      adb.close();
    }
  }

  /// Gives the TV its previous screensaver back.
  Future<void> disablePhotoFrame(TvDevice device, String prev) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      if (prev.isNotEmpty && prev != '-' && !prev.contains('PhotoDream')) {
        await adb.shell('settings put secure screensaver_components $prev');
      } else {
        await adb.shell('settings delete secure screensaver_components');
      }
    } finally {
      adb.close();
    }
  }

  /// Is our Home-key service actually running? Being listed in the setting is not enough:
  /// a TCL Google TV report showed it "Enabled" but not "Bound" after a quick off/on.
  Future<bool> _homeKeyBound(AdbClient adb) async {
    final out = await adb.shell('dumpsys accessibility 2>/dev/null | grep -i "bound services"');
    return out.toLowerCase().contains('tvcleanzer');
  }

  /// Turns the Home-key service on and makes sure Android has started it. Off/on only when it
  /// is listed but not running, with pauses: a toggle within the same second can leave it
  /// enabled-but-unbound until the next reboot.
  Future<void> _ensureHomeKeyService(AdbClient adb) async {
    final raw = (await adb.shell('settings get secure enabled_accessibility_services')).trim();
    final listed = raw.split(':').contains(_homeKeyService);
    final on = (await adb.shell('settings get secure accessibility_enabled')).trim() == '1';
    if (listed && on && await _homeKeyBound(adb)) return;
    if (!listed || !on) {
      await _setHomeKeyService(adb, enabled: true);
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      if (await _homeKeyBound(adb)) return;
    }
    for (var i = 0; i < 2; i++) {
      await _setHomeKeyService(adb, enabled: false);
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await _setHomeKeyService(adb, enabled: true);
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      if (await _homeKeyBound(adb)) return;
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

  static String _applyCommand(String skin, [LauncherLook? look]) =>
      'am broadcast -n $launcherPkg/.ConfigReceiver '
      '-a com.tvcleanzer.launcher.APPLY --es skin $skin${look == null ? '' : ' ${look.extras}'}';

  /// «Close ADB» when the work is done: debugging off (USB and wireless). The connection
  /// drops right away, so errors are expected and ignored. Turning it back on is done
  /// on the TV (Developer options), as the first time.
  Future<void> disableAdb(TvDevice device) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      await adb.shell('settings put global adb_wifi_enabled 0; settings put global adb_enabled 0',
          timeout: const Duration(seconds: 5));
    } catch (_) {
      // the TV closed the connection: that is the point
    } finally {
      adb.close();
    }
  }

  /// App opened when the TV is switched on ('' = the launcher itself). Launcher 0.6+.
  Future<void> setLauncherAutostart(TvDevice device, String pkg) async {
    if (pkg.isNotEmpty && !RegExp(r'^[A-Za-z0-9_.]+$').hasMatch(pkg)) return;
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      await adb.shell('am broadcast -n $launcherPkg/.ConfigReceiver '
          '-a com.tvcleanzer.launcher.APPLY --es autostart ${pkg.isEmpty ? '""' : pkg}');
    } finally {
      adb.close();
    }
  }

  /// Animations, tile size, focus ring, photo dimming… (launcher 0.4+; older ones ignore them).
  Future<void> applyLauncherLook(TvDevice device, LauncherLook look) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      await adb.shell('am broadcast -n $launcherPkg/.ConfigReceiver '
          '-a com.tvcleanzer.launcher.APPLY ${look.extras}');
    } finally {
      adb.close();
    }
  }

  /// versionCode of the launcher on the TV, 0 if it is not installed.
  Future<int> launcherVersion(TvDevice device) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      final out = await adb.shell('dumpsys package $launcherPkg | grep -m1 versionCode');
      return int.tryParse(RegExp(r'versionCode=(\d+)').firstMatch(out)?.group(1) ?? '') ?? 0;
    } finally {
      adb.close();
    }
  }

  // ── Apps: install APK, open on the TV, uninstall ────────────────────────────

  /// Known names for apps whose package name says little.
  static const _appNames = {
    'org.smarttube.stable': 'SmartTube', 'org.smarttube.beta': 'SmartTube Beta',
    'com.liskovsoft.smarttubetv': 'SmartTube', 'com.liskovsoft.smarttubetv.beta': 'SmartTube Beta',
    'com.teamsmart.videomanager.tv': 'SmartTube', 'org.videolan.vlc': 'VLC', 'org.xbmc.kodi': 'Kodi',
    'com.google.android.youtube.tv': 'YouTube', 'com.netflix.ninja': 'Netflix',
    'com.spotify.tv.android': 'Spotify', 'com.android.tv.settings': 'Настройки',
    'com.android.vending': 'Google Play', 'com.yandex.tv.home': 'Яндекс ТВ',
    'ru.sberdevices.starlauncher': 'Салют ТВ', 'ru.sberdevices.starmarket': 'Каталог приложений Сбера',
    'com.spocky.projengmenu': 'Projectivy Launcher', 'com.tvcleanzer.launcher': 'TVCleanzer Launcher',
    'ru.vk.store.tv': 'RuStore', 'com.vk.tv': 'VK Видео', 'ru.rutube.app': 'Rutube',
    'ru.kinopoisk.tv': 'Кинопоиск', 'ru.more.play': 'Okko', 'ru.ivi.client': 'Иви',
    'ru.mts.mtstv': 'KION', 'com.lazycatsoftware.lmp': 'LazyMedia', 'com.lazycatsoftware.lazymediadeluxe': 'LazyMedia Deluxe',
    'com.mxtech.videoplayer.ad': 'MX Player', 'com.ghisler.tcplugins.lan': 'Total Commander LAN',
    'com.cxinventor.file.explorer': 'File Commander', 'com.estrongs.android.pop': 'ES Проводник',
    'tv.twitch.android.app': 'Twitch', 'com.amazon.amazonvideo.livingroom': 'Prime Video',
    'com.disney.disneyplus': 'Disney+', 'com.plexapp.android': 'Plex',
  };

  static String _appName(String pkg, Map<String, String> labels, Map<String, _Entry> db) {
    final l = labels[pkg] ?? _appNames[pkg] ?? db[pkg]?.label;
    if (l != null && l.isNotEmpty) return tr(l);
    final segs = pkg.split('.').where((s) =>
        !const {'com', 'org', 'ru', 'tv', 'android', 'app', 'apps', 'net', 'stable', 'release'}.contains(s)).toList();
    final n = segs.isEmpty ? pkg.split('.').last : segs.last;
    return n[0].toUpperCase() + n.substring(1);
  }

  /// Apps the owner can open or uninstall: everything with an icon in the TV
  /// menu plus everything installed by the owner. Names come from our
  /// launcher when it is installed (real labels), otherwise from the database.
  Future<List<TvApp>> listApps(TvDevice device) async {
    final db  = await _loadDb();
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      final all = _parsePackageList(await adb.shell('pm list packages')).toSet();
      final user = _parsePackageList(await adb.shell('pm list packages -3')).toSet();
      final disabled = _parsePackageList(await adb.shell('pm list packages -d 2>/dev/null')).toSet();
      final launchable = _parseComponents(await adb.shell(
          'cmd package query-activities --brief -a android.intent.action.MAIN '
          '-c android.intent.category.LEANBACK_LAUNCHER 2>/dev/null; '
          'cmd package query-activities --brief -a android.intent.action.MAIN '
          '-c android.intent.category.LAUNCHER 2>/dev/null'));
      final labels = <String, String>{};
      if (all.contains(launcherPkg)) {
        final out = await adb.shell('content query --uri content://com.tvcleanzer.launcher.state/apps 2>/dev/null');
        for (final m in RegExp(r'pkg=([^,]+),.*label=(.*)$', multiLine: true).allMatches(out)) {
          labels[m.group(1)!] = m.group(2)!.trim();
        }
      }
      final pkgs = {...user, ...launchable.where(all.contains)}
        ..removeAll(disabled)
        ..remove(launcherPkg);
      final apps = [
        for (final p in pkgs)
          TvApp(pkg: p, label: _appName(p, labels, db), user: user.contains(p), launchable: launchable.contains(p)),
      ]..sort((a, b) {
          if (a.user != b.user) return a.user ? -1 : 1;
          return a.label.toLowerCase().compareTo(b.label.toLowerCase());
        });
      return apps;
    } finally {
      adb.close();
    }
  }

  /// Google Play and the services it needs. Some firmwares (and some "debloat" guides) keep
  /// them on the TV but switched off or hidden for the user: then it can simply be turned back
  /// on instead of being installed from a file (installing over the firmware's copy fails).
  static const _googlePlay = ['com.google.android.gsf', 'com.google.android.gms', 'com.android.vending'];

  /// Google Play is in the firmware but switched off or hidden.
  Future<bool> googlePlayHidden(TvDevice device) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      final all = _parsePackageList(await adb.shell('pm list packages -u 2>/dev/null')).toSet();
      final on = _parsePackageList(await adb.shell('pm list packages -e')).toSet();
      return all.contains('com.android.vending') &&
          _googlePlay.any((p) => all.contains(p) && !on.contains(p));
    } finally {
      adb.close();
    }
  }

  /// Turns the firmware's Google Play (and its services) back on. True when Play is on now.
  Future<bool> restoreGooglePlay(TvDevice device) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      final all = _parsePackageList(await adb.shell('pm list packages -u 2>/dev/null')).toSet();
      for (final p in _googlePlay.where(all.contains)) {
        final a = await adb.shell('pm install-existing $p 2>&1');
        final b = await adb.shell('pm enable $p 2>&1');
        if (!'$a$b'.toLowerCase().contains('installed') && !b.contains('enabled')) {
          AppLog.error('google play $p', '$a $b'.trim());
        }
      }
      final on = _parsePackageList(await adb.shell('pm list packages -e')).toSet();
      return on.contains('com.android.vending');
    } finally {
      adb.close();
    }
  }

  /// Open [pkg]'s page in the TV's own settings, for apps the firmware won't let ADB
  /// remove (Xiaomi's ad window answers "not installed" / stays enabled) but lets the
  /// owner disable there with the remote.
  Future<bool> openAppSettings(TvDevice device, String pkg) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      final out = await adb.shell(
          'am start -a android.settings.APPLICATION_DETAILS_SETTINGS -d package:$pkg 2>&1');
      final ok = out.contains('Starting') && !out.contains('Error');
      if (!ok) AppLog.error('settings $pkg', out.trim());
      return ok;
    } finally {
      adb.close();
    }
  }

  /// Start [pkg] on the TV (its TV icon first, then the phone-style one).
  Future<bool> openApp(TvDevice device, String pkg) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      for (final cat in ['LEANBACK_LAUNCHER', 'LAUNCHER']) {
        final out = await adb.shell('monkey -p $pkg -c android.intent.category.$cat 1 2>&1');
        if (out.contains('Events injected: 1')) return true;
      }
      return false;
    } finally {
      adb.close();
    }
  }

  /// Fully uninstall an app the owner installed.
  Future<bool> uninstallApp(TvDevice device, String pkg) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      return (await adb.shell('pm uninstall $pkg')).contains('Success');
    } finally {
      adb.close();
    }
  }

  /// A zip entry's bytes without the per-byte copy (List<int>.from on a 100 MB split took
  /// 8 bytes per byte on the phone).
  static Uint8List _bytesOf(List<int> b) => b is Uint8List ? b : Uint8List.fromList(b);

  /// APKs inside a file: a plain .apk, or the split APKs of an .apks / .xapk
  /// / .apkm bundle (a zip). Throws [AdbException] when there are none.
  static List<(String, Uint8List)> apksIn(String fileName, Uint8List data) {
    final isZip = data.length > 4 && data[0] == 0x50 && data[1] == 0x4B;
    if (!isZip) throw AdbException(tr('Это не файл приложения Android (.apk).'));
    final zip = ZipDecoder().decodeBytes(data);
    // A plain APK is a zip with AndroidManifest.xml at the root.
    if (zip.files.any((f) => f.name == 'AndroidManifest.xml')) return [(fileName, data)];
    final apks = [
      for (final f in zip.files)
        if (f.isFile && f.name.toLowerCase().endsWith('.apk') && !f.name.contains('/'))
          (f.name, _bytesOf(f.content)),
    ];
    if (apks.isEmpty) throw AdbException(tr('В этом файле нет приложения Android (.apk).'));
    // base.apk first: some firmwares want it before the splits.
    apks.sort((a, b) => (a.$1 == 'base.apk' ? 0 : 1).compareTo(b.$1 == 'base.apk' ? 0 : 1));
    return apks;
  }

  /// Install an APK (or an .apks/.xapk bundle) from the phone on the TV.
  /// Returns the installed package name when the TV reports it, else ''.
  Future<String> installApk(TvDevice device, String fileName, Uint8List data,
      {void Function(String step)? onStep}) async {
    final apks = apksIn(fileName, data);
    final before = <String>{};
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      before.addAll(_parsePackageList(await adb.shell('pm list packages -3')));
      const t = Duration(minutes: 5);
      final total = apks.fold<int>(0, (s, a) => s + a.$2.length);
      final mb = (total / 1048576).toStringAsFixed(1);
      // Big files take a while over Wi-Fi: show how far it got, then that the TV is installing.
      var base = 0;
      void progress(int sent) {
        final pct = ((base + sent) * 100 / total).floor().clamp(0, 100);
        onStep?.call(base + sent >= total
            ? tr('Устанавливаем на телевизоре… Большие приложения ставятся до нескольких минут.')
            : tr('Отправляем на телевизор: {0}% из {1} МБ. Не блокируйте телефон.', [pct, mb]));
      }
      onStep?.call(tr('Отправляем на телевизор: {0}% из {1} МБ. Не блокируйте телефон.', [0, mb]));
      String res;
      if (apks.length == 1) {
        res = await _installOne(adb, apks.first.$2, t, onProgress: progress);
      } else {
        final created = await adb.shell('cmd package install-create -r -t -S $total');
        final id = RegExp(r'\[(\d+)\]').firstMatch(created)?.group(1);
        if (id == null) throw AdbException(_installError(created));
        for (final (name, bytes) in apks) {
          final w = await adb.execWithInput(
              'cmd package install-write -S ${bytes.length} $id ${name.replaceAll(RegExp(r'[^\w.-]'), '_')} -', bytes,
              timeout: t, onProgress: progress);
          base += bytes.length;
          if (!w.contains('Success')) {
            await adb.shell('cmd package install-abandon $id');
            throw AdbException(_installError(w));
          }
        }
        onStep?.call(tr('Устанавливаем на телевизоре… Большие приложения ставятся до нескольких минут.'));
        res = await adb.shell('cmd package install-commit $id', timeout: const Duration(minutes: 10));
      }
      if (!res.contains('Success')) throw AdbException(_installError(res));
      final after = _parsePackageList(await adb.shell('pm list packages -3')).toSet();
      final added = after.difference(before);
      return added.length == 1 ? added.first : '';
    } finally {
      adb.close();
    }
  }

  /// One APK: streamed straight into the package manager; when the TV refuses that
  /// (some firmwares: "-116: Failed to prepare for install"), the old way, like
  /// `adb install` on a computer: copy to /data/local/tmp, then `pm install` the file.
  Future<String> _installOne(AdbClient adb, Uint8List apk, Duration t,
      {String flags = '-r -t', void Function(int sent)? onProgress}) async {
    final res = await adb.execWithInput('cmd package install $flags -S ${apk.length}', apk,
        timeout: t, answerTimeout: const Duration(minutes: 10), onProgress: onProgress);
    if (res.contains('Success') || _definite.hasMatch(res)) return res;
    const tmp = '/data/local/tmp/tvcleanzer_install.apk';
    try {
      await adb.execIn('cat > $tmp', apk, timeout: t, onProgress: onProgress);
      final size = int.tryParse((await adb.shell('wc -c < $tmp')).trim().split(RegExp(r'\s+')).first);
      if (size != apk.length) return res;
      final viaFile = await adb.shell('pm install $flags $tmp', timeout: const Duration(minutes: 10));
      return viaFile.contains('Success') ? viaFile : '$res\n$viaFile';
    } finally {
      await adb.shell('rm -f $tmp');
    }
  }

  /// Answers that the second way would not change.
  static final _definite = RegExp(
      'UPDATE_INCOMPATIBLE|NO_MATCHING_ABIS|OLDER_SDK|VERSION_DOWNGRADE|INSUFFICIENT_STORAGE|INVALID_APK|PARSE_FAILED');

  static String _installError(String out) {
    final o = out.trim();
    if (o.contains('UPDATE_INCOMPATIBLE')) {
      return tr('На телевизоре уже стоит это приложение с другой подписью. Удалите его в списке ниже и установите снова.');
    }
    if (o.contains('NO_MATCHING_ABIS')) {
      return tr('Эта сборка не подходит для процессора телевизора. Скачайте версию armeabi-v7a (или universal).');
    }
    if (o.contains('OLDER_SDK')) return tr('Приложению нужна более новая версия Android, чем на телевизоре.');
    if (o.contains('VERSION_DOWNGRADE')) {
      return tr('На телевизоре уже стоит более новая версия. Удалите её в списке ниже, если нужна именно эта.');
    }
    if (o.contains('INSUFFICIENT_STORAGE')) return tr('На телевизоре не хватает места. Сначала сделайте очистку.');
    if (o.contains('INVALID_APK') || o.contains('PARSE_FAILED')) return tr('Файл повреждён или это не приложение Android.');
    return tr('Установка не удалась: {0}', [o.isEmpty ? '—' : o.split('\n').last]);
  }

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
