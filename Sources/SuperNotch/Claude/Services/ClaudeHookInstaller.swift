// Owner: claude-app. Hook installer IO (SPEC §D.6). The merge logic is pure Core (`HookSettingsMerger`);
// this file only does file IO: read → plan → backup → re-read → atomic write → manifest.
// Blocking; always call from a background task.

import Foundation
import SuperNotchCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// One settings.json SuperNotch manages. The primary target carries the statusLine bridge and uses the
/// manifest the hook reads (`SuperNotchPaths.hookManifest`); extra config folders get hooks only.
nonisolated struct ClaudeHookInstallTarget: Sendable, Hashable {
    var configDirectory: String
    var manifestPath: String
    var isPrimary: Bool

    var settingsFile: String { ClaudePaths(configDirectory: configDirectory).settingsFile }
}

nonisolated struct ClaudeHookInstallOutcome: Sendable, Hashable {
    var status: ClaudeHookStatus
    /// Short human message ("Hooks installed.", "Nothing to change.").
    var message: String
    /// Backup of the previous settings.json, if one was written.
    var backupPath: String?
}

nonisolated enum ClaudeHookBinarySync: Sendable, Hashable {
    case upToDate
    case updated
    /// Neither the app bundle nor the build folder contains `supernotch-hook`.
    case missingSource
    case failed(String)
}

nonisolated struct ClaudeInstallerError: Error, Sendable, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

