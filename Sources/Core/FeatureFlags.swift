import CryptoKit
import Foundation

/// A remote kill switch for features built on undocumented APIs.
///
/// When Apple changes something in a point release, the choice is otherwise: ship a Sparkle update
/// and wait days for it to propagate, or watch every customer hit the same broken feature. This
/// fetches a small signed list of features to switch off, so the blast radius is hours.
///
/// Three properties matter and are all deliberate:
///
/// - **Fail-open.** Any failure — offline, bad signature, malformed, no feed configured — leaves
///   every feature enabled. A kill switch that can accidentally disable the product is worse than
///   no kill switch.
/// - **Signed.** The payload is verified with the same Ed25519 key as licences, so whoever controls
///   the URL cannot disable features for your users without the private key.
/// - **Never blocking.** Nothing waits on the network. The cached answer is used immediately and
///   refreshed in the background.
@MainActor
final class FeatureFlags: ObservableObject {
    static let shared = FeatureFlags()

    /// Where the signed flag file lives. Empty disables the mechanism entirely.
    ///
    /// Set this to a static file on a host you control before selling — a Cloudflare/GitHub Pages
    /// URL is plenty. See `worker/flags.json.example`.
    static let feedURL = ""

    /// Names a feature can be switched off by. Anything unrecognised is ignored, so an older build
    /// cannot be broken by a newer flag.
    enum Feature: String {
        case lockScreen
        case audioTap
        case mediaHelper
        case routes
    }

    @Published private(set) var disabled: Set<String> = []

    func isEnabled(_ feature: Feature) -> Bool { !disabled.contains(feature.rawValue) }

    private struct Payload: Codable {
        var issued: Double
        var disabled: [String]
        /// Ignore a payload aimed at other versions. Empty means "all".
        var versions: [String]?
    }

    private var cacheURL: URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let folder = base.appendingPathComponent(App.bundleID, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("flags.txt")
    }

    private init() {
        // The cached answer applies immediately; the network is never on the launch path.
        if let cacheURL, let blob = try? String(contentsOf: cacheURL, encoding: .utf8) {
            apply(blob)
        }
    }

    func start() {
        guard !Self.feedURL.isEmpty, let url = URL(string: Self.feedURL) else { return }
        refresh(from: url)
        // Once a day is enough to bound the damage without being a heartbeat to a server.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(86_400))
                guard let self else { return }
                self.refresh(from: url)
            }
        }
    }

    private func refresh(from url: URL) {
        Task { [weak self] in
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let blob = String(data: data, encoding: .utf8)
            else { return }   // fail open
            guard let self else { return }
            guard self.apply(blob) else { return }
            if let cacheURL = self.cacheURL {
                try? blob.write(to: cacheURL, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Verifies and applies a signed flag payload. Returns whether it was accepted.
    @discardableResult
    func apply(_ blob: String) -> Bool {
        guard let payload = Self.verify(
            blob,
            publicKeyHex: License.publicKeyHex,
            version: App.version
        ) else { return false }
        disabled = Set(payload)
        if !disabled.isEmpty { Debug.log("feature flags: disabled \(disabled.sorted())") }
        return true
    }

    /// Pure, so `--self-test` can drive it. Returns the disabled list, or nil if the payload is not
    /// trustworthy — in which case the caller must leave everything enabled.
    static func verify(_ blob: String, publicKeyHex: String, version: String) -> [String]? {
        let parts = blob.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let payloadData = Data(base64URLEncoded: String(parts[0])),
              let signature = Data(base64URLEncoded: String(parts[1])),
              let keyData = Data(hexEncoded: publicKeyHex), keyData.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              key.isValidSignature(signature, for: payloadData),
              let payload = try? JSONDecoder().decode(Payload.self, from: payloadData)
        else { return nil }

        if let versions = payload.versions, !versions.isEmpty, !versions.contains(version) {
            return []   // signed, but not aimed at this build
        }
        return payload.disabled
    }
}
