import 'dart:io';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

/// Turning a TV on from deep standby, when ADB no longer answers: a Wake-on-LAN «magic
/// packet» to the TV's network card. The addresses are learned while the TV is on
/// (`/sys/class/net/*/address` over ADB). Works where the TV keeps its network awake in
/// standby (often wired; Wi-Fi on some models). iPhone: broadcasts need Apple's multicast
/// entitlement, so there it may do nothing.
class WakeOnLan {
  static String _key(String tvId) => 'wol_${tvId.split(':').first}';
  static final _mac = RegExp(r'([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})');

  /// Saves the MAC addresses found in [out] (the TV's `cat …/address` output).
  static Future<void> remember(String tvId, String out) async {
    final macs = {
      for (final m in _mac.allMatches(out))
        m.group(1)!.toLowerCase()
    }.where((m) => m != '00:00:00:00:00:00' && !m.startsWith('02:00:00')).toList();
    if (macs.isEmpty) return;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setStringList(_key(tvId), macs);
    } catch (_) {}
  }

  static Future<List<String>> macs(String tvId) async {
    try {
      final sp = await SharedPreferences.getInstance();
      return sp.getStringList(_key(tvId)) ?? const [];
    } catch (_) {
      return const [];
    }
  }

  /// Sends the magic packet for every known address of the TV; false when none is known.
  static Future<bool> wake(String tvId) async {
    final list = await macs(tvId);
    if (list.isEmpty) return false;
    final host = tvId.split(':').first;
    final parts = host.split('.');
    final targets = <InternetAddress>[InternetAddress('255.255.255.255')];
    if (parts.length == 4) {
      targets.add(InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255'));
      targets.add(InternetAddress(host)); // some routers still know the TV
    }
    RawDatagramSocket? s;
    try {
      s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      s.broadcastEnabled = true;
      for (final mac in list) {
        final pkt = _packet(mac);
        for (var round = 0; round < 3; round++) {
          for (final t in targets) {
            for (final port in const [9, 7]) {
              try {
                s.send(pkt, t, port);
              } catch (_) {}
            }
          }
          await Future<void>.delayed(const Duration(milliseconds: 120));
        }
      }
    } catch (_) {
      return true; // we knew where to send; the network refused (iPhone without the entitlement)
    } finally {
      s?.close();
    }
    return true;
  }

  static Uint8List _packet(String mac) {
    final m = mac.split(':').map((h) => int.parse(h, radix: 16)).toList();
    final b = Uint8List(6 + 16 * 6);
    for (var i = 0; i < 6; i++) {
      b[i] = 0xFF;
    }
    for (var r = 0; r < 16; r++) {
      for (var i = 0; i < 6; i++) {
        b[6 + r * 6 + i] = m[i];
      }
    }
    return b;
  }
}
