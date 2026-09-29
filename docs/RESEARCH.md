
# SuperNotch: consolidated research report

*Date: 2026-09-29. Lead-architect synthesis of 8 research topics, plus the earlier `raw-claude-desktop-app.md` and the user Q&A in `REQUIREMENTS.md`. Where research and requirements disagree, this report says so. Claims marked (unverified) must be tested on a real Mac.*

The repo is `github.com/snakez3101/supernotch`, licensed **Apache-2.0**. GPL-3.0 code can never be copied in. Only MIT, BSD and Apache code can be reused, with attribution and NOTICE.

## (a) Executive summary

**Feasibility.** Every requested feature has working open-source precedents. Only optional extras would need private APIs.

The "Claude Code in the notch" niche is already crowded: Vibe Island ($19.99, closed source), Claude Pulse (free), Vibe Notch (Apache), Notchi and Open Island (GPL), and Bartender Pro "Top Shelf".

SuperNotch's opening is a **small, clean, low-energy notch** that combines four things:
- a **trustworthy** Claude traffic light (stuck or wrong status is the most common bug in competitors);
- Spotify controls;
- a file shelf with AirDrop, plus clipboard history;
- **correctly done Liquid Glass**.

**The ten key decisions**

1. **Window.**
   - One non-activating `NSPanel`, pinned top-centre on the built-in display.
   - Fixed size, big enough for the largest expanded state.
   - SwiftUI morphs an animatable `NotchShape` inside it.
   - Hit-testing only inside the current shape.
   - The app never calls `NSApp.activate`.
2. **Look.**
   - Collapsed: pure black.
   - Expanded: a black top band (notch height + ~8pt) fading into `.regular` `glassEffect(_:in: NotchShape)`, all inside one `GlassEffectContainer`.
   - Glass in a non-key panel looks foggy, so the panel becomes key while expanded. Test this.
3. **Claude sessions.**
   - A compiled `supernotch-hook` sends NDJSON over a 0600 Unix socket in Application Support.
   - It fails open: if the app isn't running, Claude Code carries on normally.
   - A Core state machine maps events to 🟡 working, 🟢 done, 🔴 needs you.
   - A documented `claude agents --json` reconciler plus PID liveness checks correct drift.
   - A blocking PermissionRequest gives Allow/Deny buttons in the notch.
4. **Names.**
   - Order: `custom-title` → `ai-title` (Claude Code already generates it with a Haiku-class model) → `session_title` → `name` from `claude agents`.
   - Haiku is called only as a fallback: `claude -p --model haiku --no-session-persistence`, with an internal env marker so our own hook ignores it.
   - `--bare` is not possible: bare mode ignores the subscription login, and the docs say it will become the default for `-p`.
5. **Usage limits.** Read the documented statusLine fields `rate_limits.five_hour` and `seven_day` (`used_percentage`, `resets_at`) through a statusLine bridge that wraps the user's existing status line.
6. **Spotify.**
   - Distributed notification `com.spotify.client.PlaybackStateChanged`, then one batched AppleScript on a serial queue.
   - Check that Spotify is running first, because AppleScript launches it otherwise.
   - Since the scope is Spotify only, skip MediaRemote and the perl adapter entirely.
7. **Shelf.**
   - AppKit `NSDraggingDestination`, handling file promises first.
   - Copy files into `~/Library/Application Support/SuperNotch/Shelf/<uuid>/`.
   - AppKit `NSDraggingSource` for drag-out, handing over the real file URL.
   - `NSSharingService(.sendViaAirDrop)`.
   - A global drag detector (drag pasteboard changeCount, file types only) opens the notch.
8. **Clipboard.**
   - Poll the `changeCount` every 0.5s and skip concealed and transient entries.
   - Tag our own pasteboard writes so they aren't captured again.
   - Paste with a CGEvent ⌘V, which needs the PostEvent permission (shown under Accessibility).
   - Plan for the upcoming `accessBehavior` privacy prompt.
9. **Build.**
   - SwiftPM plus `package_app.sh`, no Xcode project.
   - `SuperNotchCore` builds and tests on Linux.
   - The app builds on GitHub `macos-26` with Xcode 26.6, arm64 only, minimum macOS 26.
   - Sign with a **stable self-signed certificate** from secrets. Ad-hoc signing silently loses the TCC permission grants on every update.
10. **Cloud sessions.** There is no public API. The only way would be an http hook committed to each repo plus a relay we host. Leave this out of v1.

**Where the requirements conflict with the research**

