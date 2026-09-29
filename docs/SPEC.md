# SuperNotch: binding specification (v1)

Status: **binding contract** for the implementation streams. Written by the foundation (lead architect).
Inputs: `docs/REQUIREMENTS.md` (wins on conflicts) and `docs/RESEARCH.md` (baseline architecture).

Rules for everyone:

* Every file has exactly **one owner** (§C). Only edit the files you own. If you need something from a file
  you do not own, use the frozen API in §D. If that API is missing something, add it in your **own**
  files: an `extension` in a file you own, or a new file in your directory. Never edit someone else's file
  and never edit a FOUNDATION file.
* Anything marked **FROZEN** in §D is a promise to the other streams. You may add members. Do not rename,
  remove or change the signature of a frozen member.
* The app target has no local compiler (Linux has no AppKit/SwiftUI). Follow the checklist in §F.4 so the
  first macOS CI run compiles.
* Do not commit or push. The orchestrator merges the streams.

---

## A. Product and UX

### A.1 What it is

SuperNotch is a small, clean notch app for macOS 26 Tahoe and later. It runs only on the built-in MacBook
display that has a notch. It does four things:

1. **Claude Code traffic light.** Shows local Claude Code sessions (terminal, IDE, and the Claude desktop
   app's Code tab) as 🟡 working, 🟢 done or 🔴 needs you. Permission prompts can be answered inside the
   notch. Also shows usage limits (5-hour and weekly).
2. **Spotify.** Cover, title and artist, play/pause, previous/next, and seek.
3. **Shelf.** Drag files into the notch and back out. Includes an AirDrop drop zone.
4. **Clipboard history.** ⌥⌘V opens it and Return pastes the selected entry.

Out of scope for v1: cloud sessions (a `SessionSource` seam is left for later), calendar, battery, HUDs,
timer, webcam, downloads, weather, Apple Music, generic now-playing, and sounds. UI language: English.

### A.2 Presentations (states)

`NotchPresentation` (Core, FROZEN): `.closed`, `.peek(PopupRequest)`, `.expanded(NotchTab)`.

| Presentation | When | Size (points; N = physical notch size) |
|---|---|---|
| closed, **invisible** mode | default idle | exactly N (black). If usage ≥ threshold, adds a 14 pt right wing with a 5 pt orange dot |
| closed, **island** mode | idle, and a Spotify track is **playing** or a Claude session is 🟡/🔴 (§D.10) | width N.w + 2 × 36 (left wing: 22 pt artwork, corner radius 5; right wing: fake visualizer of 4 bars, 14 pt tall, and/or Claude dots of 6 pt with 3 pt spacing, up to 4, plus a usage-warning dot). With nothing to show, it looks like invisible mode |
| peek (auto popup) | Claude session done or needs input | 420 × (N.h + 64) |
| peek (permission) | pending PermissionRequest | 480 × (N.h + 128) |
| expanded | hover, click, hotkey, file drag | **540 × (N.h + 156)**. This is intentionally compact; do not grow it. Streams design to these numbers |

All sizes live in `NotchMetrics` (Core, FOUNDATION). The NSPanel has a fixed size of
`NotchMetrics.panelSize` = 580 × 340. It is centred on the notch, and SwiftUI morphs a `NotchShape` inside it.

Corner radii (`NotchShape(topCornerRadius:bottomCornerRadius:)`): closed 6/12, peek 10/20, expanded 12/24.

Animations:
* Open: `.spring(response: 0.42, dampingFraction: 0.80)`.
* Close: `.spring(response: 0.45, dampingFraction: 1.0)`.
* Content fades in with a 0.06 s delay.

### A.3 Look

* **Closed:** pure black `NotchShape`, with no glass, so it blends into the hardware notch.
* **Peek and expanded:**
  * The background is `.glassEffect(.regular, in: NotchShape(...))`.
  * The content's own `.background` is a black `LinearGradient`: solid black from 0 down to the notch
    height, and clear at about 65 % of the height. Result: black at the top that merges into the hardware
    notch, fading softly into real Liquid Glass below, with the wallpaper shining through.
  * The whole panel uses `.environment(\.colorScheme, .dark)`.
* **Switching glass on and off:** use `Glass.identity`, never by adding or removing the modifier:
  `.glassEffect(isGlass ? .regular : .identity, in: shape)`.
* **Solid black:** a style option (`NotchStyle.solidBlack`) for Reduce Transparency, or for users who
  prefer it. Also respect `accessibilityReduceTransparency`.
* **Glass buttons:** play/pause and the AirDrop tile may use `.buttonStyle(.glass)`. Do not make the whole
  notch `.interactive()`; it breaks clicks. Session rows get no glass of their own.
* **Container:** one `GlassEffectContainer` wraps the expanded content, so glass buttons blend.

### A.4 Hover, open and close

* The hover intent is counted **only over the physical notch rectangle**, plus 6 pt of horizontal slack.
* Open after `hoverOpenDelay` (default **0.15 s**) of dwell. On open, fire a haptic:
  `NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)`. Haptics can be
  turned off.
* Close when the mouse has been outside the current shape's rect (+ 8 pt) for `hoverCloseDelay` (default
  **0.35 s**).
* A click outside the notch closes it immediately.
* Hold-open counter (`NotchViewModel.holdOpen(reason:)`): the notch stays open while any token is held.
  Tokens are held for: a drag inside, an AirDrop share, text entry, a pending permission card the user is
  looking at, and QuickLook.
* **Hotkeys:**
  * ⌥⌘N toggles the notch (expanded, on the last tab).
  * ⌥⌘V toggles the clipboard history panel.
  * Both can be rebound in Settings (Carbon `RegisterEventHotKey`, no Accessibility needed).
* **Keyboard focus:** the panel becomes key **only** when the user explicitly interacts. That means a
  click inside it, opening via hotkey, or the clipboard panel. Hover-open and auto-popups never make it key,
  so they never steal typing focus.
* **Return and Esc on the permission card** (Allow and Deny) only work while the panel is key. This is a
  safety rule: someone typing in the terminal must never approve by accident.

### A.5 Expanded layout

```
 ┌─────────────[ hardware notch ]──────────────┐   ← top band, height N.h, pure black
 │ ⌂ Home  ▢ Shelf        (notch)        ⚙︎      │   tab icons left of the notch, gear right
 ├──────────────────┬──────────────────────────┤
 │ [cover 56]       │ ● Fix login bug      2m   │   Claude rows 26 pt, max 4 visible, scroll
 │ Title            │ ● Refactor parser    now  │
 │ Artist           │ ● Write README       ✓    │
 │ ━━━━━●──── 1:02  │                           │
 │  ⏮   ⏯   ⏭       │ 5h  ━━━━━━━──── 62 %      │   usage bars, 3 pt tall
 │                  │ 7d  ━━━─────── 31 %       │
 └──────────────────┴──────────────────────────┘
      music 200 pt  |   Claude ≈ 280 pt
```

* **Home tab:** `MediaHomeSection` on the left and `ClaudeHomeSection` on the right. The foundation owns
  the composition in `HomeTabView`.
* **When a column has nothing to show:** if Spotify is not running, the music column shows a small "Open
  Spotify" button. If there are no sessions, the Claude column shows "No Claude sessions". The layout never
  changes size.
* **Shelf tab:** `ShelfTabView` (shelf-clipboard) shows shelf items in a horizontal scroller (64 pt tiles),
  with the last 5 clipboard entries underneath.
* **Drag into the notch:** while a file drag is near the notch, the expanded notch switches to the Shelf
  tab and shows two drop zones side by side: "Shelf" and "AirDrop" (`DropZonesView`). Dropping on AirDrop
  opens the AirDrop picker straight away. **Owner: shelf-clipboard.** Its drag detector (global
  `leftMouseDragged` monitor + `NSPasteboard(name: .drag)`) sets `ShelfModel.isDragActive`, calls
  `notch.open(tab: .shelf)` and holds a `NotchHoldToken` while the drag is near the notch. notch-shell only
  guarantees that the panel accepts the drop (mouse events enabled) over the expanded shape while
  `isDragActive` is true.
* **Gear:** opens the Settings window.

### A.6 Auto-popups (peeks)

Claude-app asks for them and notch-shell decides and presents them, using the pure `PopupPolicy` in Core.

| Event | Popup | Rules |
|---|---|---|
| 🔴 needs input (permission) | permission card (peek, `.critical`) | Always shown, **even in fullscreen**. Subtle red glow or pulse. Stays until answered, withdrawn or 290 s. Several pending → queue, oldest first, with "1 of 3" |
| 🔴 needs input (question/elicitation) | session peek (`.critical`) | Always shown, even in fullscreen. Clicking jumps to the chat. Stays until the session changes state or the user hovers and leaves |
| 🟢 done | session peek (`.info`) with the start of the last assistant message | Only if the host app is **not** frontmost and not in fullscreen. Auto-collapses after `doneAutoCollapse` (4 s), or when the mouse leaves after hovering |
| Song change | none | – |

