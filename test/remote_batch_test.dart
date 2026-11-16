import 'package:flutter_test/flutter_test.dart';
import 'package:tvcleanzer/services/demo_tv.dart';
import 'package:tvcleanzer/state/remote.dart';

void main() {
  test('remote: quick presses are all sent, none dropped', () async {
    DemoTv.reset();
    final r = RemoteController();
    final ip = DemoTv.device().id;
    for (var i = 0; i < 5; i++) {
      r.key(ip, Keys.right);
    }
    await r.text(ip, 'ok'); // runs after the keys
    expect(r.state.status, RemoteStatus.ready);
    // the first press goes at once, the four pressed while it ran go together
    final keys = DemoTv.inputLog.where((c) => c.contains('keyevent')).toList();
    expect(keys.join(' ').split(' ').where((w) => w == '${Keys.right}').length, 5);
    expect(keys.length, lessThanOrEqualTo(2));
    expect(keys.first, startsWith('cmd input keyevent'));
    r.close();
  });
}
