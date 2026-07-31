import Foundation

public struct ExecutableLocator: Sendable {
    public typealias ExecutableCheck = @Sendable (URL) -> Bool

    private let searchPaths: [URL]
    private let isExecutable: ExecutableCheck

    public init(
        environmentPath: String? = ProcessInfo.processInfo.environment["PATH"],
        additionalSearchPaths: [URL] = [],
        commonSearchPaths: [URL] = ExecutableLocator.defaultCommonSearchPaths,
        isExecutable: @escaping ExecutableCheck = {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    ) {
        var candidates = additionalSearchPaths
        if let environmentPath {
            candidates.append(
                contentsOf: environmentPath
                    .split(separator: ":", omittingEmptySubsequences: true)
                    .filter { $0.hasPrefix("/") }
                    .map { URL(fileURLWithPath: String($0), isDirectory: true) }
            )
        }
        candidates.append(contentsOf: commonSearchPaths)

        var seen: Set<String> = []
        searchPaths = candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
        self.isExecutable = isExecutable
    }

    public func locate(_ executableName: String) throws -> URL {
        let safeName = Self.safeExecutableName(executableName)
        guard !safeName.isEmpty, safeName == executableName else {
            throw JSONRPCError.executableNotFound(safeName.isEmpty ? "unknown" : safeName)
        }

        for directory in searchPaths {
            let candidate = directory.appendingPathComponent(safeName, isDirectory: false)
            if isExecutable(candidate) {
                return candidate.standardizedFileURL
            }
        }
        throw JSONRPCError.executableNotFound(safeName)
    }

    private static func safeExecutableName(_ value: String) -> String {
        let candidate = URL(fileURLWithPath: value).lastPathComponent
        let allowed = candidate.unicodeScalars.filter {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0)
        }
        return String(String.UnicodeScalarView(allowed)).prefix(80).description
    }

    public static var defaultCommonSearchPaths: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".local/bin", isDirectory: true),
            home.appendingPathComponent("bin", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/bin", isDirectory: true),
            URL(fileURLWithPath: "/bin", isDirectory: true)
        ]
    }
}