Other rules:
* A peek never interrupts an expanded notch. While expanded, requests are queued and the Claude rows pulse.
* Duplicate requests with the same `id` replace each other.
* Debounce: a 🟢 that turns back into 🟡 within 0.8 s never pops up.

### A.7 Permission card

* **Layout:** tool name and one-line summary (monospaced for Bash), an optional detail line, then the
  session title and project name.
* **Buttons:** **Allow · Always allow · Deny**.
  * Always allow is shown only when `request.canAlwaysAllow`.
  * Always allow sends `request.alwaysAllowDecision`.
* **Dangerous commands** (`request.danger.isDangerous`):
  * The card gets a red tint and shows the reason chips.
  * The first click on Allow or Always allow turns the button into "Confirm allow". A second click within
    4 s confirms.
  * Return also needs the confirm step.
* **Keyboard:** Return = Allow and Esc = Deny, only while the panel is key (§A.4).
* **Answered elsewhere:** if the request is answered in the terminal or times out, the card disappears
  (`permissionConnectionClosed`).

### A.8 Fullscreen

* When the frontmost app is fullscreen on the notch screen, the notch is hidden (`orderOut`, or alpha 0).
* Only `.critical` popups (🔴) are shown.
* Detection is a heuristic owned by notch-shell. It re-checks on `NSWorkspace.activeSpaceDidChangeNotification`
  and `didActivateApplicationNotification`. It uses `CGWindowListCopyWindowInfo(.optionOnScreenOnly)`: the
  frontmost app's layer-0 window bounds equal the screen frame. Bounds need no Screen Recording permission.
  No private CGS APIs.

### A.9 Displays

* The notch is shown only on the built-in display (`CGDisplayIsBuiltin`) with `safeAreaInsets.top > 0`.
* In clamshell mode, with no built-in display, or in macOS 27 "below notch" mode: the app is invisible
  (the panel is ordered out). Everything else (hooks, clipboard) keeps running.
* Rebuild on `NSApplication.didChangeScreenParametersNotification` and `NSWorkspace.didWakeNotification`.

### A.10 Settings window (titled `NSWindow`; activation policy `.regular` while open)

Sidebar sections:

| Section | Owner | Contents |
|---|---|---|
| General | notch-shell | Launch at login, show menu-bar icon, closed style (invisible/island), notch style (glass/solid black), open on hover, hover delay, close delay, haptics, hide in fullscreen |
| Shortcuts | notch-shell | Recorders for ⌥⌘N and ⌥⌘V |
| Claude | claude-app (`ClaudeSettingsSection`) | Hook status + install/uninstall/repair, statusLine bridge toggle, popups on 🔴/🟢, focus-aware popups, auto-collapse seconds, Haiku titles, config folder override, usage bars + threshold, confirm dangerous |
| Music | media (`MediaSettingsSection`) | Enable Spotify, visualizer, Automation permission status + button |
| Shelf | shelf-clipboard (`ShelfSettingsSection`) | Enable shelf, AirDrop zone, retention (Off/1 d/7 d/30 d), open shelf folder, clear |
| Clipboard | shelf-clipboard (`ClipboardSettingsSection`) | Enable, limit (50–1000, default 200), capture images, ignored apps, paste permission status, clear history |
| About | notch-shell | Version, GitHub link, check for updates (open the releases page), licences (NOTICE) |

### A.11 Onboarding wizard (first launch, or from Settings › General › "Run setup again")

`OnboardingView` (notch-shell) is a single-window pager with Back/Next, and hosts:

1. **Welcome** (shell). What SuperNotch does. Note: "Everything stays on this Mac."
2. **Claude Code hooks** (claude-app, `OnboardingHooksStep`):
   * Shows the exact entries that will be added to `<config>/settings.json`, and the backup path.
   * Buttons: **Install hooks** / Skip.
   * Optional checkbox "Show usage limits (wraps your status line)", default on.
3. **Spotify** (media, `OnboardingSpotifyStep`). Asks for Automation permission (Spotify must be running).
4. **Clipboard paste** (shelf-clipboard, `OnboardingPasteStep`). PostEvent (Accessibility) permission, and
   the note about macOS pasteboard privacy.
5. **Done** (shell). Launch at login toggle and a hotkey cheat-sheet. Sets `onboardingCompleted = true`.

Every step can be skipped. The wizard itself never blocks the app.

### A.12 Menu-bar icon

* An `NSStatusItem` (FOUNDATION, `AppDelegate`) with the SF Symbol `rectangle.topthird.inset.filled`.
* Menu: Open Notch ⌥⌘N · Clipboard History ⌥⌘V · Settings… · Quit.
* Hidden when `showMenuBarIcon == false`. Then Settings is reachable via the notch gear, or by relaunching
  the app (a second launch opens Settings).

---

## B. Package and targets

`Package.swift` (FOUNDATION): tools 6.2, `platforms: [.macOS("26.0")]`, **no external dependencies**.

| Target | Kind | Path | Language mode | Builds on |
|---|---|---|---|---|
| `SuperNotchCore` | library | `Sources/SuperNotchCore` | Swift 6, strict concurrency, everything `Sendable` | Linux + macOS |
| `supernotch-hook` | executable | `Sources/supernotch-hook` | Swift 6 | Linux + macOS |
| `SuperNotch` | executable (app) | `Sources/SuperNotch` | **Swift 5 mode + `.defaultIsolation(MainActor.self)`** | macOS only (declared under `#if os(macOS)` in the manifest) |
| `SuperNotchCoreTests` | test (swift-testing) | `Tests/SuperNotchCoreTests` (+ `Fixtures/` resources) | Swift 6 | Linux + macOS |

Why these settings:

* **Core is Swift 6** because we *can* compile it locally, and it is shared with the hook.
* **The app is Swift 5 mode with MainActor as the default isolation.** Everything in the app is MainActor
  unless it opts out. Concurrency diagnostics that would be errors in Swift 6 are only warnings, so
  concurrency mistakes we cannot see locally do not fail the first CI run. Background work must opt out
  explicitly: `nonisolated` functions and types, `actor`s, `Task.detached`, or `DispatchQueue` with
  `@Sendable` closures.
* **Hotkeys use Carbon `RegisterEventHotKey`**, implemented by us (≈120 lines, `System/HotkeyCenter.swift`),
  instead of the `KeyboardShortcuts` package. No dependency resolution on CI, no extra licence, and no
  Accessibility permission.
* **The app is not an `.app` in SwiftPM.** `Scripts/package_app.sh` assembles the bundle (§G.3). The hook is
  copied to `Contents/Helpers/supernotch-hook`.
* Linux-only guards: files in `SuperNotchCore` and `supernotch-hook` import only Foundation, and
  `Glibc`/`Darwin` behind `#if canImport(...)`. Core must never import AppKit, SwiftUI, os, Combine or
  CoreGraphics. Foundation's `CGFloat`, `CGPoint`, `CGSize` and `CGRect` exist on Linux and may be used.

### B.1 Directory tree (every file below exists as a stub or real file)

```
Package.swift                                    FOUNDATION
Resources/Info.plist, SuperNotch.entitlements    FOUNDATION
Resources/AppIcon.png                            FOUNDATION (placeholder 1024², replace later)
Scripts/package_app.sh, make_selfsigned_cert.sh, install.sh, make_icon.py   FOUNDATION
.github/workflows/ci.yml, release.yml            FOUNDATION
README.md, NOTICE, LICENSE, docs/*               FOUNDATION

Sources/SuperNotchCore/
  Shared/SuperNotchPaths.swift                   FOUNDATION
  Settings/AppSettings.swift                     FOUNDATION  (all settings + defaults)
  Settings/KeyCombo.swift                        FOUNDATION
  Notch/NotchMetrics.swift                       FOUNDATION  (sizes, radii, timings)
  Notch/NotchPresentation.swift                  FOUNDATION  (NotchTab, NotchPresentation, PopupRequest…)
  Notch/NotchGeometry.swift                      notch-shell (signature FROZEN, baseline implemented)
  Notch/HoverIntent.swift                        notch-shell (signature FROZEN, baseline implemented)
  Notch/PopupPolicy.swift                        notch-shell (signature FROZEN, baseline implemented)
  IPC/*.swift                                    claude-core
  Claude/*.swift                                 claude-core
  Media/PlaybackSnapshot.swift                   FOUNDATION  (contract types)
  Media/SpotifyScriptParser.swift                media
  Shelf/ShelfItem.swift                          FOUNDATION  (contract types)
  Shelf/RetentionPolicy.swift                    shelf-clipboard
  Clipboard/ClipboardEntry.swift                 FOUNDATION  (contract types)
  Clipboard/ClipboardCaptureFilter.swift         shelf-clipboard

Sources/supernotch-hook/                         claude-core (all files)

Sources/SuperNotch/
  App/main.swift                                 FOUNDATION
  App/AppDelegate.swift                          FOUNDATION
  App/AppModel.swift                             FOUNDATION
  App/Log.swift                                  FOUNDATION
  App/SmokeTest.swift                            FOUNDATION
  Shared/SettingsStore.swift                     FOUNDATION
  Shared/NotchSlots.swift                        FOUNDATION  (maps presentations to stream views)
  Shared/HomeTabView.swift                       FOUNDATION
  Shared/DesignTokens.swift                      FOUNDATION  (colours, fonts, spacing)
  Notch/*, System/*, Settings/*, Onboarding/*    notch-shell
  Claude/**                                      claude-app
  Media/**                                       media
  Shelf/**                                       shelf-clipboard
  Clipboard/**                                   shelf-clipboard

Tests/SuperNotchCoreTests/
  Foundation/*.swift                             FOUNDATION
  Claude/*.swift, IPC/*.swift, Hook/*.swift      claude-core
  Notch/*.swift                                  notch-shell
  Media/*.swift                                  media
  Shelf/*.swift, Clipboard/*.swift               shelf-clipboard
  Fixtures/<stream>/…                            owned per sub-folder (claude/, media/, shelf/)
```

