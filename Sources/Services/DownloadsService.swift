import Foundation

/// Watches ~/Downloads and reports in-progress downloads.
///
/// Browsers all write a placeholder while downloading and rename it on completion, so counting
/// those extensions is both cheap and accurate — no polling of file sizes, no FSEvents stream.
@MainActor
final class DownloadsService {
    /// Fires with the number of downloads in flight; 0 means the folder has settled.
    var onProgress: ((Int) -> Void)?
    /// Fires once when the last in-flight download finishes.
    var onComplete: (() -> Void)?

    private var watcher: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var inFlight = 0
    private let queue = DispatchQueue(label: "dev.local.tyland.downloads")

    /// Safari, Chrome/Edge, Firefox respectively.
    nonisolated static let partialExtensions: Set<String> = ["download", "crdownload", "part"]

    private var downloadsURL: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    func start() {
        // `open()` on ~/Downloads blocks in `mach_msg` until the folder-access consent prompt is
        // answered. On the main actor that freezes the actor and every Task behind it, so the
        // syscall happens off-actor and only the DispatchSource wiring comes back here.
        let path = downloadsURL.path
        Task.detached(priority: .utility) { [weak self] in
            let fd = open(path, O_EVTONLY)
            guard let self else {
                if fd >= 0 { close(fd) }   // don't leak the descriptor if we went away
                return
            }
            await MainActor.run { self.attachWatcher(descriptor: fd, path: path) }
        }
    }

    private func attachWatcher(descriptor fd: CInt, path: String) {
        descriptor = fd
        guard descriptor >= 0 else {
            Debug.log("downloads: folder unwatchable at \(path)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.scan() }
        }
        source.resume()
        watcher = source
        scan(silent: true)
        Debug.log("downloads: watching \(path)")
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        if descriptor >= 0 { close(descriptor) }
        descriptor = -1
    }

    private func scan(silent: Bool = false) {
        // Reading the folder can block on a TCC consent prompt, so never do it on the main thread.
        let url = downloadsURL
        Task.detached(priority: .utility) {
            let count = Self.countPartials(in: url)
            await MainActor.run { self.apply(count: count, silent: silent) }
        }
    }

    private func apply(count: Int, silent: Bool) {
        guard count != inFlight else { return }
        let previous = inFlight
        inFlight = count
        onProgress?(count)
        // Going from "some" to "none" is the completion edge.
        if !silent, previous > 0, count == 0 { onComplete?() }
    }

    nonisolated static func countPartials(in directory: URL) -> Int {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { partialExtensions.contains($0.pathExtension.lowercased()) }.count
    }
}
