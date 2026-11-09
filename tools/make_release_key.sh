#!/usr/bin/env bash
# Creates the Android release (upload) key for TVCleanzer once.
# The key and its password stay on this Mac: ~/tvcleanzer-keys/ and android/key.properties
# (both outside git). BACK UP ~/tvcleanzer-keys — without it you cannot ship updates
# to people who installed this APK.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! keytool -help >/dev/null 2>&1; then
  for j in /opt/homebrew/opt/openjdk@17/bin /opt/homebrew/opt/openjdk/bin; do
    if [ -x "$j/keytool" ]; then export PATH="$j:$PATH"; break; fi
  done
fi

DIR="$HOME/tvcleanzer-keys"
KS="$DIR/tvcleanzer-upload.jks"
PROPS="android/key.properties"

if [ -f "$KS" ] && [ -f "$PROPS" ]; then
  echo "Key already exists: $KS"; exit 0
fi
if [ -f "$KS" ]; then
  echo "$KS exists but $PROPS is missing — restore key.properties from your backup."; exit 1
fi

mkdir -p "$DIR"; chmod 700 "$DIR"
PASS="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)"
keytool -genkeypair -v -keystore "$KS" -storetype JKS -alias upload \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -storepass "$PASS" -keypass "$PASS" \
  -dname "CN=TVCleanzer, O=Meteoric Potential Unipessoal Lda, C=PT" >/dev/null 2>&1
cat > "$PROPS" <<PROPS
storePassword=$PASS
keyPassword=$PASS
keyAlias=upload
storeFile=$KS
PROPS
cp "$PROPS" "$DIR/key.properties.backup"
chmod 600 "$KS" "$PROPS" "$DIR/key.properties.backup"
echo "Created $KS"
echo "Back up the whole folder $DIR (e.g. to a password manager / encrypted drive)."
