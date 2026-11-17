import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvcleanzer/services/manual_tvs.dart';

void main() {
  test('parse: port 5555 by default, explicit port, rubbish rejected', () {
    expect(ManualTvs.parse('192.168.1.50'), ('192.168.1.50', 5555));
    expect(ManualTvs.parse(' 10.0.0.7:41023 '), ('10.0.0.7', 41023));
    expect(ManualTvs.parse('192.168.1'), isNull);
    expect(ManualTvs.parse('300.1.1.1'), isNull);
    expect(ManualTvs.parse('192.168.1.5:0'), isNull);
  });

  test('remember keeps the newest first, one entry per IP; forget removes it', () async {
    SharedPreferences.setMockInitialValues({});
    await ManualTvs.remember('192.168.2.10', 5555);
    await ManualTvs.remember('192.168.3.20', 5555);
    await ManualTvs.remember('192.168.2.10', 5556);
    expect(await ManualTvs.load(), [('192.168.2.10', 5556), ('192.168.3.20', 5555)]);
    await ManualTvs.forget('192.168.3.20');
    expect(await ManualTvs.load(), [('192.168.2.10', 5556)]);
  });
}
