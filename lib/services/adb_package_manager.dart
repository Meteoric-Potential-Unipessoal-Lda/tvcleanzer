import 'dart:convert';

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

      // Run a single getprop call to get extra properties
      final propOut = await adb.shell(
          'getprop ro.product.brand && '
          'getprop ro.product.model && '
          'getprop ro.build.version.release && '
          'getprop ro.build.version.sdk && '
          'cat /proc/meminfo | head -1');

      final lines  = propOut.split('\n').map((l) => l.trim()).toList();
      final brand  = lines.isNotEmpty ? lines[0] : (cnxnProps['ro.product.brand'] ?? '');
      final model  = lines.length > 1 ? lines[1] : (cnxnProps['ro.product.model'] ?? 'Android TV');
      final ver    = lines.length > 2 ? lines[2] : (cnxnProps['ro.build.version.release'] ?? '?');
      final sdk    = int.tryParse(lines.length > 3 ? lines[3] : '') ?? 0;

      // Parse MemTotal from /proc/meminfo: "MemTotal:     1024000 kB"
      int ramMb = 0;
      if (lines.length > 4) {
        final m = RegExp(r'(\d+)').firstMatch(lines[4]);
        if (m != null) ramMb = int.parse(m.group(1)!) ~/ 1024;
      }

      return TvDevice.fromAdb(
        ip: ip,
        brand: brand,
        model: model,
        androidVer: ver,
        sdkVersion: sdk,
        ramMb: ramMb,
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
