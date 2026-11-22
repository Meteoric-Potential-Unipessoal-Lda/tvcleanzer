import 'package:flutter_test/flutter_test.dart';
import 'package:tvcleanzer/services/adb_package_manager.dart';

/// «Отправить файл на ТВ»: safe names on the TV and the type used by «Открыть на ТВ».
void main() {
  test('file names stay readable and safe for the TV shell', () {
    expect(AdbPackageManager.tvFileName('Плейлист 2026.m3u'), 'Плейлист 2026.m3u');
    expect(AdbPackageManager.tvFileName("it's \$HOME;rm -rf.mp4"), 'it_s _HOME_rm -rf.mp4');
    expect(AdbPackageManager.tvFileName('.hidden'), 'file.hidden');
    expect(AdbPackageManager.tvFileName('   '), 'file');
    final long = '${'a' * 200}.mkv';
    expect(AdbPackageManager.tvFileName(long).length, 120);
    expect(AdbPackageManager.tvFileName(long), endsWith('.mkv'));
  });

  test('types for opening on the TV', () {
    expect(AdbPackageManager.mimeOf('list.M3U'), 'audio/x-mpegurl');
    expect(AdbPackageManager.mimeOf('/sdcard/Download/TVCleanzer/film.mkv'), 'video/*');
    expect(AdbPackageManager.mimeOf('song.flac'), 'audio/*');
    expect(AdbPackageManager.mimeOf('photo.heic'), 'image/*');
    expect(AdbPackageManager.mimeOf('app.apk'), 'application/vnd.android.package-archive');
    expect(AdbPackageManager.mimeOf('README'), '*/*');
  });
}
