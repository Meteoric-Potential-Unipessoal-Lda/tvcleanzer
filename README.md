# TVCleanzer

Free Android & iOS app to clean bloatware from Android TV — no root, no technical knowledge required.

## How it works

The phone connects directly to Android TV via standard ADB protocol over Wi-Fi (port 5555). No app needs to be installed on the TV.

**Requirements:**
- Android TV with ADB over network enabled (Developer Options → Network debugging → ON)
- Phone and TV on the same Wi-Fi network

## Architecture

- **Option A (ADB TCP):** Phone implements the full ADB wire protocol with RSA-2048 authentication
- Discovers TVs by scanning the local subnet for port 5555
- Runs `pm list packages` / `pm uninstall -k --user 0` via ADB shell

## Getting started

```bash
flutter pub get
flutter run
```

## Project structure

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
