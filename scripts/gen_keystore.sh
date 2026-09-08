#!/usr/bin/env bash
# Generates a release keystore for local signing AND prints the values to store
# as GitHub Actions secrets so CI can sign every release with the same key.
#
# Requires a JDK (keytool). Run once and keep the output safe!
set -euo pipefail

cd "$(dirname "$0")/.."

KS="android/app/key.jks"
PROPS="android/key.properties"

if [ -f "$KS" ]; then
  echo "Keystore already exists: $KS — not overwriting."
  exit 1
fi

read -rp "Key alias (default: dnschanger): " ALIAS
ALIAS="${ALIAS:-dnschanger}"
read -rsp "Store password (default: generated): " SPASS; echo
read -rsp "Key password (default: same as store): " KPASS; echo

if [ -z "$SPASS" ]; then
  SPASS="$(openssl rand -base64 18 | tr -d '/+=' | head -c 18)"
fi
[ -z "$KPASS" ] && KPASS="$SPASS"

keytool -genkeypair -v \
  -keystore "$KS" \
  -alias "$ALIAS" \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -storepass "$SPASS" \
  -keypass "$KPASS" \
  -dname "CN=DNS Changer, OU=Mobile, O=DnsChangerPM, L=Unknown, S=Unknown, C=IR"

cat > "$PROPS" <<EOF
storePassword=$SPASS
keyPassword=$KPASS
keyAlias=$ALIAS
storeFile=key.jks
EOF

echo
echo "✅ Keystore written to $KS"
echo "✅ Signing config written to $PROPS"
echo
echo "Now add these as GitHub Actions secrets (Settings → Secrets and variables → Actions):"
echo "  KEYSTORE_BASE64    = $(base64 -w0 "$KS")"
echo "  KEYSTORE_PASSWORD  = $SPASS"
echo "  KEY_ALIAS          = $ALIAS"
echo "  KEY_PASSWORD       = $KPASS"
