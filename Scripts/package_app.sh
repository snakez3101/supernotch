#!/usr/bin/env bash
# Scripts/package_app.sh: assemble, sign and package SuperNotch.app (macOS only).
#
# Usage:
#   Scripts/package_app.sh [--smoke-test] [--skip-build] [--no-zip] [--no-dmg] [--help]
#
# Environment:
#   VERSION         version to embed, e.g. 1.2.3 or 0.0.0-ci.42 (default: git tag v*, else 0.1.0-dev.<sha>)
#   BUILD_NUMBER    CFBundleVersion (default: git commit count, else 1)
#   SIGN_IDENTITY   codesign identity: name or SHA-1 of a certificate; "-" = ad-hoc (default "-")
#   SIGN_KEYCHAIN   optional keychain file that holds SIGN_IDENTITY (CI temp keychain)
#   OUT_DIR         output directory (default: dist)
#   CONFIGURATION   SwiftPM configuration (default: release)
#
# Output (in $OUT_DIR):
#   SuperNotch.app
#   SuperNotch-<VERSION>-arm64.zip     ditto zip (keeps symlinks, exec bits, signature)
#   SuperNotch-<VERSION>.dmg           UDZO disk image with an /Applications symlink
#   SHA256SUMS.txt
#
# See docs/SPEC.md section G.3. No hardened runtime (no notarization, and library validation would only
# break ad-hoc / self-signed builds).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT=$PWD

APP_NAME=SuperNotch
HOOK_NAME=supernotch-hook
BUNDLE_ID=io.github.snakez3101.supernotch
CONFIGURATION=${CONFIGURATION:-release}
OUT_DIR=${OUT_DIR:-dist}
IDENTITY=${SIGN_IDENTITY:--}
APP="$OUT_DIR/$APP_NAME.app"

DO_SMOKE=0
DO_BUILD=1
DO_ZIP=1
DO_DMG=1

# ---------------------------------------------------------------------------------------------- logging
if [[ -t 1 ]]; then
  C_BLUE=$'\033[1;34m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_OFF=$'\033[0m'
else
  C_BLUE=""; C_YELLOW=""; C_RED=""; C_GREEN=""; C_OFF=""
fi
step() { printf '%s==>%s %s\n' "$C_BLUE" "$C_OFF" "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '%s ok%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
warn() { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; if [[ -n ${GITHUB_ACTIONS:-} ]]; then echo "::warning::$*"; fi; }
die()  { printf '%serror:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; if [[ -n ${GITHUB_ACTIONS:-} ]]; then echo "::error::$*"; fi; exit 1; }

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------------------------------------- args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --smoke-test) DO_SMOKE=1 ;;
    --skip-build) DO_BUILD=0 ;;
    --no-zip)     DO_ZIP=0 ;;
    --no-dmg)     DO_DMG=0 ;;
    -h|--help)    usage; exit 0 ;;
    *)            usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

[[ "$(uname -s)" == "Darwin" ]] || die "package_app.sh only runs on macOS (needs codesign, sips, iconutil, ditto, hdiutil)."
for tool in swift codesign ditto hdiutil sips iconutil plutil shasum lipo perl; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found in PATH: $tool"
done
[[ -x /usr/libexec/PlistBuddy ]] || die "/usr/libexec/PlistBuddy not found"

# ---------------------------------------------------------------------------------------------- version
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)

resolve_version() {
  local v tag
  if [[ -n ${VERSION:-} ]]; then
    v=${VERSION#v}
  elif tag=$(git describe --tags --exact-match --match 'v[0-9]*' 2>/dev/null); then
    v=${tag#v}
  elif tag=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null); then
    v="${tag#v}-dev.g${GIT_COMMIT}"
  else
    v="0.1.0-dev.g${GIT_COMMIT}"
  fi
  printf '%s' "$v"
}

VERSION_FULL=$(resolve_version)
ver_re='^[0-9A-Za-z][0-9A-Za-z._-]*$'
[[ $VERSION_FULL =~ $ver_re ]] || die "invalid VERSION '$VERSION_FULL' (allowed: letters, digits, '.', '_', '-')"
# CFBundleShortVersionString should be numeric (1.2.3): keep the part before the first '-' or '+'.
VERSION_NUM=${VERSION_FULL%%[-+]*}
num_re='^[0-9]+(\.[0-9]+){0,2}$'
if [[ ! $VERSION_NUM =~ $num_re ]]; then
  warn "version '$VERSION_FULL' has no numeric X.Y.Z prefix; CFBundleShortVersionString falls back to 0.0.0"
  VERSION_NUM=0.0.0
fi
BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
[[ $BUILD_NUMBER =~ ^[0-9]+$ ]] || die "BUILD_NUMBER must be an integer, got '$BUILD_NUMBER'"

step "Packaging $APP_NAME $VERSION_FULL (build $BUILD_NUMBER, commit $GIT_COMMIT)"
info "configuration : $CONFIGURATION (arm64)"
if [[ $IDENTITY == "-" ]]; then
  info "signing       : ad-hoc (set SIGN_IDENTITY for a stable identity)"
else
  info "signing       : identity '$IDENTITY'${SIGN_KEYCHAIN:+ in keychain $SIGN_KEYCHAIN}"
fi

# ---------------------------------------------------------------------------------------------- build
# Every Mac with a notch is Apple Silicon, so arm64 only (no universal binary).
SWIFT_ARGS=(-c "$CONFIGURATION" --arch arm64)
if [[ $DO_BUILD -eq 1 ]]; then
  step "swift build ${SWIFT_ARGS[*]}"
  swift build "${SWIFT_ARGS[@]}"
else
  step "Skipping build (--skip-build)"
fi
BIN_DIR=$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)
info "binaries in $BIN_DIR"
[[ -x "$BIN_DIR/$APP_NAME" ]] || die "missing $BIN_DIR/$APP_NAME (did 'swift build' fail, or is the app target not built?)"
[[ -x "$BIN_DIR/$HOOK_NAME" ]] || die "missing $BIN_DIR/$HOOK_NAME"
lipo -archs "$BIN_DIR/$APP_NAME" | grep -qw arm64 || die "$APP_NAME is not an arm64 binary"

