import Foundation

/// Settings storage for one test, kept in memory only. A real suite, even
/// one removed when the test ends, makes macOS write a preferences file a
/// moment later, so every test run used to leave files behind in
/// ~/Library/Preferences.
enum TestDefaults {
    static func make() -> UserDefaults {
        MemoryDefaults()
    }
}

private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    init() { super.init(suiteName: nil)! }

    override func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    override func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
    override func removeObject(forKey key: String) { lock.withLock { values[key] = nil } }
}
