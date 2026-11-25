import 'dart:async';
import 'dart:io';
import '../../lib/services/atv_remote.dart';

Future<void> main() async {
  final id = AtvIdentity(File('/tmp/atvid.crt').readAsStringSync(), File('/tmp/atvid.key').readAsStringSync());
  // 1. not paired yet → auth
  try {
    await AtvRemote('127.0.0.1', id, port: 16466).connect();
    print('FAIL: connected unpaired');
  } on AtvError catch (e) {
    print('unpaired → ${e.kind}');
  }
  // 2. wrong code
  var p = AtvPairing('127.0.0.1', id, port: 16467);
  await p.start();
  final good = File('/tmp/tvcode').readAsStringSync();
  final bad = '${good.substring(0, 2)}${(int.parse(good.substring(2), radix: 16) ^ 1).toRadixString(16).padLeft(4, '0')}';
  try {
    await p.finish(bad);
    print('FAIL: bad code accepted');
  } on AtvError catch (e) {
    print('bad code → ${e.kind} ${e.message}');
  }
  p.close();
  // 3. pairing for real (lowercase, with a space)
  p = AtvPairing('127.0.0.1', id, port: 16467);
  await p.start();
  final code = File('/tmp/tvcode').readAsStringSync();
  await p.finish('${code.substring(0, 3).toLowerCase()} ${code.substring(3)}');
  print('paired with $code');
  // 4. remote
  final r = AtvRemote('127.0.0.1', id, port: 16466);
  var changes = 0;
  r.onChange = () => changes++;
  await r.connect();
  await Future.delayed(const Duration(milliseconds: 300));
  print('on=${r.state.on} app=${r.state.app} vol=${r.state.volume}/${r.state.volumeMax} model=${r.state.model} canType=${r.canType}');
  r.key(3);
  r.key(23, direction: 1);
  r.key(23, direction: 2);
  r.text('Привет tv');
  r.openLink('https://www.youtube.com');
  await Future.delayed(const Duration(milliseconds: 2500)); // pings arrive and get answered
  r.close();
  await Future.delayed(const Duration(milliseconds: 300));
  // 5. a stranger identity is refused
  final other = AtvIdentity.generate('Other');
  try {
    await AtvRemote('127.0.0.1', other, port: 16466).connect();
    print('FAIL: stranger connected');
  } on AtvError catch (e) {
    print('stranger → ${e.kind}');
  }
  // 6. nobody on the port
  try {
    await AtvRemote('127.0.0.1', id, port: 16999).connect(timeout: const Duration(seconds: 2));
  } on AtvError catch (e) {
    print('no service → ${e.kind}');
  }
  print('changes=$changes');
  exit(0);
}
