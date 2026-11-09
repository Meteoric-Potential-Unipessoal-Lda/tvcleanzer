#!/usr/bin/env bash
# Builds TVCleanzer Launcher without Gradle: aapt2 + javac + d8 + apksigner.
# Needs: JDK 17+, Android SDK with one "platforms;android-XX" and "build-tools;XX".
# Output: build/tvcleanzer-launcher.apk, also copied to ../assets/launcher/ for the phone app.
set -euo pipefail
cd "$(dirname "$0")"

# Java: use Homebrew's JDK if the system one is only the macOS stub.
if ! javac -version >/dev/null 2>&1; then
  for j in /opt/homebrew/opt/openjdk@17/bin /opt/homebrew/opt/openjdk/bin /usr/local/opt/openjdk@17/bin; do
    if [ -x "$j/javac" ]; then export PATH="$j:$PATH"; break; fi
  done
fi
javac -version >/dev/null 2>&1 || { echo "JDK not found: brew install openjdk@17"; exit 1; }

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
for c in "$SDK" /opt/homebrew/share/android-commandlinetools "$HOME/Library/Android/sdk" /usr/local/share/android-commandlinetools; do
  if [ -n "$c" ] && [ -d "$c/build-tools" ] && [ -d "$c/platforms" ]; then SDK="$c"; break; fi
done
[ -d "$SDK/build-tools" ] || { echo "Android SDK not found. Set ANDROID_HOME."; exit 1; }
BT="$SDK/build-tools/$(ls "$SDK/build-tools" | sort -V | tail -1)"
PLATFORM="$SDK/platforms/$(ls "$SDK/platforms" | sort -V | tail -1)"
ANDROID_JAR="$PLATFORM/android.jar"
echo "SDK: $SDK"; echo "build-tools: $BT"; echo "platform: $PLATFORM"

KS_DIR="signing"; KS="$KS_DIR/launcher.jks"; KS_PASS="${LAUNCHER_KS_PASS:-tvcleanzer-dev}"
if [ ! -f "$KS" ]; then
  mkdir -p "$KS_DIR"
  keytool -genkeypair -keystore "$KS" -alias launcher -keyalg RSA -keysize 2048 \
    -validity 10000 -storepass "$KS_PASS" -keypass "$KS_PASS" -dname "CN=TVCleanzer Launcher" >/dev/null
  echo "Created signing key $KS — back it up: updates must be signed with the same key."
fi

rm -rf build && mkdir -p build/classes build/dex
"$BT/aapt2" compile --dir res -o build/res.zip
"$BT/aapt2" link -o build/unsigned.apk -I "$ANDROID_JAR" --manifest AndroidManifest.xml build/res.zip --auto-add-overlay

javac -source 8 -target 8 -Xlint:-options -encoding UTF-8 \
  -bootclasspath "$ANDROID_JAR" -d build/classes $(find src -name '*.java')
"$BT/d8" --min-api 21 --release --lib "$ANDROID_JAR" --output build/dex $(find build/classes -name '*.class')
(cd build/dex && zip -q -u ../unsigned.apk classes.dex)

"$BT/zipalign" -p -f 4 build/unsigned.apk build/aligned.apk
"$BT/apksigner" sign --ks "$KS" --ks-pass "pass:$KS_PASS" --key-pass "pass:$KS_PASS" \
  --out build/tvcleanzer-launcher.apk build/aligned.apk
"$BT/apksigner" verify build/tvcleanzer-launcher.apk

mkdir -p ../assets/launcher
cp build/tvcleanzer-launcher.apk ../assets/launcher/tvcleanzer-launcher.apk
ls -lh build/tvcleanzer-launcher.apk
echo "OK → assets/launcher/tvcleanzer-launcher.apk"
