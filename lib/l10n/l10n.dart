import 'dart:ui' show PlatformDispatcher;

import 'strings.dart';

/// Languages the app speaks. Russian is the source language of every string.
const supportedLanguages = [
  'ru', 'en', 'uk', 'es', 'pt', 'de', 'fr', 'it',
  'be', 'kk', 'uz', 'hy', 'az', 'ka', 'ky', 'tr', 'pl', 'ro', 'zh',
  'ja', 'ko', 'hi', 'id', 'vi', 'th', 'nl', 'cs', 'el', 'hu', 'sv',
];

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
    if (const ['tg', 'tk', 'mo'].contains(code)) {
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

/// Package database reasons are "what it is · скрывают в N из M проверенных списков".
/// The count goes on its own line ("\n"), so the description stays readable.
String trReason(String reason) {
  final text = <String>[];
  String? count;
  for (final part in reason.split(' · ')) {
    final m = _countRe.firstMatch(part);
    if (m == null) {
      text.add(tr(part));
    } else {
      count = tr('Убирают в {0} из {1} списков чистки ТВ', [m.group(1), m.group(2)]);
    }
  }
  return [text.join(' · '), if (count != null) count].join('\n');
}
