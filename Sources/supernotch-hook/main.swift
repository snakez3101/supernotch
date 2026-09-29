// Owner: claude-core. Entry point of the Claude Code hook helper (SPEC §D.7).
//
//   supernotch-hook hook         Claude Code hook (reads the hook JSON from stdin)
//   supernotch-hook statusline   statusLine bridge (forwards rate limits, then runs the original statusLine)
//   supernotch-hook --version
//
// FAIL OPEN: whatever happens, exit 0 and print nothing unless we have a real permission decision.

import Foundation
import SuperNotchCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

signal(SIGPIPE, SIG_IGN)

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "--version", "-v":
    print(HookRunner.version)
case "statusline":
    HookRunner.runStatusLine()
default:  // "hook" (or no argument, for robustness)
    HookRunner.runHook()
}
exit(0)
