# Translations

Russian is the source language: every user-visible string in `lib/` is written in Russian
and wrapped in `tr('…', [args])` (`lib/l10n/l10n.dart`). `{0}`, `{1}` are placeholders.

- `keys.json` — all Russian strings (index = row), including package-database labels/reasons.
- `tr_<lang>.json` — translations in the same order (en, uk, es, pt, de, fr, it).
- `lib/l10n/strings.dart` — generated map used at runtime.

Adding a string: write it in Russian inside `tr(...)`, append it to `keys.json` and to every
`tr_<lang>.json` at the same index, then regenerate `strings.dart` (see the generator in the
commit that added this folder). A missing translation falls back to English, then Russian.
