import 'package:flutter_test/flutter_test.dart';
import 'package:tvcleanzer/services/app_update.dart';

void main() {
  test('versions compare by numbers, not as text', () {
    expect(AppUpdate.newer('1.3.188', '1.3.99'), isTrue);
    expect(AppUpdate.newer('1.3.188', '1.3.188'), isFalse);
    expect(AppUpdate.newer('1.3.187', '1.3.188'), isFalse);
    expect(AppUpdate.newer('1.4', '1.3.200'), isTrue);
  });

  test('the release APK is picked, other files are not', () {
    final rel = {
      'tag_name': 'v1.3.190',
      'assets': [
        {'name': 'TVCleanzer-1.3.190-windows-x64.zip', 'browser_download_url': 'https://x/w.zip'},
        {'name': 'TVCleanzer-Launcher.apk', 'browser_download_url': 'https://x/l.apk'},
        {'name': 'TVCleanzer-1.3.190.apk', 'browser_download_url': 'https://x/a.apk'},
      ],
    };
    expect(AppUpdate.pick(rel, '1.3.188'), ('1.3.190', 'https://x/a.apk'));
    expect(AppUpdate.pick(rel, '1.3.190'), isNull);
    expect(AppUpdate.pick({'assets': []}, '1.3.188'), isNull);
    expect(AppUpdate.pick(null, '1.3.188'), isNull);
  });
}
