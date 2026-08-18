import Foundation
import SQLite3

/// Watches ~/Downloads and reports in-progress downloads.
///
/// Browsers write a placeholder while downloading and rename it on completion. The placeholder's
/// size is honest received-byte progress; Chromium also persists the total in its History database.
@MainActor
final class DownloadsService {
    /// Fires with current progress; `count == 0` means the folder has settled.
    var onProgress: ((DownloadProgress) -> Void)?
    /// Fires once when the last in-flight download finishes.
    var onComplete: (() -> Void)?

    private var watchers: [DispatchSourceFileSystemObject] = []
    private var descriptors: [CInt] = []
    private var current = DownloadProgress(count: 0, receivedBytes: 0, totalBytes: nil)
    private var scanTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var trackedPartial: String?
    private var trackedTotalBytes: Int64?
    private var lastTotalLookup = Date.distantPast
    private var partialStates: [String: PartialState] = [:]

    /// Last observed size of one placeholder, and when it last grew.
    struct PartialState: Equatable, Sendable {
        var size: Int64
        var lastGrew: Date
    }

    /// Whether to read download totals out of Chromium's History database. Off means downloads show
    /// an indeterminate ring instead of an exact bar.
    var readBrowserTotals = true

    /// A placeholder that has not grown for this long is treated as abandoned.
    ///
    /// A cancelled download or a browser crash leaves a `.crdownload` in ~/Downloads forever. The
    /// old code only asked "are there any partials", so one orphan pinned `count > 0` permanently:
    /// the 2 Hz poll never stopped, the directory (walked recursively for `.download` packages) was
    /// re-enumerated twice a second for the life of the process, every Chromium profile's History
    /// database was re-opened every 10 s, and the island showed a download that could never finish.
    nonisolated static let staleAfter: TimeInterval = 60
    private let queue = DispatchQueue(label: App.queue("downloads"))
    private let directoryURL: URL?

    /// Safari, Chrome/Edge, Firefox respectively.
    nonisolated static let partialExtensions: Set<String> = ["download", "crdownload", "part"]

    /// How often an in-flight download is re-measured. The progress views ramp between samples over
    /// exactly this long, so the bar sweeps instead of stepping; keep the two in step if it changes.
    nonisolated static let sampleInterval: TimeInterval = 0.5

