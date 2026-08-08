import Foundation

/// stderr tracing, off unless `TYLAND_DEBUG=1`. Keeps verification honest during the build —
/// the island is hard to observe otherwise, and a log line beats guessing.
enum Debug {
    static let enabled = ProcessInfo.processInfo.environment["TYLAND_DEBUG"] == "1"

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write("[tyland] \(message())\n".data(using: .utf8)!)
    }
}
