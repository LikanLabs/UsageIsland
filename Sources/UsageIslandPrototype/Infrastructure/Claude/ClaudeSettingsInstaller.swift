import Foundation

enum ClaudeBridgeStatus: Equatable, Sendable {
    /// No `~/.claude` directory: Claude Code has never run for this user.
    case claudeNotFound
    case notInstalled
    case installed
    /// The user already has their own status line; it is never replaced.
    case otherStatusLine
    /// `settings.json` exists but is not a JSON object, so it is left alone.
    case unreadableSettings
}

enum ClaudeSettingsError: Error, Equatable {
    case claudeNotFound
    case otherStatusLine
    case unreadableSettings
    case writeFailed
}

/// Adds or removes the Usage Island status line in Claude Code's user
/// settings, touching only the `statusLine` key and only when it is ours.
struct ClaudeSettingsInstaller: Sendable {
    let claudeDirectory: URL
    let executablePath: String
    let executableExists: @Sendable (String) -> Bool

    init(
        claudeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true),
        executablePath: String = Bundle.main.executablePath ?? CommandLine.arguments[0],
        executableExists: @escaping @Sendable (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    ) {
        self.claudeDirectory = claudeDirectory
        self.executablePath = executablePath
        self.executableExists = executableExists
    }

    var settingsURL: URL {
        claudeDirectory.appendingPathComponent("settings.json", isDirectory: false)
    }

    var command: String {
        Self.shellQuoted(executablePath) + " " + ClaudeStatuslineBridge.argument
    }

    func status() -> ClaudeBridgeStatus {
        guard directoryExists else { return .claudeNotFound }
        guard let settings = try? readSettings() else { return .unreadableSettings }
        guard let statusLine = settings["statusLine"] else { return .notInstalled }
        return Self.isBridge(statusLine) ? .installed : .otherStatusLine
    }

    func install() throws(ClaudeSettingsError) {
        guard directoryExists else { throw .claudeNotFound }
        var settings: [String: Any]
        do { settings = try readSettings() } catch { throw .unreadableSettings }
        if let existing = settings["statusLine"], !Self.isBridge(existing) {
            throw .otherStatusLine
        }
        settings["statusLine"] = [
            "type": "command",
            "command": command,
            "padding": 0,
        ] as [String: Any]
        try write(settings)
    }

    func uninstall() throws(ClaudeSettingsError) {
        guard directoryExists else { return }
        var settings: [String: Any]
        do { settings = try readSettings() } catch { throw .unreadableSettings }
        guard let existing = settings["statusLine"] else { return }
        guard Self.isBridge(existing) else { throw .otherStatusLine }
        settings.removeValue(forKey: "statusLine")
        try write(settings)
    }

    /// Points an installed bridge back at this app when the executable it
    /// names no longer exists (for example after the app moved). A bridge
    /// that still works, such as one from another build, is left alone.
    func repairIfNeeded() {
        guard status() == .installed,
              let settings = try? readSettings(),
              let statusLine = settings["statusLine"] as? [String: Any],
              let existingCommand = statusLine["command"] as? String,
              existingCommand != command,
              let existingPath = Self.executablePath(inCommand: existingCommand),
              !executableExists(existingPath) else { return }
        try? install()
    }

    private var directoryExists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: claudeDirectory.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        if data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeSettingsError.unreadableSettings
        }
        return object
    }

    private func write(_ settings: [String: Any]) throws(ClaudeSettingsError) {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try (data + Data("\n".utf8)).write(to: settingsURL, options: .atomic)
        } catch {
            throw .writeFailed
        }
    }

    static func isBridge(_ statusLine: Any) -> Bool {
        guard let object = statusLine as? [String: Any],
              let command = object["command"] as? String else { return false }
        return command.hasSuffix(" " + ClaudeStatuslineBridge.argument)
            && command.contains("UsageIslandPrototype")
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Reverses `shellQuoted` for commands this installer wrote.
    static func executablePath(inCommand command: String) -> String? {
        let suffix = " " + ClaudeStatuslineBridge.argument
        guard command.hasSuffix(suffix) else { return nil }
        let quoted = String(command.dropLast(suffix.count))
        guard quoted.count >= 2, quoted.hasPrefix("'"), quoted.hasSuffix("'") else { return nil }
        return String(quoted.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
    }
}
