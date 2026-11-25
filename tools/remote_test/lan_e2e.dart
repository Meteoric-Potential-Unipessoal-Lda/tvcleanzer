import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';
import '../../lib/services/lan_remote.dart';

var fails = 0;
void check(bool ok, String what) {
  print('${ok ? 'ok  ' : 'FAIL'} $what');
  if (!ok) fails++;
}

String code() => File('/tmp/lancode').readAsStringSync();
String log() => File('/tmp/lanlog').readAsStringSync();

Future<void> main() async {
  const port = 17292;
  final id = LanRemote.newId();
  check(RegExp(r'^[A-Za-z0-9_-]{8,64}$').hasMatch(id), 'phone id format ($id)');

  // unknown phone
  try {
    await LanRemote('127.0.0.1', id, port: port).connect(List.filled(32, 7));
    check(false, 'unknown phone refused');
  } on LanError catch (e) {
    check(e.kind == 'unknown', 'unknown phone refused (${e.kind})');
  }

  // pairing: a wrong code first, then the right one
  final r = LanRemote('127.0.0.1', id, port: port);
  var asked = <int>[];
  final key = await r.pair('Pixel «8» & co', (left) async {
    asked.add(left);
    await Future.delayed(const Duration(milliseconds: 100));
    final c = code();
    return asked.length == 1 ? '${(int.parse(c) + 1) % 1000000}'.padLeft(6, '0') : '${c.substring(0, 3)} ${c.substring(3)}';
  });
  check(asked.length == 2 && asked[0] == 3 && asked[1] == 2, 'wrong code then right (asked $asked)');
  check(key.length == 32, 'key 32 bytes');
  check(log().contains('KEEP $id Pixel «8» & co'), 'TV keeps the phone with its name');
  await Future.delayed(const Duration(milliseconds: 200));
  check(r.state.service && r.state.volume == 5 && r.state.volumeMax == 15 && r.state.app == 'com.test', 'state line');
  check(r.state.name == 'Тестовый ТВ' && r.state.api == 33, 'hello: name and api');
  final refused = <String>[];
  r.onRefused = refused.add;
  r.key('home');
  r.key('back');
  r.text('Привет, мир! 100% + "кавычки" #тег');
  r.launch('com.google.android.youtube.tv');
  r.openLink('https://example.com/a b?x=1&y=2');
  r.mouse('m 10 -5');
  r.setVolume(7);
  await Future.delayed(const Duration(milliseconds: 300));
  final l = log();
  check(l.contains('CMD k home') && l.contains('CMD k back'), 'keys');
  check(l.contains('CMD t ${Uri.encodeComponent('Привет, мир! 100% + "кавычки" #тег')}'), 'text line');
  check(l.contains('CMD a com.google.android.youtube.tv') && l.contains('CMD m 10 -5') && l.contains('CMD v 7'), 'app, mouse, volume');
  check(refused.contains('k back'), 'refusal reported');
  r.close();

  // auth with the key
  final r2 = LanRemote('127.0.0.1', id, port: port);
  await r2.connect(key);
  r2.key('ok');
  await Future.delayed(const Duration(milliseconds: 200));
  check(log().contains('CMD k ok'), 'second connection with the kept key');
  r2.close();

  // wrong key for a known id
  try {
    await LanRemote('127.0.0.1', id, port: port).connect(List.filled(32, 1));
    check(false, 'wrong key refused');
  } on LanError catch (e) {
    check(e.kind == 'unknown', 'wrong key refused');
  }

  // tampering and replay on a raw socket: auth by hand
  Future<List<String>> rawSession(List<String> Function(String tvNonce) lines) async {
    final s = await Socket.connect('127.0.0.1', port);
    final got = <String>[];
    final done = Completer<void>();
    String? hello;
    s.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen((x) {
      got.add(x);
      if (hello == null) {
        hello = x;
        for (final y in lines(x.split(' ')[1])) {
          s.add(utf8.encode('$y\n'));
        }
      }
    }, onDone: () => done.complete());
    await done.future.timeout(const Duration(seconds: 5), onTimeout: () => s.destroy());
    s.destroy();
    return got;
  }

  final before = 'CMD'.allMatches(log()).length;
  var got = await rawSession((n) => ['k home #0000000000000000']);
  check(got.length >= 2 && got[1] == 'what', 'a command without auth is refused');
  got = await rawSession((n) => ['auth $id ${'a' * 32} ${'0' * 64}']);
  check(got.contains('who'), 'auth with a forged mac refused');
  check('CMD'.allMatches(log()).length == before, 'nothing ran');

  // replay and tampering with a real session: auth by hand, then the same signed line twice
  String hx(List<int> b) => [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
  List<int> hm(List<int> k, String m) {
    final h = HMac(SHA256Digest(), 64)..init(KeyParameter(Uint8List.fromList(k)));
    final b = Uint8List.fromList(utf8.encode(m));
    h.update(b, 0, b.length);
    final o = Uint8List(32);
    h.doFinal(o, 0);
    return o;
  }
  const pn = '0123456789abcdef0123456789abcdef';
  List<String> signed(String tvNonce, List<(int, String)> cmds) {
    final sk = hm(key, 'sess|$tvNonce|$pn');
    return ['auth $id $pn ${hx(hm(key, 'a|$tvNonce|$pn|$id'))}',
      for (final (seq, c) in cmds) '$c #${hx(hm(sk, '$seq|$c').sublist(0, 8))}'];
  }
  got = await rawSession((n) => signed(n, [(1, 'k home'), (1, 'k home')]));
  check(got.length >= 4 && got[1].startsWith('ok ') && got.last == 'err mac', 'a replayed line is refused ($got)');
  got = await rawSession((n) => signed(n, [(1, 'k home')]).map((l) => l.replaceFirst('k home', 'k back')).toList());
  check(got.last == 'err mac', 'a changed line is refused');
  got = await rawSession((n) => signed(n, [(2, 'k up')]));
  check(got.last == 'err mac', 'a line out of order is refused');

  // busy: one pairing at a time
  final pA = LanRemote('127.0.0.1', LanRemote.newId(), port: port);
  final waitA = Completer<String?>();
  final fA = pA.pair('A', (_) => waitA.future).then((_) => 'paired', onError: (e) => '$e');
  await Future.delayed(const Duration(milliseconds: 400));
  try {
    await LanRemote('127.0.0.1', LanRemote.newId(), port: port).pair('B', (_) async => '000000');
    check(false, 'second pairing busy');
  } on LanError catch (e) {
    check(e.kind == 'busy', 'second pairing busy (${e.kind})');
  }
  waitA.complete(null); // cancelled
  await fA;
  await Future.delayed(const Duration(milliseconds: 200));
  check(log().contains('CODEDONE false'), 'cancelled pairing hides the code');

  // three runs of three wrong codes → the TV holds off pairing for a while
  for (var run = 0; run < 3; run++) {
    final pC = LanRemote('127.0.0.1', LanRemote.newId(), port: port);
    try {
      await pC.pair('C', (left) async => '${(int.parse(code()) + 1) % 1000000}'.padLeft(6, '0'));
      check(false, 'three wrong codes');
    } on LanError catch (e) {
      check(e.kind == 'tries', 'three wrong codes → tries (run ${run + 1})');
    }
    await Future.delayed(const Duration(milliseconds: 150));
  }
  try {
    await LanRemote('127.0.0.1', LanRemote.newId(), port: port).pair('D', (_) async => '000000');
    check(false, 'after failures');
  } on LanError catch (e) {
    check(e.kind == 'later', 'after failed pairings the TV holds off (${e.kind})');
  }
  // the paired phone still gets in
  final r4 = LanRemote('127.0.0.1', id, port: port);
  await r4.connect(key);
  r4.close();
  check(true, 'paired phone unaffected by the hold');

  // nobody there
  try {
    await LanRemote('127.0.0.1', id, port: 17999).connect(key);
  } on LanError catch (e) {
    check(e.kind == 'connect', 'no launcher → connect');
  }
  print(fails == 0 ? 'ALL OK' : '$fails FAILED');
  exit(fails);
}
