#!/bin/bash
# Store screenshots for every language on an iPhone Pro Max simulator
# (1320x2868, the App Store 6.9" size). Result: build/store_shots/<lang>_*.png
# The test prints "SHOT <name>"; this script then grabs the simulator screen.
set -e
set -o pipefail
cd "$(dirname "$0")/.."
LANGS="${*:-ru en uk es pt de fr it}"
pick() { xcrun simctl list devices available | grep -E "$1" | head -1 | grep -oE "[0-9A-F]{8}-[0-9A-F-]{27}" || true; }
DEV=$(pick "iPhone 1[6-9] Pro Max")
if [ -z "$DEV" ]; then
  # No Pro Max simulator yet: create one on the newest installed iOS runtime
  RT=$(xcrun simctl list runtimes available | grep -E "^iOS" | tail -1 | grep -oE "com\.apple\.CoreSimulator\.SimRuntime\.[A-Za-z0-9.-]+" || true)
  for T in iPhone-17-Pro-Max iPhone-16-Pro-Max; do
    if [ -n "$RT" ]; then DEV=$(xcrun simctl create "Store $T" "com.apple.CoreSimulator.SimDeviceType.$T" "$RT" 2>/dev/null || true); fi
    if [ -n "$DEV" ]; then break; fi
  done
fi
if [ -z "$DEV" ]; then DEV=$(pick "iPhone"); fi
if [ -z "$DEV" ]; then
  echo "No iPhone simulator found. Available runtimes and devices:"
  xcrun simctl list runtimes; xcrun simctl list devices available
  echo "Install an iOS runtime in Xcode > Settings > Components, then run again."
  exit 1
fi
echo "Simulator: $(xcrun simctl list devices | grep $DEV)"
xcrun simctl boot "$DEV" 2>/dev/null || true
open "$(xcode-select -p)/Applications/Simulator.app" 2>/dev/null || open -a Simulator 2>/dev/null || true
xcrun simctl bootstatus "$DEV" -b
# Clean status bar 9:41, full battery
xcrun simctl status_bar "$DEV" override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 || true
flutter pub get >/dev/null
mkdir -p build/store_shots
for L in $LANGS; do
  echo "=== $L ==="
  xcrun simctl uninstall "$DEV" com.tvcleanzer.app 2>/dev/null || true
  flutter drive -d "$DEV" --dart-define=TVC_LANG=$L --dart-define=TVC_DEMO_ONLY=true \
    --driver=test_driver/integration_test.dart \
    --target=integration_test/store_shots_test.dart 2>&1 | tee "build/store_shots/$L.log" | while IFS= read -r line; do
      case "$line" in
        *"SHOT "*)
          n="${line##*SHOT }"; n="${n%%[[:space:]]*}"
          if xcrun simctl io "$DEV" screenshot --type=png "build/store_shots/$n.png" >/dev/null 2>&1; then
            echo ">>> saved $n.png"
          else
            echo ">>> screenshot FAILED $n"
          fi ;;
        *"STEP "*|*"tests passed"*|*"tests failed"*|*"EXCEPTION"*|*"rror"*|*"══"*|*"Expected"*|*"Actual"*|*"not found"*|*"Xcode build"*)
          echo "$line" ;;
      esac
    done || echo "!!! $L: the test reported errors, details in build/store_shots/$L.log"
done
ls -la build/store_shots
open build/store_shots
