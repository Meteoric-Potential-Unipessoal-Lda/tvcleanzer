import 'package:flutter_test/flutter_test.dart';
import 'package:tvcleanzer/services/protection.dart';

/// Haier «Factory Mode» after a factory app was opened by mistake: never offered to open.
void main() {
  test('factory tools are service tools, ordinary apps are not', () {
    expect(Protection.isServiceTool('com.cvte.tv.hkcfac'), isTrue);
    expect(Protection.isServiceTool('com.cvte.tv.fac.aging'), isTrue);
    expect(Protection.isServiceTool('com.at.factory.factorymanager'), isTrue);
    expect(Protection.isServiceTool('com.stb.factorymenu'), isTrue);
    expect(Protection.isServiceTool('com.google.android.youtube.tv'), isFalse);
    expect(Protection.isServiceTool('com.android.tv.settings'), isFalse);
    expect(Protection.isServiceTool('ru.kinopoisk.tv'), isFalse);
  });
}
