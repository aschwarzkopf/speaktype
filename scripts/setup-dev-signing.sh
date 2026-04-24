#!/bin/bash
# setup-dev-signing.sh
# Creates a persistent self-signed code signing identity for local dev.
# With a stable cert, the signature's Designated Requirement stays the same
# across rebuilds, so TCC permissions (Accessibility, Microphone) survive.
#
# Idempotent — safe to re-run.

set -euo pipefail

CERT_NAME="SpeakType Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "✅ Identity '$CERT_NAME' already exists in your keychain"
    security find-identity -v -p codesigning | grep "$CERT_NAME"
    exit 0
fi

echo "🔐 Creating self-signed code signing cert '$CERT_NAME'..."

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT
cd "$TMP"

cat > openssl.cnf <<EOF
[req]
distinguished_name = req_distinguished_name
prompt = no
[req_distinguished_name]
CN = $CERT_NAME
[v3_req]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout cert.key -out cert.crt \
    -days 3650 -config openssl.cnf -extensions v3_req 2>/dev/null

openssl pkcs12 -export -inkey cert.key -in cert.crt \
    -out cert.p12 -passout pass:temp 2>/dev/null

echo "📥 Importing into login keychain (you may see a prompt)..."
security import cert.p12 -k "$KEYCHAIN" -P temp -T /usr/bin/codesign -T /usr/bin/productsign -T /usr/bin/security

echo ""
echo "✅ Done. Verifying..."
security find-identity -v -p codesigning | grep "$CERT_NAME" || {
    echo "⚠️  Cert not visible to codesigning yet. You may need to open Keychain Access"
    echo "   and mark the 'SpeakType Dev' certificate as trusted for code signing."
    exit 1
}

echo ""
echo "🎯 First build will prompt Keychain for codesign access — click 'Always Allow'"
