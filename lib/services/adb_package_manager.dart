import 'dart:convert';
import 'dart:math';

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
  /// A copy of this TV's History kept on the TV itself: a phone reinstall, a switch between
  /// the Telegram APK and the store app (different signatures = uninstall) or another phone
  /// doesn't lose it. /data/local/tmp belongs to adb shell and survives everything but a
  /// factory reset.
  static const tvHistoryPath = '/data/local/tmp/tvcleanzer/history.json';

  Future<String?> readTvHistory(TvDevice device) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      final out = await adb.shell('cat $tvHistoryPath 2>/dev/null');
      return out.trim().isEmpty ? null : out;
    } finally {
      adb.close();
    }
  }

  Future<void> writeTvHistory(TvDevice device, String json) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      await adb.shell('mkdir -p ${tvHistoryPath.substring(0, tvHistoryPath.lastIndexOf('/'))}');
      // written aside, then moved: a dropped connection never leaves half a file
      await adb.execIn('cat > $tvHistoryPath.tmp', Uint8List.fromList(utf8.encode(json)));
      await adb.shell('[ -s $tvHistoryPath.tmp ] && mv $tvHistoryPath.tmp $tvHistoryPath');
    } finally {
      adb.close();
    }
  }

  Future<TvDevice> getDeviceInfo(String ip,
      {int port = 5555, void Function()? onAwaitingApproval}) async {
    final adb = AdbClient.open(host: ip, port: port);
    try {
      final cnxnProps = await adb.connect(onAwaitingApproval: onAwaitingApproval);

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
      // Chinese Xiaomi firmware: the careful mode ([chinaXiaomi]).
      final cn = chinaXiaomi(_parsePackageList(raw).toSet());
      if (cn) {
        _chinaTvs.add(device.id);
      } else {
        _chinaTvs.remove(device.id);
      }
      // Installed by the owner (or a store), not part of the firmware.
      final userApps = _parsePackageList(await adb.shell('pm list packages -3')).toSet();
      // Real app names from our launcher, when it is on the TV ("Цифровое ТВ", not the
      // database's "Limehd ctv" from another model).
      final realNames = <String, String>{};
      if (pkgs.contains(launcherPkg)) {
        final out = await adb.shell('content query --uri content://com.tvcleanzer.launcher.state/apps 2>/dev/null');
        for (final m in RegExp(r'pkg=([^,]+),.*label=(.*)$', multiLine: true).allMatches(out)) {
          final l = m.group(2)!.trim();
          if (l.isNotEmpty) realNames[m.group(1)!] = l;
        }
      }

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
      // Android 5–6: no `cmd` — without this the TV's own home screen was not protected
      if (homes.isEmpty && launchable.isEmpty) {
        final old = await _oldCategories(adb);
        homes.addAll(old['HOME']!);
        launchable..addAll(old['LEANBACK_LAUNCHER']!)..addAll(old['LAUNCHER']!);
      }
      // The TV's screensaver: without it Android puts the TV to sleep at the screen timeout,
      // so it switched itself off after a few minutes without the remote — during a film in an
      // IPTV player or a browser too («после чистки телек сам отрубается», many owners).
      final dreamPkg = (await adb.shell('settings get secure screensaver_components'))
          .trim().split(',').first.split('/').first;
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
        // An app the owner installed: a list that saw it preinstalled on another model does
        // not make it junk here («Цифровое ТВ» from an APK was offered as "preinstalled").
        String? reason = entry == null ? null : trReason(entry.reason);
        String? label = entry == null ? null : tr(entry.label);
        if (userApps.contains(name) && verdict != PackageVerdict.system) {
          label = realNames[name] ?? label;
          if (verdict == PackageVerdict.remove) {
            verdict = PackageVerdict.caution;
            reason = tr('Установлено не прошивкой, а вами или магазином. Уберите, только если точно не пользуетесь.');
          } else {
            if (verdict == PackageVerdict.caution) verdict = PackageVerdict.keep;
            if (entry != null) reason = tr('Ваше приложение: TVCleanzer его не трогает.');
          }
        } else if (entry == null) {
          label = realNames[name];
        }
        if (name == dreamPkg && name != launcherPkg && verdict == PackageVerdict.remove) {
          verdict = PackageVerdict.caution;
          reason = tr('Заставка телевизора. Без неё ТВ сам выключается через несколько минут без пульта — даже во время фильма.');
        }
        if (cn && verdict != PackageVerdict.system) {
          if (_xiaomiOwn(name)) {
            verdict = PackageVerdict.system;
            reason = tr('Китайская прошивка Xiaomi: её приложения не трогаем — без них такие телевизоры зависают на логотипе.');
          } else if (verdict == PackageVerdict.remove) {
            verdict = PackageVerdict.caution;
          }
        }
        return TvPackage(
          packageName: name,
          label:   label,
          sizeMb:  (ramKb[name] ?? 0) ~/ 1024,
          verdict: verdict,
          reason:  reason,
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

  /// Chinese Xiaomi firmware (MiTV OS, China): its PatchWall `com.mitv.tvhome`, or Xiaomi's TV
  /// apps with no Google Play at all. Fragile: a MiTV-MFTR0 hung on its logo for good after
  /// com.miui.analytics was switched off and came back only through recovery (Wipe user data).
  /// There nothing of Xiaomi is offered and nothing is ticked in advance.
  static bool chinaXiaomi(Set<String> pkgs) =>
      pkgs.contains('com.mitv.tvhome') ||
      (!pkgs.contains('com.android.vending') &&
          pkgs.any((p) => p.startsWith('com.xiaomi.mitv.') || p.startsWith('com.mitv.')));

  static final _chinaTvs = <String>{};

  /// The last scan of [d] found a Chinese Xiaomi firmware ([chinaXiaomi]).
  static bool isChinaXiaomi(TvDevice d) => _chinaTvs.contains(d.id);

  /// "com.pkg/.Activity" lines -> package names.
  static Set<String> _parseComponents(String out) {
    final re = RegExp(r'^\s*([A-Za-z0-9_.]+)/');
    return out
        .split('\n')
        .map((l) => re.firstMatch(l)?.group(1))
        .whereType<String>()
        .toSet();
  }

  /// Android 5–6 have no `cmd package query-activities`: packages with a MAIN activity of
  /// each category, read from the resolver table (`dumpsys package -f r` prints each
  /// filter's categories). Keys: "HOME", "LEANBACK_LAUNCHER", "LAUNCHER".
  static Map<String, Set<String>> parseResolverCategories(String out) {
    final res = <String, Set<String>>{'HOME': {}, 'LEANBACK_LAUNCHER': {}, 'LAUNCHER': {}};
    final entry = RegExp(r'^\s*[0-9a-f]+\s+([A-Za-z0-9_.]+)/\S+\s+filter');
    final cat = RegExp(r'Category: "android\.intent\.category\.([A-Z_]+)"');
    var inActivities = false;
    String? pkg;
    for (final l in out.split('\n')) {
      if (l.contains('Activity Resolver Table')) { inActivities = true; continue; }
      if (inActivities && l.contains('Resolver Table')) break; // Receiver/Service tables
      if (!inActivities) continue;
      final e = entry.firstMatch(l);
      if (e != null) { pkg = e.group(1); continue; }
      final c = cat.firstMatch(l);
      if (c != null && pkg != null) res[c.group(1)!]?.add(pkg);
    }
    return res;
  }

  /// [parseResolverCategories] read from the TV (empty sets when it says nothing).
  Future<Map<String, Set<String>>> _oldCategories(AdbClient adb) async {
    try {
      return parseResolverCategories(
          await adb.shell('dumpsys package -f r 2>/dev/null', timeout: const Duration(seconds: 40)));
    } catch (e) {
      AppLog.error('resolver table', e);
      return {'HOME': {}, 'LEANBACK_LAUNCHER': {}, 'LAUNCHER': {}};
    }
  }

  /// Android 5–6 (SDK 21–23): no `cmd`, and `pm install-existing` can't be relied on, so
  /// apps are switched off (`pm disable-user`, undone by `pm enable`) instead of removed.
  static bool oldAndroid(int sdk) => sdk > 0 && sdk < 24;

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
      final viaDisable = usesDisable(installed) || oldAndroid(device.sdkVersion);
      // Apps the owner installed: "uninstall for user 0" deletes them for good (no copy in the
      // firmware to bring back), so they are only switched off. Undo = switch on.
      final userApps = _parsePackageList(await adb.shell('pm list packages -3')).toSet();
      final dream = (await adb.shell('settings get secure screensaver_components')).trim();
      for (final pkg in packages) {
        final name = pkg.packageName;
        try {
          // One method refused (Xiaomi keeps some ad apps from being
          // uninstalled, but lets them be disabled): try the other one.
          // Android 5–6: switched off only — an uninstall might not come back there
          final ok = userApps.contains(name) || oldAndroid(device.sdkVersion)
              ? await disable(name)
              : viaDisable
                  ? (await disable(name) || await uninstall(name))
                  : (await uninstall(name) || await disable(name));
          (ok ? removed : failed).add(name);
        } catch (_) {
          failed.add(name);
        }
      }
      // Remembered on the TV itself: «Вернуть всё скрытое» works from any phone, after a
      // reinstall, without History (a chat report: history gone, the TV could not be put back).
      if (removed.isNotEmpty) {
        try {
          await adb.shell("printf '%s\\n' ${removed.join(' ')} >> $_hiddenFile");
        } catch (_) {}
      }
      // The firmware's screensaver was removed: switch to our clock, otherwise
      // StarOS re-enables its own screensaver at boot while it stays selected.
      final dreamPkg = dream.split(',').first.split('/').first;
      if (removed.contains(dreamPkg)) {
        var clock = false;
        if (installed.contains(launcherPkg)) {
          final v = await adb.shell('dumpsys package $launcherPkg | grep -m1 versionCode');
          if ((int.tryParse(RegExp(r'versionCode=(\d+)').firstMatch(v)?.group(1) ?? '') ?? 0) >= 5) {
            await adb.shell('settings put secure screensaver_components $launcherPkg/.ClockDream');
            clock = true;
          }
        }
        // No screensaver left: the TV would go to sleep at the screen timeout (often 10 min),
        // in the middle of a film. A longer one instead; the old value comes back with «Вернуть».
        if (!clock) await _longerScreenTimeout(adb);
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
      final old = int.tryParse((await adb.shell('cat $_screenOffFile 2>/dev/null')).trim());
      if (old != null && old > 0) {
        await adb.shell('settings put system screen_off_timeout $old; rm -f $_screenOffFile');
      }
      // Check what really came back: "Готово" was shown for an app that was gone for good.
      final enabled = _parsePackageList(await adb.shell('pm list packages -e')).toSet();
      final missing = pkgs.where((p) => !enabled.contains(p)).toList();
      if (missing.isNotEmpty) {
        AppLog.error('rollback', 'not back: ${missing.join(', ')}');
        failures = failures < missing.length ? missing.length : failures;
      }
    } finally {
      adb.close();
    }
    return failures == 0;
  }

  /// What TVCleanzer switched off on this TV, one package per line (see [clean]).
  static const _hiddenFile = '/data/local/tmp/tvcleanzer_hidden';

  /// «Вернуть всё скрытое»: switches back on everything TVCleanzer may have hidden on
  /// [device] that is hidden now — the TV's own list ([_hiddenFile]), [known] (History on this
  /// phone) and apps our database suggests hiding — and puts 0.5× animations back to 1×.
  /// Never stock home screens (that is «Вернуть стандартный лаунчер», it also unpins ours) and
  /// never anything else the firmware keeps off by itself (a Google TV box looped with its old
  /// home switched back on).
  Future<RestoreAllResult> restoreAllHidden(TvDevice device, {Iterable<String> known = const []}) async {
    final db = await _loadDb();
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      final all = _parsePackageList(await adb.shell('pm list packages -u 2>/dev/null')).toSet();
      final present = _parsePackageList(await adb.shell('pm list packages')).toSet();
      final disabled = _parsePackageList(await adb.shell('pm list packages -d 2>/dev/null')).toSet();
      final hidden = {...disabled, ...all.where((p) => !present.contains(p))};
      final saved = (await adb.shell('cat $_hiddenFile 2>/dev/null'))
          .split(RegExp(r'\s+'))
          .where(_pkgName.hasMatch)
          .toSet();
      final ours = {
        ...saved,
        ...known,
        for (final e in db.entries)
          if (e.value.verdict == PackageVerdict.remove || e.value.verdict == PackageVerdict.caution) e.key,
      };
      final homes = {..._removableHomes, ..._googleTvHomes, ...await _stockHomes(adb, all)};
      final todo = hidden
          .where((p) => ours.contains(p) && !homes.contains(p) && p != launcherPkg)
          .toList()
        ..sort();
      final locked = <String>[];
      for (final p in todo) {
        try {
          await adb.shell('pm install-existing $p 2>&1');
          final en = await adb.shell('pm enable $p 2>&1');
          // Haier H55P751UG: Google services switched off by a factory app — only the TV's
          // own settings may switch them back on
          if (en.contains('cannot change component state')) locked.add(p);
        } catch (e) {
          AppLog.error('restore all $p', e);
        }
      }
      final enabled = _parsePackageList(await adb.shell('pm list packages -e')).toSet();
      final back = todo.where(enabled.contains).toList();
      final failed = todo.where((p) => !enabled.contains(p)).toList();
      if (failed.isNotEmpty) AppLog.error('restore all', 'not back: ${failed.join(', ')}');

      var anim = false;
      for (final k in _animKeys) {
        if ((await adb.shell('settings get global $k')).trim() == '0.5') {
          await adb.shell('settings put global $k 1');
          anim = true;
        }
      }
      // keep on the TV only what is still hidden
      await adb.shell(failed.isEmpty
          ? 'rm -f $_hiddenFile'
          : "printf '%s\\n' ${failed.join(' ')} > $_hiddenFile");
      return RestoreAllResult(
        restored: back,
        failed: failed.where((p) => !locked.contains(p)).toList(),
        locked: locked.where(failed.contains).toList(),
        labels: {
          for (final p in todo)
            if ((db[p]?.label ?? '').isNotEmpty) p: db[p]!.label,
        },
        animations: anim,
      );
    } finally {
      adb.close();
    }
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
  /// test/launcher_version_test.dart fails when the two differ: 1.3.62–1.3.63 shipped 0.56/0.57 with
  /// 55 here, so phones never auto-updated a 0.55 TV and showed no «new version» — held Volume
  /// stayed one step on Xiaomi for everyone who didn't press «Обновить лаунчер» by hand.
  static const bundledLauncherVersion = 78;
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
      {LauncherLook? look, bool keepSettings = false, void Function(String step)? onStep}) async {
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
      var res = await _installOne(adb, apk, const Duration(seconds: 90), flags: '-r');
      var keep = keepSettings;
      LauncherState? saved;
      if (!res.contains('Success') && needsCleanReinstall(res)) {
        // A launcher signed with another key (early builds, a test build) or left half-removed
        // («pm uninstall --user 0» from a chat tip): `install -r` can never replace it. TCL owners
        // stayed on an old launcher until they ran two uninstall commands by hand (#23, #6).
        // Its favourites, hidden and kids lists are read first and given back; its look is the
        // phone's copy, read from this TV on the Launcher tab.
        AppLog.error('launcher install', 'clean reinstall: ${_installReason(res)}');
        onStep?.call(tr('Старый лаунчер не обновляется — ставим заново, избранное сохраним…'));
        try {
          saved = await launcherState(device);
        } catch (_) {}
        await adb.shell('pm uninstall --user 0 $launcherPkg 2>&1; pm uninstall $launcherPkg 2>&1');
        res = await _installOne(adb, apk, const Duration(seconds: 90), flags: '-r');
        keep = false;
        if (!res.contains('Success')) {
          // never leave the TV without a home screen: its own one comes back
          await _restoreStockHomes(adb);
          await adb.shell('input keyevent 3');
        }
      }
      if (!res.contains('Success')) throw AdbException(_installError(res, launcher: true));

      if (!keep) await adb.shell(_applyCommand(skin, look));
      final bind = await _bind(adb, sdk, onStep: onStep);
      if (saved != null) {
        try {
          final favs = saved.apps.where((a) => a.fav >= 0).toList()..sort((a, b) => a.fav.compareTo(b.fav));
          await applyLauncher(device,
              favorites: favs.map((a) => a.pkg).toList(),
              hidden: saved.apps.where((a) => a.hidden).map((a) => a.pkg).toSet(),
              kidsApps: saved.apps.where((a) => a.kids).map((a) => a.pkg).toSet());
        } catch (e) {
          AppLog.error('launcher reinstall lists', e);
        }
      }
      return bind;
    } finally {
      adb.close();
    }
  }

  /// The launcher APK bundled with this app, or null in a build without it.
  static Future<Uint8List?> bundledLauncherApk() async {
    try {
      final data = await rootBundle.load('assets/launcher/tvcleanzer-launcher.apk');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {
      return null;
    }
  }

  /// Brings the TV's TVCleanzer Launcher up to the bundled version when it is older: owners
  /// never pressed «Обновить лаунчер» and kept fixed bugs (a Philips spoke and paused YouTube
  /// on Volume with an old launcher, until the owner updated it by hand). Careful:
  ///  * only when our launcher is installed and older — never installs it on its own;
  ///  * only when our launcher is what the TV shows: nothing playing is interrupted
  ///    (the check below presses Home); otherwise it waits for the next connection;
  ///  * `install -r` keeps the launcher's own settings, favourites and photos; nothing
  ///    from the phone (skin, look) is sent;
  ///  * then pinned again gently ([_bind] gentle): HOME setting and key filter only; nothing
  ///    of the firmware is taken off, and a Home-key service the owner switched off stays off.
  /// Returns the new versionCode, or null when nothing was done.
  Future<int?> autoUpdateLauncher(TvDevice device, Uint8List apk) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      await _healUnsafePins(adb);
      final out = await adb.shell('dumpsys package $launcherPkg | grep -m1 versionCode');
      final v = int.tryParse(RegExp(r'versionCode=(\d+)').firstMatch(out)?.group(1) ?? '') ?? 0;
      if (v <= 0 || v >= bundledLauncherVersion) return null;
      final front = await _frontPackage(adb);
      if (front != launcherPkg) {
        AppLog.error('launcher auto-update', 'v$v on the TV, waits: $front is on screen');
        return null;
      }
      final sdk = int.tryParse((await adb.shell('getprop ro.build.version.sdk')).trim()) ?? device.sdkVersion;
      if (sdk > 0 && sdk < 21) return null;
      final res = await _installOne(adb, apk, const Duration(seconds: 90), flags: '-r');
      if (!res.contains('Success')) {
        AppLog.error('launcher auto-update', 'v$v: ${res.trim()}');
        return null;
      }
      final b = await _bind(adb, sdk, gentle: true);
      AppLog.error('launcher auto-update', 'v$v → v$bundledLauncherVersion, home: ${b.name}');
      return bundledLauncherVersion;
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
  ///  [gentle] (the automatic update): HOME setting, key filter and the Home-key service only —
  ///  nothing of the firmware is taken off (no PatchWall, no stock homes, no Google TV).
  Future<LauncherBind> _bind(AdbClient adb, int sdk,
      {void Function(String step)? onStep, bool googleTvHard = false, bool gentle = false}) async {
    final b = await _bindOnce(adb, sdk, onStep: onStep, googleTvHard: googleTvHard, gentle: gentle);
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
      final off = (await _stockHomes(adb, all))
          .any((p) => disabled.contains(p) || (all.contains(p) && !present.contains(p)));
      await adb.shell('am broadcast -n $launcherPkg/.ConfigReceiver -a com.tvcleanzer.launcher.APPLY --ez stockOff $off');
    } catch (e) {
      AppLog.error('stockOff', e);
    }
  }

  Future<LauncherBind> _bindOnce(AdbClient adb, int sdk,
      {void Function(String step)? onStep, bool googleTvHard = false, bool gentle = false}) async {
    onStep?.call(tr('Делаем главным экраном…'));
    await _keepGuardLog(adb);
    await _healUnsafePins(adb);
    if (sdk >= 29) {
      final r = await adb.shell('cmd role add-role-holder android.app.role.HOME $launcherPkg 2>&1');
      if (r.trim().isNotEmpty) AppLog.error('home role', r.trim());
      if (r.toLowerCase().contains('exception')) await adb.shell('cmd package set-home-activity $launcherHome');
    } else {
      await adb.shell('cmd package set-home-activity $launcherHome');
    }
    // «ТВ» in the launcher reads the tuner's channel list to open the antenna, not the last
    // HDMI (runtime permission; refused on some firmwares — then the launcher falls back).
    if (sdk >= 23) {
      await adb.shell('pm grant $launcherPkg com.android.providers.tv.permission.READ_EPG_DATA 2>&1');
    }
    // «Запущенные»: the launcher's own recent-apps row reads usage stats (Android 5.1+)
    if (sdk >= 22) {
      await adb.shell('appops set $launcherPkg GET_USAGE_STATS allow 2>&1');
    }
    // 0.69: the launcher puts its Home-key service back after a reboot if the TV dropped it
    // (TCL Smart TV Pro 55C745: fine until a reboot, then the stock home again)
    await adb.shell('pm grant $launcherPkg android.permission.WRITE_SECURE_SETTINGS 2>&1');
    // Bluetooth pill (0.63): what is connected needs BLUETOOTH_CONNECT on Android 12+
    if (sdk >= 31) {
      await adb.shell('pm grant $launcherPkg android.permission.BLUETOOTH_CONNECT 2>&1');
    }
    // «Экран гаснет без пульта» in the launcher's own settings (0.59): the screen timeout
    if (sdk >= 23) {
      await adb.shell('appops set $launcherPkg WRITE_SETTINGS allow 2>&1');
    }
    // Where Home already opens us through the HOME setting, the service must not catch keys:
    // that costs key repeat — held Volume moves one step (Haier FF Pro, Xiaomi MOEU1, and many
    // Xiaomi owners in the chat: held «−» no longer went down to mute). Xiaomi was kept on the
    // filter for the Mi key; the service still puts our launcher back over PatchWall by its
    // window, so holding Volume matters more.
    await _setKeyFilter(adb, true);
    if (_pkgOf(await _resolvedHome(adb)) == launcherPkg) {
      await _setKeyFilter(adb, false);
      if (!await _homeOpensOurs(adb)) await _setKeyFilter(adb, true);
    }
    // Firmwares that force their own launcher on Home: our accessibility service catches the
    // Home key. It must not only be listed but really running ("bound"). (Without the key
    // filter it still puts our launcher back over a stock screen that comes up at power-on.)
    // The automatic update keeps the owner's choice: a service switched off in the TV's
    // settings stays off.
    final serviceListed = (await adb.shell('settings get secure enabled_accessibility_services'))
        .trim()
        .split(':')
        .contains(_homeKeyService);
    if (!gentle || serviceListed) await _ensureHomeKeyService(adb);

    onStep?.call(tr('Проверяем кнопку «Домой»…'));
    final resolved = _pkgOf(await _resolvedHome(adb));
    if (await _homeOpensOurs(adb) && resolved == launcherPkg) {
      // Xiaomi: PatchWall still opens itself at every power-on (past the HOME role); our
      // Home-key service puts the launcher back over it by its window (0.56+). PatchWall is no
      // longer taken off the TV for that (1.3.66): a Xiaomi reset itself to factory two seconds
      // after «Установить лаунчер» (#46), and a Chinese MiTV had no home screen at all without
      // its PatchWall the next day (#2). Taken off by older versions: «Вернуть стандартный лаунчер».
      return LauncherBind.role;
    }
    // The automatic update never takes anything away: what pinned the launcher before
    // (stock homes already off, the Home-key service) is still in place.
    if (gentle) return await _homeOpensOurs(adb) ? LauncherBind.service : LauncherBind.failed;

    // Our launcher must open at all before anything is taken away.
    await adb.shell('am start -n $launcherHome');
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    if (await _frontPackage(adb) != launcherPkg) return LauncherBind.failed;

    final installed = _parsePackageList(await adb.shell('pm list packages')).toSet();
    // Xiaomi's own homes stay (PatchWall included): see [_xiaomiOwn].
    final stock = _removableHomes.where((p) => installed.contains(p) && !_xiaomiOwn(p)).toList();
    final googleTv = installed.contains('com.google.android.apps.tv.launcherx');
    // The firmware's own home that Home opens whatever the HOME setting says (a be311 box,
    // Android 13: HOME resolved to ours, Home opened com.master.t972 every time).
    final fw = googleTv ? null : await _firmwareHome(adb);
    if (fw != null && !stock.contains(fw)) stock.add(fw);
    // Only what is safe to switch off, and only where the TV takes our launcher as a home at all.
    final safe = <String>[];
    if (stock.isNotEmpty && !googleTv) {
      if (await _ourHomeListed(adb)) {
        for (final p in stock) {
          if (await _safeToSwitchOff(adb, p)) safe.add(p);
        }
      } else {
        AppLog.error('pin', 'the TV does not list our launcher as a home: nothing switched off (${stock.join(', ')})');
      }
    }
    if (safe.isNotEmpty) {
      onStep?.call(tr('Закрепляем лаунчер…'));
      final viaDisable = usesDisable(installed) || oldAndroid(sdk);
      // the TV switches them back on by itself unless the check below passes (#3)
      final token = await _armGuard(adb, safe);
      final removed = <String>[];
      for (final p in safe) {
        AppLog.error('pin', 'switching off $p'); // in the «?» report even if the TV goes away now
        final out = viaDisable || p == fw
            ? await adb.shell('pm disable-user --user 0 $p 2>&1')
            : await adb.shell('pm uninstall -k --user 0 $p 2>&1');
        if (out.toLowerCase().contains('success') || out.contains('new state: disabled')) {
          removed.add(p);
        } else {
          AppLog.error('stock home $p', out.trim());
        }
      }
      // remembered on the TV: put back with «Вернуть стандартный лаунчер» ([_stockHomes])
      if (fw != null && removed.contains(fw)) await adb.shell("echo '$fw' > $_firmwareHomesFile");
      if (sdk >= 29) {
        await adb.shell('cmd role add-role-holder android.app.role.HOME $launcherPkg');
      } else {
        await adb.shell('cmd package set-home-activity $launcherHome');
      }
      if (await _homeOpensOurs(adb) && await _networkUp(adb)) {
        await _keepGuard(adb, token);
        return LauncherBind.hard;
      }
      // Did not help: never leave the TV without its own launcher.
      for (final p in removed) {
        await adb.shell('pm install-existing $p');
        await adb.shell('pm enable $p');
      }
      await _keepGuard(adb, token);
      if (fw != null) await adb.shell('rm -f $_firmwareHomesFile');
    }
    // Google TV whose firmware never starts our Home-key service (TCL Android 11/12 reports:
    // "enabled" but not "bound", even after off/on), or runs it but still lets launcherx
    // take Home, keeps its launcherx on Home and after
    // every power-on. Only with the owner's explicit "yes" ([googleTvHard], after a warning):
    // switch launcherx off together with the setup screen that would take Home after it
    // (restorable; what CleanYourTV google-tv lists do), kept only if Home really opens ours.
    // Never on its own: a Philips owner removed our launcher in the TV's settings afterwards
    // and was left with a black screen (nothing turned Google TV Home back on).
    // Also when the service IS running but Google TV still takes Home (a TCL Smart TV Pro,
    // Android 11 report: service bound, Home opened launcherx every time): offer the same.
    // TCL Google TV (G10 board, Smart TV Pro): HDMI is played by launcherx itself — with it
    // off, picking a source switched the input in hardware but nothing showed it, and the owner
    // landed back on our home (VIV, 1.3.48 report). There the hard way is never taken.
    final inputsInHome = googleTv && await _inputsLiveInGoogleTvHome(adb);
    if (inputsInHome) AppLog.error('google tv hard', 'skipped: HDMI is shown by launcherx');
    if (googleTv && googleTvHard && !inputsInHome) {
      onStep?.call(tr('Закрепляем лаунчер…'));
      final token = await _armGuard(adb, _googleTvHomes.where(installed.contains).toList());
      final off = <String>[];
      for (final p in _googleTvHomes.where(installed.contains)) {
        AppLog.error('pin', 'switching off $p (owner agreed)');
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
        if (await _homeOpensOurs(adb) && await _networkUp(adb)) {
          await _keepGuard(adb, token);
          return LauncherBind.hard;
        }
        for (final p in off) {
          await adb.shell('pm enable $p');
        }
      }
      await _keepGuard(adb, token);
    }
    // Google TV, Yandex, Sber…: the stock home stays; our service sends Home to us.
    // From our own screen: Home pressed on the stock home itself only refreshes it, so the
    // check always failed where the TV already sat on launcherx (TCL Smart TV Pro, 1.3.78).
    if (googleTv) {
      await adb.shell('am start -n $launcherHome');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    }
    await adb.shell('input keyevent 3');
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    if (await _frontPackage(adb) == launcherPkg) return LauncherBind.service;
    if (googleTv && !googleTvHard) {
      AppLog.error('google tv home', 'Home stays on launcherx (service bound: ${await _homeKeyBound(adb)})');
      await _logHomeService(adb);
      return LauncherBind.needsGoogleTvHard;
    }
    return LauncherBind.failed;
  }

  /// Does Google TV's home play the HDMI inputs here (nobody else answers "view an input")?
  /// TCL G10: nobody answers it at all — launcherx starts TCL's own player its own way; with
  /// launcherx off, HDMI was gone (VIV: «С экрана Google TV источник HDMI включился»).
  Future<bool> _inputsLiveInGoogleTvHome(AdbClient adb) async {
    final out = await adb.shell('cmd package query-activities --brief -a android.intent.action.VIEW '
        '-d content://android.media.tv/passthrough/x 2>&1');
    final handlers = RegExp(r'([A-Za-z][\w.]+)/').allMatches(out).map((m) => m.group(1)!).toSet();
    return handlers.every((p) => _googleTvHomes.contains(p) || p == launcherPkg);
  }

  /// Firmware homes TVCleanzer switched off on this TV (see [_firmwareHome]), one per line.
  static const _firmwareHomesFile = '/data/local/tmp/tvcleanzer_homes';

  /// Firmware homes known to be started by Home directly, without declaring HOME.
  static const _knownFirmwareHomes = {'com.master.t972'};

  /// Homes that are never switched off this way: Google TV (Home falls to a recovery screen),
  /// Yandex and Sber (their apps live there), settings and the system itself.
  static bool _neverOff(String p) =>
      p == launcherPkg || p == 'android' || p == 'com.android.systemui' ||
      p == 'com.android.tv.settings' || p == 'com.android.settings' ||
      _googleTvHomes.contains(p) || p.startsWith('com.yandex.') || p.startsWith('ru.sberdevices.') ||
      _operatorHome(p);

  /// Set-top boxes of TV operators: their home IS the TV service (Dom.ru com.ertelecom.domrutvstb,
  /// Rostelecom, MTS, Beeline); switching it off would take the channels away.
  static bool _operatorHome(String p) =>
      p.startsWith('com.ertelecom.') || p.startsWith('ru.rt.') || p.startsWith('ru.mts.') ||
      p.startsWith('com.mts.') || p.startsWith('ru.beeline.') || p.startsWith('ru.kion.');

  /// What Home really opens when it is not ours: the firmware's own home, when it looks like
  /// one (declares HOME or is known). Null otherwise.
  Future<String?> _firmwareHome(AdbClient adb) async {
    try {
      await adb.shell('input keyevent 3');
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      final front = await _frontPackage(adb);
      if (front == null || _neverOff(front)) return null;
      final homes = _parseComponents(await adb.shell(
          'cmd package query-activities --brief -a android.intent.action.MAIN '
          '-c android.intent.category.HOME 2>/dev/null'));
      if (homes.isEmpty) homes.addAll((await _oldCategories(adb))['HOME']!); // Android 5–6
      final ok = homes.contains(front) || _knownFirmwareHomes.contains(front);
      AppLog.error('firmware home', '$front (declares HOME: ${homes.contains(front)}) ${ok ? 'switching off' : 'left'}');
      return ok ? front : null;
    } catch (e) {
      AppLog.error('firmware home', e);
      return null;
    }
  }

  /// [_stockHomesOf] plus the firmware homes this TV remembers ([_firmwareHomesFile]).
  Future<List<String>> _stockHomes(AdbClient adb, Set<String> all) async {
    final saved = (await adb.shell('cat $_firmwareHomesFile 2>/dev/null'))
        .split(RegExp(r'\s+'))
        .where((p) => _pkgName.hasMatch(p) && all.contains(p) && !_neverOff(p));
    return {..._stockHomesOf(all), ...saved}.toList();
  }

  static final _pkgName = RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$');

  /// Google TV's home and its setup screen: switched off only when nothing else keeps
  /// Home on our launcher (see [_bind]); always switched back on with our launcher removed.
  static const _googleTvHomes = [
    'com.google.android.apps.tv.launcherx',
    'com.google.android.tungsten.setupwraith',
  ];

  /// Xiaomi's own packages are never switched off to pin our launcher (1.3.66), PatchWall
  /// included: a Xiaomi reset itself to factory two seconds after «Установить лаунчер» (#46);
  /// a Chinese MiTV (MFTR0, OS 2) with com.mitv.tvhome off had no home screen at all, and its
  /// HOME allow-list let our launcher be home only until the next reboot (#2: dark screen the
  /// next day, Home and Back dead); its fallback home lives in com.xiaomi.mitv.settings.
  /// The Home-key service keeps Home on ours there instead.
  static bool _xiaomiOwn(String p) =>
      p.startsWith('com.mitv.') || p.startsWith('com.xiaomi.') || p.startsWith('com.miui.');

  /// Names of what a TV can't live without: settings, setup, network, the system UI.
  static final _vitalName =
      RegExp(r'settings|setup|provision|network|wifi|systemui|framework|fallback|bluetooth', caseSensitive: false);

  /// May the pinning switch [p] off? Never a core part of the firmware: an app running as the
  /// system user (on TCL and others the home can share it with network and settings services:
  /// a TCL Smart TV Pro lost Wi‑Fi at «Установить лаунчер» and needed a factory reset, #3),
  /// a persistent one, or one whose name says it is vital.
  Future<bool> _safeToSwitchOff(AdbClient adb, String p) async {
    if (_neverOff(p) || _xiaomiOwn(p) || _vitalName.hasMatch(p)) {
      AppLog.error('pin', 'kept $p: never switched off');
      return false;
    }
    try {
      final why = unsafeDump(await adb.shell(
          'dumpsys package $p 2>/dev/null | grep -m8 -E "userId=|appId=|sharedUser=|pkgFlags=|flags="'));
      if (why == null) return true;
      AppLog.error('pin', 'kept $p: $why');
    } catch (e) {
      AppLog.error('pin', 'kept $p: $e');
    }
    return false;
  }

  /// Firmware homes older versions switched off that the pinning would never touch now
  /// ([_safeToSwitchOff]): a Rombica 65MT-UDG54G (Android 13, Amlogic) had Home on its setup
  /// wizard com.droidlogic.setupwizard; 1.3.2x took it off as «the firmware's launcher», and the
  /// TV hung on the boot logo at a later start. Put back at the next connection (scan, «Сделать
  /// главным ещё раз»), before the TV restarts; Home stays ours through the Home-key service.
  Future<void> _healUnsafePins(AdbClient adb) async {
    try {
      final saved = (await adb.shell('cat $_firmwareHomesFile 2>/dev/null'))
          .split(RegExp(r'\s+'))
          .where(_pkgName.hasMatch)
          .toList();
      if (saved.isEmpty) return;
      final keep = <String>[];
      for (final p in saved) {
        if (await _safeToSwitchOff(adb, p)) {
          keep.add(p);
          continue;
        }
        AppLog.error('heal', 'switching $p back on');
        await adb.shell('pm install-existing $p >/dev/null 2>&1; pm enable $p 2>&1');
        // a setup wizard that stayed the home: the TV never finished its first setup
        if (RegExp('setup|provision', caseSensitive: false).hasMatch(p)) {
          await adb.shell('settings put global device_provisioned 1; settings put secure user_setup_complete 1');
        }
      }
      if (keep.length == saved.length) return;
      await adb.shell(keep.isEmpty ? 'rm -f $_firmwareHomesFile' : "echo '${keep.join(' ')}' > $_firmwareHomesFile");
    } catch (e) {
      AppLog.error('heal', e);
    }
  }

  /// Why a `dumpsys package` excerpt marks a core package (null: an ordinary app).
  static String? unsafeDump(String d) {
    if (RegExp(r'\b(userId|appId)=(1000|1001|1002|1027)\b').hasMatch(d)) return 'system uid';
    if (RegExp(r'android\.uid\.(system|phone|bluetooth|nfc|shell)').hasMatch(d)) return 'shared system uid';
    if (RegExp(r'\bPERSISTENT\b').hasMatch(d)) return 'persistent';
    return null;
  }

  /// Does the TV take our launcher as a home screen at all? Firmwares with a HOME allow-list
  /// (Chinese Xiaomi, OS 3) never list it: there switching their home off leaves nothing.
  Future<bool> _ourHomeListed(AdbClient adb) async {
    final homes = _parseComponents(await adb.shell(
        'cmd package query-activities --brief -a android.intent.action.MAIN '
        '-c android.intent.category.HOME 2>/dev/null'));
    if (homes.isEmpty) homes.addAll((await _oldCategories(adb))['HOME']!); // Android 5–6
    return homes.contains(launcherPkg);
  }

  /// The TV still has a network (the home just switched off did not take Wi‑Fi with it).
  /// Answering at all means ADB over the network works; a TV on Ethernet or an emulator
  /// may print nothing, which counts as up.
  Future<bool> _networkUp(AdbClient adb) async {
    try {
      final out = await adb.shell('ip route 2>&1 | grep -c .');
      final n = int.tryParse(out.trim());
      if (n == 0) {
        AppLog.error('pin', 'no network routes after switching the home off');
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  static const _guardDir = '/data/local/tmp';
  static const _guardLog = '$_guardDir/tvcleanzer_guard.log';

  /// The TV's own safety net for the pinning: a script on the TV switches [pkgs] back on in
  /// [seconds] unless [_keepGuard] marks the check as passed. For when the phone loses the TV
  /// halfway — Wi‑Fi gone together with a home (#3), the TV restarting, the app closed during
  /// the check. Runs past the ADB connection (HUP ignored). Returns its token (null: not armed).
  Future<String?> _armGuard(AdbClient adb, List<String> pkgs, {int seconds = 150}) async {
    if (pkgs.isEmpty || !pkgs.every(_pkgName.hasMatch)) return null;
    final token = '${DateTime.now().millisecondsSinceEpoch}';
    try {
      await adb.shell("printf '%s' '${guardScript(pkgs, seconds, token)}' > $_guardDir/tvcleanzer_guard_$token.sh; "
          '( nohup sh $_guardDir/tvcleanzer_guard_$token.sh 2>/dev/null || sh $_guardDir/tvcleanzer_guard_$token.sh ) '
          '</dev/null >/dev/null 2>&1 &');
      return token;
    } catch (e) {
      AppLog.error('guard', e);
      return null;
    }
  }

  /// The script [_armGuard] leaves on the TV (no single quotes: it is passed inside them).
  static String guardScript(List<String> pkgs, int seconds, String token) {
    final ok = '$_guardDir/tvcleanzer_ok_$token';
    final list = pkgs.join(' ');
    return [
      'trap "" HUP',
      'sleep $seconds',
      'if [ ! -f $ok ]; then',
      '  for p in $list; do pm install-existing \$p >/dev/null 2>&1; pm enable \$p >/dev/null 2>&1; done',
      '  echo "\$(date) put back: $list" >> $_guardLog',
      'fi',
      'rm -f $ok $_guardDir/tvcleanzer_guard_$token.sh',
    ].join('\n');
  }

  /// The check passed (or the phone put everything back itself): the guard does nothing.
  Future<void> _keepGuard(AdbClient adb, String? token) async {
    if (token == null) return;
    try {
      await adb.shell('touch $_guardDir/tvcleanzer_ok_$token');
    } catch (_) {}
  }

  /// What a guard had to put back since the last connection, into the «?» report.
  Future<void> _keepGuardLog(AdbClient adb) async {
    try {
      final log = (await adb.shell('cat $_guardLog 2>/dev/null')).trim();
      if (log.isNotEmpty) {
        AppLog.error('guard', log);
        await adb.shell('rm -f $_guardLog');
      }
    } catch (_) {}
  }

  /// Puts back stock home screens taken off by [_bind] (when our launcher is removed).
  Future<void> _restoreStockHomes(AdbClient adb) async {
    final all = _parsePackageList(await adb.shell('pm list packages -u 2>/dev/null')).toSet();
    final now = _parsePackageList(await adb.shell('pm list packages -e')).toSet();
    for (final p in await _stockHomes(adb, all)) {
      if (!all.contains(p) || now.contains(p)) continue;
      AppLog.error('restore home', p);
      await adb.shell('pm install-existing $p');
      await adb.shell('pm enable $p');
    }
  }

  /// The stock homes TVCleanzer may have switched off on this TV, and so may switch back on.
  /// Google TV: only launcherx and its setup screen. Its old Android TV home (tvlauncher,
  /// leanback) comes switched off from the factory there and must stay off: turning it on
  /// with «Вернуть стандартный лаунчер» left a Google TV box restarting in a loop.
  static List<String> _stockHomesOf(Set<String> installed) =>
      installed.contains('com.google.android.apps.tv.launcherx') ? _googleTvHomes : _removableHomes;

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
      // Never leave the TV without a home screen: our launcher goes only when another one is
      // there to take Home (a Xiaomi Box 4K 2nd Gen ended up restarting in a loop with its
      // Google TV Home switched off and our launcher removed).
      final homes = _parseComponents(await adb.shell(
          'cmd package query-activities --brief -a android.intent.action.MAIN '
          '-c android.intent.category.HOME 2>/dev/null'));
      if (homes.isEmpty) homes.addAll((await _oldCategories(adb))['HOME']!); // Android 5–6
      final enabled = _parsePackageList(await adb.shell('pm list packages -e')).toSet();
      final saved = (await adb.shell('cat $_firmwareHomesFile 2>/dev/null')).split(RegExp(r'\s+'));
      final others = {...homes, ...saved.where(_knownFirmwareHomes.contains)}
          .where((p) => p != launcherPkg && enabled.contains(p)
              && p != 'com.android.tv.settings' && p != 'com.android.settings').toList();
      if (others.isEmpty) {
        AppLog.error('uninstall launcher', 'no other home: ${homes.join(', ')}');
        throw AdbException(tr('Не удалось включить родной главный экран телевизора, поэтому наш лаунчер оставлен (иначе остался бы чёрный экран). Пришлите отчёт через «?».'));
      }
      await _setHomeKeyService(adb, enabled: false);
      await adb.shell('rm -f $_firmwareHomesFile');
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
      // 0.31+: HDMI and other inputs (older launchers answer with apps rows: no id= there)
      final inp = await adb.shell('content query --uri content://com.tvcleanzer.launcher.state/inputs 2>/dev/null');
      final inputs = [
        for (final m in RegExp(r'id=([^,]+), label=(.*)$', multiLine: true).allMatches(inp))
          LauncherInput(m.group(1)!.trim(), m.group(2)!.trim()),
      ];
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
        inputs: inputs,
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

  // ── «Живые обои» (launcher 0.61+) ────────────────────────────────────────

  static const liveWallLauncher = 61;
  static const liveWallMaxMb = 150;

  /// A short video looping without sound behind the TV's home screen: streamed into the
  /// launcher (content write …/wallvideo; Android 10+, the launcher's external dir before).
  Future<void> setLiveWall(TvDevice device, Stream<List<int>> data, int length,
      {void Function(int sent)? onProgress}) async {
    const tmp = '/data/local/tmp/tvcleanzer_wallvideo';
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      final freeKb = await _dataFreeKb(adb);
      final needKb = length * 2 ~/ 1024 + 200 * 1024;
      if (freeKb > 0 && freeKb < needKb) {
        throw AdbException(tr('На телевизоре мало места: нужно {0} МБ, свободно {1} МБ.',
            ['${needKb ~/ 1024}', '${freeKb ~/ 1024}']));
      }
      await adb.execInStream('cat > $tmp', data, onProgress: onProgress,
          timeout: Duration(seconds: max(120, length ~/ (1024 * 1024))));
      final size = int.tryParse((await adb.shell('wc -c < $tmp')).trim().split(RegExp(r'\s+')).first) ?? -1;
      if (size != length) {
        await adb.shell('rm -f $tmp');
        throw AdbException(tr('Файл не дошёл до телевизора. Попробуйте ещё раз.'));
      }
      final sdk = int.tryParse((await adb.shell('getprop ro.build.version.sdk')).trim()) ?? 0;
      var ok = false;
      if (sdk >= 29) {
        ok = (await adb.shell('content write --uri content://$launcherPkg.state/wallvideo < $tmp && echo TVC_OK',
                timeout: Duration(seconds: max(60, length ~/ (10 * 1024 * 1024)))))
            .contains('TVC_OK');
      }
      if (!ok) {
        ok = (await adb.shell('mkdir -p $_launcherFiles && cp $tmp $_launcherFiles/wallvideo.mp4 '
                '&& chmod 666 $_launcherFiles/wallvideo.mp4 && echo TVC_OK',
                timeout: Duration(seconds: max(60, length ~/ (10 * 1024 * 1024)))))
            .contains('TVC_OK');
      }
      await adb.shell('rm -f $tmp');
      if (!ok) {
        throw AdbException(tr('Телевизор не дал сохранить видео. Обновите лаунчер на ТВ и попробуйте снова.'));
      }
      await _broadcast(adb, '--es liveWall set --ez liveWallOn true');
    } finally {
      adb.close();
    }
  }

  Future<void> removeLiveWall(TvDevice device) => _apply(device, '--es liveWall none');

  Future<void> setLiveWallOn(TvDevice device, bool on) => _apply(device, '--ez liveWallOn $on');

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

  // ── Music in the photo frame (launcher 0.61+) ────────────────────────────

  static const musicExts = ['mp3', 'm4a', 'aac', 'ogg', 'oga', 'opus', 'flac', 'wav'];
  static const musicLauncher = 61;

  /// Extension the launcher keeps the track under ('mp3' when unknown).
  static String musicExt(String name) {
    final e = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return musicExts.contains(e) ? e : 'mp3';
  }

  /// Sends tracks one by one, read from disk piece by piece: /data/local/tmp, then into the
  /// launcher (content write …/music/<ext> on Android 10+, its external files dir before that).
  /// Returns how many the TV kept.
  Future<int> addMusic(TvDevice device, List<({String name, int length, Stream<List<int>> Function() open})> tracks,
      {void Function(int done, int total)? onProgress}) async {
    const tmp = '/data/local/tmp/tvcleanzer_music';
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      final total = tracks.fold<int>(0, (a, t) => a + t.length);
      final freeKb = await _dataFreeKb(adb);
      final needKb = total ~/ 1024 * 2 + 200 * 1024; // the copy in tmp + the launcher's own + room
      if (freeKb > 0 && freeKb < needKb) {
        throw AdbException(tr('На телевизоре мало места: нужно {0} МБ, свободно {1} МБ.',
            ['${needKb ~/ 1024}', '${freeKb ~/ 1024}']));
      }
      final sdk = int.tryParse((await adb.shell('getprop ro.build.version.sdk')).trim()) ?? 0;
      var stored = 0;
      for (var i = 0; i < tracks.length; i++) {
        onProgress?.call(i, tracks.length);
        final t = tracks[i];
        final ext = musicExt(t.name);
        await adb.execInStream('cat > $tmp', t.open(),
            timeout: Duration(seconds: max(120, t.length ~/ (1024 * 1024))));
        final size = int.tryParse((await adb.shell('wc -c < $tmp')).trim().split(RegExp(r'\s+')).first);
        if (size != t.length) continue;
        var ok = false;
        if (sdk >= 29) {
          ok = (await adb.shell('content write --uri content://$launcherPkg.state/music/$ext < $tmp && echo TVC_OK'))
              .contains('TVC_OK');
        }
        if (!ok) {
          final name = 'm${DateTime.now().millisecondsSinceEpoch}_$i.$ext';
          ok = (await adb.shell('mkdir -p $_launcherFiles/music && cp $tmp $_launcherFiles/music/$name '
                  '&& chmod 666 $_launcherFiles/music/$name && echo TVC_OK'))
              .contains('TVC_OK');
        }
        if (ok) stored++;
      }
      await adb.shell('rm -f $tmp');
      await _broadcast(adb, '--es music added');
      onProgress?.call(tracks.length, tracks.length);
      if (stored == 0) {
        throw AdbException(tr('Телевизор не дал сохранить музыку. Обновите лаунчер на ТВ и попробуйте снова.'));
      }
      return stored;
    } finally {
      adb.close();
    }
  }

  Future<void> clearMusic(TvDevice device) => _apply(device, '--es music clear');

  Future<void> setFrameMusic(TvDevice device, bool on) => _apply(device, '--ez frameMusic $on');

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

  /// The screen timeout before [clean] made it longer (put back by [rollback]).
  static const _screenOffFile = '/data/local/tmp/tvcleanzer_screen_off';

  /// Screen timeout after the screensaver was cleaned away: at least [longScreenOffMin].
  Future<void> _longerScreenTimeout(AdbClient adb) async {
    try {
      final ms = int.tryParse((await adb.shell('settings get system screen_off_timeout')).trim()) ?? 0;
      if (ms <= 0 || ms >= longScreenOffMin * 60000) return;
      await adb.shell('[ -f $_screenOffFile ] || echo $ms > $_screenOffFile; '
          'settings put system screen_off_timeout ${longScreenOffMin * 60000}');
      AppLog.error('screen timeout', 'screensaver removed: ${ms ~/ 60000} min → $longScreenOffMin min');
    } catch (e) {
      AppLog.error('screen timeout', e);
    }
  }

  /// What [clean] sets when no screensaver is left, and the «Экран и сон» suggestion: 4 hours.
  static const longScreenOffMin = 240;

  /// «Never» for the screen timeout (Android's largest value).
  static const neverMs = 2147483647;

  /// How the TV goes dark without the remote: minutes of the screen timeout (0 unknown,
  /// -1 never) and whether a working screensaver comes then (otherwise the TV goes to sleep).
  Future<({int minutes, bool screensaver})> screenSleep(TvDevice device) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      final ms = int.tryParse((await adb.shell('settings get system screen_off_timeout')).trim()) ?? 0;
      final comp = (await adb.shell('settings get secure screensaver_components')).trim();
      final on = (await adb.shell('settings get secure screensaver_enabled')).trim() != '0';
      final pkg = comp.split(',').first.split('/').first;
      var saver = false;
      if (on && _pkgName.hasMatch(pkg)) {
        saver = _parsePackageList(await adb.shell('pm list packages -e $pkg')).contains(pkg);
      }
      return (minutes: sleepMinutes(ms), screensaver: saver);
    } finally {
      adb.close();
    }
  }

  /// screen_off_timeout (ms) → minutes for the UI: 0 unknown, -1 never.
  static int sleepMinutes(int ms) => ms <= 0 ? 0 : ms >= neverMs ~/ 2 ? -1 : (ms / 60000).round();

  /// Sets the screen timeout; [minutes] -1 = never.
  Future<void> setScreenSleep(TvDevice device, int minutes) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      await adb.shell('settings put system screen_off_timeout ${minutes < 0 ? neverMs : minutes * 60000}; '
          'rm -f $_screenOffFile');
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

  /// For «?» reports when Home stays on the stock home: what our service saw (launcher 0.65+
  /// logs it) and whether Android refused to start our home.
  Future<void> _logHomeService(AdbClient adb) async {
    try {
      final v = RegExp(r'versionName=(\S+)')
          .firstMatch(await adb.shell('dumpsys package $launcherPkg 2>/dev/null | grep -m1 versionName'))
          ?.group(1);
      // by tag: a busy TCL logcat pushed our lines out of the last 2000 within seconds
      final ours = await adb.shell('logcat -d -s TVCleanzerHome:I 2>/dev/null | grep -v "^-" | tail -7');
      final blocked = await adb.shell('logcat -d 2>/dev/null | '
          'grep -iE "background activity start|abort.*tvcleanzer|app switch" | tail -2');
      final lines = '$ours\n$blocked'.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
      AppLog.error('home service', 'launcher $v; ${lines.isEmpty ? 'nothing in logcat' : '${lines.length} lines'}');
      for (final l in lines) {
        final i = l.indexOf(RegExp(r' [IWE] '));
        AppLog.error('hs', i < 0 ? l : l.substring(i + 3));
      }
    } catch (_) {}
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
  /// The virtual mouse draws through the Home-key service: on and running first.
  Future<void> ensureHomeKeyService(AdbClient adb) => _ensureHomeKeyService(adb);

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
    // For «?» reports: did the setting stick at all (a be311 box: it read back null)?
    final back = (await adb.shell('settings get secure enabled_accessibility_services')).trim();
    final declared = (await adb.shell('dumpsys package $launcherPkg 2>/dev/null | grep -c HomeKeyService')).trim();
    AppLog.error('home key service', 'not running; setting=$back; declared=$declared');
  }

  /// Launcher 0.29+: whether its service catches remote keys (older ones ignore it).
  Future<void> _setKeyFilter(AdbClient adb, bool on) async {
    await adb.shell('am broadcast -n $launcherPkg/.ConfigReceiver -a com.tvcleanzer.launcher.APPLY --ez keyFilter $on');
    await Future<void>.delayed(const Duration(milliseconds: 500));
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
      final out = await adb.shell("settings put secure enabled_accessibility_services '${list.join(':')}' 2>&1; "
          'settings put secure accessibility_enabled 1 2>&1');
      if (out.trim().isNotEmpty) AppLog.error('home key service', out.trim());
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

  /// App opened when the TV is switched on ('' = the launcher itself). Launcher 0.6+;
  /// «input:<id>» (an HDMI input or the TV's live TV) needs 0.31+.
  Future<void> setLauncherAutostart(TvDevice device, String pkg) async {
    if (pkg.isNotEmpty &&
        !RegExp(r'^[A-Za-z0-9_.]+$').hasMatch(pkg) &&
        !RegExp(r'^input:[A-Za-z0-9_.:/$-]+$').hasMatch(pkg)) {
      return;
    }
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      await adb.shell('am broadcast -n $launcherPkg/.ConfigReceiver '
          "-a com.tvcleanzer.launcher.APPLY --es autostart ${pkg.isEmpty ? '""' : "'$pkg'"}");
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
  /// For «Сообщить о проблеме»: the launcher version and what its Home-key service did last
  /// (launcher 0.65+ logs it as TVCleanzerHome). Empty when the TV does not answer.
  Future<String> launcherServiceLog(TvDevice device) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect().timeout(const Duration(seconds: 4));
      final v = RegExp(r'versionName=(\S+)')
          .firstMatch(await adb.shell('dumpsys package $launcherPkg 2>/dev/null | grep -m1 versionName'))
          ?.group(1);
      if (v == null) return '';
      // is the Home-key service on and really running, and how long since the TV booted
      final acc = (await adb.shell('settings get secure enabled_accessibility_services')).contains('tvcleanzer');
      final bound = (await adb.shell('dumpsys accessibility 2>/dev/null | grep -i "bound services"'))
          .toLowerCase()
          .contains('tvcleanzer');
      final up = double.tryParse((await adb.shell('cat /proc/uptime')).trim().split(' ').first)?.round() ?? 0;
      final grant = (await adb.shell('dumpsys package $launcherPkg 2>/dev/null | grep -c "WRITE_SECURE_SETTINGS: granted=true"')).trim();
      // accessibility as a whole off, or the firmware force-stopping our app at boot (then no
      // broadcast and no job reaches it)
      final accOn = (await adb.shell('settings get secure accessibility_enabled')).trim();
      final stopped = RegExp(r'stopped=(\w+)')
              .firstMatch(await adb.shell('dumpsys package $launcherPkg 2>/dev/null | grep -m1 "stopped="'))
              ?.group(1) ??
          '?';
      final out = await adb.shell('logcat -d -s TVCleanzerHome:I 2>/dev/null | grep -v "^-" | tail -12');
      final lines = out
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .map((l) {
            final i = l.indexOf(RegExp(r' [IWE] '));
            final t = l.length > 18 ? l.substring(6, 14) : '';
            var m = i < 0 ? l : l.substring(i + 3).replaceFirst('TVCleanzerHome: ', '');
            if (m.length > 160) m = '${m.substring(0, 160)}…';
            return '$t $m';
          })
          .toList();
      // a firmware that switches the service straight back off (T95 / be311 box): did it crash,
      // or did the system turn it off?
      final crash = (await adb.shell('logcat -d -b crash 2>/dev/null | grep -A3 "Process: com.tvcleanzer.launcher" | tail -4; '
              'logcat -d 2>/dev/null | grep -iE "tvcleanzer.launcher/.HomeKeyService|accessibilityservice.*tvcleanzer" | tail -3'))
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .map((l) => l.length > 160 ? '${l.substring(0, 160)}…' : l)
          .toList();
      return '--- launcher $v ---\nservice: on $acc, running $bound, boot ${up ~/ 60} min ago, keeper ${grant == '0' ? 'no' : 'yes'}, '
          'accessibility $accOn, stopped $stopped\n'
          '${lines.join('\n')}\n'
          '${crash.isEmpty ? '' : '--- system ---\n${crash.join('\n')}\n'}';
    } catch (_) {
      return '';
    } finally {
      adb.close();
    }
  }

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
      if (launchable.isEmpty) {
        final old = await _oldCategories(adb); // Android 5–6: no `cmd`
        launchable..addAll(old['LEANBACK_LAUNCHER']!)..addAll(old['LAUNCHER']!);
      }
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

  // ── Remote extras: cast, links, search, screenshot, sleep timer ────────────────────────

  /// Single-quoted for the TV's shell.
  static String _sq(String s) => "'${s.replaceAll("'", "'\\''")}'";

  /// Where «Отправить файл на ТВ» puts files: the TV's Download folder, seen by its file
  /// managers, players and IPTV apps («Добавить плейлист» → файл). The top idea in the chat:
  /// IPTV playlists and files from the phone to the TV without a USB stick.
  static const tvFilesDir = '/sdcard/Download/TVCleanzer';

  /// A file name safe for the TV's shell and file managers (letters of any language kept).
  static String tvFileName(String name) {
    var n = name.replaceAll(RegExp(r'[^\p{L}\p{N}._ -]', unicode: true), '_').trim();
    if (n.isEmpty || n.startsWith('.')) n = 'file$n';
    return n.length > 120 ? n.substring(n.length - 120) : n;
  }

  /// MIME type by extension, for «Открыть на ТВ».
  static String mimeOf(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'm3u' || 'm3u8' => 'audio/x-mpegurl',
      'xspf' => 'application/xspf+xml',
      'mp4' || 'm4v' || 'mkv' || 'avi' || 'mov' || 'webm' || 'ts' || '3gp' || 'wmv' || 'flv' => 'video/*',
      'mp3' || 'm4a' || 'aac' || 'flac' || 'ogg' || 'wav' || 'opus' => 'audio/*',
      'jpg' || 'jpeg' || 'png' || 'webp' || 'gif' || 'heic' || 'bmp' => 'image/*',
      'pdf' => 'application/pdf',
      'txt' || 'srt' || 'log' => 'text/plain',
      'apk' => 'application/vnd.android.package-archive',
      _ => '*/*',
    };
  }

  /// Sends a file from the phone into [tvFilesDir] on the TV, piece by piece (a film of several
  /// gigabytes never has to fit in the phone's memory). Returns its path on the TV.
  Future<String> sendFile(TvDevice device, String name, Stream<List<int>> data, int length,
      {void Function(int sent)? onProgress}) async {
    final path = '$tvFilesDir/${tvFileName(name)}';
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      await adb.shell('mkdir -p $tvFilesDir');
      final freeKb = await _dataFreeKb(adb);
      final needKb = length ~/ 1024 + 200 * 1024; // the file + room for the TV itself
      if (freeKb > 0 && freeKb < needKb) {
        throw AdbException(tr('На телевизоре мало места: нужно {0} МБ, свободно {1} МБ.',
            ['${needKb ~/ 1024}', '${freeKb ~/ 1024}']));
      }
      final t = Duration(seconds: max(120, length ~/ (2 * 1024 * 1024)));
      await adb.execInStream('cat > ${_sq(path)}', data, onProgress: onProgress, timeout: t);
      final size = int.tryParse((await adb.shell('wc -c < ${_sq(path)}')).trim().split(RegExp(r'\s+')).first) ?? -1;
      if (size != length) {
        await adb.shell('rm -f ${_sq(path)}');
        throw AdbException(tr('Файл не дошёл до телевизора. Попробуйте ещё раз.'));
      }
      // so galleries and players see it without a restart (refused on some firmwares: fine)
      await adb.shell('am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE '
          '-d ${_sq('file://$path')} >/dev/null 2>&1');
      return path;
    } finally {
      adb.close();
    }
  }

  /// Opens a file on the TV with an app that takes its type. False when none did.
  Future<bool> openTvFile(TvDevice device, String path) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      final out = await adb.shell('am start -a android.intent.action.VIEW -d ${_sq('file://$path')} '
          '-t ${_sq(mimeOf(path))} -f 0x10000001 2>&1');
      final ok = !RegExp(r'Error|Exception|No Activity|unable to resolve', caseSensitive: false).hasMatch(out);
      if (!ok) AppLog.error('open file on tv', out.trim());
      return ok;
    } finally {
      adb.close();
    }
  }

  /// Shows a photo / video from the phone on the TV (launcher 0.42+: StateProvider "cast" +
  /// CastActivity). [data] is read piece by piece, so a film of several gigabytes never has to
  /// fit in the phone's memory; the TV needs room for two copies for a moment (the upload,
  /// then the launcher's own). Throws with a readable message when space or the launcher is short.
  Future<void> castFile(TvDevice device, Stream<List<int>> data, int length, {required bool video,
      void Function(int sent)? onProgress, void Function()? onSaving}) async {
    const tmp = '/data/local/tmp/tvcleanzer_cast';
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    var waiting = false;
    try {
      await adb.connect();
      await adb.shell('rm -f $tmp');
      final freeKb = await _dataFreeKb(adb);
      final needKb = length * 2 ~/ 1024 + 300 * 1024; // two copies + room for the TV itself
      if (freeKb > 0 && freeKb < needKb) {
        throw AdbException(tr('На телевизоре мало места для этого видео: нужно {0} МБ, свободно {1} МБ.',
            ['${needKb ~/ 1024}', '${freeKb ~/ 1024}']));
      }
      if (video) {
        // the TV says «загружается» at once (launcher 0.61+; older ones just close this screen)
        await adb.shell('am start -n $launcherPkg/.CastActivity -f 0x10008000 --es type wait >/dev/null 2>&1');
        waiting = true;
      }
      await adb.execInStream('cat > $tmp', data, onProgress: onProgress, timeout: const Duration(seconds: 120));
      onSaving?.call();
      final size = int.tryParse((await adb.shell('wc -c < $tmp')).trim().split(RegExp(r'\s+')).first) ?? -1;
      if (size != length) {
        await adb.shell('rm -f $tmp');
        throw AdbException(tr('Файл не дошёл до телевизора. Попробуйте ещё раз.'));
      }
      // the TV's flash copies some 20 MB/s on a slow box
      final copy = Duration(seconds: max(120, length ~/ (10 * 1024 * 1024)));
      final w = await adb.shell('content write --uri content://$launcherPkg.state/cast < $tmp 2>&1 && echo TVC_OK',
          timeout: copy);
      await adb.shell('rm -f $tmp');
      if (!w.contains('TVC_OK')) {
        throw AdbException(tr('Обновите лаунчер на ТВ: показ фото и видео с телефона есть в новой версии.'));
      }
      final out = await adb.shell('am start -n $launcherPkg/.CastActivity -f 0x10008000 '
          '--es type ${video ? 'video' : 'image'} 2>&1');
      waiting = false;
      if (out.contains('Error')) {
        throw AdbException(tr('Обновите лаунчер на ТВ: показ фото и видео с телефона есть в новой версии.'));
      }
    } finally {
      if (waiting) {
        // the upload broke off: take the «загружается» screen away
        await adb.shell('am start -n $launcherPkg/.CastActivity -f 0x10008000 --es type close >/dev/null 2>&1')
            .catchError((_) => '');
      }
      adb.close();
    }
  }

  /// Opens the launcher's «Повтор экрана» screen, listening on [port] for the phone with
  /// [token] (launcher 0.43+). False when the launcher on the TV is older.
  /// [phone]:[phonePort] — the phone's own port, which the TV dials too (launcher 0.45+).
  Future<bool> startMirror(TvDevice device,
      {required int port, required String token, String? phone, int phonePort = 0}) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      final back = phone != null && phonePort > 0 ? ' --es phone $phone --ei phonePort $phonePort' : '';
      final out = await adb.shell('am start -n $launcherPkg/.MirrorActivity -f 0x10000000 '
          '--ei port $port --es token $token$back 2>&1');
      return !out.contains('Error') && !out.contains('does not exist');
    } finally {
      adb.close();
    }
  }

  /// Closes the TV's mirror screen (the phone's owner cancelled before it began).
  Future<void> closeMirror(TvDevice device) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      await adb.shell('am start -n $launcherPkg/.MirrorActivity -f 0x10000000 --ez close true 2>&1');
    } catch (_) {
    } finally {
      adb.close();
    }
  }

  /// Opens a link on the TV: YouTube links go to the YouTube app, others to a browser.
  Future<bool> openUrl(TvDevice device, String url) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      final out = await adb.shell('am start -a android.intent.action.VIEW -d ${_sq(url)} 2>&1');
      return !out.contains('Error');
    } finally {
      adb.close();
    }
  }

  /// The TV's own search with [query] (Android TV / Google TV); else the Search key.
  static const youtubeTv = 'com.google.android.youtube.tv';

  /// Did `am start` reach an activity? («Warning: … delivered to currently running» is fine.)
  static bool started(String out) =>
      !RegExp(r'Error|Exception|unable to resolve|No Activity found', caseSensitive: false).hasMatch(out);

  /// Searches for [query] where the owner is: in the app on screen (YouTube, VK Видео,
  /// Кинопоиск… take a SEARCH intent with the words), else in the TV's own search. Typing
  /// Russian text into YouTube's search box can't work (it ignores Paste) — this does (tester, 22.11).
  /// Returns the package that got the search ('' = the TV's search).
  Future<String> tvSearch(TvDevice device, String query) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      final q = _sq(query);
      final front = await _frontPackage(adb);
      if (front == youtubeTv) {
        var out = await adb.shell('am start -a android.intent.action.SEARCH '
            '-n $youtubeTv/com.google.android.apps.youtube.tv.activity.ShellActivity --es query $q 2>&1');
        if (started(out)) return youtubeTv;
        final url = 'https://www.youtube.com/results?search_query=${Uri.encodeQueryComponent(query)}';
        out = await adb.shell('am start -a android.intent.action.VIEW -d ${_sq(url)} $youtubeTv 2>&1');
        if (started(out)) return youtubeTv;
      } else if (front != null && front != launcherPkg && front != 'android' &&
          !RegExp(r'systemui|launcher|tvhome|\.home').hasMatch(front)) {
        // an app, not a home screen: home screens go to the TV's own search below
        final out = await adb.shell('am start -a android.intent.action.SEARCH -p $front --es query $q 2>&1');
        if (started(out)) return front;
      }
      final out = await adb.shell('am start -a android.search.action.GLOBAL_SEARCH --es query $q 2>&1');
      if (!started(out)) await adb.shell('input keyevent 84');
      return '';
    } finally {
      adb.close();
    }
  }

  /// A PNG of what the TV shows right now.
  Future<Uint8List> screenshot(TvDevice device) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      final png = await adb.execOut('screencap -p', timeout: const Duration(seconds: 20));
      if (png.length < 8 || png[1] != 0x50 || png[2] != 0x4E || png[3] != 0x47) {
        throw AdbException(tr('Телевизор не дал сделать снимок экрана.'));
      }
      return png;
    } finally {
      adb.close();
    }
  }

  static const _sleepPid = '/data/local/tmp/tvcleanzer_sleep';

  /// Puts the TV to sleep in [minutes] (a shell timer on the TV itself: works with the phone
  /// away). 0 cancels.
  Future<void> sleepTimer(TvDevice device, int minutes) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      await adb.shell('[ -f $_sleepPid ] && kill \$(cat $_sleepPid) 2>/dev/null; rm -f $_sleepPid');
      if (minutes <= 0) return;
      // its own session: survives the end of this ADB connection
      final job = "echo \$\$ > $_sleepPid; sleep ${minutes * 60}; rm -f $_sleepPid; input keyevent 223";
      await adb.shell('if command -v setsid >/dev/null 2>&1; then setsid sh -c ${_sq(job)} '
          '>/dev/null 2>&1 < /dev/null & else nohup sh -c ${_sq(job)} >/dev/null 2>&1 < /dev/null & fi');
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

  /// `install -r` failed in a way only removing the old copy fixes: another signing key, or a
  /// copy kept for no user (`pm uninstall --user 0` left it half there).
  static bool needsCleanReinstall(String res) => RegExp(
          r'UPDATE_INCOMPATIBLE|INSTALL_FAILED_DUPLICATE_PERMISSION|INSTALL_FAILED_ALREADY_EXISTS|'
          r'INSTALL_FAILED_SHARED_USER_INCOMPATIBLE|signatures do not match|INCONSISTENT_CERTIFICATES')
      .hasMatch(res);

  static String _installError(String out, {bool launcher = false}) {
    final o = out.trim();
    if (launcher && o.contains('VERSION_DOWNGRADE')) {
      return tr('На телевизоре лаунчер новее, чем в этом приложении. Обновите TVCleanzer на телефоне.');
    }
    if (launcher && needsCleanReinstall(o)) {
      return tr('Старый лаунчер не удалось заменить: {0}. Пришлите отчёт через «?».', [_installReason(o)]);
    }
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
    return tr('Установка не удалась: {0}', [_installReason(o)]);
  }

  /// The line that says why: «Failure [...]», else the exception line. A Java stack trace ends
  /// with «... 13 more», which is all a MiTV-MOOQ1 report showed.
  static String _installReason(String o) {
    final lines = o.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    if (lines.isEmpty) return '—';
    for (final l in lines) {
      if (l.contains('Failure') || l.contains('INSTALL_FAILED')) return l;
    }
    for (final l in lines) {
      if (!l.startsWith('at ') && !l.startsWith('...') && RegExp(r'Exception|Error').hasMatch(l)) {
        return l.length > 200 ? l.substring(0, 200) : l;
      }
    }
    return lines.last;
  }

  // ── TV language and keyboard ─────────────────────────────────────────────────

  /// The TV's keyboards: every input method it has (`ime list -a -s`), the switched-on ones
  /// and the one in use. After a reset a Chinese Xiaomi typed only Chinese in every search
  /// (MFTR0): the seller's keyboard was still there, just not chosen.
  Future<({List<String> all, Set<String> enabled, String current})> keyboards(TvDevice device) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      List<String> ids(String out) =>
          out.split('\n').map((l) => l.trim()).where(_component.hasMatch).toList();
      final all = ids(await adb.shell('ime list -a -s 2>/dev/null'));
      final enabled = ids(await adb.shell('ime list -s 2>/dev/null')).toSet();
      final current = (await adb.shell('settings get secure default_input_method')).trim();
      for (final e in [...enabled, if (_component.hasMatch(current)) current]) {
        if (!all.contains(e)) all.add(e);
      }
      return (all: all, enabled: enabled, current: current);
    } finally {
      adb.close();
    }
  }

  /// Makes [id] the TV's keyboard (switched on first). True when the TV reads it back.
  Future<bool> setKeyboard(TvDevice device, String id) async {
    if (!_component.hasMatch(id)) return false;
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      final pkg = id.split('/').first;
      final out = await adb.shell('pm enable $pkg >/dev/null 2>&1; ime enable $id 2>&1; ime set $id 2>&1');
      final now = (await adb.shell('settings get secure default_input_method')).trim();
      if (now != id) AppLog.error('keyboard', '$id: ${out.trim()} (now $now)');
      return now == id;
    } finally {
      adb.close();
    }
  }

  /// A readable name for a keyboard id; the package name when we don't know it.
  static String keyboardName(String id) {
    final p = id.split('/').first;
    if (p == 'com.google.android.leanback.ime') return tr('Клавиатура Android TV (Leanback)');
    if (p == 'com.google.android.inputmethod.latin') return 'Gboard';
    if (p == 'com.android.inputmethod.latin') return tr('Клавиатура Android');
    if (p.contains('sogou')) return tr('Sogou (китайская)');
    if (p.contains('baidu')) return tr('Baidu (китайская)');
    if (p.contains('pinyin') || p.contains('iflytek')) return tr('Китайская клавиатура');
    if (p.contains('yandex')) return tr('Яндекс Клавиатура');
    if (p.contains('swiftkey')) return 'SwiftKey';
    if (p.contains('tvcleanzer')) return 'TVCleanzer';
    return p;
  }

  /// The TV's system language tag ("ru-RU"), or '' when it says nothing.
  Future<String> tvLocale(TvDevice device) async {
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      return localeFrom(await adb.shell(
          'getprop persist.sys.locale; settings get system system_locales; getprop ro.product.locale'));
    } finally {
      adb.close();
    }
  }

  /// The first real language tag in [out] (lines of getprop / settings; "null" skipped).
  static String localeFrom(String out) {
    for (final l in out.split('\n')) {
      final t = l.trim().split(',').first.trim();
      if (RegExp(r'^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$').hasMatch(t)) return t;
    }
    return '';
  }

  /// Changes the TV's system language to [tag] ("ru-RU") through our launcher (0.59+): Android
  /// lets an app do it once ADB grants CHANGE_CONFIGURATION. Returns '' when done, else why not.
  Future<String> setTvLocale(TvDevice device, String tag) async {
    if (!RegExp(r'^[a-z]{2,3}(-[A-Z]{2})?$').hasMatch(tag)) return 'bad tag';
    final adb = AdbClient.open(host: device.ipAddress, port: device.port);
    try {
      await adb.connect();
      final v = await adb.shell('dumpsys package $launcherPkg | grep -m1 versionCode');
      final code = int.tryParse(RegExp(r'versionCode=(\d+)').firstMatch(v)?.group(1) ?? '') ?? 0;
      if (code < 59) {
        return tr('Нужен TVCleanzer Launcher 0.59 или новее: установите или обновите его на вкладке «Лаунчер».');
      }
      final g = await adb.shell('pm grant $launcherPkg android.permission.CHANGE_CONFIGURATION 2>&1');
      if (g.trim().isNotEmpty) AppLog.error('locale grant', g.trim());
      final out = await adb.shell('am broadcast -n $launcherPkg/.ConfigReceiver '
          '-a com.tvcleanzer.launcher.APPLY --es locale $tag 2>&1');
      final data = RegExp(r'data="([^"]*)"').firstMatch(out)?.group(1) ?? out.trim();
      await Future<void>.delayed(const Duration(seconds: 2));
      final now = localeFrom(await adb.shell('getprop persist.sys.locale; settings get system system_locales'));
      if (data == 'ok' || now.split('-').first == tag.split('-').first) return '';
      AppLog.error('locale $tag', '$data (now ${now.isEmpty ? '-' : now})');
      return tr('Телевизор не дал сменить язык: {0}', [data.isEmpty ? '—' : data]);
    } finally {
      adb.close();
    }
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
