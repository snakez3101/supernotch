#!/usr/bin/env bash
# CI helper (macOS runner): import the optional stable self-signed identity into a temporary keychain.
#
# Environment:
#   SIGNING_P12_BASE64    base64 of the .p12 (GitHub secret; see docs/INSTALL.md). Empty/unset => ad-hoc signing.
#   SIGNING_P12_PASSWORD  password of the .p12 (GitHub secret)
#   SIGNING_IDENTITY      optional identity name to pick when the .p12 holds several (GitHub secret)
#   SIGNING_STRICT=1      fail the job when a certificate IS configured but cannot be used
#                         (release builds). Default: warn and fall back to ad-hoc so CI stays green.
#   RUNNER_TEMP, GITHUB_ENV, GITHUB_STEP_SUMMARY   set by GitHub Actions
#
# On success it appends SIGN_IDENTITY (certificate SHA-1) and SIGN_KEYCHAIN to $GITHUB_ENV for
# Scripts/package_app.sh. Untrusted self-signed identities do not always sign headlessly, so the import is
# proven with a canary codesign before it is used.
set -euo pipefail

TMP=${RUNNER_TEMP:-${TMPDIR:-/tmp}}

note() { echo "$*"; if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then echo "- $*" >>"$GITHUB_STEP_SUMMARY"; fi; }

adhoc() {
  # $1 = reason
  if [[ ${SIGNING_STRICT:-0} == 1 ]]; then
    echo "::error::$1 (SIGNING_STRICT=1, refusing to fall back to an ad-hoc signature)"
    exit 1
  fi
  echo "::warning::$1 Falling back to ad-hoc signing."
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then echo "- Signing: **ad-hoc** ($1)" >>"$GITHUB_STEP_SUMMARY"; fi
  exit 0
}

if [[ -z ${SIGNING_P12_BASE64:-} ]]; then
  echo "No SIGNING_P12_BASE64 secret configured: the app will be signed ad-hoc."
  echo "(Run Scripts/make_selfsigned_cert.sh once and store the secrets to keep macOS permission grants across updates.)"
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then echo "- Signing: **ad-hoc** (no SIGNING_P12_BASE64 secret)" >>"$GITHUB_STEP_SUMMARY"; fi
  exit 0
fi
if [[ -z ${SIGNING_P12_PASSWORD:-} ]]; then
  adhoc "SIGNING_P12_BASE64 is set but SIGNING_P12_PASSWORD is empty."
fi

KC="$TMP/supernotch-signing.keychain-db"
KC_PW=$(uuidgen)
echo "::add-mask::$KC_PW"
P12="$TMP/supernotch-signing.p12"
rm -f "$KC"

echo "Decoding the certificate ..."
if ! printf '%s' "$SIGNING_P12_BASE64" | base64 -D >"$P12" 2>/dev/null; then
  printf '%s' "$SIGNING_P12_BASE64" | base64 --decode >"$P12" 2>/dev/null || adhoc "SIGNING_P12_BASE64 is not valid base64."
fi
[[ -s $P12 ]] || adhoc "SIGNING_P12_BASE64 decoded to an empty file."

echo "Creating a temporary keychain ..."
security create-keychain -p "$KC_PW" "$KC"
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p "$KC_PW" "$KC"

echo "Importing the identity ..."
if ! security import "$P12" -k "$KC" -P "$SIGNING_P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null; then
  rm -f "$P12"
  adhoc "security import failed (wrong password, or a .p12 that macOS cannot read: recreate it with Scripts/make_selfsigned_cert.sh)."
fi
rm -f "$P12"
# Let codesign use the private key without a (headless impossible) UI prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PW" "$KC" >/dev/null 2>&1 \
  || echo "warning: set-key-partition-list failed (continuing)"

# Put the temporary keychain first in the user search list, keep the others.
existing=()
while IFS= read -r line; do
  line=${line#"${line%%[![:space:]]*}"}
  line=${line%\"}
  line=${line#\"}
  if [[ -n $line ]]; then existing+=("$line"); fi
done < <(security list-keychains -d user)
security list-keychains -d user -s "$KC" "${existing[@]+"${existing[@]}"}"

# Pick the identity: all identities in the temp keychain, not only "valid" ones (self-signed => not trusted).
pick_identity() {
  local line hash name first_hash="" first_name="" want=${SIGNING_IDENTITY:-}
  local re='^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-Fa-f]{40})[[:space:]]+"(.*)"'
  while IFS= read -r line; do
    if [[ $line =~ $re ]]; then
      hash=${BASH_REMATCH[1]}
      name=${BASH_REMATCH[2]}
      if [[ -z $first_hash ]]; then first_hash=$hash; first_name=$name; fi
      if [[ -n $want && $name == "$want" ]]; then
        printf '%s\t%s\n' "$hash" "$name"
        return 0
      fi
    fi
  done < <(security find-identity -p codesigning "$KC")
  if [[ -n $first_hash ]]; then printf '%s\t%s\n' "$first_hash" "$first_name"; fi
}

canary() {
  # $1 = identity. Signs a throw-away copy of a system binary and checks the designated requirement.
  local f="$TMP/supernotch-canary" dr
  rm -f "$f"
  cp /bin/echo "$f"
  if ! codesign --force --sign "$1" --keychain "$KC" --timestamp=none "$f" >/dev/null 2>&1; then
    rm -f "$f"
    return 1
  fi
  dr=$(codesign -d -r- "$f" 2>&1 | sed -nE 's/^(# )?designated => //p')  # "# " = implicit requirement
  rm -f "$f"
  echo "canary designated requirement: $dr"
  [[ $dr == *"certificate leaf"* || $dr == *"anchor"* ]]
}

picked=$(pick_identity)
if [[ -z $picked ]]; then
  adhoc "the .p12 contains no code-signing identity (does the certificate have the codeSigning extended key usage?)."
fi
IDENT_HASH=${picked%%$'\t'*}
IDENT_NAME=${picked#*$'\t'}
echo "Identity: $IDENT_NAME ($IDENT_HASH)"

if ! canary "$IDENT_HASH"; then
  echo "The identity does not sign yet (untrusted self-signed certificate). Trusting it for code signing ..."
  cert="$TMP/supernotch-signing-cert.pem"
  security find-certificate -a -p "$KC" >"$cert"
  sudo -n security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain "$cert" \
    || echo "warning: add-trusted-cert failed"
  rm -f "$cert"
  canary "$IDENT_HASH" || adhoc "the imported identity '$IDENT_NAME' cannot sign on this runner."
fi

{
  echo "SIGN_IDENTITY=$IDENT_HASH"
  echo "SIGN_KEYCHAIN=$KC"
} >>"${GITHUB_ENV:-/dev/null}"
note "Signing: stable self-signed identity **$IDENT_NAME** (\`$IDENT_HASH\`)"
echo "Stable signing identity ready."
