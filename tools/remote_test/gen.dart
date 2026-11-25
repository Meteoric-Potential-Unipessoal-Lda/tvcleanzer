import 'dart:io';
import '../../lib/services/atv_remote.dart';
void main(List<String> a) {
  final sw = Stopwatch()..start();
  final id = AtvIdentity.generate(a.isEmpty ? 'TVCleanzer on Pixel 8' : a[0]);
  stderr.writeln('gen ${sw.elapsedMilliseconds} ms');
  File('/tmp/atvid.crt').writeAsStringSync(id.certPem);
  File('/tmp/atvid.key').writeAsStringSync(id.keyPem);
  final (n, e) = id.publicNumbers();
  print('${n.toRadixString(16).substring(0, 16)} e=$e');
}
