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

    private var watcher: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var current = DownloadProgress(count: 0, receivedBytes: 0, totalBytes: nil)
    private var scanTask: Task<Void, Never>?
    private var trackedPartial: String?
    private var trackedTotalBytes: Int64?
    private var lastTotalLookup = Date.distantPast
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
        scanTask?.cancel()
        scanTask = nil
        watcher?.cancel()
        watcher = nil
        if descriptor >= 0 { close(descriptor) }
        descriptor = -1
    }

    private func scan(silent: Bool = false) {
        // File-extension events can arrive continuously. One scan per 250 ms is enough for a
        // glanceable HUD and prevents a large download from flooding SwiftUI with repaints.
        guard scanTask == nil else { return }
        let url = downloadsURL
        let knownPath = trackedPartial
        let knownTotal = trackedTotalBytes
        let lookupDue = Date().timeIntervalSince(lastTotalLookup) >= 10

        scanTask = Task { [weak self] in
            if !silent { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { self?.scanTask = nil; return }

            let result = await Task.detached(priority: .utility) {
                let partials = Self.partialURLs(in: url)
                let received = partials.reduce(Int64(0)) { $0 + Self.logicalSize(of: $1) }
                let path = partials.count == 1 ? partials[0].path : nil
                let total: Int64?
                let lookedUp: Bool

                if path == knownPath, let knownTotal, knownTotal >= received {
                    total = knownTotal
                    lookedUp = false
                } else if path == knownPath, !lookupDue {
                    total = nil
                    lookedUp = false
                } else if let partial = partials.first, partials.count == 1 {
                    total = Self.chromiumTotalBytes(for: partial, receivedBytes: received)
                    lookedUp = true
                } else {
                    total = nil
                    lookedUp = false
                }

                return (
                    DownloadProgress(count: partials.count,
                                     receivedBytes: received,
                                     totalBytes: total),
                    path,
                    total,
                    lookedUp
                )
            }.value

            guard !Task.isCancelled else { self?.scanTask = nil; return }
            self?.scanTask = nil
            self?.trackedPartial = result.1
            self?.trackedTotalBytes = result.2
            if result.3 { self?.lastTotalLookup = Date() }
            self?.apply(progress: result.0, silent: silent)
        }
    }

    private func apply(progress: DownloadProgress, silent: Bool) {
        guard progress != current else { return }
        let previous = current
        current = progress
        onProgress?(progress)
        // Going from "some" to "none" is the completion edge.
        if !silent, previous.count > 0, progress.count == 0 { onComplete?() }
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