nonisolated struct ClaudeHookInstaller: Sendable {
    let paths: SuperNotchPaths
    let appVersion: String
    /// Backups kept per settings file (oldest are deleted).
    var maxBackups = 20

    init(paths: SuperNotchPaths, appVersion: String) {
        self.paths = paths
        self.appVersion = appVersion
    }

    // MARK: - Targets and specs

    func primaryTarget(configDirectory: String) -> ClaudeHookInstallTarget {
        ClaudeHookInstallTarget(configDirectory: configDirectory, manifestPath: paths.hookManifest, isPrimary: true)
    }

    /// Extra config folder (reported by a hook via CLAUDE_CONFIG_DIR). Separate manifest, no statusLine.
    func secondaryTarget(configDirectory: String) -> ClaudeHookInstallTarget {
        let tag = Self.fileTag(for: configDirectory)
        return ClaudeHookInstallTarget(
            configDirectory: configDirectory, manifestPath: paths.appSupport + "/hook-manifest.\(tag).json",
            isPrimary: false)
    }

    func spec(for target: ClaudeHookInstallTarget, claudeVersion: ClaudeVersion?, wrapStatusLine: Bool)
        -> HookInstallSpec
    {
        var spec = HookInstallSpec.make(
            hookBinaryPath: paths.hookBinary, claudeVersion: claudeVersion,
            wrapStatusLine: wrapStatusLine && target.isPrimary)
        // Version unknown right now (CLI not found, e.g. before the first hook reported it): keep the event set of
        // the last install instead of calling it "needs repair" and stripping the extended events.
        if claudeVersion == nil, let manifest = loadManifest(at: target.manifestPath),
            manifest.settingsFile == target.settingsFile
        {
            let previous = manifest.events.map { HookEventName(rawValue: $0) }
            if !previous.isEmpty, Set(previous).isSuperset(of: spec.events) { spec.events = previous }
        }
        return spec
    }

    /// Exactly the JSON our entries add (onboarding / settings preview), incl. the wrapped status line.
    func preview(for target: ClaudeHookInstallTarget, spec: HookInstallSpec) -> String {
        let settings = (try? readSettings(at: settingsURL(for: target))).flatMap { try? parse($0) }
        var original: String?
        if let status = settings?["statusLine"], !HookSettingsMerger.isOurs(status, marker: spec.marker) {
            original = status["command"]?.stringValue
        } else {
            // Ours is installed: the user's command is in the manifest, or inside our `--wrap '<orig>'` argument.
            original =
                loadManifest(at: target.manifestPath)?.originalStatusLineCommand
                ?? settings?["statusLine"].flatMap { HookSettingsMerger.recoverWrappedStatusLine($0) }?["command"]?
                .stringValue
        }
        return HookSettingsMerger.previewEntries(spec: spec, originalStatusLineCommand: original)
            .serialized(pretty: true)
    }

    // MARK: - Status

    func status(of target: ClaudeHookInstallTarget, spec: HookInstallSpec) -> ClaudeHookStatus {
        let settings: JSONValue?
        do {
            settings = try parse(readSettings(at: settingsURL(for: target)))
        } catch {
            return .failed("\(error)")
        }
        let state = HookSettingsMerger.state(of: settings, spec: spec)
        let binaryPresent = FileManager.default.isExecutableFile(atPath: paths.hookBinary)
        switch state {
        case .notInstalled:
            return .notInstalled
        case .installed:
            guard binaryPresent else { return .needsRepair("The hook helper is missing. Repair to restore it.") }
            if HookSettingsMerger.hooksDisabled(in: settings) {
                return .needsRepair(
                    "Claude Code runs no hooks while \"disableAllHooks\" is set in settings.json. Remove it to use "
                        + "SuperNotch.")
            }
            return .installed
        case .needsRepair(let missing):
            if missing.isEmpty {
                return .needsRepair("The status line bridge or a duplicate entry needs an update.")
            }
            let names = missing.map(\.rawValue).joined(separator: ", ")
            return .needsRepair("Missing or outdated hooks: \(names).")
        }
    }

    // MARK: - Install / uninstall

    func install(into target: ClaudeHookInstallTarget, spec: HookInstallSpec, now: Date = Date()) throws
        -> ClaudeHookInstallOutcome
    {
        let url = settingsURL(for: target)
        for _ in 0..<3 {
            let original = try readSettings(at: url)
            let parsed = try parse(original)
            let previous = loadManifest(at: target.manifestPath)
            let result: HookMergeResult
            do {
                result = try HookSettingsMerger.install(
                    spec: spec, into: parsed, previousManifest: previous, settingsFile: target.settingsFile,
                    appVersion: appVersion, now: now)
            } catch {
                throw ClaudeInstallerError("\(error) Nothing was changed.")
            }
            guard result.changed else {
                try writeManifest(result.manifest, to: target.manifestPath)
                return ClaudeHookInstallOutcome(status: .installed, message: "Hooks are already installed.")
            }
            let backup = try backUp(original, target: target, now: now)
            // Re-read right before writing: if Claude Code or the user changed the file meanwhile, re-plan.
            guard try readSettings(at: url) == original else { continue }
            try atomicWrite(HookSettingsMerger.serialize(result.settings), to: url)
            try writeManifest(result.manifest, to: target.manifestPath)
            return ClaudeHookInstallOutcome(status: .installed, message: "Hooks installed.", backupPath: backup)
        }
        throw ClaudeInstallerError("settings.json kept changing while installing. Please try again.")
    }

    func uninstall(from target: ClaudeHookInstallTarget, now: Date = Date()) throws -> ClaudeHookInstallOutcome {
        let url = settingsURL(for: target)
        for _ in 0..<3 {
            let original = try readSettings(at: url)
            guard let parsed = try parse(original) else {
                removeManifest(at: target.manifestPath)
                return ClaudeHookInstallOutcome(status: .notInstalled, message: "Nothing to remove.")
            }
            let manifest = loadManifest(at: target.manifestPath)
            let cleaned: JSONValue
            do {
                cleaned = try HookSettingsMerger.uninstall(from: parsed, manifest: manifest)
            } catch {
                throw ClaudeInstallerError("\(error) Nothing was changed.")
            }
            guard cleaned.serialized() != parsed.serialized() else {
                removeManifest(at: target.manifestPath)
                return ClaudeHookInstallOutcome(status: .notInstalled, message: "Nothing to remove.")
            }
            let backup = try backUp(original, target: target, now: now)
            guard try readSettings(at: url) == original else { continue }
            try atomicWrite(HookSettingsMerger.serialize(cleaned), to: url)
            removeManifest(at: target.manifestPath)
            return ClaudeHookInstallOutcome(status: .notInstalled, message: "Hooks removed.", backupPath: backup)
        }
        throw ClaudeInstallerError("settings.json kept changing while uninstalling. Please try again.")
    }

    func hasManifest(for target: ClaudeHookInstallTarget) -> Bool {
        FileManager.default.fileExists(atPath: target.manifestPath)
    }

    // MARK: - Hook binary

    /// Copies `supernotch-hook` from the app bundle to the stable path referenced by settings.json when the
    /// bytes differ (SPEC §D.6). `sourceCandidates` are checked in order.
    func syncHookBinary(sourceCandidates: [String]) -> ClaudeHookBinarySync {
        let fileManager = FileManager.default
        let destination = paths.hookBinary
        guard let source = sourceCandidates.first(where: { fileManager.isExecutableFile(atPath: $0) }),
            let sourceData = fileManager.contents(atPath: source), !sourceData.isEmpty
        else {
            return .missingSource
        }
        if fileManager.isExecutableFile(atPath: destination), let existing = fileManager.contents(atPath: destination),
            existing == sourceData
        {
            return .upToDate
        }
        do {
            try fileManager.createDirectory(atPath: paths.binDirectory, withIntermediateDirectories: true)
            // New inode via rename: never rewrite a signed executable in place (code signature caching).
            let temporary = paths.binDirectory + "/.\(SuperNotchPaths.hookBinaryName).\(UUID().uuidString).tmp"
            try sourceData.write(to: URL(fileURLWithPath: temporary))
            guard chmod(temporary, 0o755) == 0 else {
                unlink(temporary)
                return .failed("chmod failed (errno \(errno))")
            }
            guard rename(temporary, destination) == 0 else {
                let code = errno
                unlink(temporary)
                return .failed("rename failed (errno \(code))")
            }
            return .updated
        } catch {
            return .failed("\(error)")
        }
    }

    // MARK: - IO helpers

    /// settings.json with symlinks resolved (dotfile managers), so the atomic rename replaces the real file.
    func settingsURL(for target: ClaudeHookInstallTarget) -> URL {
        URL(fileURLWithPath: target.settingsFile).resolvingSymlinksInPath()
    }

    /// nil when the file does not exist.
    private func readSettings(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ClaudeInstallerError("Could not read \(url.path): \(error.localizedDescription)")
        }
    }

    /// Strict parse (Core). Empty or whitespace-only ⇒ nil ("no settings yet"); invalid ⇒ throws, never written.
    private func parse(_ data: Data?) throws -> JSONValue? {
        do {
            return try HookSettingsMerger.parseSettings(data)
        } catch {
            throw ClaudeInstallerError("\(error)")
        }
    }

    private func backUp(_ data: Data?, target: ClaudeHookInstallTarget, now: Date) throws -> String? {
        guard let data else { return nil }
        let fileManager = FileManager.default
        let directory = paths.settingsBackupDirectory
        do {
            try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        } catch {
            throw ClaudeInstallerError("Could not create the backup folder: \(error.localizedDescription)")
        }
        let base = HookSettingsMerger.backupPath(directory: directory, settingsFile: target.settingsFile, date: now)
        var path = base
        var counter = 2
        while fileManager.fileExists(atPath: path) {
            path = String(base.dropLast(".bak".count)) + "-\(counter).bak"
            counter += 1
        }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
        } catch {
            throw ClaudeInstallerError("Could not write the backup: \(error.localizedDescription)")
        }
        pruneBackups(in: directory, target: target, now: now)
        return path
    }

    /// Keeps the newest `maxBackups` backups of this settings file (ISO timestamps sort chronologically).
    private func pruneBackups(in directory: String, target: ClaudeHookInstallTarget, now: Date) {
        let sample = HookSettingsMerger.backupFileName(settingsFile: target.settingsFile, date: now)
        guard let range = sample.range(of: "settings.json.") else { return }
        let prefix = String(sample[..<range.upperBound])
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        let candidates = names.filter { name in
            name.hasPrefix(prefix) && name.hasSuffix(".bak") && (name.dropFirst(prefix.count).first?.isNumber ?? false)
        }.sorted()
        guard candidates.count > maxBackups else { return }
        for name in candidates.prefix(candidates.count - maxBackups) {
            try? FileManager.default.removeItem(atPath: directory + "/" + name)
        }
    }

    /// Temp file in the same directory, then rename(2) into place. Keeps the original file mode.
    private func atomicWrite(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent().path
        do {
            try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        } catch {
            throw ClaudeInstallerError("Could not create \(directory): \(error.localizedDescription)")
        }
        let temporary = directory + "/.settings.json.supernotch-\(UUID().uuidString).tmp"
        do {
            try data.write(to: URL(fileURLWithPath: temporary), options: [.withoutOverwriting])
        } catch {
            throw ClaudeInstallerError("Could not write settings.json: \(error.localizedDescription)")
        }
        if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
            let permissions = attributes[.posixPermissions]
        {
            try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary)
        }
        guard rename(temporary, url.path) == 0 else {
            let code = errno
            unlink(temporary)
            throw ClaudeInstallerError("Could not replace settings.json (errno \(code)).")
        }
    }

    private func loadManifest(at path: String) -> HookManifest? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(HookManifest.self, from: data)
    }

    /// Default date encoding on purpose: `supernotch-hook` decodes the manifest with a plain JSONDecoder.
    private func writeManifest(_ manifest: HookManifest, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(atPath: paths.appSupport, withIntermediateDirectories: true)
            let data = try encoder.encode(manifest)
            try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
        } catch {
            throw ClaudeInstallerError("Could not write the hook manifest: \(error.localizedDescription)")
        }
    }

    private func removeManifest(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Filesystem-safe tag for a config folder ("~/.claude-work" → "claude-work-1a2b3c4d").
    static func fileTag(for configDirectory: String) -> String {
        let base = (configDirectory as NSString).lastPathComponent
        let cleaned = String(base.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        var hash: UInt32 = 2_166_136_261  // FNV-1a, stable across launches (unlike Hasher).
        for byte in configDirectory.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        let hex = String(hash, radix: 16)
        return (cleaned.isEmpty ? "config" : String(cleaned.prefix(24))) + "-" + hex
    }
}