    private var defaultDownloadsURL: URL {
        directoryURL ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    /// Folders to watch. ~/Downloads is always included; the rest come from Settings, because
    /// plenty of people point their browser somewhere else entirely.
    var folders: [URL] = [] {
        didSet {
            guard folders.map(\.path) != oldValue.map(\.path), !watchers.isEmpty || !oldValue.isEmpty
            else { return }
            restart()
        }
    }

    private var watchedURLs: [URL] {
        var seen = Set<String>()
        return ([defaultDownloadsURL] + folders)
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL
    }

    func start() {
        // `open()` on ~/Downloads blocks in `mach_msg` until the folder-access consent prompt is
        // answered. On the main actor that freezes the actor and every Task behind it, so the
        // syscall happens off-actor and only the DispatchSource wiring comes back here.
        let paths = watchedURLs.map(\.path)
        Task.detached(priority: .utility) { [weak self] in
            let opened = paths.map { ($0, open($0, O_EVTONLY)) }
            guard let self else {
                for (_, fd) in opened where fd >= 0 { close(fd) }
                return
            }
            await MainActor.run { self.attachWatchers(opened) }
        }
    }

    private func restart() {
        stop()
        start()
    }

    private func attachWatchers(_ opened: [(String, CInt)]) {
        for (path, fd) in opened {
            guard fd >= 0 else {
                Debug.log("downloads: folder unwatchable at \(path)")
                continue
            }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .delete, .rename],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor in self?.scan() }
            }
            source.resume()
            watchers.append(source)
            descriptors.append(fd)
            Debug.log("downloads: watching \(path)")
        }
        guard !watchers.isEmpty else { return }
        scan(silent: true)
    }

    func stop() {
        stopPolling()
        scanTask?.cancel()
        scanTask = nil
        for watcher in watchers { watcher.cancel() }
        watchers.removeAll()
        for fd in descriptors where fd >= 0 { close(fd) }
        descriptors.removeAll()
        partialStates.removeAll()
    }

    /// `coalesce` is for filesystem events, which arrive in bursts. The poll is already paced, and
    /// making it wait too turned a 500 ms beat into a ragged 750 ms one — visible as a bar that
    /// lurches. Its samples go straight through.
    private func scan(silent: Bool = false, coalesce: Bool = true) {
        // File-extension events can arrive continuously. One scan per 250 ms is enough for a
        // glanceable HUD and prevents a large download from flooding SwiftUI with repaints.
        guard scanTask == nil else { return }
        let urls = watchedURLs
        let knownPath = trackedPartial
        let knownTotal = trackedTotalBytes
        let lookupDue = Date().timeIntervalSince(lastTotalLookup) >= 10

        let known = partialStates
        let allowLookup = lookupDue && readBrowserTotals
        let mayReadBrowsers = readBrowserTotals

        scanTask = Task { [weak self] in
            if coalesce, !silent { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { self?.scanTask = nil; return }

            let result = await Task.detached(priority: .utility) { () -> Sample in
                let now = Date()
                var sizes: [String: Int64] = [:]
                var found: [String: URL] = [:]
                for folder in urls {
                    for partial in Self.partialURLs(in: folder) {
                        sizes[partial.path] = Self.logicalSize(of: partial)
                        found[partial.path] = partial
                    }
                }

                let (active, states, finished) = Self.activePartials(sizes: sizes, known: known, now: now)
                let received = active.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
                let path = active.count == 1 ? active[0] : nil
                let total: Int64?
                let lookedUp: Bool

                if path == knownPath, let knownTotal, knownTotal >= received {
                    total = knownTotal
                    lookedUp = false
                } else if path == knownPath, !allowLookup {
                    total = nil
                    lookedUp = false
                } else if mayReadBrowsers, let path, let partial = found[path] {
                    total = Self.chromiumTotalBytes(for: partial, receivedBytes: received)
                    lookedUp = true
                } else {
                    total = nil
                    lookedUp = false
                }

                return Sample(
                    progress: DownloadProgress(count: active.count,
                                               receivedBytes: received,
                                               totalBytes: total),
                    states: states,
                    activePath: path,
                    total: total,
                    lookedUp: lookedUp,
                    finished: finished
                )
            }.value

            guard !Task.isCancelled else { self?.scanTask = nil; return }
            self?.scanTask = nil
            self?.partialStates = result.states
            self?.trackedPartial = result.activePath
            self?.trackedTotalBytes = result.total
            if result.lookedUp { self?.lastTotalLookup = Date() }
            self?.apply(progress: result.progress, silent: silent, finished: result.finished)
        }
    }

    private struct Sample: Sendable {
        var progress: DownloadProgress
        var states: [String: PartialState]
        var activePath: String?
        var total: Int64?
        var lookedUp: Bool
        var finished: Int
    }

    /// Which placeholders still count as live downloads, and the carried-forward bookkeeping.
    ///
    /// Pure — no filesystem — so `--self-test` can drive it directly. A partial is live while it is
    /// still growing; once its size has been unchanged for `staleAfter` it is dropped from the
    /// active set, which is what lets the poll and the island finally settle. Paths that vanished
    /// from the listing are forgotten, so a re-download of the same name starts fresh.
    nonisolated static func activePartials(
        sizes: [String: Int64],
        known: [String: PartialState],
        now: Date
    ) -> (active: [String], states: [String: PartialState], finished: Int) {
        var states: [String: PartialState] = [:]
        var active: [String] = []

        for (path, size) in sizes {
            let previous = known[path]
            // Growth — or a first sighting — restarts the clock. Shrinking counts too: a browser
            // that truncates and restarts a download is very much still working.
            let lastGrew = (previous == nil || previous!.size != size) ? now : previous!.lastGrew
            states[path] = PartialState(size: size, lastGrew: lastGrew)
            if now.timeIntervalSince(lastGrew) < staleAfter { active.append(path) }
        }

        // A placeholder that was still live and is now gone was renamed to its final name — that,
        // and only that, is a finished download. Ageing one out must never ring the completion
        // chime, or every abandoned .crdownload would announce itself a minute later.
        let finished = known.filter { path, state in
            sizes[path] == nil && now.timeIntervalSince(state.lastGrew) < staleAfter
        }.count

        return (active.sorted(), states, finished)
    }

    private func apply(progress: DownloadProgress, silent: Bool, finished: Int = 0) {
        guard progress != current else { return }
        let previous = current
        current = progress
        if progress.count > 0 { startPolling() } else { stopPolling() }
        onProgress?(progress)
        // Going from "some" to "none" is the completion edge — but only when a placeholder actually
        // vanished. Ageing an abandoned one out empties the set too, and must stay silent.
        if !silent, previous.count > 0, progress.count == 0, finished > 0 { onComplete?() }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(Self.sampleInterval)) }
                catch { break }
                guard let self else { break }
                self.scan(coalesce: false)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    nonisolated static func countPartials(in directory: URL) -> Int {
        partialURLs(in: directory).count
    }

    nonisolated static func snapshot(in directory: URL, totalBytes: Int64? = nil) -> DownloadProgress {
        let partials = partialURLs(in: directory)
        return DownloadProgress(
            count: partials.count,
            receivedBytes: partials.reduce(Int64(0)) { $0 + logicalSize(of: $1) },
            totalBytes: partials.count == 1 ? totalBytes : nil
        )
    }

    private nonisolated static func partialURLs(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { partialExtensions.contains($0.pathExtension.lowercased()) }
    }

    private nonisolated static func logicalSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isDirectory != true { return Int64(values.fileSize ?? 0) }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let child as URL in enumerator {
            let childValues = try? child.resourceValues(forKeys: keys)
            if childValues?.isDirectory != true { total += Int64(childValues?.fileSize ?? 0) }
        }
        return total
    }

    /// Chromium writes totals to each profile's History DB. Read only size/path columns and cache
    /// the result for the lifetime of the placeholder; URLs and browsing history are never read.
    private nonisolated static func chromiumTotalBytes(
        for partial: URL,
        receivedBytes: Int64
    ) -> Int64? {
        guard partial.pathExtension.lowercased() == "crdownload" else { return nil }
        let expectedTarget = partial.deletingPathExtension().path
        let canMatchPath = !partial.lastPathComponent.hasPrefix("Unconfirmed ")
        var exact: (total: Int64, started: Int64)?
        var fallback: (total: Int64, started: Int64)?

        for history in chromiumHistoryFiles() {
            var database: OpaquePointer?
            let uri = "file:\(history.path)?immutable=1"
            guard sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
                    == SQLITE_OK,
                  let database
            else {
                if database != nil { sqlite3_close(database) }
                continue
            }
            defer { sqlite3_close(database) }

            let sql = """
                SELECT target_path, total_bytes, start_time
                FROM downloads
                WHERE total_bytes >= ? AND state != 1
                ORDER BY start_time DESC
                LIMIT 16
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement
            else { continue }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, receivedBytes)

            while sqlite3_step(statement) == SQLITE_ROW {
                guard let targetBytes = sqlite3_column_text(statement, 0) else { continue }
                let target = String(cString: targetBytes)
                let candidate = (
                    total: sqlite3_column_int64(statement, 1),
                    started: sqlite3_column_int64(statement, 2)
                )
                if canMatchPath, target == expectedTarget,
                   candidate.started > (exact?.started ?? .min) {
                    exact = candidate
                }
                if candidate.started > (fallback?.started ?? .min) { fallback = candidate }
            }
        }
        return exact?.total ?? fallback?.total
    }

    private nonisolated static func chromiumHistoryFiles() -> [URL] {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return [] }

        let roots = [
            "Dia/User Data",
            "Google/Chrome",
            "Microsoft Edge",
            "BraveSoftware/Brave-Browser",
            "Vivaldi",
            "Comet",
            "com.operasoftware.Opera",
        ].map { support.appendingPathComponent($0, isDirectory: true) }

        return roots.flatMap { root in
            let profiles = [root] + ((try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? [])
            return profiles
                .map { $0.appendingPathComponent("History") }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }
}
