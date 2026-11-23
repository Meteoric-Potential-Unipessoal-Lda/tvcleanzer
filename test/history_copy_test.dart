import 'package:flutter_test/flutter_test.dart';
import 'package:tvcleanzer/state/history.dart';

/// 1.3.73: History kept on the TV too, merged back into a reinstalled phone.
void main() {
  CleanRecord rec(String id, String tv, int day, {bool restored = false}) => CleanRecord(
        id: id,
        tvIp: tv,
        tvName: 'TV',
        packages: ['com.a.$id'],
        labels: const {},
        savedMb: 1,
        date: DateTime(2026, 11, day),
        restored: restored,
      );

  test('a fresh phone gets the TV copy, under the TV address of today', () {
    final m = HistoryNotifier.merge(const [], [rec('1', '10.0.0.5', 1), rec('2', '10.0.0.5:4321', 3)], '10.0.0.9');
    expect(m.map((r) => r.id), ['2', '1'], reason: 'newest first');
    expect(m.every((r) => r.tvIp == '10.0.0.9'), isTrue);
  });

  test('nothing doubles; «Вернуть» on either side counts', () {
    final phone = [rec('1', '10.0.0.5', 1), rec('2', '10.0.0.5', 2, restored: true)];
    final tv = [rec('1', '10.0.0.5', 1, restored: true), rec('2', '10.0.0.5', 2), rec('3', '10.0.0.5', 3)];
    final m = HistoryNotifier.merge(phone, tv, '10.0.0.5');
    expect(m.length, 3);
    expect(m.firstWhere((r) => r.id == '1').restored, isTrue);
    expect(m.firstWhere((r) => r.id == '2').restored, isTrue);
  });

  test('the cap still holds', () {
    final tv = [for (var i = 0; i < 80; i++) rec('$i', 'x', 1 + i % 28)];
    expect(HistoryNotifier.merge(const [], tv, 'x', max: 50).length, 50);
  });

  test('host of an address with or without the wireless port', () {
    expect(HistoryNotifier.hostOf('192.168.1.5:37123'), '192.168.1.5');
    expect(HistoryNotifier.hostOf('192.168.1.5'), '192.168.1.5');
  });
}