---

## C. File ownership map

| Stream | Owns (create, edit, delete freely inside) | Must not touch |
|---|---|---|
| **(1) claude-core** | `Sources/SuperNotchCore/Claude/**`, `Sources/SuperNotchCore/IPC/**`, `Sources/supernotch-hook/**`, `Tests/SuperNotchCoreTests/{Claude,IPC,Hook}/**`, `Tests/SuperNotchCoreTests/Fixtures/claude/**` | everything else |
| **(2) claude-app** | `Sources/SuperNotch/Claude/**` (socket server, hook installer IO, agents poller, session-file watcher, transcript reader, Haiku title generator, deep-link/terminal focuser, statusLine bridge support, liveness, `ClaudeSessionsModel`, all Claude views incl. `ClaudeHomeSection`, `SessionRowView`, `PermissionCardView`, `UsageBarsView`, `ClaudeIslandIndicator`, `ClaudePeekView`, `ClaudeSettingsSection`, `OnboardingHooksStep`) | Core (ask claude-core by writing needs into `Sources/SuperNotch/Claude/CORE_REQUESTS.md`; meanwhile use a local `extension`) |
| **(3) notch-shell** | `Sources/SuperNotch/{Notch,System,Settings,Onboarding}/**`, `Sources/SuperNotchCore/Notch/{NotchGeometry,HoverIntent,PopupPolicy}.swift`, `Tests/SuperNotchCoreTests/Notch/**` | foundation files (`NotchMetrics`, `NotchPresentation`) |
| **(4) media** | `Sources/SuperNotch/Media/**`, `Sources/SuperNotchCore/Media/SpotifyScriptParser.swift` (+ new files in `Core/Media/` except `PlaybackSnapshot.swift`), `Tests/SuperNotchCoreTests/Media/**`, `Fixtures/media/**` | `PlaybackSnapshot.swift` |
| **(5) shelf-clipboard** | `Sources/SuperNotch/{Shelf,Clipboard}/**`, `Sources/SuperNotchCore/Shelf/RetentionPolicy.swift`, `Sources/SuperNotchCore/Clipboard/ClipboardCaptureFilter.swift` (+ new files in `Core/Shelf`, `Core/Clipboard` except the contract files), `Tests/SuperNotchCoreTests/{Shelf,Clipboard}/**`, `Fixtures/shelf/**` | `ShelfItem.swift`, `ClipboardEntry.swift` |
| **FOUNDATION** | everything else (see §B.1) | – |

**Shared-file escape hatch.** A stream that truly needs a change in a FOUNDATION file does not edit it.
Instead it:
1. adds a clearly marked file `Sources/SuperNotch/<StreamDir>/_Foundation+<Stream>.swift` containing
   extensions (for example a computed property on `AppSettings` derived from existing fields), and
2. describes the requested foundation change in its final report. The orchestrator applies it.

New persisted settings go in `AppSettings` through the orchestrator. Until then a stream may use
`UserDefaults.standard` directly with a key prefixed `sn.<stream>.`.

**Type name uniqueness.** All app files compile into one module. Every top-level type a stream adds must be
prefixed by its area (`Claude…`, `Media…`, `Spotify…`, `Shelf…`, `Clipboard…`, `Notch…`, `Hotkey…`,
`Onboarding…`, `Settings…`), or be `private`/`fileprivate`. Never declare generic top-level names
(`Row`, `Tile`, `Helpers`, `Constants`) and never add top-level free functions.

---

## D. Public interfaces (FROZEN)

The code in the repo is the source of truth for exact signatures. This section lists what crosses stream
boundaries and what it means.

### D.1 Core: Claude models (`SuperNotchCore/Claude`, claude-core)

* `Session`: id, cwd, transcriptPath, pid, pidStartTime, claudeExecutablePath, host (`SessionHost`), phase
  (`SessionPhase`), lastError, title (`SessionTitle?`), titleCandidates, firstPrompt, lastAssistantPreview,
  activeSubagents, pendingPermissionIDs, visibility, isStale, startedAt, updatedAt, phaseChangedAt.
  * Computed: `trafficLight`, `isVisible`, `hasError`, `projectName`, `displayTitle`.
* `SessionPhase`: `.idle | .working | .done | .needsInput(NeedsInputKind)`.
  * `NeedsInputKind`: `.permission | .question | .other`.
* `TrafficLight`: `.grey < .green < .yellow < .red` (Comparable; aggregate = max).
* `SessionHost`, `SessionHostKind` (`terminal`, `claudeDesktop`, `vscode`, `unknown`): used by the focuser
  and by focus-aware popups (`appBundleID`).
* `PermissionRequest`: id (= envelope id), sessionID, toolName, toolInput, summary, detail, danger
  (`DangerAssessment`), suggestions, receivedAt.
  * Computed: `canAlwaysAllow`, `alwaysAllowDecision`.
* `PermissionDecision`: `.allow | .allowAlways(updatedPermissions:) | .deny(message:)`.
  * `hookStdout` is exactly what the hook prints.
* `UsageLimits` / `UsageWindow`: `fiveHour`, `sevenDay`, `usedPercentage` 0…100, `fraction` 0…1,
  `resetsAt`, `isWarning(threshold:)`.
* `SessionEvent`, `SessionEffect`, `TranscriptSignals`, `AgentsListEntry`.
* `SessionSource` (`@MainActor` protocol: `sourceID`, `start(sink:)`, `stop()`). This is the seam for a
  future cloud source.
* `SessionStore` (the reducer):

  ```swift
  public struct SessionStore: Sendable {
      public init(configuration: SessionStoreConfiguration = .init())
      public private(set) var sessions: [String: Session]          // all, incl. hidden
      public private(set) var permissions: [String: PermissionRequest]
      public private(set) var usage: UsageLimits?
      public mutating func apply(_ event: SessionEvent, now: Date) -> [SessionEffect]
      public var visibleSessions: [Session]            // sorted: red, yellow, green, grey; then phaseChangedAt desc
      public var pendingPermissions: [PermissionRequest]  // oldest first, visible sessions only
      public var aggregateLight: TrafficLight?         // nil when no visible session
  }
  ```

* `TitleResolver`, `DangerousCommandClassifier`, `TranscriptTailParser`, `ClaudePaths`, `ClaudeVersion`.
* `HookSettingsMerger` + `HookInstallSpec` + `HookManifest` + `ShellQuote` (installer logic, §D.6).

### D.2 Core: notch contract (`SuperNotchCore/Notch`, FOUNDATION + notch-shell)

