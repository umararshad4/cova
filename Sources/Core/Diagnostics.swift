import AppKit
import Darwin
import Foundation

/// Crash capture and a private-symbol health report.
///
/// This app is built on symbols Apple does not document and can withdraw in any point release, and
/// `PrivateSymbols.swift` is deliberately written to degrade to silence when one disappears. That is
/// the right runtime behaviour and a terrible business one: without this, a macOS update can kill
/// Now Playing, keyboard backlight and screen-recording detection for every customer at once, and
/// the first you hear of it is a refund.
///
/// Nothing is transmitted. Reports are written locally; sending one is a button the user presses.
@MainActor
enum Diagnostics {
    private static var reportsURL: URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let folder = base.appendingPathComponent(App.bundleID, isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: - Crash capture

    /// Pre-opened before any crash, because `open()` is not async-signal-safe.
    nonisolated(unsafe) private static var crashFD: Int32 = -1

    static func install() {
        guard let folder = reportsURL else { return }
        let path = folder.appendingPathComponent("crash-in-progress.txt").path
        crashFD = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)

        NSSetUncaughtExceptionHandler { exception in
            let text = """
                exception: \(exception.name.rawValue)
                reason: \(exception.reason ?? "none")
                stack:
                \(exception.callStackSymbols.joined(separator: "\n"))
                """
            Diagnostics.writeRaw(text)
        }

        // Only the signals that mean "this process is already broken". SIGPIPE is deliberately not
        // here — a dead media helper closing its pipe is normal and is handled.
        for signalNumber in [SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP] {
            signal(signalNumber) { received in
                // Async-signal-safe only: no allocation, no Foundation, no Swift runtime calls
                // beyond these. `backtrace_symbols_fd` writes straight to the descriptor.
                var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
                let count = backtrace(&frames, 64)
                if Diagnostics.crashFD >= 0 {
                    var header = "signal \(received)\n"
                    header.withUTF8 { buffer in
                        _ = write(Diagnostics.crashFD, buffer.baseAddress, buffer.count)
                    }
                    backtrace_symbols_fd(&frames, count, Diagnostics.crashFD)
                    fsync(Diagnostics.crashFD)
                }
                signal(received, SIG_DFL)
                raise(received)
            }
        }
    }

    nonisolated private static func writeRaw(_ text: String) {
        guard crashFD >= 0 else { return }
        var copy = text + "\n"
        copy.withUTF8 { buffer in
            _ = write(crashFD, buffer.baseAddress, buffer.count)
        }
        fsync(crashFD)
    }

    /// Promotes a crash file left behind by the previous run into a timestamped report, and returns
    /// it. Called once at launch, before anything can crash again.
    static func collectPreviousCrash() -> String? {
        guard let folder = reportsURL else { return nil }
        let inProgress = folder.appendingPathComponent("crash-in-progress.txt")
        guard let data = try? Data(contentsOf: inProgress), !data.isEmpty,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        try? FileManager.default.removeItem(at: inProgress)
        return text
    }

    // MARK: - Private symbol health

    /// Which undocumented symbols still resolve on this machine. The early warning that an OS
    /// update has moved something.
    static func symbolReport() -> [(name: String, resolved: Bool)] {
        [
            ("DisplayServicesGetBrightness", Private.displayServicesGetBrightness != nil),
            ("DisplayServicesSetBrightness", Private.displayServicesSetBrightness != nil),
            ("KeyboardBrightnessClient", Private.keyboardBrightnessClient != nil),
            ("SLSMainConnectionID", Private.cgsMainConnectionID != nil),
            ("SLSSpaceCreate", Private.cgsSpaceCreate != nil),
            ("SLSSpaceAddWindowsAndRemoveFromSpaces", Private.cgsSpaceAddWindows != nil),
            ("SLSIsScreenWatcherPresent", Private.cgsIsScreenWatcherPresent != nil),
        ]
    }

    static var brokenSymbols: [String] {
        symbolReport().filter { !$0.resolved }.map(\.name)
    }

    // MARK: - Report

    /// Everything worth putting in a support email, and nothing else. No identifiers, no file
    /// paths, no calendar or media content.
    static func summary(includingCrash crash: String? = nil) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let symbols = symbolReport()
            .map { "  \($0.resolved ? "ok  " : "GONE") \($0.name)" }
            .joined(separator: "\n")
        var text = """
            Tyland \(App.version) (\(App.build))
            macOS \(os)
            arch: \(machineArch())
            license: \(License.shared.tier)

            private symbols:
            \(symbols)
            """
        if let crash, !crash.isEmpty {
            text += "\n\nprevious crash:\n" + crash
        }
        return text
    }

    private static func machineArch() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    /// Opens a support email with the report already filled in, so a bug report arrives with the
    /// facts rather than "it stopped working".
    static func composeSupportEmail(crash: String? = nil) {
        let body = summary(includingCrash: crash)
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportAddress
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Tyland \(App.version) — support"),
            URLQueryItem(name: "body", value: "\n\n---\n" + body),
        ]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// Replace with your real support address before selling.
    static let supportAddress = "support@example.com"
}
