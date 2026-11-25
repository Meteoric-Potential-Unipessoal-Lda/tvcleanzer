import 'dart:convert';
import 'dart:io';
import '../../lib/services/atv_remote.dart';
import '../../lib/services/no_adb.dart';

class MapStore implements NoAdbStore {
  final m = <String, String>{};
  @override
  String? get(String k) => m[k];
  @override
  Future<void> set(String k, String? v) async => v == null ? m.remove(k) : m[k] = v;
}

var fails = 0;
void check(bool ok, String what) {
  print('${ok ? 'ok  ' : 'FAIL'} $what');
  if (!ok) fails++;
}

Future<void> main() async {
  final st = MapStore();
  st.m['noadb_atv_id'] = jsonEncode(AtvIdentity(File('/tmp/atvid.crt').readAsStringSync(), File('/tmp/atvid.key').readAsStringSync()).toJson());
  final n = NoAdb(st, atvPort: 16466, atvPairPort0: 16467, lanPort: 17292);
  check(await n.connect('127.0.0.1') == null, 'nothing paired → null');
  check(await n.probe('127.0.0.1') == AltKind.atv, 'probe prefers Google service');
  final a = await n.pairAtv('127.0.0.1', () async => File('/tmp/tvcode').readAsStringSync());
  check(a.kind == AltKind.atv && a.isOpen && a.canNavigate, 'ATV paired and open');
  a.key(19);
  a.longKey(23);
  a.text('Тест');
  a.launch('com.netflix.ninja');
  await Future.delayed(const Duration(seconds: 1));
  a.close();
  final a2 = await n.connect('127.0.0.1');
  check(a2?.kind == AltKind.atv, 'ATV reconnects from the store');
  a2?.close();

  // LAN only (another «TV» with no Google service)
  final n2 = NoAdb(st, atvPort: 16999, atvPairPort0: 16998, lanPort: 17292);
  check(await n2.probe('127.0.0.1') == AltKind.lan, 'probe finds the launcher');
  final l = await n2.pairLan('127.0.0.1', 'Pixel', (_) async => File('/tmp/lancode').readAsStringSync());
  await Future.delayed(const Duration(milliseconds: 200));
  check(l.kind == AltKind.lan && l.canNavigate && l.canMouse, 'LAN paired, state says dpad and mouse');
  final refused = <String>[];
  l.onRefused = refused.add;
  l.key(4);
  l.key(178); // input: no name
  l.text('Привет');
  l.launch('org.videolan.vlc');
  l.mouse('m 3 4');
  await Future.delayed(const Duration(milliseconds: 300));
  check(refused.contains('k 178') && refused.contains('k back'), 'refusals ($refused)');
  l.close();
  st.m.remove('noadb_atv_127.0.0.1');
  final l2 = await n2.connect('127.0.0.1');
  check(l2?.kind == AltKind.lan, 'LAN reconnects from the store');
  l2?.close();
  st.m['noadb_lan_127.0.0.1'] = base64.encode(List.filled(32, 9));
  check(await n2.connect('127.0.0.1') == null && !st.m.containsKey('noadb_lan_127.0.0.1'), 'a forgotten phone drops its key');
  final log = File('/tmp/lanlog').readAsStringSync();
  check(log.contains('CMD a org.videolan.vlc') && log.contains('CMD m 3 4') && log.contains('CMD t %D0%9F'), 'LAN commands arrived');
  final tv = File('/tmp/tvlog.jsonl').readAsStringSync();
  check(tv.contains('market://launch?id=com.netflix.ninja') && tv.contains('START_LONG') && tv.contains('END_LONG'), 'ATV app link and long press');
  print(fails == 0 ? 'ALL OK' : '$fails FAILED');
  exit(fails);
}
