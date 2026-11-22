import 'package:flutter_test/flutter_test.dart';
import 'package:tvcleanzer/models/launcher_look.dart';
import 'package:tvcleanzer/services/adb_package_manager.dart';

/// Launcher 0.61: the top bar's greeting, clock size and one-line date; music in the photo frame.
void main() {
  test('top bar settings travel to the TV and back', () {
    const def = LauncherLook();
    expect(def.greeting, isTrue);
    expect(def.barClock, 0);
    expect(def.oneLine, isFalse);
    final l = LauncherLook.fromMap({'greeting': '0', 'barClock': '2', 'oneLine': '1'});
    expect(l.greeting, isFalse);
    expect(l.barClock, 2);
    expect(l.oneLine, isTrue);
    expect(l.extras, contains('--ez greeting false'));
    expect(l.extras, contains('--ei barClock 2'));
    expect(l.extras, contains('--ez oneLine true'));
    expect(LauncherLook.fromMap({'barClock': '9'}).barClock, 2);
    expect(LauncherLook.fromMap(l.toJson()).barClock, 2);
  });

  test('music tracks keep a type the TV can play', () {
    expect(AdbPackageManager.musicExt('Song.MP3'), 'mp3');
    expect(AdbPackageManager.musicExt('a.flac'), 'flac');
    expect(AdbPackageManager.musicExt('voice.amr'), 'mp3');
    expect(AdbPackageManager.musicExt('noext'), 'mp3');
    expect(AdbPackageManager.musicLauncher, lessThanOrEqualTo(AdbPackageManager.bundledLauncherVersion));
  });

  test('live wallpaper and voice search helpers', () {
    expect(AdbPackageManager.liveWallLauncher, lessThanOrEqualTo(AdbPackageManager.bundledLauncherVersion));
    expect(AdbPackageManager.started('Starting: Intent { act=android.intent.action.SEARCH }'), isTrue);
    expect(AdbPackageManager.started('Warning: Activity not started, intent has been delivered to currently running top-most instance.'), isTrue);
    expect(AdbPackageManager.started('Error: Activity not started, unable to resolve Intent'), isFalse);
  });
}
