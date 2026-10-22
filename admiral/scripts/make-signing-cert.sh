#!/usr/bin/env bash
#
# Create the local code-signing identity Admiral is signed with — run once per Mac.
#
# Why this exists: macOS stores every privacy grant (App Data, Automation, Files &
# Folders) against the app's *designated requirement* — the rule that says "this is
# still the same app". An ad-hoc signature (`codesign --sign -`) has no designated
# requirement at all, so TCC falls back to the executable's cdhash. Every rebuild
# changes that hash, macOS decides Admiral is a different app, and re-asks for
# everything. Signing with a stable certificate instead pins the requirement to
#
#     identifier "com.pedro.admiral" and certificate leaf = H"<this cert>"
#
# which survives rebuilds, so the grants are given once and kept.
#
# The certificate is a self-signed local one: no Apple Developer account, never
# leaves this Mac, and only ever used to sign Admiral. Keep it — losing it means
# re-granting the permissions once against its replacement.
#
set -euo pipefail

# Always this name — the one scripts/sign-app.sh looks for as its self-signed fallback. It never
# follows $ADMIRAL_SIGN_ID: that names the real "Developer ID Application: …" identity, and a Mac
# without it would otherwise mint a self-signed impostor carrying the Developer ID's name.
CERT_NAME="Admiral Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "✓ '$CERT_NAME' already exists in the login keychain — nothing to do."
  security find-identity -v -p codesigning | grep -F "$CERT_NAME" || true
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A code-signing leaf: codeSigning EKU is what makes `security find-identity
# -p codesigning` and codesign accept it. Written as a config file rather than
# -addext so this works on both OpenSSL and the system LibreSSL.
cat > "$TMP/cert.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no

[ dn ]
CN = $CERT_NAME

[ ext ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
subjectKeyIdentifier   = hash
CNF

echo "▶ Generating a self-signed code-signing certificate: $CERT_NAME"
openssl req -x509 -newkey rsa:2048 -sha256 -days 7300 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null

# -legacy: the Security framework's PKCS#12 reader rejects OpenSSL 3's default
# AES-256 / PBKDF2 encoding, so ask for the RC2/3DES one it understands.
openssl pkcs12 -export -legacy -out "$TMP/id.p12" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$CERT_NAME" -passout pass:admiral 2>/dev/null \
  || openssl pkcs12 -export -out "$TMP/id.p12" \
       -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$CERT_NAME" -passout pass:admiral

# -T /usr/bin/codesign: only codesign may use the private key without a prompt. (This used
# -A, any process at all, to avoid "a dialog on every build" — but codesign is the only tool
# that signs, so trusting it alone avoids that dialog just the same, and no other process
# can sign as this identity silently.) If macOS still asks once, "Always Allow" adds it.
echo "▶ Importing into the login keychain"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P admiral -T /usr/bin/codesign -f pkcs12

# Trust it for code signing in the *user* trust domain, so find-identity reports
# it as valid. Best-effort: signing works from the keychain either way, this only
# affects whether the identity is listed as trusted.
echo "▶ Trusting it for code signing"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" 2>/dev/null \
  || echo "  (could not set trust automatically — signing still works; see the note below)"

echo
security find-identity -v -p codesigning | grep -F "$CERT_NAME" \
  && echo "✓ '$CERT_NAME' is ready. Build and install with: scripts/release.sh" \
  || cat <<'NOTE'
The certificate is in the keychain but is not listed as a *trusted* code-signing
identity. codesign can still sign with it, and the designated requirement it
produces is stable — which is all TCC needs. To make it trusted, open Keychain
Access, find the certificate, and set "Code Signing" to "Always Trust".
NOTE
