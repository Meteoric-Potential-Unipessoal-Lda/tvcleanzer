import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvcleanzer/services/app_log.dart';

/// The «?» report prints [appVersion]; it stayed 1.3.61 through 1.3.62–1.3.64.
void main() {
  test('appVersion = pubspec version', () {
    final pub = File('pubspec.yaml').readAsStringSync();
    final v = RegExp(r'^version:\s*([0-9.]+)\+', multiLine: true).firstMatch(pub)!.group(1)!;
    expect(appVersion, v);
  });
}
