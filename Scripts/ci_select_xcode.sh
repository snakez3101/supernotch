#!/usr/bin/env bash
# CI helper (macOS runner): select the newest stable Xcode 26.x and print the toolchain versions.
#
# Runner images ship several Xcodes (/Applications/Xcode_26.6.app, Xcode_26.5.app, ...) plus previews such as
# Xcode_27_beta_N.app, and the default one changes over time. Picking the newest 26.x explicitly keeps the
# build on a compiler that knows the macOS 26 SDK (Liquid Glass APIs) and never on a beta.
# Exports DEVELOPER_DIR through $GITHUB_ENV when running in GitHub Actions.
set -euo pipefail

APPS_DIR=${XCODE_APPS_DIR:-/Applications}          # overridable for tests
PLISTBUDDY=${PLISTBUDDY:-/usr/libexec/PlistBuddy}

echo "Installed Xcode apps:"
for app in "$APPS_DIR"/Xcode*.app; do
  if [[ -d $app ]]; then echo "  $app"; fi
done

best_ver=""
best_app=""
for app in "$APPS_DIR/Xcode.app" "$APPS_DIR"/Xcode_26*.app "$APPS_DIR"/Xcode-26*.app; do
  [[ -d $app ]] || continue
  case "$app" in
    *[Bb]eta*) continue ;;
  esac
  ver=$("$PLISTBUDDY" -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || true)
  [[ $ver == 26 || $ver == 26.* ]] || continue
  if [[ -z $best_ver ]]; then
    best_ver=$ver
    best_app=$app
  elif [[ $ver != "$best_ver" && "$(printf '%s\n%s\n' "$best_ver" "$ver" | sort -V | tail -n 1)" == "$ver" ]]; then
    best_ver=$ver
    best_app=$app
  fi
done

if [[ -z $best_app ]]; then
  echo "::error::No stable Xcode 26.x found under $APPS_DIR. SuperNotch needs the macOS 26 SDK (Liquid Glass). Is the runner label macos-26?"
  exit 1
fi

echo "Selecting Xcode $best_ver at $best_app"
sudo xcode-select -s "$best_app/Contents/Developer"
export DEVELOPER_DIR="$best_app/Contents/Developer"
if [[ -n ${GITHUB_ENV:-} ]]; then
  echo "DEVELOPER_DIR=$DEVELOPER_DIR" >>"$GITHUB_ENV"
fi

echo "--- xcodebuild -version"
xcodebuild -version
echo "--- swift --version"
swift --version
echo "--- SDK"
xcrun --show-sdk-path
xcrun --show-sdk-version

if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
  {
    echo "### Toolchain"
    echo
    echo '```text'
    xcodebuild -version
    swift --version 2>&1
    echo "macOS SDK $(xcrun --show-sdk-version)"
    echo '```'
  } >>"$GITHUB_STEP_SUMMARY"
fi
