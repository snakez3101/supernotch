# SuperNotch – User requirements (from Q&A, 2026-09-29)

Native macOS notch app (Swift/SwiftUI/AppKit), "like NotchNook but better", clean & small – NOT a big fat notch.

## Platform / delivery
- Target: macOS 26 Tahoe+ only (native Liquid Glass APIs, no legacy fallback needed).
- Only on the built-in MacBook display (the one with the notch). No fake notch on external displays.
- Delivered as a ready-made .app built by GitHub Actions (macOS runner). User has no Apple Developer account -> ad-hoc signed, right-click->Open on first launch.
- UI language: English.

## Look & interaction
- Expanded notch: black at the top (blends seamlessly into the hardware notch) with a soft gradient into real Liquid Glass below (wallpaper shines through).
- Opens on hover with short delay (~0.15 s) + subtle haptic feedback. Collapses when mouse leaves.
- Closed state is user-configurable between:
  (a) "Invisible until event": looks like the plain hardware notch; only events/hover do something.
  (b) "Dynamic Island style": album cover left, small audio visualizer right, Claude traffic-light dots appear only while chats are active.
- Expanded layout: Tab "Home" (music left | Claude chats right) + Tab "Shelf" (file shelf / clipboard) that auto-opens when a file is dragged onto the notch. Settings gear.
- Global hotkey to open the notch; ⌥⌘V opens clipboard history, Enter pastes (needs Accessibility permission).

## Claude Code sessions (headline feature)
- Show Claude Code sessions: BOTH local sessions (Claude desktop app "Code" tab; terminal sessions come for free via hooks) AND cloud sessions (claude.ai/code) if technically possible.
- Traffic light: 🟡 working (subtle pulse) · 🟢 done · 🔴 needs me (question or permission).
- Chat names shortened to 2–4-word AI titles via Claude Haiku using the user's existing subscription (`claude -p --model haiku`), no API key.
- When a chat needs input: notch pops open automatically; for permission requests show Allow / Deny buttons directly in the notch (PermissionRequest hook); for questions a click jumps to the chat.
- Auto-popup on: red (needs me) and green (done). No sound selected. No popup on song change.
- Finished (green) chats stay in the list until the session is closed; if the user continues, it becomes yellow again.
- Extra: show Claude usage / limits (5-hour and weekly).

## Music
- Spotify desktop app only (AppleScript): play/pause, next/prev, seek, cover, title/artist. No Web API login, no Apple Music, no generic now-playing.

## Shelf ("second clipboard")
- Drag & drop files into the notch; drag them back out; persistent across restarts.
- Separate AirDrop drop zone: while dragging, show two targets "Shelf" and "AirDrop"; dropping on AirDrop opens the AirDrop picker immediately. Also AirDrop from shelf items.
- Also text/link/image clipboard history (Cmd+C history), ignore password-manager (concealed/transient) entries.
- Auto-cleanup after configurable time (e.g. 24 h).

## Not wanted (for now)
- Calendar, battery, volume/brightness HUD, timer, webcam mirror, downloads, weather, Apple Music, generic media.

## Round 5–6 answers (final)
- Cloud sessions (claude.ai/code): NOT in v1 (no public API). Local only: Claude desktop app "Code" tab + terminal/VS Code sessions via hooks. Architecture should leave a clean seam (SessionSource protocol) for a future cloud source.
- Repo will be made PUBLIC by the user (unlimited free macOS CI minutes). Until then keep macOS CI runs lean (Linux job first, macOS only if Linux green).
- Signing: stable self-signed certificate (so TCC grants survive updates) stored as GitHub secrets SIGNING_P12_BASE64 / SIGNING_P12_PASSWORD; CI falls back to ad-hoc signing if secrets are absent. Provide Scripts/make_selfsigned_cert.sh (user runs once on Mac) and a one-line install.sh (curl | bash) that installs latest release into /Applications and strips quarantine.
- Permission request buttons: Allow · Always allow · Deny. Dangerous commands (rm -rf, git push --force, sudo, etc.) are highlighted red and need a second confirming click. Keyboard: Return = Allow, Esc = Deny while notch is open & focused (nice-to-have).
- Usage limits: two thin bars (5h / weekly) in Home view under the chat list; a small warning indicator in the closed notch when ≥80 %.
- Fullscreen apps: notch hidden, EXCEPT red (needs-me) events still pop up.
- Hotkeys: ⌥⌘N opens/closes notch; ⌥⌘V opens clipboard history (Enter pastes). Both rebindable in Settings.
- Hook installation: first-run onboarding wizard showing what changes; one click installs into ~/.claude/settings.json with automatic timestamped backup; "Uninstall hooks" in Settings. Respect CLAUDE_CONFIG_DIR.

## Defaults decided by orchestrator (user can change later)
- Titles: prefer Claude Code's own title (custom-title > ai-title > session_title > agents-list name); only if none exists, generate 2–4 word title via `claude -p --model haiku --no-session-persistence` (marked with env var so our own hook ignores that session); cache titles; never write back.
- Hide headless/SDK/subagent sessions (and our own Haiku calls).
- Focus-aware: skip the green "done" popup if the app hosting that session is frontmost; red always pops.
- Green popup auto-collapses after ~4 s (or when mouse leaves after hovering).
- No sound. Red events get a subtle glow/pulse.
- Closed "Dynamic Island" mode uses a fake animated visualizer (no microphone/audio-capture permission).
- Shelf: drag-out copies; items stored as copies in Application Support; auto-cleanup default 7 days (Off/1d/7d/30d). Clipboard history: 200 entries, text/links/images, same cleanup setting, skip concealed/transient types.
- Clamshell / no built-in display: app stays invisible.
- Bundle ID: io.github.snakez3101.supernotch. App name: SuperNotch. Min macOS 26.0. UI English.
- Click on a session: open that session in Claude desktop app (claude:// deep link, undocumented → fallback: activate app); terminal sessions: activate the hosting terminal app (best effort).
