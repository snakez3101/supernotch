import Foundation

// Owner: claude-core. Signature is contract (SPEC §D.1); the rule set may grow.
//
// Heuristic and intentionally conservative: a false positive costs the user one extra click ("Confirm
// allow"), a false negative lets a destructive command through with a single click. The command is split
// into simple commands at `;`, `&&`, `||`, `|`, `&`, newlines, `$(`, backticks and parentheses (quotes are
// NOT honoured for splitting, so text inside quotes can only add warnings, never hide one). Wrappers such as
// `sudo`, `env`, `nohup`, `xargs`, `sh -c` and leading `VAR=value` assignments are looked through.

public enum DangerousCommandClassifier {
    /// Short chip labels shown on the permission card.
    public enum Reason {
        public static let recursiveDelete = "recursive delete"
        public static let delete = "delete"
        public static let sudo = "sudo"
        public static let forcePush = "force push"
        public static let remoteBranchDelete = "remote branch delete"
        public static let hardReset = "hard reset"
        public static let gitClean = "git clean"
        public static let discardChanges = "discard changes"
        public static let branchDelete = "branch delete"
        public static let stashDrop = "stash drop"
        public static let historyRewrite = "history rewrite"
        public static let diskWrite = "disk write"
        public static let diskErase = "disk erase"
        public static let chmod777 = "chmod 777"
        public static let recursiveChown = "recursive chmod/chown"
        public static let pipeToShell = "pipe to shell"
        public static let forkBomb = "fork bomb"
        public static let dropTable = "drop table"
        public static let deleteAllRows = "delete all rows"
        public static let shutdown = "shutdown"
        public static let killAll = "kill all"
        public static let crontabRemoval = "crontab removal"
        public static let systemSetting = "system setting"
        public static let remoteDestroy = "irreversible remote action"
        public static let sensitiveFile = "sensitive file"
    }

    /// Assesses a tool call. Dangerous ⇒ card turns red and Allow needs a second confirming click.
    public static func assess(toolName: String, input: JSONValue) -> DangerAssessment {
        switch toolName {
        case "Bash", "PowerShell":
            return assess(command: input["command"]?.stringValue ?? "")
        case "Write", "Edit", "MultiEdit", "NotebookEdit":
            let path = input["file_path"]?.stringValue ?? input["notebook_path"]?.stringValue ?? ""
            return isSensitivePath(path) ? DangerAssessment(isDangerous: true, reasons: [Reason.sensitiveFile]) : .safe
        default:
            return .safe
        }
    }

    public static func assess(command: String) -> DangerAssessment {
        var reasons: [String] = []
        func add(_ reason: String) { if !reasons.contains(reason) { reasons.append(reason) } }

        analyze(command, depth: 0, add: add)

        // Whole-text checks (SQL inside psql -c "…", heredocs, fork bombs).
        let text = collapse(command.lowercased())
        if text.replacingOccurrences(of: " ", with: "").contains(":(){:|:&};:")
            || text.replacingOccurrences(of: " ", with: "").contains(":(){")
        {
            add(Reason.forkBomb)
        }
        for phrase in ["drop table", "drop database", "drop schema", "truncate table"] where text.contains(phrase) {
            add(Reason.dropTable)
        }
        let sqlContext = [
            "psql", "mysql", "mariadb", "sqlite", "sql", "duckdb", "clickhouse", "cqlsh", "snowsql", "bq query",
            "db execute", "--execute",
        ]
        if let range = text.range(of: "delete from "), sqlContext.contains(where: { text.contains($0) }) {
            let rest = text[range.upperBound...]
            let statement = rest.split(separator: ";", maxSplits: 1).first.map(String.init) ?? String(rest)
            if !statement.contains(" where ") { add(Reason.deleteAllRows) }
        }
        return DangerAssessment(isDangerous: !reasons.isEmpty, reasons: reasons)
    }

