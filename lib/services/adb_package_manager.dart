import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/tv_device.dart';
import 'adb_client.dart';

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

      final packages = pkgs.map((name) {
        final entry = db[name];
        return TvPackage(
          packageName: name,
          label:   entry?.label,
          sizeMb:  entry?.sizeMb ?? 0,
          verdict: entry?.verdict ?? PackageVerdict.keep,
          reason:  entry?.reason,
        );
      }).toList()
        ..sort((a, b) {
          // Sort: remove → caution → keep → system
          final order = {
            PackageVerdict.remove:  0,
            PackageVerdict.caution: 1,
            PackageVerdict.keep:    2,
            PackageVerdict.system:  3,
          };
          return (order[a.verdict] ?? 2).compareTo(order[b.verdict] ?? 2);
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
      await adb.shell('cmd package set-home-activity $launcherHome');
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

  static Future<Map<String, _Entry>> _loadDb() async {
    if (_db != null) return _db!;

    final raw  = await rootBundle.loadString('assets/packages.json');
    final list = jsonDecode(raw) as List<dynamic>;
    _db = {};
    for (final item in list) {
      final m = item as Map<String, dynamic>;
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
