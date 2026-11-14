import 'dart:ui' show PlatformDispatcher;

import 'strings.dart';

/// Languages the app speaks. Russian is the source language of every string.
const supportedLanguages = ['ru', 'en', 'uk', 'es', 'pt', 'de', 'fr', 'it'];

String _lang = 'en';

/// Current interface language code (one of [supportedLanguages]).
String get appLanguage => _lang;

/// Picks the language from the phone's settings. Call once before runApp.
void initLanguage() {
  // Forced language for store screenshots: --dart-define=TVC_LANG=en
  const forced = String.fromEnvironment('TVC_LANG');
  if (supportedLanguages.contains(forced)) {
    _lang = forced;
    return;
  }
  for (final l in PlatformDispatcher.instance.locales) {
    final code = l.languageCode.toLowerCase();
    if (supportedLanguages.contains(code)) {
      _lang = code;
      return;
    }
    // Russian-reading regions without their own translation
    if (const ['be', 'kk', 'ky', 'uz', 'tg', 'hy', 'az', 'ka'].contains(code)) {
      _lang = 'ru';
      return;
    }
  }
  _lang = 'en';
}

/// Translates a Russian source string; {0}, {1}… are replaced by [args].
String tr(String ru, [List<Object?> args = const []]) {
  var s = ru;
  if (_lang != 'ru') {
    s = translations[_lang]?[ru] ?? translations['en']?[ru] ?? ru;
  }
  for (var i = 0; i < args.length; i++) {
    s = s.replaceAll('{$i}', '${args[i]}');
  }
  return s;
}

final _countRe = RegExp(r'^скрывают в (\d+) из (\d+) проверенных списков$');

/// Package database reasons are "category · скрывают в N из M проверенных списков".
String trReason(String reason) => reason.split(' · ').map((part) {
      final m = _countRe.firstMatch(part);
      return m == null
          ? tr(part)
          : tr('скрывают в {0} из {1} проверенных списков', [m.group(1), m.group(2)]);
    }).join(' · ');
