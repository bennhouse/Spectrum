#!/bin/zsh
# Creates the local signing identity in signing/ (not in the repository): a self-signed code
# signing certificate in its own keychain. Signing every build with the same identity keeps the
# folder permissions (Desktop, Documents, Downloads) across rebuilds; an ad hoc signature changes
# with every build and macOS forgets them.
#   scripts/setup-signing.sh
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="Spectrum Local Signing"
KC="$PWD/signing/spectrum.keychain-db"
PASS="spectrum"
if [[ -f "$KC" ]]; then
    echo "signing/spectrum.keychain-db already exists."
    exit 0
fi
mkdir -p signing
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out signing/cert.pem 2>/dev/null
openssl pkcs12 -export -inkey "$WORK/key.pem" -in signing/cert.pem -name "$NAME" \
    -out "$WORK/identity.p12" -passout pass:$PASS 2>/dev/null

security create-keychain -p "$PASS" "$KC"
security set-keychain-settings "$KC"            # no auto-lock
security unlock-keychain -p "$PASS" "$KC"
security import "$WORK/identity.p12" -k "$KC" -P "$PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$KC" >/dev/null
echo "Created $KC with identity \"$NAME\"."
