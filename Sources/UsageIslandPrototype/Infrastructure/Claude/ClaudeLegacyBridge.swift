import Foundation

/// Versions 0.1.3 through 0.1.7 could add a Claude Code status line that ran
/// this executable with `--claude-statusline`. The feature was removed: Claude
/// usage comes from the CLI's `get_usage` answer for everyone, so Codex and
/// Claude need no setup at all. This cleans up after those versions.
enum ClaudeLegacyBridge {
    static let argument = "--claude-statusline"

    /// Where those versions stored the status line's rate limits.
    static var recordURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Usage Island", isDirectory: true)
            .appendingPathComponent("claude-rate-limits.json", isDirectory: false)
    }

    /// Removes the status line those versions added, never one the user wrote,
    /// and the record it kept. Safe to call on every launch.
    @discardableResult
    static func removeIfInstalled(settings: ClaudeSettingsFile = ClaudeSettingsFile(), recordURL: URL = recordURL) -> Bool {
        let removed = settings.removeUsageIslandStatusLine()
        try? FileManager.default.removeItem(at: recordURL)
        let directory = recordURL.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: directory)
        }
        return removed
    }
}

/// Claude Code's user settings, touched only to remove our own status line.
struct ClaudeSettingsFile: Sendable {
    let claudeDirectory: URL

    init(claudeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude", isDirectory: true)) {
        self.claudeDirectory = claudeDirectory
    }

    var settingsURL: URL {
        claudeDirectory.appendingPathComponent("settings.json", isDirectory: false)
    }

    /// True when the `statusLine` key was ours and is now gone. Other keys,
    /// a user's own status line and unreadable files are left as they are.
    func removeUsageIslandStatusLine() -> Bool {
        guard FileManager.default.fileExists(atPath: settingsURL.path),
              let data = try? Data(contentsOf: settingsURL),
              var settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let statusLine = settings["statusLine"], Self.isUsageIslandStatusLine(statusLine) else { return false }
        settings.removeValue(forKey: "statusLine")
        guard let updated = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return false }
        return (try? (updated + Data("\n".utf8)).write(to: settingsURL, options: .atomic)) != nil
    }

    static func isUsageIslandStatusLine(_ statusLine: Any) -> Bool {
        guard let object = statusLine as? [String: Any],
              let command = object["command"] as? String else { return false }
        return executablePath(inCommand: command).map { $0.hasSuffix("/UsageIslandPrototype") } ?? false
    }

    /// The executable in a command those versions wrote, in either format:
    /// `[ -x 'P' ] && exec 'P' --claude-statusline || true` or
    /// `'P' --claude-statusline`. Anything else is not ours.
    static func executablePath(inCommand command: String) -> String? {
        let argument = " " + ClaudeLegacyBridge.argument
        let quoted: Substring
        if command.hasPrefix("[ -x "), command.hasSuffix(argument + " || true") {
            let inner = command.dropFirst("[ -x ".count).dropLast((argument + " || true").count)
            guard let separator = inner.range(of: " ] && exec ") else { return nil }
            let first = inner[..<separator.lowerBound]
            guard first == inner[separator.upperBound...] else { return nil }
            quoted = first
        } else if command.hasSuffix(argument) {
            quoted = command.dropLast(argument.count)
        } else {
            return nil
        }
        guard quoted.count >= 2, quoted.hasPrefix("'"), quoted.hasSuffix("'") else { return nil }
        let body = quoted.dropFirst().dropLast()
        // Only what shell quoting produced: every inner quote is escaped.
        guard !body.replacingOccurrences(of: "'\\''", with: "").contains("'") else { return nil }
        return String(body).replacingOccurrences(of: "'\\''", with: "'")
    }
}
