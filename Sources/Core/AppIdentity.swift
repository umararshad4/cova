import Foundation

/// Everything that needs to name the app, in one place.
///
/// The bundle identifier is the primary key for every TCC grant, for `UserDefaults`, for
/// `SMAppService` login-item registration and for the update feed. It can be changed exactly once
/// without resetting every user's permissions and preferences — so it is read from the bundle
/// rather than typed into a dozen files, and `Resources/Info.plist` is the only place it lives.
enum App {
    /// Falls back only when running a bare binary outside a bundle (a `swiftc` scratch build).
    static let bundleID = Bundle.main.bundleIdentifier ?? "dev.local.tyland"

    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Tyland"

    static let version =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"

    /// Label for a private dispatch queue, e.g. `App.queue("downloads")`.
    static func queue(_ suffix: String) -> String { "\(bundleID).\(suffix)" }

    /// A `defaults write` line the user can paste, always naming the real domain.
    static func defaultsCommand(_ key: String, _ value: String) -> String {
        "defaults write \(bundleID) \(key) \(value)"
    }
}
