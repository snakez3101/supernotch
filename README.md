# SuperNotch

[![CI](https://github.com/snakez3101/supernotch/actions/workflows/ci.yml/badge.svg)](https://github.com/snakez3101/supernotch/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
![macOS 26+](https://img.shields.io/badge/macOS-26%20Tahoe%2B-black)

A small, clean notch app for macOS 26 (Tahoe) and later. It turns the MacBook notch into a quiet control
surface for four things and stays out of the way otherwise:

- **Claude Code traffic light**: every local session at a glance, and permission prompts answered right in the notch.
- **Spotify**: cover, title, artist, play/pause, previous/next and seek.
- **Shelf**: drop files into the notch, drag them back out, or send them with AirDrop.
- **Clipboard history**: press ⌥⌘V, pick an entry, press Return to paste.

It is native Swift (SwiftUI + AppKit), uses real Liquid Glass, has no third-party dependencies, and idles at
practically zero CPU. Everything stays on your Mac.

<!-- Screenshots: add PNGs under docs/images/ and reference them here.
     Suggested set: closed (island style), expanded Home tab, permission card, Shelf with the AirDrop zone,
     clipboard history.
![Expanded notch](docs/images/expanded.png)
-->
> Screenshots: _coming soon_.

## Features

**Claude Code sessions** (terminal, IDE, the VS Code extension and the Claude desktop app's Code tab)

- Traffic light per session: 🟡 working, 🟢 done, 🔴 needs you (question or permission).
- Permission requests appear as a card with **Allow**, **Always allow** and **Deny**. A subagent's request shows up
  on its parent session. Dangerous commands (`rm -rf`, `git push --force`, `sudo`, ...) are highlighted and need
  a second confirming click. Return and Esc only work after you click into the notch, so typing in your terminal
  can never approve by accident.
- Questions from Claude (`AskUserQuestion`) turn the row red and take you to the chat; there is no Allow/Deny for them.
- Background runs (`claude -p`, Agent SDK apps, Cowork) are hidden. If SuperNotch is not running, Claude Code
  behaves exactly as before.
- Short session titles: Claude Code's own title when there is one, otherwise a 2-4 word title from Claude Haiku
  through your existing `claude` login (no API key), asked for only after Claude Code has had its chance.
- Usage limits (5-hour and weekly) as two thin bars, with a small warning dot in the closed notch above 80 %.
- Click a session to jump to it (Claude desktop app, VS Code or the hosting terminal).
- Auto-popups only when it matters: 🔴 always (even in fullscreen), 🟢 only if you are not already looking at
  that app. Several waiting cards are queued ("1 of 3"). No sounds.

**Spotify** (desktop app only, via AppleScript; no login, no web API)

- Cover, title, artist, progress with seek, play/pause, previous/next.
- Closed "island" style shows the cover on the left and a small animated visualizer on the right, only while a
  track is playing.

**Shelf and clipboard**

- Drag files into the notch, drag them out again (copies), persistent across restarts, automatic cleanup
  (Off / 1 day / 7 days / 30 days; pinned items stay). Text, links and images can be dropped too. Select several
  tiles, Quick Look them, reveal them in Finder or share them.
- Two drop zones while dragging: **Shelf** and **AirDrop** (opens the AirDrop picker immediately).
- Clipboard history of text, links, images and files (200 entries by default, 50 to 1000), with search and pins.
  In the ⌥⌘V panel: ↑/↓ to move, Return to paste, ⌘Return to copy, ⌘1 to ⌘9 to paste a row. Password-manager
  entries (concealed or transient) and apps you ignore are never stored.

**Look and feel**

- Compact by design: the expanded notch is 540 pt wide. Black at the top so it blends into the hardware notch,
  fading into Liquid Glass below.
- Opens after a short hover (about 0.15 s) with a subtle haptic tick; closes when the mouse leaves.
- Two closed styles: *invisible until an event* (looks like the plain notch) or *Dynamic Island style*.
- Only on the built-in display that has a notch. Hides in fullscreen apps. Hotkeys: ⌥⌘N (notch) and ⌥⌘V
  (clipboard), both rebindable (a shortcut needs ⌘ or ⌃).

## Requirements

- A MacBook with a notch, on Apple Silicon, running **macOS 26 Tahoe or later**.
- Optional: Spotify desktop app, Claude Code (`claude`) and/or the Claude desktop app.

## Install

### One-liner (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/snakez3101/supernotch/main/Scripts/install.sh | bash
```

This downloads the latest release, quits a running SuperNotch, installs it to `/Applications`, removes the
quarantine flag (so there is no Gatekeeper prompt) and launches it. Run it again any time to update.
Pin a version with `... | bash -s -- --version v1.0.0`.

### DMG or zip

1. Download `SuperNotch-<version>.dmg` (or the `.zip`) from the
   [Releases](https://github.com/snakez3101/supernotch/releases) page.
2. Drag **SuperNotch** into **Applications**.
3. The app is **not notarized** (there is no paid Apple Developer account behind it), so macOS blocks the first
   launch. Allow it once:
   1. Try to open SuperNotch. macOS shows a dialog that it could not verify the app; click **Done**.
   2. Open **System Settings > Privacy & Security**, scroll to the **Security** section, and click
      **Open Anyway** next to "SuperNotch was blocked". Authenticate and confirm.
   3. (On macOS 15 and later, right-click > Open no longer bypasses this.)

   Or remove the quarantine flag in Terminal instead:

   ```bash
   xattr -dr com.apple.quarantine /Applications/SuperNotch.app
   ```

### Update and uninstall

- Update: run the one-liner again, or replace the app in `/Applications`.
- Uninstall: in **Settings > Claude** click *Uninstall hooks*, quit SuperNotch, delete
  `/Applications/SuperNotch.app`, and optionally delete `~/Library/Application Support/SuperNotch`.

Maintainers: see [docs/INSTALL.md](docs/INSTALL.md) for the signing certificate and release setup.

## Permissions

On first launch a short setup wizard runs (Settings > General > *Run setup again* repeats it). Every step can be
skipped and nothing is required to use the parts you do not need.

| Permission | Used for | When it is asked |
|---|---|---|
| **Automation** > Spotify | Spotify controls and cover (AppleScript to the running Spotify desktop app) | The first time SuperNotch talks to a running Spotify |
| **Automation** > iTerm2 or Terminal | Jump to the right terminal window or tab (best effort; other terminals are just brought to the front) | The first time you click a session hosted in that terminal |
| **Accessibility** | Paste from clipboard history (⌥⌘V, Return): SuperNotch posts a ⌘V key event. Without it the entry is only copied and you press ⌘V yourself | The clipboard step of the wizard, or the first paste |
| Files | No Full Disk Access needed. SuperNotch is not sandboxed. It keeps its own data in `~/Library/Application Support/SuperNotch` (shelf copies, clipboard history, hook helper, backups), and edits only `~/.claude/settings.json` (with a backup) | - |
| Pasteboard | macOS 15.4 and later may ask to allow "Paste from Other Apps" for clipboard history | When history starts recording |
| Hotkeys, hover | none | - |

Claude Code sessions need no permission, but the **hooks** must be installed (see below). If the notch does not
react to hover or file drags (newer macOS releases may require it), enable SuperNotch under **Accessibility**.
The wizard and Settings show the current status. Everything stays on your Mac. The only network requests
SuperNotch makes itself are for Spotify cover images.

### Claude Code hooks

SuperNotch learns about Claude Code sessions through Claude Code's official hooks. The wizard shows the exact
entries it will add to `~/.claude/settings.json` (or `$CLAUDE_CONFIG_DIR/settings.json`) and where the timestamped
backup goes. Only entries that call `supernotch-hook` are added or removed; your other settings and hooks are
never touched, and an invalid `settings.json` is never overwritten. The hook helper is copied to
`~/Library/Application Support/SuperNotch/bin/supernotch-hook`, talks to the app over a private Unix socket, and
**fails open**: if SuperNotch is not running, Claude Code carries on exactly as before.

Newer hook events (Claude Code 2.1.101 and later) are installed only when your `claude` is recent enough; older
versions get the base set. Optionally SuperNotch wraps your `statusLine` to read the usage limits: your own command
still runs unchanged (SuperNotch just hands over to it), and the original is stored and restored on uninstall.
Without a status line of your own it shows "Model · N% context".

### Keeping your permissions across updates

Ad-hoc signed builds change their code identity on every update, so macOS forgets the Automation and
Accessibility grants. Releases built by this repository's CI are signed with one stable self-signed
certificate (when the maintainer has configured it), which keeps the grants. If you build yourself, see below.

## Build from source

Requirements: macOS 26 with **Xcode 26** (Swift 6.2 or later).

```bash
git clone https://github.com/snakez3101/supernotch.git
cd supernotch

swift build                 # debug build of everything
swift test                  # unit tests (swift-testing)
Scripts/package_app.sh      # dist/SuperNotch.app + .zip + .dmg (ad-hoc signed)
Scripts/package_app.sh --smoke-test   # also launch the packaged app once and check it exits cleanly
open dist/SuperNotch.app
```

Useful environment variables for `Scripts/package_app.sh`: `VERSION` (default: from the git tag),
`SIGN_IDENTITY` (default `-`, ad-hoc), `OUT_DIR`. To sign with a stable identity, create it once with
`Scripts/make_selfsigned_cert.sh --import` and build with `SIGN_IDENTITY="SuperNotch Self-Signed"`.

The platform-independent core (`SuperNotchCore`) and the Claude Code hook helper (`supernotch-hook`) also build
and test on Linux (`swift build && swift test` with a Swift 6.2+ toolchain). The AppKit/SwiftUI app target only
exists on macOS.

## Architecture

SwiftPM only, no Xcode project, no third-party dependencies. Details and the frozen interfaces between the
parts are in [docs/SPEC.md](docs/SPEC.md); the user requirements are in
[docs/REQUIREMENTS.md](docs/REQUIREMENTS.md) and the research behind the decisions in
[docs/RESEARCH.md](docs/RESEARCH.md).

| Target | Kind | What it is |
|---|---|---|
| `SuperNotchCore` | library (Swift 6, Foundation only) | Pure logic and contract types: Claude session state machine, hook settings merger, IPC framing, notch geometry and hover intent, popup policy, Spotify output parser, shelf retention, clipboard capture filter, settings. Builds and is tested on Linux and macOS. |
| `supernotch-hook` | executable | The tiny, fail-open helper that Claude Code runs for every hook event and for the status line. Forwards events to the app over a Unix socket and returns permission decisions. |
| `SuperNotch` | executable (macOS only) | The app: one non-activating `NSPanel` pinned to the notch, SwiftUI views morphing a `NotchShape` with Liquid Glass, and the system integrations (hotkeys, Spotify, drag and drop, clipboard, hooks, settings, onboarding). |
| `SuperNotchCoreTests` | tests | swift-testing suites and fixtures for the core. |

```
Claude Code ──hook──> supernotch-hook ──Unix socket──> SuperNotch.app ──> SessionStore (Core) ──> notch UI
                                        <── permission decision (Allow / Deny) ──┘
```

`Scripts/package_app.sh` assembles the `.app` from the SwiftPM build products (the hook goes to
`Contents/Helpers/`), and GitHub Actions builds, tests, signs and publishes it (`.github/workflows`).

## Contributing

Issues and pull requests are welcome. Please read the SPEC first: it defines file ownership, the frozen
interfaces and the macOS compile-safety checklist. CI runs a Linux job (build, tests, syntax check of the app
sources) and a macOS 26 job (real compile, tests, packaging, smoke test) on every push.

## License

[Apache License 2.0](LICENSE). Third-party attributions are listed in [NOTICE](NOTICE). SuperNotch is an
independent project and is not affiliated with Apple, Spotify or Anthropic.