```swift
public enum NotchTab: String, Sendable, Codable, CaseIterable { case home, shelf }
public enum NotchPresentation: Sendable, Hashable { case closed, peek(PopupRequest), expanded(NotchTab) }

public enum PopupPriority: Int, Sendable, Comparable { case info = 0, critical = 1 }
public enum PopupPayload: Sendable, Hashable {
    case claudeSession(sessionID: String)      // done / question peek → ClaudePeekView
    case claudePermission(requestID: String)   // permission card → PermissionCardView
}
public struct PopupRequest: Sendable, Hashable, Identifiable {
    public var id: String                      // same id ⇒ replaces (use PopupRequest.claudeSessionID(_:))
    public var priority: PopupPriority
    public var payload: PopupPayload
    public var hostAppBundleID: String?        // for focus-aware suppression of .info popups
    public var autoDismissAfter: TimeInterval? // e.g. 4 s for 🟢
    public var createdAt: Date
}
public struct PopupContext: Sendable {         // world state the policy looks at (+ memberwise init, see file)
    public var isFullscreen, isExpanded, isNotchAvailable: Bool
    public var frontmostAppBundleID: String?
    public var popupsForNeedsInput, popupsForDone, skipDoneWhenHostFrontmost, hideInFullscreen: Bool
}
public enum PopupDecision: Sendable, Equatable { case show, queue, suppress }
public enum PopupPolicy { public static func decide(_ request: PopupRequest, context: PopupContext) -> PopupDecision }

public struct NotchGeometry: Sendable, Hashable {   // pure math, tested on Linux
    public init?(screenFrame: CGRect, safeAreaTop: CGFloat, auxiliaryTopLeftWidth: CGFloat?, auxiliaryTopRightWidth: CGFloat?)
    public let screenFrame: CGRect
    public let notchRect: CGRect            // screen coordinates (AppKit, origin bottom-left)
    public var notchSize: CGSize
    public var panelFrame: CGRect           // fixed NotchMetrics.panelSize, top-centred on the notch
    public func size(for presentation: NotchPresentation, closedWidthExtra: CGFloat) -> CGSize
    public func shapeRectInScreen(for size: CGSize) -> CGRect // top-centred rect of the current shape
    public func hoverRect(slack: CGFloat) -> CGRect
}
public struct HoverIntent: Sendable { /* pure dwell state machine; see file */ }
```

### D.3 Core: media, shelf, clipboard, settings (FOUNDATION contract types)

* `PlaybackSnapshot`: track (`TrackInfo?`), state (`PlaybackState`), positionSeconds, positionTimestamp,
  shuffling, repeating, volume (0…100).
  * `position(at:)` extrapolates while playing. `progress(at:)` is 0…1.
* `TrackInfo`: id, title, artist, album, durationSeconds, artworkURL.
  * `isAd`, `isLocal`, `isEpisode` are derived from the Spotify id/URI.
* `ShelfItem`: id, kind (`file | folder | text | link | image`), displayName, storedRelativePath (relative
  to `SuperNotchPaths.shelfDirectory`), text, urlString, byteSize, addedAt, pinned, originalPath.
* `ClipboardEntry`: id, content (`.text | .link | .image(relativePath:pixelWidth:pixelHeight:) | .files([path])`),
  sourceAppBundleID, sourceAppName, capturedAt, pinned, contentHash, `previewText`.
* `RetentionPeriod`: `off | oneDay | sevenDays | thirtyDays` (default `.sevenDays`), `interval`.
* `AppSettings`: every persisted setting with its default (see the file). It is stored as JSON in
  `UserDefaults` under `AppSettings.userDefaultsKey` ("sn.settings.v1") and decoded tolerantly: a missing
  key takes its default.
* `KeyCombo`: Carbon keyCode + Carbon modifier mask. Defaults: `.toggleNotchDefault` (⌥⌘N, keyCode 45),
  `.clipboardHistoryDefault` (⌥⌘V, keyCode 9).

### D.4 App-side observable models (FROZEN API; implementation owned by the stream)

All are `@Observable final class` on the MainActor. Views get them via `@Environment(X.self)`. Every model
has the same initializer, `init(settings: SettingsStore, notch: NotchViewModel)`, except `NotchViewModel`,
which uses `init(settings:)`. They also all have `start()` and `stop()`. `AppModel` (FOUNDATION) builds
them in this order: settings → notch → claude → media → shelf → clipboard. It injects all of them into
every SwiftUI hierarchy with `.environment(...)` (see `AppModel.inject(_:)`).

**`SettingsStore`** (FOUNDATION, real): `var settings: AppSettings` (saved on every set), `func reset()`.
Views bind with `@Bindable var store = settingsStore; $store.settings.hoverOpenDelay`.

**`NotchViewModel`** (notch-shell):
```swift
var presentation: NotchPresentation { get }      // drives the UI
var selectedTab: NotchTab                        // last tab (kept while closed)
var geometry: NotchGeometry? { get }             // nil ⇒ no built-in notch display
var isFullscreenActive: Bool { get }
var isHovering: Bool { get }
var isKeyFocused: Bool { get }                   // panel is key (keyboard shortcuts allowed)
var queuedPopups: [PopupRequest] { get }
func open(tab: NotchTab? = nil, focus: Bool = false)   // focus = make panel key
func close()
func toggle()
func present(_ request: PopupRequest)            // runs PopupPolicy; show / queue / suppress
func withdraw(popupID: String)                   // remove a shown or queued popup
func holdOpen(reason: String) -> NotchHoldToken  // token.release(); also released on deinit
// NotchHoldToken (notch-shell, Notch/NotchHoldToken.swift): `final class` (nonisolated, Sendable);
// `release()` is idempotent and non-mutating, so `let token` properties work; dropping the token releases it.
func openSettings()                              // shows the Settings window (calls the handler below)
var openSettingsHandler: (() -> Void)?           // set by AppDelegate
```

**`ClaudeSessionsModel`** (claude-app):
```swift
var sessions: [Session] { get }                  // visible, sorted (SessionStore.visibleSessions)
var permissions: [PermissionRequest] { get }     // pending, oldest first
var usage: UsageLimits? { get }
var aggregateLight: TrafficLight? { get }
var hasActiveSessions: Bool { get }              // any visible session
var isUsageWarning: Bool { get }                 // usage ≥ settings.usageWarningThreshold
var hookStatus: ClaudeHookStatus { get }         // .unknown, .notInstalled, .installed, .needsRepair(String), .failed(String)
func session(id: String) -> Session?
func permission(id: String) -> PermissionRequest?
func answer(requestID: String, decision: PermissionDecision)
func focus(sessionID: String)                    // jump to chat (§D.8)
```

**`MediaModel`** (media):
```swift
var snapshot: PlaybackSnapshot? { get }
var isSpotifyRunning: Bool { get }
var hasTrack: Bool { get }                       // running && snapshot?.track != nil
var isPlaying: Bool { get }
var artwork: NSImage? { get }
var automationPermission: MediaAutomationPermission { get }  // .unknown, .granted, .denied, .notRunning
func playPause(); func nextTrack(); func previousTrack()
func seek(to seconds: Double)
func requestAutomationPermission()
func openSpotify()
```

**`ShelfModel`** (shelf-clipboard):
```swift
var items: [ShelfItem] { get }                   // newest first
var isDragActive: Bool { get }                   // a file drag is in progress near/over the notch
func add(fileURLs: [URL])
func addText(_ text: String)
func remove(id: UUID); func togglePin(id: UUID); func removeAll()
func fileURL(for item: ShelfItem) -> URL?
func airDrop(itemIDs: [UUID])
```

**`ClipboardModel`** (shelf-clipboard):
```swift
var entries: [ClipboardEntry] { get }            // newest first (pinned first)
var isHistoryPanelVisible: Bool { get }
var canPaste: Bool { get }                       // PostEvent permission granted
func toggleHistoryPanel(); func showHistoryPanel(); func hideHistoryPanel()
func paste(_ entryID: UUID)                      // write to the pasteboard (+ own marker) and send ⌘V
func copy(_ entryID: UUID)
func delete(_ entryID: UUID); func togglePin(_ entryID: UUID); func clearAll()
func requestPastePermission()
func imageURL(for entry: ClipboardEntry) -> URL?
```

### D.5 View slots (FROZEN type names: each stream provides a `View` with a no-argument initializer unless noted)

| View | Owner | Used by |
|---|---|---|
| `MediaHomeSection()` | media | `HomeTabView` (left column, 200 pt) |
| `MediaIslandArtwork()` | media | closed island, left wing (22 × 22) |
| `MediaIslandVisualizer()` | media | closed island, right wing (≤ 20 × 14; animates only while playing) |
| `MediaSettingsSection()`, `OnboardingSpotifyStep()` | media | Settings / onboarding |
| `ClaudeHomeSection()` | claude-app | `HomeTabView` (right column) |
| `ClaudeIslandIndicator()` | claude-app | closed island right wing while Claude is 🟡/🔴 (dots + usage-warning dot); other closed cases: §D.10 |
| `ClaudePeekView(sessionID: String)` | claude-app | peek for `.claudeSession` |
| `PermissionCardView(requestID: String)` | claude-app | peek for `.claudePermission` |
| `ClaudeSettingsSection()`, `OnboardingHooksStep()` | claude-app | Settings / onboarding |
| `ShelfTabView()` | shelf-clipboard | Shelf tab (incl. `DropZonesView` while dragging) |
| `ShelfSettingsSection()`, `ClipboardSettingsSection()`, `OnboardingPasteStep()` | shelf-clipboard | Settings / onboarding |
| `NotchContainerView()` | notch-shell | root of the panel (reads `NotchViewModel`, uses `NotchSlots`) |

`NotchSlots` (FOUNDATION) is the only place that references stream views for the notch. The shell renders:
* `NotchSlots.islandLeading()` and `NotchSlots.islandTrailing()` when closed;
* `NotchSlots.peek(request)` for a peek;
* `NotchSlots.tab(tab)` when expanded (`HomeTabView` or `ShelfTabView`).

