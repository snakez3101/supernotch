#!/usr/bin/env bash
# SuperNotch installer for macOS 26+ (Apple Silicon).
#
#   curl -fsSL https://raw.githubusercontent.com/snakez3101/supernotch/main/Scripts/install.sh | bash
#
# What it does:
#   1. finds the latest GitHub release of snakez3101/supernotch and downloads SuperNotch-<version>-arm64.zip
#   2. quits a running SuperNotch
#   3. installs it to /Applications (ditto) and removes the quarantine flag (no Gatekeeper prompt)
#   4. launches it
#
# Options (pass them after `bash -s --`):
#   --version vX.Y.Z   install a specific release instead of the latest
#   --no-launch        do not open the app afterwards
#   -h, --help         show this help
# Environment: INSTALL_DIR (default /Applications), SUPERNOTCH_REPO (default snakez3101/supernotch),
#              GITHUB_TOKEN (optional, only raises the API rate limit).
#
# Everything lives inside main() so a partially downloaded script can never run half of itself.
set -euo pipefail

REPO=${SUPERNOTCH_REPO:-snakez3101/supernotch}
APP_NAME=SuperNotch
INSTALL_DIR=${INSTALL_DIR:-/Applications}
WANT_TAG=${SUPERNOTCH_VERSION:-latest}
LAUNCH=1

if [[ -t 1 ]]; then
  C_BLUE=$'\033[1;34m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_BLUE=""; C_YELLOW=""; C_RED=""; C_GREEN=""; C_DIM=""; C_OFF=""