    /// File-editing tools writing to system locations, credentials, shell start-up files, git hooks or
    /// Claude Code's own settings (which could grant further permissions).
    public static func isSensitivePath(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let lower = path.lowercased()
        let prefixes = [
            "/etc/", "/private/etc/", "/system/", "/usr/", "/bin/", "/sbin/", "/library/", "/var/db/", "/boot/",
        ]
        if prefixes.contains(where: { lower.hasPrefix($0) }) { return true }
        let fragments = [
            "/.ssh/", "/.aws/", "/.gnupg/", "/.kube/config", "/.docker/config.json", "/.netrc", "/library/keychains/",
            "/.git/hooks/", "/.claude/settings", "/.claude.json", "/.config/gh/hosts.yml", "/.npmrc", "/.pypirc",
        ]
        if fragments.contains(where: { lower.contains($0) }) { return true }
        let rcFiles = [
            "/.zshrc", "/.zshenv", "/.zprofile", "/.bashrc", "/.bash_profile", "/.profile", "/.config/fish/config.fish",
        ]
        return rcFiles.contains(where: { lower.hasSuffix($0) })
    }

    // MARK: - Lexer

    enum Separator { case start, sequence, pipe, substitution }

    struct Segment {
        var words: [String]
        var separator: Separator
    }