### D.6 Hook installation (claude-core logic, claude-app IO)

Hook binary: copied on every launch (if the hash differs) from `SuperNotch.app/Contents/Helpers/supernotch-hook`
to `~/Library/Application Support/SuperNotch/bin/supernotch-hook` (mode 0755). The path is stable across
app moves and updates, and is re-verified on every launch (Open Island #693).

Settings file: `ClaudePaths.resolve(environment:homeDirectory:override:).settingsFile`. The order is: the
override from Settings, then `$CLAUDE_CONFIG_DIR`, then `~/.claude`. The app is launched by launchd, so it
usually does not see the user's shell `CLAUDE_CONFIG_DIR`. The hook reports the one it saw in
`context.claudeConfigDir`. When claude-app notices a different config dir, it offers to install there too.

Command string: `ShellQuote.quote(hookBinaryPath) + " hook"`, for example:
`'/Users/me/Library/Application Support/SuperNotch/bin/supernotch-hook' hook`.
Our entries are identified by the substring `SuperNotch/bin/supernotch-hook`.

Entries merged into `settings.json` (one matcher group per event, appended; never reorders or removes
other hooks):

```json
{
  "hooks": {
    "SessionStart":      [{ "matcher": "*", "hooks": [{ "type": "command", "command": "'…/supernotch-hook' hook", "timeout": 10 }] }],
    "SessionEnd":        [{ "matcher": "*", "hooks": [{ "type": "command", "command": "'…/supernotch-hook' hook", "timeout": 10 }] }],
    "UserPromptSubmit":  [{               "hooks": [{ "type": "command", "command": "'…/supernotch-hook' hook", "timeout": 10 }] }],
    "PreToolUse":        [{ "matcher": "*", "hooks": [ … timeout 10 ] }],
    "PostToolUse":       [{ "matcher": "*", "hooks": [ … timeout 10 ] }],
    "PermissionRequest": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "'…/supernotch-hook' hook", "timeout": 300 }] }],
    "Notification":      [{ "matcher": "*", "hooks": [ … ] }],
    "Stop":              [{               "hooks": [ … ] }],
    "SubagentStop":      [{ "matcher": "*", "hooks": [ … ] }],
    "PreCompact":        [{ "matcher": "*", "hooks": [ … ] }]
    // + extended events when claude --version ≥ 2.1.0:
    // PostToolUseFailure, PermissionDenied, StopFailure, SubagentStart, PostCompact
  },
  "statusLine": { "type": "command", "command": "'…/supernotch-hook' statusline" }   // only if the bridge is enabled
}
```

Installer rules (`HookSettingsMerger`, pure, tested):
* Parse strictly with `JSONValue.parse`. Invalid JSON: **refuse** and report; never overwrite.
* Keep all unknown keys, keep key order (`JSONObject`), and pretty-print with 2 spaces.
* Idempotent. Install twice gives the same bytes. Uninstall removes only our entries, and removes an
  event array or `hooks` object that becomes empty *only if we created it* (tracked in `HookManifest`).
* statusLine bridge:
  * The user's original `statusLine` object is saved in `HookManifest.originalStatusLine`.
  * Ours is set in its place. On uninstall the original is restored.
  * Never wrap our own command (Open Island #671).
* IO (claude-app, `HookInstaller`):
  1. Back up to `~/Library/Application Support/SuperNotch/Backups/settings.json.<ISO8601>.bak`.
  2. Re-read the file just before writing. If it changed since the plan was shown, re-plan.
  3. Write to a temp file in the same directory, then `rename` it into place.
  4. Write the manifest to `SuperNotchPaths.hookManifest`.

### D.7 Hook ↔ app IPC protocol (claude-core)

* **Transport:** Unix domain stream socket.
  * Path: `SocketPath.resolve(homeDirectory:uid:environment:)`, which gives
    `~/Library/Application Support/SuperNotch/hook.sock`, or `/tmp/supernotch-<uid>.sock` if the path would
    exceed 103 bytes. `$SUPERNOTCH_SOCKET` overrides it.
  * The app creates it with mode 0600, and unlinks a stale file first.
* **Framing:** NDJSON (`NDJSON.encodeLine`). One `HookEnvelope` per connection, hook → app.
* **Envelope:** `{ v, id, sentAt, event, expectsReply, context: HookContext, payload: <raw stdin JSON> }`.
* **Non-blocking events** (everything except PermissionRequest): the hook connects (100 ms timeout),
  writes one line, closes, prints nothing and exits 0.
* **PermissionRequest** (`expectsReply = true`):
  * The hook keeps the connection open and waits up to `IPCConfig.permissionReplyTimeout` (290 s) for one
    `HookReply` line `{ v, id, decision }`.
  * If `decision` is non-nil, the hook prints `decision.hookStdout` and exits 0.
  * If it is nil, or on timeout, EOF or any error, the hook prints nothing and exits 0, so Claude Code
    shows its own prompt (**fail open**).
* **App side:**
  * When the user answers, send the `HookReply`, then close.
  * If the request is hidden or not answerable (internal, headless or subagent session): reply
    `decision: nil` immediately (`SessionEffect.replyPassthrough`).
  * If the peer closes first: `SessionEvent.permissionConnectionClosed`.
* **statusLine bridge** (`supernotch-hook statusline`):
  1. Reads the statusLine JSON from stdin.
  2. Sends an envelope with `event = "StatusLine"` (non-blocking).
  3. Runs the original statusLine command from the manifest via `/bin/sh -c` with the same stdin, and
     prints its stdout. With no original, it prints nothing. Total budget: 1 s.
* **Hook context enrichment:** the hook walks up to 8 parent processes (`proc_pidinfo`/`sysctl` on macOS;
  `/proc` on Linux) to find the `claude` process (argv0 basename `claude`, or a node process whose argv
  contains `claude`). From it the hook records `claudePID`, `claudeStartTime`, `claudeExecutablePath`,
  `tty` and `isPrintMode` (argv contains `-p` or `--print`). Environment fields come from
  `HookContext(environment:hookVersion:)`.
* **Performance budget:** the hook must finish in under 30 ms for non-blocking events. No Foundation
  `Process`, no network, no file writes unless `SUPERNOTCH_HOOK_DEBUG=1`.

### D.8 Jump to chat (claude-app, `SessionFocuser`)

| Host | Technique |
|---|---|
| Claude desktop | `claude://code/continue?session=<local_id>`, which is undocumented. If `NSWorkspace.open` returns false, activate `com.anthropic.claudefordesktop` |
| iTerm2 | AppleScript: select the session whose `unique id` matches `ITERM_SESSION_ID`, otherwise match by tty |
| Terminal.app | AppleScript: select the tab whose `tty` matches |
| Ghostty / kitty / WezTerm / tmux | Best effort (`wezterm cli activate-pane`, `kitten @ focus-window`, `tmux select-pane`), then activate the app |
| VS Code / Cursor | Activate the app (`code -r <cwd>` is optional) |
| Fallback | Walk the parent processes of `pid` until one belongs to a GUI app (`NSRunningApplication(processIdentifier:)`), then `activate()` |

Automation permission is requested lazily, per host.

### D.9 Usage limits

* The statusLine bridge (§D.7) is the only source. There is **no** Keychain or token scraping.
* `ClaudeSessionsModel.usage` shows the latest value (pruned when `resetsAt` passes) and keeps it across
  restarts in `UserDefaults` key `sn.claude.usage`.
* Views: `UsageBarsView` with two 3 pt bars, labelled "5h" and "7d", showing the percentage and the reset
  time on hover. It turns orange at the threshold and red at ≥ 95 %.

### D.10 App wiring (Foundation clarification, additive; nothing above changes)

§D.4/§D.5 left a few cross-stream entry points implicit. These are the exact names. The FOUNDATION files
are real code; read them for details.

**Provided by FOUNDATION** (`App/*`, `Shared/*`; use freely):

```swift
@Observable final class AppModel {                     // App/AppModel.swift
    static private(set) var shared: AppModel?          // for AppKit glue only; views use @Environment
    let paths: SuperNotchPaths
    let settings: SettingsStore
    let notch: NotchViewModel
    let claude: ClaudeSessionsModel
    let media: MediaModel
    let shelf: ShelfModel
    let clipboard: ClipboardModel
    let version: String, build: String                 // Info.plist ("dev"/"0" when unbundled), e.g. for About
    private(set) var isRunning: Bool
    init(settings: SettingsStore = SettingsStore(),    // builds settings → notch → claude → media → shelf → clipboard
         paths: SuperNotchPaths = SuperNotchPaths(homeDirectory: NSHomeDirectory()))
    func start(); func stop()                          // same order / reverse order; idempotent
    func inject<V: View>(_ view: V) -> some View       // .environment(AppModel) + all six models
    func showSettings()                                // opens/focuses the Settings window
    func showOnboarding()                              // "Run setup again" (Settings › General)
    func quit()
}

@Observable final class SettingsStore {                // Shared/SettingsStore.swift
    init(defaults: UserDefaults = .standard)
    var settings: AppSettings                          // normalized + saved on every set (Bindable-friendly)
    func update(_ change: (inout AppSettings) -> Void) // several fields, one save
    func reset()                                       // defaults; keeps onboardingCompleted + launchAtLogin
    func observe(_ handler: @escaping (_ old: AppSettings, _ new: AppSettings) -> Void) -> SettingsStore.ObserverToken
}   // called synchronously after each real change; keep the token (cancel() or dropping it ends the observation)

nonisolated enum Log { … }                             // §F.2 categories + `system`
enum NotchSlots { … }                                  // §D.5 (+ closedWings / closedWidthExtra / hasIslandContent)
enum DesignTokens { … }                                // Shared/DesignTokens.swift: colours, fonts, spacing, glass gradient
struct HomeTabView: View { init() }
```

Core additions (FOUNDATION files, tested): `NotchMetrics.contentFadeInDelay`, `NotchMetrics.closedWings(…)` /
`NotchMetrics.closedWidthExtra(…)`,
`NotchMetrics.glassGradientStops(…)`, `NotchStyle.usesGlass(reduceTransparency:)`,
`AppSettings.clipboardLimitRange` (50…1000, §A.10; `normalize()` clamps to it) and
`AppSettings.resetToDefaults()`.

Every hierarchy built with `AppModel.inject(_:)` also carries `AppModel` itself, so a view may use
`@Environment(AppModel.self)` (e.g. for `showOnboarding()`).

**Provided by notch-shell** (FOUNDATION's `AppDelegate`/`SmokeTest` call exactly these):

```swift
final class NotchWindowController {                    // Notch/NotchWindowController.swift
    init(appModel: AppModel)
    func start()   // builds the NotchPanel hosting appModel.inject(NotchContainerView()); tracks screens, wake,
                   // spaces and fullscreen; registers the global hotkeys (System/HotkeyCenter) from settings and
                   // re-registers them on change: toggleNotchHotkey → appModel.notch.toggle() (focused),
                   // clipboardHotkey → appModel.clipboard.toggleHistoryPanel()
    func stop()    // orders the panel out, removes monitors/observers, unregisters hotkeys
}
struct SettingsView: View { init() }                   // Settings/SettingsView.swift: root of the Settings window (§A.10)
struct OnboardingView: View { init() }                 // Onboarding/OnboardingView.swift: §A.11 pager
```

Lifecycle and windows (implemented in `App/AppDelegate.swift`):

* Launch: `AppModel()` → `notch.openSettingsHandler = …` → `appModel.start()` → `NotchWindowController(appModel:)`
  `.start()` → menu-bar item (§A.12) → onboarding if `!settings.onboardingCompleted`. Quit: controller `stop()`,
  then `appModel.stop()`.
* The Settings and onboarding windows are titled `NSWindow`s owned by `AppDelegate`, hosting
  `appModel.inject(SettingsView())` / `appModel.inject(OnboardingView())`. The activation policy is `.regular`
  while either is open and `.accessory` again when both are closed. The app has a standard main menu (App,
  Edit, Window), so ⌘C/⌘V/⌘A/⌘W work in those windows.
* Onboarding closes itself when `settings.onboardingCompleted` becomes `true` (the Done step sets it).
  Closing the onboarding window with its close button also sets it (the wizard never blocks; it can be
  re-run). "Run setup again" calls `appModel.showOnboarding()`; setting `onboardingCompleted = false` has the
  same effect.
* A second launch (Finder reopen, or a second process, via a distributed notification) opens Settings.

**Slot composition rules** (`Shared/NotchSlots.swift`, `Shared/HomeTabView.swift`):

* **Island content** (`NotchSlots.hasIslandContent(settings:media:claude:)`): a Spotify track is **playing**
  (`spotifyEnabled && hasTrack && isPlaying`), or Claude is active: `claudeEnabled` and
  `aggregateLight` is 🟡 or 🔴. Paused tracks and 🟢/idle sessions do not keep the island open (🟢 is announced by
  its peek); this keeps the closed notch compact.
* **Closed wings: one rule** — `NotchMetrics.closedWings(mode:hasIslandContent:showsUsageWarning:)` (Core,
  tested) returns `(leading, trailing)`: island mode with content ⇒ 36 / 36; otherwise usage warning ⇒
  0 / 14 (**right wing only**; the shape's centre moves `(trailing − leading) / 2` to the right, the physical
  notch never moves); else 0 / 0. `NotchSlots.closedWings(settings:media:claude:)` feeds it from the models and
  `NotchSlots.closedWidthExtra(…)` is the sum. notch-shell's `NotchClosedWings.resolve(…)` must return exactly
  these values (ideally by calling `NotchMetrics.closedWings`).
* `NotchSlots.islandLeading()`: `MediaIslandArtwork()` in island mode while a track is playing, else nothing.
* `NotchSlots.islandTrailing()`:
  * island mode and Claude active ⇒ `ClaudeIslandIndicator()` (session dots + its own usage-warning dot);
  * island mode otherwise (a track is playing) ⇒ `MediaIslandVisualizer()` (if `showVisualizer`) + the
    usage-warning dot (drawn by `NotchSlots`) when needed;
  * no island content or invisible mode ⇒ only the usage-warning dot (drawn by `NotchSlots`), or nothing.
  Slot views size themselves (≤ wing width) and render nothing when they have nothing to show.
* `NotchSlots.tab(_:)` / `NotchSlots.peek(_:)` fill the area the shell gives them below the top band
  (height N.h). The shell draws the tab icons and the gear in the top band and insets the slot area by
  `NotchMetrics.contentPadding` on the left, right and bottom, so slot views add no outer padding of their
  own. `peek(_:)` applies `.id(request.id)`, so a new request always gets fresh view state.
* `HomeTabView`: `MediaHomeSection()` gets exactly 200 pt × column height (it shows its own "Open Spotify"
  state); a hairline; `ClaudeHomeSection()` gets the rest at full column height and renders **both** the
  session rows **and** `UsageBarsView` at its bottom (§A.5 diagram). `HomeTabView` does not add
  `UsageBarsView` itself. If `spotifyEnabled` is off the Claude column takes the full width; if `claudeEnabled`
  is off the music column stays 200 pt and the rest shows a hint. The overall size never changes.
* Smoke test (`App/SmokeTest.swift`, §G.2): `SuperNotch --smoke-test` exits 0 within a few seconds (watchdog
  25 s; `package_app.sh` allows 30 s), shows no window or dialog, and never touches `~/.claude`. It sets
  `SUPERNOTCH_SMOKE_TEST=1`, `SUPERNOTCH_SOCKET` and `CLAUDE_CONFIG_DIR` (+ `claudeConfigDirOverride`) to temp
  paths, uses an isolated `UserDefaults` suite, renders every §D.5 view off-screen, then starts/stops all models
  and `NotchWindowController` with `spotifyEnabled` and `clipboardEnabled` off. Models must not show dialogs
  or write outside Application Support / temp while `SUPERNOTCH_SMOKE_TEST=1`.
* Glass look (§A.3): `DesignTokens.GlassLook.gradient(notchHeight:shapeHeight:)` is the black→clear
  `LinearGradient` (stops from the pure `NotchMetrics.glassGradientStops(notchHeight:shapeHeight:)`), and
  `DesignTokens.GlassLook.glass(style:reduceTransparency:)` returns `.regular` or `.identity` for
  `.glassEffect(_:in:)` (pure rule: `NotchStyle.usesGlass(reduceTransparency:)`;
  `DesignTokens.GlassLook.usesGlass(style:reduceTransparency:)` returns the Bool). `DesignTokens.Glass` is a
  typealias of `GlassLook` (early-draft name); inside `DesignTokens` the SwiftUI type is `SwiftUI.Glass`.
  Animations: `DesignTokens.Motion.open` / `.close` / `.contentFadeIn` (§A.2).

---

## E. Claude session state machine (claude-core, `SessionStore.apply`)

### E.1 Transitions

| Event (hook unless noted) | Condition | New phase / effect |
|---|---|---|
| SessionStart | new id | create `.idle`, row hidden until first prompt if host is Claude Desktop (pre-warm) ⇒ `visibility = .hiddenUntilFirstPrompt`; set `sessionTitle` candidate; `transcriptRefreshNeeded` |
| SessionStart | `source == "resume"/"clear"/"compact"` on known id | keep row; `clear` resets titles/firstPrompt |
| UserPromptSubmit | – | `.working`; clears `lastError`; sets `firstPrompt` once; hidden-until-first-prompt ⇒ visible (`sessionAppeared`); `titleGenerationNeeded` if `TitleResolver.needsGeneration` |
| PreToolUse | tool == `AskUserQuestion` | `.needsInput(.question)` |
| PreToolUse / PostToolUse / PostToolUseFailure / SubagentStart / PreCompact / PostCompact | phase ≠ `.done` / `.idle` **or** there is an unresolved pending permission | `.working` (**#98 rule:** after Stop, late PostToolUse does *not* revive the session) |
| PermissionRequest | visible session, not subagent (`agent_id` absent) | add `PermissionRequest`; `.needsInput(.permission)`; `permissionAdded` |
| PermissionRequest | hidden / subagent / internal | `replyPassthrough` (hook shows native prompt) |
| PostToolUse / PostToolUseFailure / PermissionDenied | a pending permission of this session whose `tool_name` + `tool_input` match (no `tool_use_id` on PermissionRequest) | remove it (`permissionRemoved` + `replyPassthrough`); phase `.working` (or `.done` for PermissionDenied if Stop follows) |
| `permissionAnswered` (app) | – | remove request; `.working` if allow, stays `.working` on deny (Claude continues) |
| `permissionConnectionClosed` | – | remove request; if no other pending ⇒ `.working` |
| Notification | `notification_type` ∈ `NotificationType.needsInput` and no pending permission | `.needsInput(.permission)` if `permission_prompt`, else `.question` |
| Notification | `idle_prompt` | `.done` |
| Stop | – | `.done`; store `lastAssistantPreview` (first 140 chars); remove all pending permissions (`replyPassthrough`) |
| StopFailure | – | `.done` + `lastError = error` |
| SubagentStart / SubagentStop | – | `activeSubagents` ± 1 (clamped ≥ 0); never a row |
| SessionEnd | – | remove session + its permissions (`sessionRemoved`) |
| `agentsSnapshot` | per matching `sessionId` | `status=busy` ⇒ `.working` (unless needsInput); `status=waiting` ⇒ `.needsInput(waitingFor contains "permission" ? .permission : .question)` only if no hook-driven needsInput already; `status=idle` && phase `.working` for > 10 s since last hook ⇒ `.done`; background `state` maps working/blocked/done; failed/stopped ⇒ remove; fill `agentsName` candidate |
| `agentsSnapshot` | known session whose pid is not listed, snapshot is non-empty and session older than 30 s | nothing (liveness decides) |
| `processExited(pid)` | – | remove every session with that pid |
| `transcript(id, signals)` | – | update title candidates; `interrupted && phase == .working` ⇒ `.done` |
| `titleGenerated` | – | set `generated` candidate |
| `tick` | phase `.working` and no event for 10 min | `isStale = true` (cleared by any event) |
| `hook(.statusLine)` | – | update `usage` (`UsageLimits.fromStatusLine`), `usageUpdated` |

After every applied event the store recomputes `title = TitleResolver.resolve(...)`. It emits
`phaseChanged` only on a real phase change.

### E.2 Visibility (hidden sessions never create rows, popups or permission cards)

* `context.isInternal` (SUPERNOTCH_INTERNAL=1, our own Haiku and `claude agents` calls) gives `.hiddenInternal`.
* `context.isPrintMode`, `entrypoint` starting with `sdk`, or `CLAUDE_CODE_ENTRYPOINT == "sdk-*"` gives
  `.hiddenHeadless`.
* Events with `agent_id` (inside a subagent) update only the parent's `activeSubagents`/`updatedAt`.
* Remote (`isRemote`) sessions are ignored entirely.

### E.3 Drift correction and liveness (claude-app drives, Core decides)

* `AgentsPoller` runs `<claudeExecutablePath or "claude"> agents --json --all` with
  `SUPERNOTCH_INTERNAL=1`:
  * at launch, on wake, and every 20 s **only while sessions exist**;
  * with a 5 s timeout;
  * and it gives up after 3 failures (the CLI is too old: log it and keep hooks-only).
* `SessionFileWatcher`: a `DispatchSource` vnode watcher on `<config>/sessions/`, whose `<pid>.json` files
  are undocumented. A file removal hints at a process exit, which is confirmed with `kill(pid, 0)`.
* Liveness: every 10 s while sessions exist, `kill(pid, 0) == -1 && errno == ESRCH`, or a changed start
  time (`proc_pidinfo` `PROC_PIDTBSDINFO`), gives `processExited`.
* Desktop sessions without a pid: liveness follows `com.anthropic.claudefordesktop` running. If it quits,
  all its sessions are removed.

### E.4 Title resolution

This follows REQUIREMENTS and `TitleResolver`. The order is:

1. `custom-title` (transcript)
2. `ai-title` (transcript)
3. `session_title` (SessionStart)
4. `claude agents` `name` (unless it is a default name like `repo-3f`)
5. the Haiku-generated title
6. the first prompt (truncated)
7. the project name

Haiku generation (claude-app `ClaudeTitleGenerator`):
* It runs at most once per session, is cached in `SuperNotchPaths.titleCache`, and only runs if
  `generateTitlesWithHaiku`. Titles are never written back.
* The command is:
  ```
  claude -p --model haiku --no-session-persistence --max-turns 1 --output-format text "<prompt>"
  ```
  * It runs with `cwd` = a fresh empty temp dir, env `SUPERNOTCH_INTERNAL=1`, a 20 s timeout, and at most
    2 concurrent calls.
  * Prompt: "Summarise this coding task as a 2–4 word title. Reply with the title only.\n\n<text>".
  * The output goes through `TitleResolver.shorten`. On failure, keep the fallback.

---

## F. Engineering rules

### F.1 Energy and performance

* **No always-on timers** except the clipboard `changeCount` poll (0.5 s, `tolerance` 0.2 s). Everything
  else is event-driven, or runs only while needed (the agents poller and liveness only while sessions exist).
* **Animations** (pulse, visualizer, progress `TimelineView`) run only while visible. Cap them at 30 fps
  with `TimelineView(.animation(minimumInterval: 1/30))`. Stop them when collapsed, when paused, or when
  the notch is hidden.
* **Mouse monitors:** global `mouseMoved` monitors only do rect checks. Do not allocate per event.
* **AppleScript** (Spotify) runs on one serial background queue, never on the main thread, and only after
  `NSRunningApplication.runningApplications(withBundleIdentifier:)` confirms Spotify is running.
  Otherwise it would launch Spotify.
* **Target:** < 0.5 % CPU when idle, and zero wakeups from SuperNotch while idle apart from the clipboard
  poll.

### F.2 Logging

The logging API lives in `App/Log.swift` (FOUNDATION):

```swift
nonisolated enum Log {
    static let subsystem = "io.github.snakez3101.supernotch"
    static let app, notch, claude, ipc, media, shelf, clipboard, settings, system: Logger
}
```

* Use `Log.claude.debug("…")`, and `privacy: .public` only for non-personal values.
* Never log prompts, file contents or clipboard contents.
* Core has no logging. It returns errors or values.
* The hook logs to `~/Library/Logs/SuperNotch/hook.log` only when `SUPERNOTCH_HOOK_DEBUG=1`.

### F.3 Error handling

* Core throws typed errors (`struct …Error: Error, Sendable`) or returns optionals. It never uses
  `fatalError`, `try!`, `!`, or `precondition` on external input.
* App: failures degrade gracefully and are shown as status in Settings (e.g. `hookStatus`,
  `automationPermission`). Never show an `NSAlert` from a background event.
* External formats (hook payloads, transcripts, `agents --json`, Spotify output) are always decoded
  tolerantly. Unknown fields and events are ignored.

### F.4 macOS compile-safety checklist (the app target is only type-checked on CI)

1. Import exactly what you use: `import AppKit`, `import SwiftUI`, `import Observation` (for `@Observable`
   outside SwiftUI files), `import Carbon.HIToolbox`, `import ServiceManagement`, `import QuickLookThumbnailing`,
   `import UniformTypeIdentifiers`, `import os`, and `import SuperNotchCore` in every file that uses Core
   types.
2. With `defaultIsolation(MainActor)`:
   * Code called from background queues, `DispatchSource` handlers, Carbon C callbacks or `@Sendable`
     closures must be `nonisolated`, or hop with `Task { @MainActor in … }` or
     `DispatchQueue.main.async`.
   * C callbacks (`EventHandlerUPP`, `CGEventTap`) must be `@convention(c)` closures that capture nothing.
     Pass `self` via `Unmanaged.passUnretained(self).toOpaque()`.
3. **Never force-unwrap optional AppKit properties:**
   * `NSScreen.main`, `auxiliaryTopLeftArea`/`auxiliaryTopRightArea`, `deviceDescription[.init("NSScreenNumber")]`
   * `NSImage(named:)`, `NSImage(systemSymbolName:accessibilityDescription:)`
   * `NSAppleScript(source:)`
   * `NSSharingService(named:)`
   * `NSRunningApplication(...)`
   * `FileManager.urls(...).first`
4. **`@Observable` classes:**
   * Declare `final class X` with `@Observable` from the Observation module. SwiftUI views read them via
     `@Environment(X.self) private var x`.
   * For bindings, use `@Bindable var x = x` inside `body`.
   * Do not combine `@Observable` with `ObservableObject` or `@Published`.
   * Mark properties that must not trigger updates `@ObservationIgnored`. Use it for timers, monitors and
     tokens, and for any `var` in a class where you implement `deinit`.
5. **`deinit` is nonisolated.** Do not touch MainActor state in `deinit` of a MainActor class. Put cleanup
   in `stop()`. `NotchHoldToken` releases via a nonisolated-safe closure.
6. **Liquid Glass APIs (macOS 26):**
   * `.glassEffect(_ glass: Glass = .regular, in: some Shape)`, `Glass.regular`, `.clear`, `.identity`,
     `.tint(_:)`, `.interactive()`
   * `GlassEffectContainer(spacing:) { … }`
   * `.glassEffectID(_:in:)` with `@Namespace`
   * `.buttonStyle(.glass)` / `.glassProminent`
   * AppKit: `NSGlassEffectView` (`contentView`, `cornerRadius`, `tintColor`)
   * No availability checks are needed, since the minimum target is 26.0.
7. **SwiftUI on macOS:**
   * No `UIKit` types. Use `.onKeyPress(.return)` / `.onKeyPress(.escape)` (macOS 14+), and
     `.focusable()` + `@FocusState`.
   * `.contentShape(Rectangle())` for hit areas.
   * `Color(nsColor:)`, `Image(nsImage:)`, `.foregroundStyle`.
   * Avoid deprecated APIs such as `.foregroundColor` and `.onChange(of:perform:)` with a single-parameter
     closure. Use `.onChange(of: x) { old, new in }` or `.onChange(of: x) { }`.
8. **`NSPanel` subclass:** override `canBecomeKey` / `canBecomeMain` as `override var … : Bool { … }`. Use
   `NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)` for the level.
9. **`NSHostingView` subclass:** `required init(rootView:)` must be declared when subclassing, as
   `required init(rootView: Content)` (`override` is implied and only produces a warning), and
   `required init?(coder:)` must be declared too.
10. **AppleScript:** `NSAppleScript.executeAndReturnError(_:)` takes an
    `AutoreleasingUnsafeMutablePointer<NSDictionary?>?`. Declare `var error: NSDictionary?` and pass
    `&error`. `NSAppleScript` is not `Sendable`: create it and use it on the same serial queue.
11. **Carbon hot keys:**
    * `RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType, id: UInt32), GetApplicationEventTarget(), 0, &ref)`
    * The signature is a four-char `OSType`, e.g. `0x534E4F54` ("SNOT").
12. **Process spawning:** `Process` with `executableURL`, `arguments` and `environment`. Always set
    `standardInput = FileHandle.nullDevice`. Read pipes before `waitUntilExit`, or use `terminationHandler`,
    to avoid a deadlock on full pipes.
13. **Paths:** use `SuperNotchPaths(homeDirectory: NSHomeDirectory())`. Never hard-code `/Users/...`.
14. **Name collisions:** see §C "Type name uniqueness". Avoid the names `Session`, `Tab` and `Item` for new
    app types, because Core already exports `Session`.
15. **`#Preview` blocks:** allowed, but keep them trivial (they must type-check).
16. **Always parse locally.** Before finishing, run `swiftc -parse` over your files. It catches syntax
    errors without an SDK:
    `find Sources/SuperNotch -name '*.swift' -print0 | xargs -0 swiftc -parse`.

### F.5 Style

* `.swift-format` is in the repo root: 4 spaces and 120 columns. No force-unwrap, no force-try, and no
  IUOs in new code.
* Lint is non-blocking in CI.
* Every file starts with a comment naming its owner stream. Stubs carry `TODO(<stream>)`.

---

## G. Tests, CI, release

### G.1 Tests (swift-testing, `import Testing`; they run on Linux and macOS)

| Stream | Must test |
|---|---|
| claude-core | State machine sequences, one fixture per known bug: #98 late PostToolUse, interrupt marker, permission resolution by PostToolUse and PermissionDenied, subagent counter, Desktop pre-warm, hidden internal/headless. Also: the settings merger (idempotent; refuses invalid JSON; keeps key order and unknown keys; uninstall; statusLine wrap/unwrap), titles, the transcript tail, agents decoding, NDJSON framing, decision JSON, and hook fail-open (run the hook binary with no socket → exit 0, empty stdout) |
| notch-shell | `NotchGeometry` (14″/16″ fixtures, nil aux areas), `HoverIntent` (dwell, grace, slack), `PopupPolicy` (fullscreen, focus-aware, expanded queueing) |
| media | `SpotifyScriptParser` (normal, ad, episode, local file, not running), `PlaybackSnapshot.position(at:)` |
| shelf-clipboard | `RetentionPolicy` (pinned never expire, off, boundaries), `ClipboardCaptureFilter` (concealed, transient, own marker, ignored apps), dedupe/limit |
| FOUNDATION | `AppSettings` tolerant decoding/defaults, `KeyCombo`, `SuperNotchPaths`, `SocketPath` |

Fixtures are read with `Bundle.module.url(forResource:withExtension:subdirectory:)` from `Fixtures/<stream>/`.

### G.2 CI (`.github/workflows/ci.yml`)

Triggers: push to any branch, and pull requests. Concurrency: `ci-${{ github.ref }}` with cancel-in-progress.

1. **linux** (`ubuntu-24.04`, container `swift:6.3.3-noble`, about 2 min):
   * `swift build`, `swift build --product supernotch-hook`, `swift test`
   * `swiftc -parse` over `Sources/SuperNotch`
   * `swift format lint` (non-blocking)
   * `actionlint` is optional.
2. **macos** (`needs: linux`, `runs-on: macos-26`):
   * Select the newest `/Applications/Xcode_26*.app`. Fail with a clear message if there is none.
   * `swift build -c release --arch arm64` (log uploaded on failure), then `swift test`.
   * Import the signing certificate from secrets if they are present, otherwise sign ad-hoc.
   * `Scripts/package_app.sh`, then `--smoke-test`.
   * Upload `dist/SuperNotch-<ver>-arm64.zip` as an artifact (`archive: false`).
3. **release.yml:** on tags `v*`, the same macOS steps, then `gh release create` with the zip and DMG.

### G.3 Packaging, signing, install

* **`Scripts/package_app.sh`:**
  1. Build release arm64.
  2. Assemble `dist/SuperNotch.app` (`MacOS/SuperNotch`, `Helpers/supernotch-hook`, `Info.plist` with the
     version, `AppIcon.icns` from `Resources/AppIcon.png`).
  3. Sign inside-out with `$SIGN_IDENTITY`, falling back to ad-hoc `-`. No hardened runtime.
  4. `codesign --verify --strict`, and print the designated requirement.
  5. Package the zip via `ditto`, and the DMG via `hdiutil` UDZO.
* **`Scripts/make_selfsigned_cert.sh`:** the user runs it once on their Mac. It creates the "SuperNotch
  Self-Signed" code-signing identity with openssl (`-legacy` p12), imports it into the login keychain, and
  prints the two values to paste into the GitHub secrets `SIGNING_P12_BASE64` and `SIGNING_P12_PASSWORD`.
  A stable certificate means Automation and Accessibility grants survive updates.
* **`Scripts/install.sh`:** `curl -fsSL …/install.sh | bash`.
  1. Downloads the latest release zip via the GitHub API.
  2. Quits a running SuperNotch.
  3. Installs to `/Applications` with `ditto`, then runs `xattr -dr com.apple.quarantine` and launches it.
* **First launch without install.sh:** System Settings › Privacy & Security › "Open Anyway".
  Right-click › Open no longer bypasses Gatekeeper on macOS 15 and later.

---

## H. Open risks (track in PRs)

1. **No local macOS compile.** Mitigation: the §F.4 checklist, `swiftc -parse`, and small commits.
2. **Glass may look foggy in a non-key panel.** Mitigation: the black gradient hides most of it, and the
   solid-black style is available. Test on a real Mac.
3. **Permission race** between our card and the native terminal or Desktop prompt. Mitigation: resolve
   the card via PostToolUse, PermissionDenied or a connection close.
4. **`claude agents --json`** coverage of Desktop sessions is unverified. Mitigation: hooks first, and the
   poller is optional.
5. **The `claude://` deep link to Desktop sessions is undocumented.** Mitigation: fall back to activating
   the app.
6. **Global mouse monitors and the drag detector may need Accessibility on 26/27.** Mitigation: detect it
   and show it in onboarding.
7. **Self-signed CI signing** may fail headless. Mitigation: ad-hoc fallback, so CI stays green.