| Requirement | Problem | Proposal |
|---|---|---|
| Ad-hoc signing, right-click → Open | Right-click → Open no longer bypasses Gatekeeper on macOS 15, 26 and 27. The ad-hoc cdhash changes every build, so the Accessibility (⌥⌘V) and Automation (Spotify) grants are lost after each update. | Use a self-signed stable certificate. First launch via "Open Anyway" in System Settings, or `install.sh` (a curl download gets no quarantine flag). |
| 0.15s hover to open | Accidental opens are the top complaint about competitors (boring.notch #388, Bartender, NotchNook). | Count hover only over the physical notch rect, add a 300–500ms close grace, make both configurable. |
| Haiku naming via `claude -p` | Uses subscription quota, spawns a full Claude process (hooks fire, and a transcript is written unless `--no-session-persistence` is set), and takes seconds. | Built-in `ai-title` first, Haiku as fallback, cached, at most once per session. |
| Audio visualizer in the island | A real Core Audio tap needs a recording prompt and shows a recording indicator; without the usage string the buffers are silent. | Fake animated bars driven by play state. |
| Cloud sessions "if possible" | Not reliably possible. | Defer. |
| Auto-popup on 🟢 and 🔴 | Noisy with several sessions, and pops over a chat the user is already looking at. | Focus-aware (like Claude Pulse): pulse the dot instead of expanding when that chat's window is frontmost. |

## (b) Landscape

**Open-source projects**

| Project | License | Reuse code? | What to take |
|---|---|---|---|
| DynamicNotchKit | MIT | Yes, with credit | Animatable `NotchShape`; −50 black padding so spring overshoot doesn't show |
| NotchDrop | MIT | Yes | Copy-based shelf; AirDrop tile; 0.001-alpha drop target; retention guard |
| Vibe Notch / Claude Island | Apache-2.0 | Yes, keep NOTICE | Hook event set; blocking PermissionRequest over a socket; version-gated events; phase state machine |
| Notchy | MIT | Yes | Traffic-light semantics; debounce against flicker |
| Maccy | MIT | Yes | Clipboard capture, privacy filters, marker type, CGEvent paste |
| CodexBar, Dimillian/Skills | MIT | Yes | SwiftPM + `package_app.sh` + Linux CI |
| Apple Landmarks sample | Apple Sample Code License | Yes, keep notice | Correct glass API usage |
| mediaremote-adapter | BSD-3 | Yes | Not needed for Spotify-only scope |
| boring.notch | GPL-3.0 | **No** (patterns only) | Fixed panel with shape morph inside; drag detector; share hold-open counter; Spotify notification + AppleScript |
| Atoll | GPL-3.0 | No | Copy-only drag-out (#682); what *not* to do (private glass variants, clipboard stored in `~/Documents`) |
| Notchi | GPL-3.0 | No | hitTest click-through; walking the parent chain to find the Claude PID; filtering out `-p` sessions |
| Open Island | GPL-3.0 | No | Best reference for jumping to the right terminal and for a safe installer (backup, atomic write, manifest) |
| mew-notch, DynamicNotch | GPL-3.0 | No | Its glass toggle shows the non-key fog |
| MioIsland | CC BY-NC 4.0 | No | – |

**Commercial apps**

| App | Price | Strength to beat | Weakness to avoid |
|---|---|---|---|
| NotchNook | $25 lifetime or $3/mo | Tray with AirDrop | Steals focus, idle CPU reports, overlays fullscreen video |
| Alcove | ~$15 | Animation polish | Covers app menus |
| DynamicLake Pro | ~$14 | Breadth, glass mode | Needs Accessibility, quirks after macOS updates |
| Bartender Top Shelf | $15/yr | Clipboard password filter, shelf retention, Claude/Codex tracking | Subscription backlash, hover confusion |
| Vibe Island | $19.99 | Exact tab jump for 20+ terminals, approvals, AskUserQuestion, quota | Closed source, sprawl |
| Claude Pulse | Free | Focus-aware alerts, keyboard approve/deny, `rm -rf` guard | – |

**Complaints to design against**
- Idle CPU (boring.notch #1607 and #1260, Atoll, NotchNook).
- Hover flapping (#388).
- Stuck menu-bar strip in fullscreen on Tahoe (#1359).
- Oversized window hides menu-bar items (#1399).
- A Safari tab drag opens the shelf (#1530).
- Drops from Outlook, Mail and Pinterest fail because there is no file-promise receiver.
- Session stuck on "Processing" when PostToolUse arrives after Stop (Vibe Notch #98).
- An invalid hook key breaks `settings.json` (#85).
- A stale hook path silently drops every event (Open Island #693).

## (c) Per-feature approach

### c1. Window and animation

**Panel setup**
- `NSPanel` with `[.borderless, .nonactivatingPanel]`, `isOpaque=false`, `.clear` background, `hasShadow=false`.
- `level = .mainMenu+3`.
- `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`.
- `becomesKeyOnlyIfNeeded`, `canBecomeKey` returns `isExpanded`, appearance `.darkAqua`.
- Content is an `NSHostingView` subclass with `acceptsFirstMouse` true and a `hitTest` that returns nil outside the current shape path.

**Geometry**
- Built-in display: `CGDisplayIsBuiltin(NSScreenNumber)`.
- Has a notch: `safeAreaInsets.top > 0`.
- Notch width: `frame.width − auxiliaryTopLeftArea.width − auxiliaryTopRightArea.width`.
- Notch height: `safeAreaInsets.top`.
- In the macOS 27 below-notch display mode the inset is 0 and the auxiliary areas are nil. Hide, or show a pill (question 20).

**Window size and rebuilds**
- Fixed at about 640×260, centred at the top. Never full width.
- Rebuild on `didChangeScreenParametersNotification` (only if the UUID or frame changed), on `NSWorkspace.didWakeNotification` (#336), and on clamshell changes.

**Hover and closing**
- `NSTrackingArea` over the physical notch rect.
- Open after 150ms of dwell; close with a 300–500ms grace period.
- Haptic: `NSHapticFeedbackManager` `.alignment`.
- A global mouse-down monitor, only while expanded, closes on outside clicks.
- A hold-open counter keeps it open while typing, during a share, drag or QuickLook, while pinned, or while a permission request is pending.

**Animation**
- Open: `.spring(response: 0.42, dampingFraction: 0.8)`. Close: `response: 0.45`, `dampingFraction: 1`.
- Corner radii: closed 6/14, open 19/24.
- Stages: closed (invisible or island) → peek (auto-popup) → expanded (Home and Shelf tabs).

**Fullscreen and hotkeys**
- Fullscreen: keep `.fullScreenAuxiliary`, hide using a heuristic (menu-bar visibility or `visibleFrame`) on `activeSpaceDidChange`. No private CGS calls. (unverified)
- Hotkeys: the `KeyboardShortcuts` package (MIT) uses registered hotkeys and needs no Accessibility permission.

### c2. Liquid Glass

**What "Apple open-sourced" actually is:** not the renderer. It is:
- the **Landmarks: Building an app with Liquid Glass** sample (permissive Apple Sample Code License);
- the article "Applying Liquid Glass to custom views";
- WWDC25 sessions 219, 310, 323 and 356, and the HIG Materials page;
- the free Design Resources (UI kits, Icon Composer), which are free to use but not open source.

**Public APIs**
- SwiftUI: `glassEffect(_:in:)`; `Glass.regular`, `.clear` and `.identity`, with `.tint` and `.interactive`; `GlassEffectContainer(spacing:)`; `glassEffectID`, `glassEffectUnion`, `glassEffectTransition`; `.buttonStyle(.glass)` and `.glassProminent`.
- AppKit: `NSGlassEffectView` (`contentView`, `cornerRadius`, `tintColor`, `style`) and `NSGlassEffectContainerView`.

**Our design**
- Collapsed: black fill, no glass.
- Expanded: black→clear `LinearGradient` at the top (solid to 30%, clear by 65%), then `.glassEffect(.regular, in: NotchShape(6,24))`.
- Switch between the two with `.identity`, never by adding or removing the modifier.
- Force dark mode.
- Glass buttons (play, AirDrop) sit in the same container and morph via `glassEffectID`. The Claude list rows get no glass of their own.

**Gotchas**
- Glass in a non-key panel looks foggy (make the panel key while expanded).
- macOS 26.2 cached the backdrop of borderless windows (forum 810314).
- macOS 27 renders `.tint(.black)` as solid.
- Making the whole notch `.interactive()` breaks clicks.
- Respect Reduce Transparency and the macOS 27 system glass slider; don't build our own transparency slider.
- Avoid the private `set_variant:` / `CABackdropLayer` tricks Atoll uses.
- Minimum macOS 26, so no fallback is needed. Still offer a "Solid black" style.

### c3. Claude Code monitoring

**c3.1 Data sources, in order of trust**

1. **Hooks.** Confirmed in `scratchpad/docs/hooks.md`.
   - Events we use: SessionStart/End, UserPromptSubmit, Stop, StopFailure, Pre/PostToolUse(Failure), PermissionRequest, PermissionDenied, Notification, SubagentStart/Stop, Pre/PostCompact.
   - Common fields: `session_id`, `transcript_path`, `cwd`, `permission_mode`, `hook_event_name`, and `agent_id` when inside a subagent.
   - `notification_type` values that mean "needs you": `permission_prompt`, `elicitation_dialog`, `agent_needs_input`. `idle_prompt` means done.
   - Hooks fire in the terminal, the IDE, and Desktop local sessions.
2. **`claude agents --json [--all]`.** The documented "supported way to read session state from outside".
   - Fields: `cwd`, `kind`, `startedAt`, `pid`, `status` (busy/waiting/idle), `waitingFor`, `state` (working/blocked/done/failed/stopped, background sessions only), `sessionId`, `name`.
   - Run it at launch, on wake, and every 15–30s but only while sessions exist.
   - (unverified) Whether it includes Desktop sessions.
3. **Transcript tail.** Read the last ~64KB on each hook and on vnode change events.
   - `custom-title`, `ai-title` and legacy `summary` entries, last one wins.
   - The `[Request interrupted by user` marker, because Stop is not reliable on Esc.
   - The format is undocumented.
4. **Liveness.** `kill(pid, 0)` plus the process start time from `proc_pidinfo`, to guard against PID reuse. `~/.claude/sessions/<pid>.json` is an undocumented fallback.

**c3.2 Hook binary**
- Swift, starts in about 5ms. Not Python: `/usr/bin/python3` is only a stub that opens an install dialog if the Command Line Tools are missing.
- Lives in `~/Library/Application Support/SuperNotch/bin/`. It is re-verified and repaired on every launch (prevents #693).
- It enriches the stdin payload with:
  - the Claude PID (walk parents up to 8 hops until argv0 is `claude`) and the tty;
  - `TERM_PROGRAM`, `ITERM_SESSION_ID`, `TERM_SESSION_ID`, `TMUX`/`TMUX_PANE`, `KITTY_WINDOW_ID`, `WEZTERM_PANE`;
  - `CLAUDE_CODE_ENTRYPOINT` (`claude-desktop` = Desktop), `CLAUDE_CODE_HOST_SESSION_ID` (`local_<uuid>`), `__CFBundleIdentifier`;
  - an `isPrint` flag (the session was started with `-p`) and the `SUPERNOTCH_INTERNAL` marker.
- It sends NDJSON `{v,seq,event,env,payload}` to `hook.sock` (mode 0600). If the path exceeds 104 bytes it uses `/tmp/supernotch-$UID.sock`.
- Connect timeout is about 100ms. On failure it exits 0 with empty output.
- Only PermissionRequest blocks (hook `timeout` 86400, binary gives up at about 290s).
- It is a command hook rather than an http hook because only a process in Claude's process tree can see the PID, tty and environment.

**c3.3 Installer** (writes `~/.claude/settings.json`, respects `CLAUDE_CONFIG_DIR`)
- Strict parse; refuse to touch invalid JSON.
- Timestamped backup.
- Re-read just before writing, then an atomic write that preserves key order.
- Our entries are identified by the binary path. Install and uninstall are idempotent.
- Events are version-gated via `claude --version`.
- The merge is a pure Core function with tests.
- A plugin (`hooks/hooks.json`) was considered as the primary path and rejected: community reports say plugin hooks are dropped by some hosts.

**c3.4 State machine** (pure, table-tested)

| Trigger | State |
|---|---|
| Pending PermissionRequest; PreToolUse(AskUserQuestion); Notification `permission_prompt`, `elicitation_dialog` or `agent_needs_input`; agents `state=blocked` | 🔴 needs you (permission or question) |
| UserPromptSubmit, Pre/PostToolUse(Failure), SubagentStart, Pre/PostCompact | 🟡 working |
| Stop; `idle_prompt`; agents `state=done`; interrupt marker in transcript | 🟢 done |
| StopFailure | 🟢 with a ⚠ badge |
| SessionEnd; dead PID; agents `failed`/`stopped` | Removed |
| Fresh SessionStart | Grey until the first prompt |

Rules:
- A PostToolUse after Stop does not turn the session yellow again without a new UserPromptSubmit (fixes #98).
- Debounce state flicker for about 800ms.
- A pending permission resolves when a PostToolUse or PermissionDenied arrives with the same `tool_use_id`; then close the held socket.
- Subagent events are only a counter on the parent row.
- A watchdog marks sessions "stale".
- The collapsed state shows one aggregated dot: red beats yellow beats green.

**c3.5 Names** (2–4 words)
- Order: `custom-title` → last `ai-title` → `session_title` → agents `name` → first prompt summarised once by Haiku.
- Titles longer than 4 words are compressed once by Haiku. Everything is cached per session.
- The Haiku call runs with an empty temp directory as cwd and `SUPERNOTCH_INTERNAL=1`, with about a 20s timeout, falling back to `repo · branch`:
  ```
  claude -p --model haiku --no-session-persistence --max-turns 1 --tools "" …
  ```
  Verify these flags with `claude --help`.
- Optional write-back via `sessionTitle` from UserPromptSubmit, off by default.

**c3.6 Approvals**
- Allow: `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`.
- Deny: `{"behavior":"deny","message":…}`. Exit code 2 is not honoured for this event.
- Show the tool name and a one-line summary of the input. Destructive commands (`rm -rf`, force-push, `sudo`) need a second confirmation.
- Optional "always allow" via `updatedPermissions` from `permission_suggestions`.
- AskUserQuestion: clicking jumps to the chat. Inline answers via `updatedInput.answers` would be v2.
- Desktop: per the docs, a PermissionRequest hook that answers first prevents the `permission_prompt`. Test the race between our hook and the Desktop card.

**c3.7 Jump to the chat**

| Host | Technique |
|---|---|
| Terminal.app | AppleScript: match `tty of tab` |
| iTerm2 | AppleScript: match the UUID from `ITERM_SESSION_ID`, or the tty, then `select` |
| Ghostty | AppleScript terminal id, captured at SessionStart or UserPromptSubmit |
| tmux | `list-panes -a` → pane whose pid is an ancestor → `select-window`/`select-pane`/`switch-client`, then activate the host terminal |
| kitty / WezTerm | `kitten @ focus-window` / `wezterm cli activate-pane` |
| VS Code / Cursor | `code -r <cwd>` (window only) |
| Claude Desktop | Undocumented `claude://code/continue?session=local_<uuid>` or `claude://claude.ai/epitaxy/local_<uuid>`; otherwise activate `com.anthropic.claudefordesktop` |
| Fallback | Walk parents with `proc_pidinfo` until a GUI app is found, then `.activate()` |

Automation permission is requested per host, lazily.

**c3.8 Usage limits**
- A statusLine bridge forwards `rate_limits` to the socket, then execs the user's original status line and passes its output through.
- The original command is kept in a manifest, with a guard against wrapping ourselves (Open Island #671).
- The data is only present for Pro and Max plans, and only after the first API response.
- No Keychain token scraping.

**c3.9 Desktop Code tab**
- Covered by hooks, because Desktop uses the same `settings.json`.
- A pre-warm process sends a SessionStart for a throwaway session, so create a row lazily on the first prompt or tool event.
- Show a Desktop badge. Liveness follows Claude.app.
- Titles as fallback: `~/Library/Application Support/Claude/claude-code-sessions/…/local_*.json` (read-only, undocumented).

**c3.10 Cloud sessions.** No public list or status API. A repo-committed http hook plus a hosted relay and SSE would be push-only, with no approvals. Out of scope for v1.

### c4. Spotify
- On `PlaybackStateChanged`, run one compiled `NSAppleScript` on a serial queue.
  - Player: `player state`, `player position` (seconds), `shuffling`, `repeating`, `sound volume`.
  - Track: `name`, `artist`, `album`, `duration` (ms), `artwork url`, `id`.
  - Log the notification's `userInfo` once; it may contain enough to skip the script.
- Check it is running via `NSRunningApplication(bundleIdentifier: "com.spotify.client")` before any script.
- Commands: `playpause`, `next track`, `previous track`, `set player position`. Update the UI optimistically, then re-query after about 50ms.
- Position: extrapolate from `(elapsed, timestamp, playing)`. Use `TimelineView(minimumInterval: 0.5)` only while expanded.
- Artwork:
  - Fetch the 640px `artwork url` and cache it by URL.
  - Fallback: `open.spotify.com/oembed?url=spotify:track:<id>`, which gives a 300px thumbnail.
  - Handle ad, episode and local IDs.
  - Accent colour: downsample to 32×32 and clamp.
- Permissions:
  - `NSAppleEventsUsageDescription` in Info.plist.
  - Onboarding calls `AEDeterminePermissionToAutomateTarget(askUserIfNeeded: true)`. It returns -600 when Spotify isn't running, so ask the user to open Spotify first.
  - Add the `com.apple.security.automation.apple-events` entitlement for the future.
- Island visualizer: 3–4 fake bars, capped at 24–30fps, stopped when paused or collapsed. Optional swipe to change track.

### c5. Shelf, AirDrop and clipboard

**Drag detection**
- On global mouse-down, record the drag pasteboard's `changeCount`.
- On global mouse-dragged, trigger only if all three hold: the count changed, the types include a fileURL or file promise (not plain URL/string, which avoids #1530), and the cursor is in the notch zone.
- Then show drop mode with two targets: **Shelf** and **AirDrop**.
- (unverified) Whether global mouse monitors need Accessibility on macOS 26.

**Drop target**
- AppKit `NSView`, `registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes + [.URL, .string, .png, .tiff])`.
- Read with `readObjects([NSFilePromiseReceiver, NSURL], .urlReadingFileURLsOnly)`.
- Fulfil promises with `receivePromisedFiles` on a background queue while showing a spinner.
- Use `draggingExited`/`draggingEnded` to close.

**Storage**
- Copy into `Application Support/SuperNotch/Shelf/<uuid>/`. APFS should make this a near-free clone (unverified).
- Index: atomic `items.json` of `ShelfItem{id, kind: file|text|link|image, storage: copy|reference, name, size, addedAt, pinned, expiresAt}`.
- Retention default 24h, with a >0 guard. Pinned items never expire.
- Missing files are greyed out. Optional bookmark reference for huge files.

**Drag-out**
- `NSDraggingSource` with `NSDraggingItem(url as NSURL)`, multi-select, `.copy` by default (see Atoll #682).
- `NSFilePromiseProvider` for virtual items.
- Not SwiftUI `.draggable`, which hands over a temp copy (forum 837005).
- `endedAt` releases the hold-open.

**Thumbnails and Quick Look**
- `QLThumbnailGenerator` in an actor with a cache.
- For QuickLook the panel becomes key temporarily and implements the `QLPreviewPanel` controller methods.

**AirDrop**
- `NSSharingService(named: .sendViaAirDrop)`: `canPerform`, then `perform`.
- The delegate supplies the source frame and window.
- A hold-open counter with a 2s fallback, because `didShare` and `didFail` are unreliable.
- Text goes out as a temporary `.txt`.
- Fallback: picker or Reveal in Finder. Never call activate.

**Clipboard history (⌥⌘V)**
- Capture:
  - Poll `changeCount` every 0.5s and read items only when it changes.
  - Skip `org.nspasteboard` Concealed, Transient and AutoGenerated types and our own `dev.supernotch.own` marker.
  - Per-app ignore list, pre-filled with password managers.
  - Types: string, RTF, HTML, PNG/TIFF (stored as files), fileURL.
  - Deduplicate by hash. Cap at 200 items and a total size.
  - Source app: `org.nspasteboard.source`, otherwise the frontmost app.
- Paste:
  - `writeObjects` plus our marker, then a `CGEvent` ⌘V with a layout-aware keycode.
  - Needs PostEvent permission (`CGPreflightPostEventAccess` / `CGRequestPostEventAccess`).
  - The non-activating panel keeps the target app focused, so the paste lands there.
  - Fallback: "Copied, press ⌘V".
- Privacy: check `NSPasteboard.accessBehavior`; if `.alwaysDeny`, offer manual capture, with onboarding text.
- Edge over Spotlight's built-in clipboard history: pins, thumbnails, drag-out, per-app rules, paste as plain text, optional Touch ID.

### c6. Extras and quality bar
- **Launch at login:** `SMAppService.mainApp.register()`, handling `.requiresApproval`. Must run from `/Applications`. Fallback: a LaunchAgent. Test this with the self-signed build.
- **Settings window:** a titled `NSWindow`, switching the activation policy to `.regular` while open. It hosts onboarding and a permission status list (Spotify Automation, PostEvent, paste privacy, hooks installed).
- **Energy:**
  - No always-on timers except the clipboard poll.
  - Animations stop when collapsed, and views are created lazily.
  - The agents reconcile only runs while sessions exist.
  - Target under 0.5% CPU at idle, checked against the Energy tab on every release.
- **Privacy:** no analytics; everything stays local.
- **Non-goals:** calendar, battery, HUD, timer, webcam, downloads, weather, Apple Music, generic now-playing.

## (d) Architecture

SwiftPM package, tools version 6.2, `platforms: .macOS("26.0")`, with the UI targets wrapped in `#if os(macOS)`.

**`SuperNotchCore`**: Foundation only, `Sendable`, builds and tests on Linux.
- `Claude/`: HookEnvelope, HookEvent, SessionStateMachine, SessionStore reducer, TitleResolver, TranscriptTailParser, AgentsListDecoder, UsageLimits, SettingsJSONMerger, DangerousCommandClassifier.
- `IPC/`: NDJSON framing, PermissionDecision encoder.
- `Media/`: PlaybackSnapshot, PositionExtrapolator, SpotifyScriptOutputParser.
- `Shelf/`: ShelfItem, ShelfIndex, ExpiryPolicy.
- `Clipboard/`: ClipboardEntry, CaptureFilter, HistoryPolicy.
- `Geometry/`: NotchGeometry, HoverIntent.
- `Settings/`: AppSettings.

**`supernotch-hook`**: executable using Foundation plus Darwin/Glibc. Reads stdin, enriches it, writes to the socket, fails open. It also compiles on Linux, so tests can run there.

**`SuperNotch`**: the macOS app, with `.defaultIsolation(MainActor.self)`.
- `App/`: AppDelegate, onboarding, Settings.
- `Notch/`: NotchPanel, HitTestHostingView, NotchShape, root views, Home and Shelf tabs.
- `Claude/`: HookSocketServer, HookInstaller IO, AgentsPoller, TranscriptWatcher, TitleGenerator, TerminalFocuser, StatusLineBridge.
- `Media/`: SpotifyController, ArtworkCache.
- `Shelf/`: DragDetector, DropTargetView, DragSourceView, ShelfStore, ThumbnailActor, AirDropService.
- `Clipboard/`: ClipboardMonitor, PasteService.
- `System/`: ScreenObserver, Hotkeys, LoginItem, Permissions.

**Supporting folders**
- `Tests/SuperNotchCoreTests`: swift-testing, with fixtures built from real hook payloads in the docs.
- `Resources/`: Info.plist, entitlements, icon.
- `Scripts/`: `package_app.sh`, `install.sh`, `make_selfsigned_cert.sh`.

**Dependencies and concurrency**
- Dependencies: `KeyboardShortcuts` (MIT) only. Sparkle is deferred.
- The socket server runs on its own queue and hops to MainActor. The UI uses `@Observable` models.

**What is tested where**
- On Linux: state machine sequences (including #98), the settings merge (idempotent, refuses invalid JSON, keeps key order, uninstall), titles, transcript tail, agents decoding, NDJSON, decision JSON, retention, clipboard filters, geometry, the Spotify parser, and hook fail-open.
- Not on Linux: all UI code. It only gets `swiftc -parse` there; the macOS runner does the real type-check.

## (e) Build, CI, distribution

**Toolchain**
- Swift 6.3.3 for Linux is unpacked at `scratchpad/swiftlinux/…/usr/bin`, and Core was verified with it.
- CI uses `macos-26` with Xcode 26.6 pinned via `xcode-select`. Avoid `macos-15`, which can't launch a macOS-26-minimum binary, and the `xcode-27` beta runners.

**`ci.yml`**
1. Linux job (container `swift:6.3-noble`): `swift build && swift test`, `swiftc -parse` over the UI sources, `swift format lint --strict`.
2. macOS job, which depends on the Linux job:
   - `swift build -c release --arch arm64 | tee build.log`, then `swift test`;
   - `package_app.sh`, then `--smoke-test`;
   - `upload-artifact@v7` of the ditto zip with `archive: false`, so executable bits and symlinks survive.
3. SwiftLint 0.65.1 is optional.

Starter files live in `scratchpad/example-kit/`.

**`package_app.sh`**
- Assemble the `.app` and put `supernotch-hook` in `Contents/Helpers`.
- Set the version with PlistBuddy; build the icon with sips and iconutil.
- Run `xattr -cr`, then sign inside-out with `SIGN_IDENTITY` (defaults to `-`), then `codesign --verify --strict --deep`.
- Check that the designated requirement shows `certificate leaf`.
- Package with `ditto` (zip) and `hdiutil` UDZO (DMG). Not `create-dmg`.

**Info.plist**
- `LSUIElement`, `LSMinimumSystemVersion 26.0`, `CFBundleIdentifier dev.supernotch.app` (to confirm), `NSAppleEventsUsageDescription`.
- No sandbox.

**Signing without an Apple Developer account**
- Create a self-signed certificate once with openssl (`-legacy` PKCS12). Store it as the secrets `SIGNING_P12_BASE64` and `SIGNING_P12_PASSWORD`.
- CI imports it into a temporary keychain: create, settings, unlock, import `-T codesign`, set-key-partition-list, list-keychains.
- No hardened runtime.
- (unverified) Whether headless signing and the import both work. The first CI run proves it. Fallback: ad-hoc signing plus `tccutil reset` after updates.

**Release, install and updates**
- Release: tag `v*` → build and sign → `gh release create --generate-notes` with the zip and DMG.
- Install, either way:
  - `curl … install.sh | bash`, which downloads the latest zip, ditto's it into `/Applications` and runs `xattr -dr`;
  - or the DMG, then "Open Anyway" in System Settings. Right-click → Open no longer works.
- Updates: in-app "Check GitHub Releases". Sparkle waits until it is verified with self-signed builds.

**Feedback loop and permissions**
- Feedback: push, the Linux job answers in 1–2 minutes, then the macOS compile errors arrive via the GitHub MCP `get_job_logs`.
- Onboarding permissions: Automation for Spotify and for each terminal, PostEvent for paste, and paste privacy. No screen recording or microphone.

## (f) Risks

| Risk | Likelihood / impact | Mitigation |
|---|---|---|
| No local macOS compile, run or visual test | High / High | Logic in Core; CI smoke test; the user tests early builds and sends screenshots or video; small PRs |
| Glass fog in non-key windows, 26.2 backdrop cache, macOS 27 tint | Medium / Medium | Key panel while expanded; gradient band; no black tint; Solid-black option |
| Self-signed headless signing or PKCS12 import fails | Medium / Medium | Test in the first CI run; ad-hoc fallback |
| Hook schema churn; unknown keys invalidate settings; undocumented transcript title records | Medium / High | Version-gated installer; tolerant decoding; agents reconciler; health check |
| Stuck or wrong traffic light | High / High | c3.4 rules, interrupt marker, watchdog, reconcile, a fixture test per known bug |
| Permission race with the terminal or Desktop prompt | Medium / Medium | `tool_use_id` resolution; 290s give-up |
| Haiku naming uses quota; `-p` may later default to `--bare` | Medium / Low | Built-in titles first; cache; explicit flags; re-test on Claude Code updates |
| Spotify AppleScript breaks or the grant is missing | Low-Medium / Medium | Graceful error state; notification payload as backup; onboarding check |
| Pasteboard privacy enforcement | Medium / Medium | Detect it; manual capture |
| Global mouse monitors need Accessibility on 26/27 | Low / Medium | Test on clean TCC; fallback to a 0.001-alpha drop strip |
| Imperfect fullscreen heuristic | Medium / Low | Per-app override |
| Below-notch mode or clamshell | Low / Low | Hide cleanly |
| Energy regressions | Medium / High | Budget rules; release checklist |
| Terminal-jump coverage | – | Ask which terminals; app-activation fallback |
| GPL contamination (repo is Apache) | Low / High | Clean-room rule; NOTICE file; credit sources |

## (g) Product questions still open (not answered in REQUIREMENTS.md)

1. Free self-signed certificate (permissions survive updates) instead of ad-hoc? One-time "Open Anyway", or a one-line `install.sh`?
2. Which terminal(s) do you run Claude Code in: Terminal, iTerm2, Ghostty, Warp, VS Code/Cursor, tmux? Or mostly the Desktop Code tab?
3. Which MacBook model (14″/16″ Pro or Air), and which macOS version (26.x or 27)?
4. Permission buttons: only Allow once / Deny, or also "Always allow"? Should destructive commands need a second click?
5. Focus-aware: should the notch not pop open if you are already looking at that chat's window?
6. How long should the 🟢 done popup stay open, and should it close as soon as you move the mouse?
7. Hide headless, SDK and subagent sessions completely, or show them in a collapsed group?
8. OK to drop cloud sessions from v1?
9. Prefer Claude's own auto-title and use Haiku only as a fallback? Also write the short name back into Claude Code?
10. How to show usage limits (always, or only above 80%)? Do you already have a custom status line?
11. Fake visualizer instead of a real audio tap (which needs a recording permission and shows an indicator)?
12. When neither music nor Claude is active, should the island automatically go back to the invisible hardware look?
13. Shelf: should dragging out move or copy? AirDrop only, or other share targets too? A size or item limit?
14. Clipboard: how many items and how many days? Images? Paste as plain text (⇧⏎)? Touch ID lock?
15. In fullscreen: hide completely, or still allow the red popup?
16. Which hotkey opens the notch? Enter/Esc/number keys to approve or deny while it is open?
17. You chose no sound: should red still give a haptic or visual flash?
18. Install the hooks automatically in a first-run wizard (with a backup), or behind an explicit button?
19. Is the repo public (free macOS CI minutes)? Is the bundle ID `dev.supernotch.app` OK?
20. In clamshell or below-notch mode: fully invisible, or a small floating pill?