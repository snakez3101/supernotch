# claude-app → claude-core requests

Owner: claude-app. Things the app side needs from `Sources/SuperNotchCore/{Claude,IPC}` and the hook.
Each item says what the app does meanwhile, so nothing is blocked.

1. **Seed persisted usage into the store.** `SessionStore.usage` can only be set by a StatusLine envelope, so
   the value restored from `UserDefaults` (`sn.claude.usage`, SPEC §D.9) cannot live in the store.
   Request: `public mutating func restoreUsage(_ usage: UsageLimits?)` (no effects).
   Meanwhile: `ClaudeSessionsModel` keeps a separate `restoredUsage` and publishes `store.usage ?? restoredUsage`.

2. **AskUserQuestion arrives as a PermissionRequest (critique C2).** It must never become an Allow/Deny card.
   Request: in `.permissionRequest`, for `AskUserQuestion` emit `replyPassthrough`, set `.needsInput(.question)`,
   add no `PermissionRequest`.
   Meanwhile: the app filters question tools out of `permissions`, replies `decision: nil` at once and pops the
   red question peek (`ClaudeSessionsModel.isQuestionTool`).

3. **Title generation timing (C5 / SPEC §E.4).** `titleGenerationNeeded` fires on the first UserPromptSubmit,
   before Claude Code writes its ai-title.
   Meanwhile: the app waits until 20 s after the session started, re-reads the transcript and generates only
   if `TitleResolver.needsGeneration` is still true.

4. **Stale permission cards after a native deny (C4).** PermissionDenied only fires in auto mode.
   Request: also resolve a session's pending permissions (with `replyPassthrough`) on a main-thread
   UserPromptSubmit, StopFailure, Notification `idle_prompt` and `transcript.interrupted`.
   The app already withdraws cards on every `permissionRemoved` and on hook EOF.

5. **Executable path from the hook (C7).** Please report the real `claude` binary (`proc_pidpath` / first
   string of `KERN_PROCARGS2`), not `node`. The app only accepts a hint whose basename is `claude` or that lives
   in `…/claude/versions/` and otherwise resolves `claude` itself.

6. **Config folder discovery (C13).** `context.claudeConfigDir` is rarely set. The app derives the folder from
   `transcript_path` (`<config>/projects/…`) and scans launchd / login shell / `settings.json env` / `~/.claude*`.
   No Core change needed; FYI.

7. **Optional: persist sessions across app restarts (C20).** `Codable` on `Session`/`SessionPhase` would let
   the app keep green rows after an update. Not required for v1.
