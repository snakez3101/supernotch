import Foundation

// Owner: claude-core. Signature is contract (SPEC §D.1); the rule set may grow.
// A baseline implementation exists so the permission card works before claude-core lands.

public enum DangerousCommandClassifier {
    /// Assesses a tool call. Dangerous ⇒ card turns red and Allow needs a second confirming click.
    public static func assess(toolName: String, input: JSONValue) -> DangerAssessment {
        switch toolName {
        case "Bash", "PowerShell":
            return assess(command: input["command"]?.stringValue ?? "")
        default:
            return .safe
        }
    }

    /// Heuristic, intentionally conservative (false positives only cost one extra click).
    public static func assess(command: String) -> DangerAssessment {
        let text = " " + command.lowercased().replacingOccurrences(of: "\n", with: " ") + " "
        var reasons: [String] = []
        func has(_ needle: String) -> Bool { text.contains(needle) }

        if has(" rm ") || has(";rm ") || has("&&rm ") {
            let recursive = has(" -rf") || has(" -fr") || has(" -r ") || has("--recursive")
            if recursive { reasons.append("recursive delete") }
        }
        if has(" sudo ") { reasons.append("sudo") }
        if has("git push") && (has(" --force") || has(" -f ") || has("--force-with-lease") || has(" +")) {
            reasons.append("force push")
        }
        if has("git reset --hard") { reasons.append("hard reset") }
        if has("git clean -f") || has("git clean -xf") || has("git clean -xdf") || has("git clean -df") {
            reasons.append("git clean")
        }
        if has(" mkfs") || has(" dd if=") || has(" of=/dev/") { reasons.append("disk write") }
        if has("chmod -r 777") || has("chmod 777 /") { reasons.append("chmod 777") }
        if has("| sh ") || has("| bash ") || has("|sh ") || has("|bash ") { reasons.append("pipe to shell") }
        if has(":(){") { reasons.append("fork bomb") }
        if has(" drop table ") || has(" drop database ") { reasons.append("drop database") }
        if has(" > /dev/sd") || has("diskutil erase") { reasons.append("disk erase") }
        return DangerAssessment(isDangerous: !reasons.isEmpty, reasons: reasons)
    }
}
