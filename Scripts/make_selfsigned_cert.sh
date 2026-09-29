#!/usr/bin/env bash
# Scripts/make_selfsigned_cert.sh: create the stable self-signed code-signing identity for SuperNotch.
#
# Run this ONCE on your Mac (it also works on Linux). Why: an ad-hoc signature changes with every build, so
# macOS forgets the Automation (Spotify) and Accessibility grants after each update. A stable certificate keeps
# the "designated requirement" identical across builds, so grants survive updates. It does NOT make Gatekeeper
# trust the app (only a paid Developer ID + notarization does that); see docs/INSTALL.md.
#
# Usage:
#   Scripts/make_selfsigned_cert.sh [--import] [--name NAME] [--days N] [--out DIR] [--repo OWNER/REPO]
#                                   [--password PW] [--keep-pem] [--force]
#
#   --import       also import the identity into your login keychain and trust it for code signing
#                  (only needed for local builds with SIGN_IDENTITY; CI needs just the GitHub secrets)
#   --name NAME    certificate common name / identity name   (default: "SuperNotch Self-Signed")
#   --days N       validity in days                          (default: 3650 = 10 years)
#   --out DIR      output directory                          (default: ./supernotch-signing)
#   --repo R       GitHub repo used in the printed commands  (default: snakez3101/supernotch)
#   --password PW  PKCS12 password                           (default: random)
#   --keep-pem     keep the unencrypted private key (key.pem); by default it is deleted after export
#   --force        overwrite an existing output directory
#
# Output (DIR is chmod 700; NEVER commit it, *.p12/*.pem are in .gitignore):
#   <name>.p12         PKCS12 bundle (private key + certificate), legacy encryption for `security import`
#   p12.base64         the .p12 as a single base64 line  -> GitHub secret SIGNING_P12_BASE64
#   p12.password       the password (no trailing newline) -> GitHub secret SIGNING_P12_PASSWORD
#   identity.name      the identity name                  -> GitHub secret SIGNING_IDENTITY
#   cert.pem           the public certificate
set -euo pipefail

NAME="SuperNotch Self-Signed"
DAYS=3650
OUT="./supernotch-signing"
REPO="snakez3101/supernotch"
PASSWORD=""
DO_IMPORT=0
KEEP_PEM=0
FORCE=0

if [[ -t 1 ]]; then
  C_BLUE=$'\033[1;34m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_BLUE=""; C_YELLOW=""; C_RED=""; C_GREEN=""; C_BOLD=""; C_OFF=""