# ---------------------------------------------------------------------------------------------- assemble
step "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$BIN_DIR/$HOOK_NAME" "$APP/Contents/Helpers/$HOOK_NAME"
chmod 755 "$APP/Contents/MacOS/$APP_NAME" "$APP/Contents/Helpers/$HOOK_NAME"

PLIST="$APP/Contents/Info.plist"
cp Resources/Info.plist "$PLIST"
PB=/usr/libexec/PlistBuddy
"$PB" -c "Set :CFBundleShortVersionString $VERSION_NUM" "$PLIST"
"$PB" -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
"$PB" -c "Set :SNFullVersion $VERSION_FULL" "$PLIST"
"$PB" -c "Set :SNGitCommit $GIT_COMMIT" "$PLIST"
plutil -lint "$PLIST" >/dev/null || die "Info.plist is not valid after version substitution"
info "Info.plist: version $VERSION_NUM ($BUILD_NUMBER), bundle id $("$PB" -c 'Print :CFBundleIdentifier' "$PLIST")"

# SwiftPM resource bundles (if any target ever declares resources) go to Contents/Resources.
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
  info "resource bundle: $(basename "$bundle")"
  cp -R "$bundle" "$APP/Contents/Resources/"
done
# Embedded frameworks (none today; ready for e.g. Sparkle later).
for fw in "$BIN_DIR"/*.framework; do
  mkdir -p "$APP/Contents/Frameworks"
  info "framework: $(basename "$fw")"
  cp -R "$fw" "$APP/Contents/Frameworks/"
  install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true
done
shopt -u nullglob

# ---------------------------------------------------------------------------------------------- icon
make_icns() {
  local png=Resources/AppIcon.png
  if [[ ! -f $png ]] && command -v python3 >/dev/null 2>&1; then
    info "Resources/AppIcon.png missing, generating it with Scripts/make_icon.py"
    python3 Scripts/make_icon.py "$png" || true
  fi
  if [[ ! -f $png ]]; then
    warn "Resources/AppIcon.png not found; the app gets no icon"
    return 0
  fi
  local w h
  w=$(sips -g pixelWidth "$png" 2>/dev/null | awk '/pixelWidth/ {print $2}')
  h=$(sips -g pixelHeight "$png" 2>/dev/null | awk '/pixelHeight/ {print $2}')
  [[ $w == 1024 && $h == 1024 ]] || warn "Resources/AppIcon.png is ${w:-?}x${h:-?}, expected 1024x1024"
  local tmp iconset s
  tmp=$(mktemp -d)
  iconset="$tmp/AppIcon.iconset"
  mkdir -p "$iconset"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$png" --out "$iconset/icon_${s}x${s}.png" >/dev/null
    sips -z "$((s * 2))" "$((s * 2))" "$png" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$tmp"
  info "AppIcon.icns created"
}
step "Building AppIcon.icns"
make_icns

# ---------------------------------------------------------------------------------------------- sign
codesign_args=(--force --sign "$IDENTITY" --timestamp=none)
if [[ -n ${SIGN_KEYCHAIN:-} ]]; then
  codesign_args+=(--keychain "$SIGN_KEYCHAIN")
fi

step "Signing inside-out ($([[ $IDENTITY == "-" ]] && echo ad-hoc || echo "$IDENTITY"))"
# No "--options runtime": the hardened runtime buys nothing without notarization and, with an ad-hoc or
# self-signed identity, library validation only causes trouble.
xattr -cr "$APP"
shopt -s nullglob
for fw in "$APP"/Contents/Frameworks/*.framework; do
  info "sign $(basename "$fw")"
  codesign "${codesign_args[@]}" "$fw"
done
shopt -u nullglob
info "sign Contents/Helpers/$HOOK_NAME"
codesign "${codesign_args[@]}" --identifier "$BUNDLE_ID.hook" "$APP/Contents/Helpers/$HOOK_NAME"
info "sign $APP_NAME.app (entitlements: Resources/SuperNotch.entitlements)"
codesign "${codesign_args[@]}" --entitlements Resources/SuperNotch.entitlements "$APP"

step "Verifying signature"
codesign --verify --strict --deep --verbose=2 "$APP"
DESIGNATED=$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')
info "designated requirement: ${DESIGNATED:-unknown}"
if [[ $IDENTITY == "-" ]]; then
  info "ad-hoc signature: the requirement is a cdhash, so Automation/Accessibility grants reset on every update."
elif [[ $DESIGNATED == *cdhash* ]]; then
  warn "SIGN_IDENTITY is set but the designated requirement is a cdhash: the identity was not used"
else
  ok "stable identity: grants survive updates"
fi
info "architectures: $(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"
"$APP/Contents/Helpers/$HOOK_NAME" --version >/dev/null 2>&1 || warn "$HOOK_NAME --version did not exit cleanly"

# ---------------------------------------------------------------------------------------------- smoke test
run_with_timeout() {
  local secs=$1
  shift
  perl -e 'alarm shift @ARGV; exec @ARGV or die "exec failed: $!\n"' "$secs" "$@"
}

if [[ $DO_SMOKE -eq 1 ]]; then
  step "Smoke test: $APP_NAME --smoke-test (30 s limit)"
  set +e
  run_with_timeout 30 "$APP/Contents/MacOS/$APP_NAME" --smoke-test </dev/null
  smoke_rc=$?
  set -e
  if [[ $smoke_rc -ne 0 ]]; then
    die "smoke test failed with exit code $smoke_rc (142 = timeout)"
  fi
  ok "smoke test passed"
fi

# ---------------------------------------------------------------------------------------------- zip + dmg
ZIP="$OUT_DIR/$APP_NAME-$VERSION_FULL-arm64.zip"
DMG="$OUT_DIR/$APP_NAME-$VERSION_FULL.dmg"
rm -f "$ZIP" "$DMG" "$OUT_DIR/SHA256SUMS.txt"

if [[ $DO_ZIP -eq 1 ]]; then
  step "Creating $ZIP"
  # ditto keeps symlinks, permissions and the code signature (plain zip and upload-artifact's zipping do not).
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
fi

if [[ $DO_DMG -eq 1 ]]; then
  step "Creating $DMG"
  # Plain hdiutil: create-dmg drives Finder via AppleScript and can hang on headless CI.
  STAGE=$(mktemp -d)
  ditto "$APP" "$STAGE/$APP_NAME.app"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -fs HFS+ -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"
fi

(
  cd "$OUT_DIR"
  files=()
  for f in "$APP_NAME-$VERSION_FULL-arm64.zip" "$APP_NAME-$VERSION_FULL.dmg"; do
    if [[ -f $f ]]; then files+=("$f"); fi
  done
  if [[ ${#files[@]} -gt 0 ]]; then
    shasum -a 256 "${files[@]}" >SHA256SUMS.txt
  fi
)

# ---------------------------------------------------------------------------------------------- summary
step "Done"
info "app : $APP"
if [[ -f $ZIP ]]; then info "zip : $ZIP ($(du -h "$ZIP" | cut -f1))"; fi
if [[ -f $DMG ]]; then info "dmg : $DMG ($(du -h "$DMG" | cut -f1))"; fi
if [[ -f $OUT_DIR/SHA256SUMS.txt ]]; then info "sums: $OUT_DIR/SHA256SUMS.txt"; fi

if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  {
    echo "version=$VERSION_FULL"
    echo "app=$APP"
    if [[ -f $ZIP ]]; then echo "zip=$ZIP"; fi
    if [[ -f $DMG ]]; then echo "dmg=$DMG"; fi
  } >>"$GITHUB_OUTPUT"
fi

if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
  {
    echo "### Packaged $APP_NAME $VERSION_FULL"
    echo
    echo "| | |"
    echo "|---|---|"
    echo "| Build | $BUILD_NUMBER (commit \`$GIT_COMMIT\`) |"
    if [[ $IDENTITY == "-" || $DESIGNATED == *cdhash* ]]; then
      echo "| Signing | ad-hoc (grants reset on every update) |"
    else
      echo "| Signing | stable identity (grants survive updates) |"
    fi
    echo "| Designated requirement | \`${DESIGNATED:-unknown}\` |"
    if [[ -f $ZIP ]]; then echo "| Zip | \`$(basename "$ZIP")\` ($(du -h "$ZIP" | cut -f1)) |"; fi
    if [[ -f $DMG ]]; then echo "| DMG | \`$(basename "$DMG")\` ($(du -h "$DMG" | cut -f1)) |"; fi
    if [[ $DO_SMOKE -eq 1 ]]; then echo "| Smoke test | passed |"; fi
  } >>"$GITHUB_STEP_SUMMARY"
fi

# Touch the bundle so Finder refreshes its icon cache.
touch "$APP"
cd "$ROOT"
