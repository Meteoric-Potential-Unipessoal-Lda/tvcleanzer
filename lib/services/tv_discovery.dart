import 'dart:async';
import 'dart:io';

import 'package:network_info_plus/network_info_plus.dart';

import '../models/tv_device.dart';
import 'adb_package_manager.dart';

// ─── TV Discovery via ADB port 5555 ──────────────────────────────────────────

/// Scans the local Wi-Fi subnet for hosts with ADB port 5555 open,
/// then authenticates via ADB to retrieve device information.
///
/// Option A — no TV app required. TV just needs:
///   Settings → Developer Options → ADB over network → ON
class TvDiscovery {
  static const int _adbPort      = 5555;
  static const int _concurrency  = 32;  // parallel port-check sockets
  static const Duration _portTimeout = Duration(milliseconds: 500);
  static const Duration _adbTimeout  = Duration(seconds: 12);

  final AdbPackageManager _adb;
  TvDiscovery(this._adb);

  /// Yields discovered [TvDevice] objects as they are found.
  /// Completes when all IPs in the subnet have been probed.
  Stream<TvDevice> discover() async* {
    final subnet = await _subnetBase();
    if (subnet == null) return;

    // Build list of candidate IPs (1-254), excluding the router (.1)
    final ips = List.generate(253, (i) => '$subnet${i + 2}');

    // ── Phase 1: parallel port-5555 check ───────────────────────────────────
    final open = <String>[];
    await _inBatches(ips, _concurrency, (ip) async {
      if (await _isPortOpen(ip)) open.add(ip);
    });

    // ── Phase 2: ADB connect to each responding host ─────────────────────────
    for (final ip in open) {
      try {
        final device = await _adb
            .getDeviceInfo(ip)
            .timeout(_adbTimeout);
        yield device;
      } catch (_) {
        // Not an ADB device or auth failed — skip silently
      }
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  Future<bool> _isPortOpen(String ip) async {
    try {
      final sock = await Socket.connect(ip, _adbPort, timeout: _portTimeout);
      sock.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _subnetBase() async {
    try {
      final info = NetworkInfo();
      final ip   = await info.getWifiIP();
      if (ip == null || ip.isEmpty) return null;

      final parts = ip.split('.');
      if (parts.length != 4) return null;
      return '${parts[0]}.${parts[1]}.${parts[2]}.';
    } catch (_) {
      return null;
    }
  }

  static Future<void> _inBatches<T>(
    List<T> items,
    int concurrency,
    Future<void> Function(T) fn,
  ) async {
    final batches = <Future<void>>[];
    for (int i = 0; i < items.length; i++) {
      batches.add(fn(items[i]));
      if (batches.length >= concurrency) {
        await Future.wait(batches);
        batches.clear();
      }
    }
    if (batches.isNotEmpty) await Future.wait(batches);
  }
}