fi
step() { printf '%s==>%s %s\n' "$C_BLUE" "$C_OFF" "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --import)   DO_IMPORT=1 ;;
    --keep-pem) KEEP_PEM=1 ;;
    --force)    FORCE=1 ;;
    --name)     [[ $# -ge 2 ]] || die "--name needs a value"; NAME=$2; shift ;;
    --days)     [[ $# -ge 2 ]] || die "--days needs a value"; DAYS=$2; shift ;;
    --out)      [[ $# -ge 2 ]] || die "--out needs a value"; OUT=$2; shift ;;
    --repo)     [[ $# -ge 2 ]] || die "--repo needs a value"; REPO=$2; shift ;;
    --password) [[ $# -ge 2 ]] || die "--password needs a value"; PASSWORD=$2; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

command -v openssl >/dev/null 2>&1 || die "openssl not found"
[[ $DAYS =~ ^[0-9]+$ && $DAYS -ge 1 ]] || die "--days must be a positive integer"
name_re='^[A-Za-z0-9 ._-]+$'
[[ $NAME =~ $name_re ]] || die "--name may only contain letters, digits, spaces, '.', '_' and '-'"
repo_re='^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
[[ $REPO =~ $repo_re ]] || die "--repo must look like OWNER/REPO"
IS_MAC=0
if [[ "$(uname -s)" == "Darwin" ]]; then IS_MAC=1; fi
if [[ $DO_IMPORT -eq 1 && $IS_MAC -eq 0 ]]; then die "--import needs macOS (security(1))"; fi

if [[ -e $OUT ]]; then
  if [[ $FORCE -eq 1 ]]; then
    rm -rf "$OUT"
  else
    die "$OUT already exists. Use --out DIR for another location or --force to overwrite (it would replace your existing key!)."
  fi
fi
umask 077
mkdir -p "$OUT"
chmod 700 "$OUT"

if [[ -z $PASSWORD ]]; then
  # 24 alphanumeric characters: safe in shells, GitHub secrets and PKCS12.
  PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true)
  [[ ${#PASSWORD} -eq 24 ]] || die "could not generate a random password"
fi

KEY="$OUT/key.pem"
CERT="$OUT/cert.pem"
P12="$OUT/${NAME// /-}.p12"
CONF="$OUT/openssl.cnf"

step "Generating a ${DAYS}-day self-signed code-signing certificate '$NAME'"
info "openssl: $(openssl version)"
# A config file instead of -addext works with both OpenSSL 3 and the LibreSSL that ships with macOS.
cat >"$CONF" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_codesign
prompt = no

[dn]
CN = $NAME
O = SuperNotch

[v3_codesign]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes -keyout "$KEY" -out "$CERT" -days "$DAYS" -config "$CONF" -sha256 2>/dev/null \
  || die "openssl req failed"

step "Exporting PKCS12 (macOS-compatible encryption)"
# macOS `security import` cannot read the AES-based PKCS12 that OpenSSL 3 writes by default. Options, in order:
#   1. -legacy                      (OpenSSL 3 with the legacy provider)
#   2. explicit SHA1/3DES ciphers   (OpenSSL 3 without the legacy provider)
#   3. plain export                 (LibreSSL and OpenSSL 1.x already use the old ciphers)
export_p12() {
  if openssl pkcs12 -export -legacy -inkey "$KEY" -in "$CERT" -name "$NAME" -out "$P12" -passout "pass:$PASSWORD" 2>/dev/null; then
    info "used: openssl pkcs12 -export -legacy"
  elif openssl pkcs12 -export -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
       -inkey "$KEY" -in "$CERT" -name "$NAME" -out "$P12" -passout "pass:$PASSWORD" 2>/dev/null; then
    info "used: openssl pkcs12 -export with explicit SHA1/3DES ciphers"
  elif openssl pkcs12 -export -inkey "$KEY" -in "$CERT" -name "$NAME" -out "$P12" -passout "pass:$PASSWORD" 2>/dev/null; then
    info "used: openssl pkcs12 -export (default ciphers)"
  else
    die "openssl pkcs12 -export failed"
  fi
}
export_p12
[[ -s $P12 ]] || die "PKCS12 file was not created"
base64 <"$P12" | tr -d '\n' >"$OUT/p12.base64"
printf '%s' "$PASSWORD" >"$OUT/p12.password"
printf '%s' "$NAME" >"$OUT/identity.name"
rm -f "$CONF"
if [[ $KEEP_PEM -eq 0 ]]; then rm -f "$KEY"; fi

FPR=$(openssl x509 -in "$CERT" -noout -fingerprint -sha1 2>/dev/null | sed 's/^.*=//' | tr -d ':')
END=$(openssl x509 -in "$CERT" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')
info "SHA-1 fingerprint: ${FPR:-unknown}"
info "valid until      : ${END:-unknown}"
info "written to       : $OUT/"

# ------------------------------------------------------------------------------------------ local import
if [[ $DO_IMPORT -eq 1 ]]; then
  step "Importing into your login keychain"
  KC="$HOME/Library/Keychains/login.keychain-db"
  [[ -f $KC ]] || KC="login.keychain"
  security import "$P12" -k "$KC" -P "$PASSWORD" -T /usr/bin/codesign \
    || die "security import failed (is the login keychain unlocked?)"
  step "Trusting the certificate for code signing (macOS asks for your password)"
  if security add-trusted-cert -r trustRoot -p codeSign -k "$KC" "$CERT"; then
    info "trusted"
  else
    warn "could not set trust. Open Keychain Access, find '$NAME', Get Info > Trust > Code Signing = Always Trust."
  fi
  info "valid code-signing identities on this Mac:"
  security find-identity -v -p codesigning | sed 's/^/      /'
  info "Use it locally with:  SIGN_IDENTITY=\"$NAME\" Scripts/package_app.sh"
fi

# ------------------------------------------------------------------------------------------ instructions
ABS_OUT=$(cd "$OUT" && pwd)
cat <<EOF

${C_GREEN}Done.${C_OFF} Now store the identity in GitHub so CI signs every build with it.

${C_BOLD}Option A: GitHub CLI${C_OFF} (gh auth login first):

  gh secret set SIGNING_P12_BASE64   --repo $REPO < "$ABS_OUT/p12.base64"
  gh secret set SIGNING_P12_PASSWORD --repo $REPO < "$ABS_OUT/p12.password"
  gh secret set SIGNING_IDENTITY     --repo $REPO < "$ABS_OUT/identity.name"

${C_BOLD}Option B: GitHub web UI${C_OFF}
  1. Open https://github.com/$REPO/settings/secrets/actions
  2. New repository secret, three times:
       SIGNING_P12_BASE64    the content of $ABS_OUT/p12.base64
                             (macOS: pbcopy < "$ABS_OUT/p12.base64", then paste)
       SIGNING_P12_PASSWORD  $PASSWORD
       SIGNING_IDENTITY      $NAME

Then push a commit: the CI log of the macOS job prints "designated requirement: ... certificate leaf = H..."
when the stable identity was used (ad-hoc builds print "cdhash").

${C_BOLD}Keep private:${C_OFF} $ABS_OUT/ holds your signing key. Back it up somewhere safe (a password manager) and
never commit it. If you lose it, create a new one: users then have to re-grant Automation/Accessibility once.
After replacing a certificate, reset stale grants with:
  tccutil reset AppleEvents io.github.snakez3101.supernotch
  tccutil reset Accessibility io.github.snakez3101.supernotch
EOF
if [[ $DO_IMPORT -eq 0 && $IS_MAC -eq 1 ]]; then
  cat <<EOF

To also sign local builds with this same identity, import it into your login keychain
(or re-run this script with --import, which creates a NEW identity, so update the secrets afterwards):
  security import "$ABS_OUT/${P12##*/}" -k ~/Library/Keychains/login.keychain-db -P '$PASSWORD' -T /usr/bin/codesign
  security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db "$ABS_OUT/cert.pem"
EOF
fi
