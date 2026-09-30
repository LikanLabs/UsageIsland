import Foundation

/// Version fields from an app bundle's `Info.plist` on disk.
struct BundleVersion: Equatable, Sendable {
    let short: String
    let build: String

    /// Reads the bundle as it is on disk now, which after `brew upgrade` is
    /// newer than the code running in this process. Nil while the bundle is
    /// missing or half-copied, so an upgrade in progress is not mistaken for
    /// a new version.
    static func onDisk(at bundleURL: URL) -> BundleVersion? {
        guard bundleURL.pathExtension == "app" else { return nil }
        let plist = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist),
              let short = info["CFBundleShortVersionString"] as? String, !short.isEmpty,
              let build = info["CFBundleVersion"] as? String, !build.isEmpty else { return nil }
        return BundleVersion(short: short, build: build)
    }
}

enum AppUpdateRelaunch {
    /// Relaunch once a different, complete version sits on disk, but never
    /// while the user has the panel open.
    static func shouldRelaunch(running: BundleVersion?, onDisk: BundleVersion?, panelOpen: Bool) -> Bool {
        guard let running, let onDisk, !panelOpen else { return false }
        return running != onDisk
    }

    /// Starts a detached shell that waits for this process to exit and then
    /// opens the bundle again, picking up the version now on disk. `open` is
    /// retried briefly in case the upgrade was still copying files.
    static func scheduleReopen(of bundleURL: URL, afterExitOf pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            #"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; for attempt in 1 2 3 4 5 6 7 8 9 10; do /usr/bin/open "$2" && exit 0; sleep 2; done; exit 1"#,
            "usage-island-relaunch", String(pid), bundleURL.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