    /// Splits a command line into simple commands. Quote characters are dropped from words but do not
    /// protect separators; a backslash makes the next character literal.
    static func segments(_ command: String) -> [Segment] {
        var result: [Segment] = []
        var words: [String] = []
        var word = ""
        var separator = Separator.start
        var backtickOpen = false

        func endWord() {
            if !word.isEmpty { words.append(word) }
            word = ""
        }
        func endSegment(next: Separator) {
            endWord()
            if !words.isEmpty { result.append(Segment(words: words, separator: separator)) }
            words = []
            separator = next
        }

        let characters = Array(command)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
            switch character {
            case "\\":
                if let next {
                    if next == "\n" {
                        endWord()
                    } else {
                        word.append(next)
                    }
                    index += 2
                    continue
                }
            case "'", "\"":
                break  // dropped
            case " ", "\t", "\r":
                endWord()
            case "\n", ";":
                endSegment(next: .sequence)
            case "&":
                if next == "&" { index += 1 }
                if next == ">" {  // &> redirection
                    endWord()
                    words.append(">")
                    index += 2
                    continue
                }
                endSegment(next: .sequence)
            case "|":
                if next == "|" {
                    index += 1
                    endSegment(next: .sequence)
                } else {
                    if next == "&" { index += 1 }
                    endSegment(next: .pipe)
                }
            case "$" where next == "(":
                index += 1
                endSegment(next: .substitution)
            case "`":
                backtickOpen.toggle()
                endSegment(next: backtickOpen ? .substitution : .sequence)
            case "(":
                endSegment(next: .substitution)
            case ")":
                endSegment(next: .sequence)
            case ">", "<":
                endWord()
                var token = String(character)
                if next == ">" || next == "&" {  // `>>`, `>&` / `<&` (fd duplication, not a separator)
                    token.append(next ?? ">")
                    index += 1
                }
                words.append(token)
            default:
                word.append(character)
            }
            index += 1
        }
        endSegment(next: .sequence)
        return result
    }

    // MARK: - Analysis

    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh", "pwsh", "powershell"]
    static let interpreters: Set<String> = shells.union([
        "python", "python2", "python3", "perl", "ruby", "node", "php", "osascript", "eval", "source", ".",
        "invoke-expression", "iex",
    ])
    static let downloaders: Set<String> = [
        "curl", "wget", "fetch", "http", "https", "invoke-webrequest", "iwr", "invoke-restmethod", "irm",
    ]
    static let rmLike: Set<String> = ["rm", "remove-item", "ri", "del", "erase", "rd"]
    static let rootish: Set<String> = [
        "/", "/*", "~", "~/", "~/*", "$home", "${home}", "$home/", "/usr", "/etc", "/system", "/library", "/bin",
        "/sbin", "/var", "/users", "/applications", "/opt",
    ]

    static func analyze(_ command: String, depth: Int, add: (String) -> Void) {
        guard depth < 4 else { return }
        var pipelineHasDownloader = false
        var previousProgram: String?
        for segment in segments(command) {
            if segment.separator != .pipe { pipelineHasDownloader = false }
            guard let (program, args) = unwrap(segment.words, depth: depth, add: add) else {
                previousProgram = nil
                continue
            }
            if interpreters.contains(program) && segment.separator == .pipe && pipelineHasDownloader {
                add(Reason.pipeToShell)
            }
            if downloaders.contains(program) {
                pipelineHasDownloader = true
                if segment.separator == .substitution, let previousProgram, interpreters.contains(previousProgram) {
                    add(Reason.pipeToShell)
                }
            }
            check(program: program, args: args, add: add)
            // `sh -c '…'`, `bash -c "…"`: analyse the script text too.
            if shells.contains(program),
                let flag = args.firstIndex(where: { ["-c", "-command", "/c"].contains($0.lowercased()) }),
                flag + 1 < args.count
            {
                analyze(args[(flag + 1)...].joined(separator: " "), depth: depth + 1, add: add)
            }
            previousProgram = program
        }
    }

    /// Strips assignments and wrapper commands; returns the real program (lowercased basename) and its args.
    static func unwrap(_ words: [String], depth: Int, add: (String) -> Void) -> (String, [String])? {
        var rest = words[...]
        while let first = rest.first {
            let lower = programName(first)
            if isAssignment(first) {
                rest = rest.dropFirst()
            } else if lower == "sudo" || lower == "doas" || lower == "pkexec" || lower == "run0" {
                add(Reason.sudo)
                rest = rest.dropFirst()
                rest = skipOptions(rest, withValue: ["-u", "-g", "-c", "-p", "-h", "-r", "-t", "-d", "-C", "-D", "-U"])
            } else if lower == "su" {
                add(Reason.sudo)
                if let flag = rest.firstIndex(where: { $0 == "-c" || $0 == "--command" }), flag + 1 < rest.endIndex {
                    analyze(rest[(flag + 1)...].joined(separator: " "), depth: depth + 1, add: add)
                }
                return nil
            } else if ["env", "command", "builtin", "exec", "nohup", "time", "caffeinate", "stdbuf", "unbuffer"]
                .contains(lower)
            {
                rest = skipOptions(rest.dropFirst(), withValue: ["-u", "-S", "-C", "-P", "-w"])
            } else if lower == "nice" || lower == "ionice" || lower == "timeout" || lower == "gtimeout" {
                rest = skipOptions(rest.dropFirst(), withValue: ["-n", "-c", "-s", "-k"])
                if lower.hasSuffix("timeout"), let duration = rest.first, duration.first?.isNumber == true {
                    rest = rest.dropFirst()
                }
            } else if lower == "xargs" || lower == "parallel" {
                rest = skipOptions(rest.dropFirst(), withValue: ["-n", "-I", "-i", "-P", "-L", "-s", "-d", "-E", "-a"])
            } else if lower == "watch" {
                rest = skipOptions(rest.dropFirst(), withValue: ["-n", "-d"])
            } else {
                break
            }
        }
        guard let first = rest.first else { return nil }
        return (programName(first), Array(rest.dropFirst()))
    }

    static func skipOptions(_ words: ArraySlice<String>, withValue: Set<String>) -> ArraySlice<String> {
        var rest = words
        while let first = rest.first, first.hasPrefix("-") || isAssignment(first) {
            rest = rest.dropFirst()
            if first == "--" { break }
            if withValue.contains(first) { rest = rest.dropFirst() }
        }
        return rest
    }

    static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        guard let head = name.first, head.isLetter || head == "_" else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    static func programName(_ word: String) -> String {
        var name = word
        while name.hasPrefix("\\") { name.removeFirst() }
        if let slash = name.lastIndex(of: "/"), name.index(after: slash) < name.endIndex {
            name = String(name[name.index(after: slash)...])
        }
        return name.lowercased()
    }

    /// Short option clusters ("-rf", "-Rv") and long options ("--recursive").
    static func hasShortFlag(_ args: [String], _ letters: Set<Character>) -> Bool {
        args.contains { arg in
            arg.hasPrefix("-") && !arg.hasPrefix("--") && arg.count > 1 && arg.dropFirst().contains(where: letters.contains)
        }
    }

    static func check(program: String, args: [String], add: (String) -> Void) {
        let lowerArgs = args.map { $0.lowercased() }
        switch program {
        case _ where rmLike.contains(program):
            let recursive =
                hasShortFlag(args, ["r", "R"]) || lowerArgs.contains("--recursive")
                || lowerArgs.contains("--no-preserve-root") || lowerArgs.contains("-recurse")
            if recursive {
                add(Reason.recursiveDelete)
            } else if lowerArgs.contains(where: rootish.contains) {
                add(Reason.delete)
            }
        case "shred", "srm":
            add(Reason.delete)
        case "find":
            if lowerArgs.contains("-delete") { add(Reason.recursiveDelete) }
            if let exec = lowerArgs.firstIndex(where: { ["-exec", "-execdir", "-ok", "-okdir"].contains($0) }),
                exec + 1 < args.count
            {
                check(program: programName(args[exec + 1]), args: Array(args[(exec + 2)...]), add: add)
            }
        case "mv":
            if lowerArgs.last == "/dev/null" { add(Reason.delete) }
        case "git":
            checkGit(lowerArgs, originalArgs: args, add: add)
        case "dd":
            if lowerArgs.contains(where: { $0.hasPrefix("of=") }) { add(Reason.diskWrite) }
        case "fdisk", "sfdisk", "gdisk", "parted", "wipefs", "format-volume", "clear-disk", "initialize-disk":
            add(Reason.diskErase)
        case _ where program.hasPrefix("mkfs") || program.hasPrefix("newfs"):
            add(Reason.diskErase)
        case "diskutil":
            let sub = lowerArgs.first ?? ""
            if sub.contains("erase") || sub.contains("zerodisk") || sub.contains("randomdisk")
                || sub.contains("partitiondisk") || sub.contains("reformat")
                || (sub == "apfs" && lowerArgs.dropFirst().first.map { $0.hasPrefix("delete") } == true)
            {
                add(Reason.diskErase)
            }
        case "chmod":
            let worldWritable = ["777", "0777", "a+rwx", "ugo+rwx", "o+w", "a+w", "o+rwx", "666", "0666"]
            if lowerArgs.contains(where: worldWritable.contains) { add(Reason.chmod777) }
            let recursive = hasShortFlag(args, ["R"]) || lowerArgs.contains("--recursive")
            if recursive && lowerArgs.contains(where: rootish.contains) { add(Reason.recursiveChown) }
        case "chown", "chgrp":
            let recursive = hasShortFlag(args, ["R"]) || lowerArgs.contains("--recursive")
            if recursive && lowerArgs.contains(where: rootish.contains) { add(Reason.recursiveChown) }
        case "shutdown", "reboot", "halt", "poweroff", "stop-computer", "restart-computer":
            add(Reason.shutdown)
        case "kill":
            if lowerArgs.contains("-1") { add(Reason.killAll) }
        case "crontab":
            if hasShortFlag(args, ["r"]) { add(Reason.crontabRemoval) }
        case "csrutil", "spctl":
            if lowerArgs.contains(where: { $0.contains("disable") }) { add(Reason.systemSetting) }
        case "nvram":
            if lowerArgs.contains(where: { $0.contains("=") || $0 == "-c" || $0 == "-d" }) { add(Reason.systemSetting) }
        case "set-executionpolicy":
            if lowerArgs.contains(where: { $0.contains("unrestricted") || $0.contains("bypass") }) {
                add(Reason.systemSetting)
            }
        case "terraform", "pulumi", "tofu":
            if lowerArgs.contains("destroy") { add(Reason.remoteDestroy) }
        case "kubectl", "helm":
            if lowerArgs.first == "delete" || lowerArgs.first == "uninstall" { add(Reason.remoteDestroy) }
        case "gh":
            if lowerArgs.count >= 2, lowerArgs[1] == "delete" { add(Reason.remoteDestroy) }
        case "aws":
            if lowerArgs.first == "s3",
                lowerArgs.contains("rb") || (lowerArgs.contains("rm") && lowerArgs.contains("--recursive"))
            {
                add(Reason.remoteDestroy)
            }
        case "docker", "podman":
            let joined = lowerArgs.joined(separator: " ")
            if joined.hasPrefix("system prune") || joined.hasPrefix("volume rm") || joined.hasPrefix("volume prune") {
                add(Reason.remoteDestroy)
            }
        case "npm", "pnpm", "yarn":
            if lowerArgs.first == "unpublish" { add(Reason.remoteDestroy) }
        default:
            break
        }
        // Redirection onto a raw disk device: `> /dev/disk2`, `>/dev/sda`.
        for (index, arg) in lowerArgs.enumerated() {
            let target: String
            if arg == ">" || arg == ">>" {
                guard index + 1 < lowerArgs.count else { continue }
                target = lowerArgs[index + 1]
            } else {
                continue
            }
            if ["/dev/sd", "/dev/disk", "/dev/rdisk", "/dev/nvme", "/dev/hd", "/dev/mmcblk"].contains(where: {
                target.hasPrefix($0)
            }) {
                add(Reason.diskWrite)
            }
        }
    }

    static func checkGit(_ args: [String], originalArgs: [String], add: (String) -> Void) {
        // Skip global options: -C <path>, -c <k=v>, --git-dir=…, --no-pager …
        var index = 0
        while index < args.count, args[index].hasPrefix("-") {
            if args[index] == "-c" || args[index] == "-C" { index += 1 }
            index += 1
        }
        guard index < args.count else { return }
        let sub = args[index]
        let rest = Array(args[(index + 1)...])
        let original = Array(originalArgs[(index + 1)...])
        switch sub {
        case "push":
            let force =
                rest.contains { $0 == "--force" || $0.hasPrefix("--force-with-lease") || $0 == "--force-if-includes" }
                || rest.contains("--mirror") || hasShortFlag(original, ["f"])
                || rest.contains { $0.hasPrefix("+") && $0.count > 1 }
            if force { add(Reason.forcePush) }
            if rest.contains("--delete") || hasShortFlag(original, ["d"])
                || rest.contains(where: { $0.hasPrefix(":") && $0.count > 1 })
            {
                add(Reason.remoteBranchDelete)
            }
        case "reset":
            if rest.contains("--hard") { add(Reason.hardReset) }
        case "clean":
            if hasShortFlag(original, ["f"]) || rest.contains("--force") { add(Reason.gitClean) }
        case "checkout":
            if rest.contains("--") || rest.contains(".") || rest.contains("--force") || hasShortFlag(original, ["f"]) {
                add(Reason.discardChanges)
            }
        case "restore":
            let stagedOnly =
                (rest.contains("--staged") || hasShortFlag(original, ["S"]))
                && !(rest.contains("--worktree") || hasShortFlag(original, ["W"]))
            if !stagedOnly { add(Reason.discardChanges) }
        case "branch":
            if original.contains("-D") || (rest.contains("--delete") && rest.contains("--force")) {
                add(Reason.branchDelete)
            }
        case "stash":
            if rest.first == "drop" || rest.first == "clear" { add(Reason.stashDrop) }
        case "filter-branch", "filter-repo":
            add(Reason.historyRewrite)
        default:
            break
        }
    }

    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).joined(separator: " ")
    }
}
