import Dispatch
import Foundation

/// Calls `onChange` on the main actor shortly after files in a directory are
/// created, replaced or removed. Atomic writes replace the file, so the
/// directory itself is watched. Bursts are coalesced by `debounce`.
@MainActor
final class DirectoryChangeWatcher {
    private let directory: URL
    private let debounce: Duration
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: Task<Void, Never>?

    init(directory: URL, debounce: Duration = .milliseconds(300), onChange: @escaping @MainActor () -> Void) {
        self.directory = directory
        self.debounce = debounce
        self.onChange = onChange
    }

    func start() {
        guard source == nil else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { @Sendable [weak self] in
            Task { @MainActor in self?.scheduleChange() }
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    func stop() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
    }

    private func scheduleChange() {
        pending?.cancel()
        pending = Task { [weak self, debounce] in
            do { try await Task.sleep(for: debounce) } catch { return }
            self?.onChange()
        }
    }
}
