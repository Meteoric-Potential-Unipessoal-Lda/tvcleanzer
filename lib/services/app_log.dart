import 'dart:io';

import '../models/tv_device.dart';

/// Version shown in reports (keep in sync with pubspec.yaml).
const appVersion = '0.9.1';

/// Small in-memory log of recent problems, for "Сообщить о проблеме".
class AppLog {
  AppLog._();

  static final List<String> _lines = [];

  static void error(String where, Object e) {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    var msg = e.toString().replaceAll(RegExp(r'\s+'), ' ');
    if (msg.length > 300) msg = '${msg.substring(0, 300)}…';
    // no IP addresses in reports
    msg = msg.replaceAll(RegExp(r'\b\d{1,3}(\.\d{1,3}){3}\b'), 'x.x.x.x');
    where = where.replaceAll(RegExp(r'\b\d{1,3}(\.\d{1,3}){3}\b'), 'x.x.x.x');
    _lines.add('${two(t.hour)}:${two(t.minute)}:${two(t.second)} $where: $msg');
    if (_lines.length > 30) _lines.removeAt(0);
  }

  /// Text the user pastes into the Telegram chat.
  static String report({TvDevice? tv, String? launcher}) {
    final b = StringBuffer()
      ..writeln('TVCleanzer $appVersion — отчёт о проблеме')
      ..writeln('Телефон: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    if (tv != null) {
      b.writeln('ТВ: ${tv.shortName.isEmpty ? 'неизвестно' : tv.shortName}, '
          'Android ${tv.androidVer} (SDK ${tv.sdkVersion}), ОЗУ ${tv.ramMb} МБ');
    } else {
      b.writeln('ТВ: не выбран');
    }
    if (launcher != null) b.writeln('Главный экран ТВ: $launcher');
    b.writeln('Что случилось: (опишите своими словами)');
    b.writeln('---');
    if (_lines.isEmpty) {
      b.writeln('Ошибок в журнале нет.');
    } else {
      for (final l in _lines.reversed.take(15)) {
        b.writeln(l);
      }
    }
    return b.toString();
  }
}
