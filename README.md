# TVCleanzer

Бесплатное приложение для телефона (Android, iPhone) и Windows, которое чистит Android TV от мусора по ADB — без root и без компьютерных знаний. Плюс свой лаунчер для телевизора.

Free Android, iOS and Windows app to clean bloatware from Android TV over ADB — no root, no technical knowledge required. Comes with its own TV launcher.

## Скачать / Download

| Что | Где |
| --- | --- |
| Приложение для телефона | Google Play и App Store — «TVCleanzer» |
| Windows | [Releases](https://github.com/Meteoric-Potential-Unipessoal-Lda/tvcleanzer/releases/latest) → `TVCleanzer-…-windows-x64.zip` |
| **Лаунчер для телевизора отдельно** | **[TVCleanzer-Launcher.apk](https://github.com/Meteoric-Potential-Unipessoal-Lda/tvcleanzer/releases/latest/download/TVCleanzer-Launcher.apk)** — всегда последняя версия |

### Лаунчер без телефона / The launcher without a phone

Если телевизор не подключается к приложению, лаунчер можно поставить прямо на ТВ:

1. Откройте на телевизоре любой браузер и введите адрес
   `github.com/Meteoric-Potential-Unipessoal-Lda/tvcleanzer/releases/latest/download/TVCleanzer-Launcher.apk`
   — или скачайте этот файл на компьютере и перенесите на телевизор флешкой.
2. Откройте скачанный файл и установите. Если телевизор спросит — разрешите установку из этого источника («Неизвестные источники»).
3. Нажмите «Домой» на пульте и выберите **TVCleanzer Launcher** → «Всегда».
4. Если «Домой» всё равно открывает родной экран: Настройки → Специальные возможности → включите **«TVCleanzer: кнопка Домой»**.
5. Оформление, избранное, обои и всё остальное — шестерёнкой ⚙ на главном экране лаунчера.

Без приложения на телефоне не будет настройки лаунчера с телефона и его автообновления — новые версии ставьте так же, по той же ссылке.

Install on the TV without the phone app: open the link above in any TV browser (or copy the APK with a USB stick), install it, press Home and pick **TVCleanzer Launcher** → Always. If Home still opens the stock screen, enable the accessibility service **“TVCleanzer: Home key”**.

## For developers

### How it works

The phone connects directly to Android TV via standard ADB protocol over Wi-Fi (port 5555). No app needs to be installed on the TV.

**Requirements:**
- Android TV with ADB over network enabled (Developer Options → Network debugging → ON)
- Phone and TV on the same Wi-Fi network

### Architecture

- **Option A (ADB TCP):** Phone implements the full ADB wire protocol with RSA-2048 authentication
- Discovers TVs by scanning the local subnet for port 5555
- Runs `pm list packages` / `pm uninstall -k --user 0` via ADB shell

### Getting started

```bash
flutter pub get
flutter run
```

### Project structure

```
lib/
  services/
    adb_client.dart          # ADB wire protocol + RSA-2048 auth
    adb_package_manager.dart # Package ops via ADB shell
    tv_discovery.dart        # Subnet scan for port 5555
  models/
    tv_device.dart
    tv_package.dart
    scan_result.dart
    clean_result.dart
  screens/
    home_screen.dart
    scan_screen.dart
    clean_screen.dart
    result_screen.dart
  theme/
    app_theme.dart
assets/
  packages.json              # Bloatware database
```