fi
step() { printf '%s==>%s %s\n' "$C_BLUE" "$C_OFF" "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '%s ok%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
warn() { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
SuperNotch installer for macOS 26+ (Apple Silicon).

  curl -fsSL https://raw.githubusercontent.com/snakez3101/supernotch/main/Scripts/install.sh | bash
  curl -fsSL https://raw.githubusercontent.com/snakez3101/supernotch/main/Scripts/install.sh | bash -s -- --version v1.0.0

Options:
  --version vX.Y.Z   install a specific release instead of the latest
  --no-launch        do not open the app afterwards
  -h, --help         show this help

Environment: INSTALL_DIR (default /Applications), SUPERNOTCH_REPO (default snakez3101/supernotch),
             GITHUB_TOKEN (optional, only raises the GitHub API rate limit).
USAGE
}

# Prints the download URL of the arm64 zip for the wanted release, or nothing.
find_zip_url_api() {
  local api json
  if [[ $WANT_TAG == latest ]]; then
    api="https://api.github.com/repos/$REPO/releases/latest"
  else
    api="https://api.github.com/repos/$REPO/releases/tags/$WANT_TAG"
  fi
  local curl_args=(-fsSL -H "Accept: application/vnd.github+json" -H "User-Agent: supernotch-installer")
  if [[ -n ${GITHUB_TOKEN:-} ]]; then curl_args+=(-H "Authorization: Bearer $GITHUB_TOKEN"); fi
  json=$(curl "${curl_args[@]}" "$api" 2>/dev/null </dev/null) || return 0
  printf '%s\n' "$json" \
    | grep -Eo '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+-arm64\.zip"' \
    | head -n 1 \
    | sed -E 's/.*"(https:[^"]+)"$/\1/' || true
}

# Fallback without the API (rate limit, proxy): follow the /releases/latest redirect to learn the tag.
find_zip_url_redirect() {
  local tag final
  if [[ $WANT_TAG == latest ]]; then
    final=$(curl -fsSIL -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" </dev/null 2>/dev/null) || return 0
    tag=${final##*/}
  else
    tag=$WANT_TAG
  fi
  [[ $tag =~ ^v[0-9] ]] || return 0
  printf 'https://github.com/%s/releases/download/%s/%s-%s-arm64.zip\n' "$REPO" "$tag" "$APP_NAME" "${tag#v}"
}

quit_running_app() {
  if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then return 0; fi
  step "Quitting the running $APP_NAME"
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then return 0; fi
    sleep 0.5
  done
  pkill -9 -x "$APP_NAME" >/dev/null 2>&1 || true
  sleep 0.5
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)   [[ $# -ge 2 ]] || die "--version needs a value (e.g. v1.0.0)"; WANT_TAG=$2; shift ;;
      --no-launch) LAUNCH=0 ;;
      -h|--help)   usage; exit 0 ;;
      *)           die "unknown option: $1 (try --help)" ;;
    esac
    shift
  done
  if [[ $WANT_TAG != latest && $WANT_TAG != v* ]]; then WANT_TAG="v$WANT_TAG"; fi

  printf '\n%s%s installer%s  %s(%s)%s\n\n' "$C_GREEN" "$APP_NAME" "$C_OFF" "$C_DIM" "$REPO" "$C_OFF"

  [[ "$(uname -s)" == "Darwin" ]] || die "$APP_NAME is a macOS app; this installer only runs on macOS."
  local major
  major=$(sw_vers -productVersion 2>/dev/null | cut -d. -f1 || echo 0)
  [[ $major =~ ^[0-9]+$ && $major -ge 26 ]] || die "$APP_NAME needs macOS 26 (Tahoe) or later; this Mac runs $(sw_vers -productVersion 2>/dev/null || echo unknown)."
  [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" == "1" ]] \
    || die "$APP_NAME is built for Apple Silicon (every Mac with a notch is one); this Mac is not."
  for tool in curl ditto xattr open pgrep pkill; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
  done

  step "Looking for the $WANT_TAG release"
  local url
  url=$(find_zip_url_api)
  if [[ -z $url ]]; then
    info "GitHub API unavailable, trying the release redirect"
    url=$(find_zip_url_redirect)
  fi
  [[ -n $url ]] || die "could not find a release zip for $REPO. Is there a published release yet?
       Releases: https://github.com/$REPO/releases"
  info "$url"

  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/supernotch-install.XXXXXX")
  # shellcheck disable=SC2064  # expand $tmp now on purpose
  trap "rm -rf '$tmp'" EXIT

  step "Downloading"
  curl -fL --progress-bar -o "$tmp/$APP_NAME.zip" "$url" </dev/null || die "download failed: $url"

  step "Unpacking"
  mkdir -p "$tmp/x"
  ditto -x -k "$tmp/$APP_NAME.zip" "$tmp/x" </dev/null || die "the download is not a valid zip"
  [[ -d "$tmp/x/$APP_NAME.app" ]] || die "$APP_NAME.app not found inside the zip"

  quit_running_app

  step "Installing to $INSTALL_DIR"
  local dest="$INSTALL_DIR/$APP_NAME.app"
  local sudo_cmd
  sudo_cmd=()
  mkdir -p "$INSTALL_DIR" 2>/dev/null || true
  if [[ ! -w $INSTALL_DIR ]]; then
    info "$INSTALL_DIR is not writable for you, using sudo (you may be asked for your password)"
    sudo_cmd=(sudo)
  fi
  if [[ -e $dest ]]; then
    info "replacing the existing $APP_NAME.app"
    "${sudo_cmd[@]+"${sudo_cmd[@]}"}" rm -rf "$dest"
  fi
  "${sudo_cmd[@]+"${sudo_cmd[@]}"}" ditto "$tmp/x/$APP_NAME.app" "$dest"
  "${sudo_cmd[@]+"${sudo_cmd[@]}"}" xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true

  if codesign --verify --deep --strict "$dest" 2>/dev/null; then
    ok "signature valid"
  else
    warn "codesign verification failed; the download may be damaged. Try again, or use the DMG from the releases page."
  fi
  local version
  version=$(/usr/libexec/PlistBuddy -c 'Print :SNFullVersion' "$dest/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$dest/Contents/Info.plist" 2>/dev/null \
    || echo "?")
  ok "installed $APP_NAME $version at $dest"

  if [[ $LAUNCH -eq 1 ]]; then
    step "Launching"
    open "$dest" || warn "could not launch it; open $dest manually"
  fi

  cat <<EOF

${C_GREEN}Done.${C_OFF} Hover over the notch (or press ⌥⌘N) to open $APP_NAME.

First run:
  - The setup wizard walks you through the Claude Code hooks, Spotify and clipboard permissions.
  - macOS asks for Automation access to Spotify the first time it is needed (allow it), and
    Accessibility if you want ⌥⌘V to paste directly into other apps.
  - Update later by running this installer again; your settings and history are kept.

EOF
}

main "$@"
