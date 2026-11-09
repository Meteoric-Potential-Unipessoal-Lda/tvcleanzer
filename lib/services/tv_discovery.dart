import 'dart:async';
import 'dart:io';

import '../models/tv_device.dart';
import 'adb_package_manager.dart';
import 'app_log.dart';

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
  // Long enough for the user to tap "Allow" on the TV on first connect.
  static const Duration _adbTimeout  = Duration(seconds: 75);

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
      } catch (e) {
        // Not an ADB device or auth failed: skip, but keep it for reports
        AppLog.error('connect $ip', e);
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

  /// Base of the phone's Wi-Fi /24 subnet, e.g. "192.168.1.".
  /// Uses dart:io directly (no plugin): prefers Wi-Fi interfaces
  /// (en*/wlan*) and skips cellular, VPN and virtual ones.
  Future<String?> _subnetBase() async {
    List<NetworkInterface> ifaces;
    try {
      ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    } catch (_) {
      return null;
    }
    const skip = ['lo', 'pdp_ip', 'rmnet', 'ccmni', 'utun', 'ipsec', 'tun',
                  'bridge', 'vmnet', 'awdl', 'llw', 'ap', 'p2p'];
    String? best, fallback;
    for (final iface in ifaces) {
      final name = iface.name.toLowerCase();
      if (skip.any(name.startsWith)) continue;
      for (final a in iface.addresses) {
        if (!_isPrivate(a.address)) continue;
        if (name.startsWith('en') || name.startsWith('wlan')) {
          best ??= a.address;
        } else {
          fallback ??= a.address;
        }
      }
    }
    final ip = best ?? fallback;
    if (ip == null) return null;
    final parts = ip.split('.');
    return '${parts[0]}.${parts[1]}.${parts[2]}.';
  }

  static bool _isPrivate(String ip) {
    final p = ip.split('.').map(int.tryParse).toList();
    if (p.length != 4 || p.contains(null)) return false;
    return p[0] == 10 ||
        (p[0] == 192 && p[1] == 168) ||
        (p[0] == 172 && p[1]! >= 16 && p[1]! <= 31);
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
