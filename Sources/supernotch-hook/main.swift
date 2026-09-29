// Owner: claude-core. Entry point of the Claude Code hook helper (SPEC §D.7).
//
//   supernotch-hook hook                          Claude Code hook (reads the hook JSON from stdin)
//   supernotch-hook statusline [--wrap '<cmd>']   statusLine bridge (forwards rate limits, then runs <cmd>)
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

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "--version", "-v", "version":
    StandardOutput.write(HookRunner.version + "\n")
case "statusline":
    HookRunner.runStatusLine(arguments: Array(arguments.dropFirst()))
default:  // "hook" (or anything else, for robustness)
    HookRunner.runHook()
}
exit(0)
