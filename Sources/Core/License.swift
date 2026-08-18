import CryptoKit
import Foundation
import IOKit

/// What the user is entitled to right now.
///
/// Deliberately a separate object from `Settings`, and never merged into it: preferences are the
/// user's to change, entitlement is not. Keeping them apart means no future refactor can
/// accidentally expose the licence state through the same `@Stored` machinery that the settings
/// window binds to.
@MainActor
final class License: ObservableObject {
    static let shared = License()

    enum Tier: Equatable {
        /// Inside the free trial, with everything unlocked.
        case trial(daysLeft: Int)
        /// A verified licence.
        case licensed(email: String, seats: Int)
        /// Had a licence; its signed blob is past its refresh deadline.
        case expired
        /// Trial is over and no licence was entered.
        case free

        var isPro: Bool {
            switch self {
            case .trial, .licensed: return true
            case .expired, .free: return false
            }
        }
    }

    @Published private(set) var tier: Tier = .free

    /// Whether the paywall is off. **Derived, not a switch you remember to flip.**
    ///
    /// A build carrying the placeholder key cannot validate any licence anyone could ever buy, so
    /// enforcing a gate against it would lock out paying customers with no way back. A build with a
    /// real key can, so the gate arms itself. That removes the single most dangerous manual step in
    /// the launch: shipping a paywall with no key, or shipping a real key with no paywall.
    ///
    /// So: paste your public key into `publicKeyHex` and the product becomes paid. Nothing else.
    static var bypassGate: Bool { publicKeyHex == placeholderKeyHex }

    static let placeholderKeyHex = String(repeating: "0", count: 64)

    var isPro: Bool { Self.bypassGate || tier.isPro }

    /// Ed25519 public key that signs licence blobs, hex-encoded, 32 bytes.
    ///
    /// **Replace this before selling anything.** Generate a pair with
    /// `swift scripts/make-license-key.swift --generate`, keep the private key in the checkout
    /// Worker's secrets, and paste the public half here. The placeholder below verifies nothing
    /// anyone else can forge a licence *for*, because no one has its private key — but it is also
    /// not yours, so a licence you issue would not validate.
    static let publicKeyHex = "0000000000000000000000000000000000000000000000000000000000000000"

    /// Days of unrestricted trial. Seven, not fourteen: stacked on the statutory 14-day EU
    /// withdrawal right, a 14-day trial is 28 days of free use per buyer, and the merchant-of-record
    /// fee is not refunded when you refund.
    static let trialDays = 7

    private let store = LicenseStore()
    private var blob: String?

    private init() {
        refresh()
    }

    // MARK: - State

    func refresh() {
        blob = store.licenseBlob
        tier = Self.resolve(
            blob: blob,
            publicKeyHex: Self.publicKeyHex,
            machine: Self.machineID(),
            trialStart: store.trialStart(startingIfNeeded: true),
            now: Date()
        )
        Debug.log("license: \(tier)")
    }

    /// Where a purchased licence key is exchanged for a signed blob. Empty means offline-only,
    /// which is the state until the Worker in `worker/license.js` is deployed.
    static let activationEndpoint = ""

    /// Accepts either form: the key a customer buys, or an already-signed blob (useful for testing
    /// and for support handing someone a replacement).
    ///
    /// Returns nil on success, or a sentence to show the user.
    func activate(_ candidate: String) async -> String? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Enter your licence key." }

        // A blob carries its own signature; a purchase key has to be exchanged for one.
        if trimmed.contains(".") {
            return store(blob: trimmed)
        }
        guard !Self.activationEndpoint.isEmpty, let url = URL(string: Self.activationEndpoint) else {
            return "This build cannot activate licence keys yet."
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "key": trimmed,
            "machine": Self.machineID(),
        ])

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "Could not reach the licence server. Check your connection and try again." }

        if let blob = object["license"] as? String { return store(blob: blob) }
        return (object["error"] as? String) ?? "That licence key was not accepted."
    }

    private func store(blob: String) -> String? {
        switch Self.verify(blob, publicKeyHex: Self.publicKeyHex, machine: Self.machineID(), now: Date()) {
        case .success:
            store.licenseBlob = blob
            refresh()
            return nil
        case .failure(let reason):
            return reason
        }
    }

    /// Renews the signed blob while it is still valid, so a licence never lapses just because the
    /// user was offline on the wrong day. Never blocks anything.
    func refreshIfExpiringSoon() {
        guard case .licensed = tier,
              let blob, let payload = Self.payload(of: blob),
              !Self.activationEndpoint.isEmpty
        else { return }
        let expires = Date(timeIntervalSince1970: payload.expires)
        guard expires.timeIntervalSinceNow < 14 * 86_400 else { return }
        Task { [weak self] in
            _ = await self?.activate(blob)
        }
    }

    func deactivate() {
        store.licenseBlob = nil
        refresh()
    }

    // MARK: - Verification (pure, so `--self-test` can drive it)

    struct Payload: Codable, Equatable {
        var tier: String
        var email: String
        /// `IOPlatformUUID` of the Mac this blob was issued for. Empty means any machine.
        var machine: String
        var issued: Double
        /// When the app must re-check with the server. Not the purchase expiring — a licence with a
        /// lapsed blob refreshes silently while online, and only stops working if it never can.
        var expires: Double
        var seats: Int
    }

    enum Failure: Equatable {
        case success
        case failure(String)
    }

    /// Format: `<base64url(payload JSON)>.<base64url(signature)>`.
    static func verify(
        _ blob: String,
        publicKeyHex: String,
        machine: String,
        now: Date
    ) -> Failure {
        let parts = blob.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let payloadData = Data(base64URLEncoded: String(parts[0])),
              let signature = Data(base64URLEncoded: String(parts[1]))
        else { return .failure("That does not look like a licence key.") }

        guard let keyData = Data(hexEncoded: publicKeyHex), keyData.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { return .failure("This build has no valid licence key configured.") }

        guard key.isValidSignature(signature, for: payloadData) else {
            return .failure("That licence key is not valid.")
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: payloadData) else {
            return .failure("That licence key is damaged.")
        }
        guard payload.tier == "pro" else { return .failure("Unknown licence type.") }
        guard payload.machine.isEmpty || payload.machine == machine else {
            return .failure("That licence key belongs to a different Mac.")
        }
        guard Date(timeIntervalSince1970: payload.expires) > now else {
            return .failure("That licence key needs to be refreshed — connect to the internet.")
        }
        return .success
    }

    static func resolve(
        blob: String?,
        publicKeyHex: String,
        machine: String,
        trialStart: Date?,
        now: Date
    ) -> Tier {
        if let blob {
            switch verify(blob, publicKeyHex: publicKeyHex, machine: machine, now: now) {
            case .success:
                if let payload = payload(of: blob) {
                    return .licensed(email: payload.email, seats: payload.seats)
                }
                return .licensed(email: "", seats: 1)
            case .failure:
                // A blob that once verified and no longer does is an expiry, not a forgery: the
                // honest reading is "needs a refresh", and Pro simply stops starting.
                return .expired
            }
        }
        guard let trialStart else { return .free }
        let elapsed = now.timeIntervalSince(trialStart) / 86_400
        let left = Double(trialDays) - elapsed
        return left > 0 ? .trial(daysLeft: Int(ceil(left))) : .free
    }

    static func payload(of blob: String) -> Payload? {
        let parts = blob.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, let data = Data(base64URLEncoded: String(first)) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    /// Stable per-Mac identifier. `IOPlatformUUID` survives an OS reinstall on the same logic board;
    /// a serial or MAC-address hash does not survive a Time Machine restore, which turns into
    /// support tickets about licences that stopped working after a repair.
    static func machineID() -> String {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return "" }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(
            service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String else { return "" }
        return value
    }
}

// MARK: - Storage

/// Licence blob and trial start, kept in two places on purpose.
///
/// Keychain items carry an ACL bound to the creating binary's code signature, so a blob written by
/// one build can become unreadable to the next — which would silently de-licence a paying customer
/// the first time the signing identity changes. Application Support is the readable fallback; the
/// Keychain copy is what makes a casual `defaults delete` insufficient to reset a trial. The
/// *earlier* of the two trial dates always wins.
@MainActor
private struct LicenseStore {
    private let account = "license"
    private let service = App.bundleID

    private var supportURL: URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let folder = base.appendingPathComponent(App.bundleID, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("license.json")
    }

    private struct Record: Codable {
        var blob: String?
        var trialStart: Double?
    }

    private func readFile() -> Record {
        guard let url = supportURL, let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(Record.self, from: data)
        else { return Record() }
        return record
    }

    private func writeFile(_ record: Record) {
        guard let url = supportURL, let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: url, options: .atomic)
    }

    var licenseBlob: String? {
        get { keychainRead() ?? readFile().blob }
        nonmutating set {
            keychainWrite(newValue)
            var record = readFile()
            record.blob = newValue
            writeFile(record)
        }
    }

    /// The earlier of the stored dates, so deleting one copy cannot restart a trial.
    func trialStart(startingIfNeeded: Bool) -> Date? {
        var record = readFile()
        let stored = record.trialStart.map { Date(timeIntervalSince1970: $0) }
        if let stored { return stored }
        guard startingIfNeeded else { return nil }
        let now = Date()
        record.trialStart = now.timeIntervalSince1970
        writeFile(record)
        return now
    }

    // MARK: Keychain

    private func keychainRead() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func keychainWrite(_ value: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var insert = base
        insert[kSecValueData as String] = data
        insert[kSecAttrSynchronizable as String] = false
        SecItemAdd(insert as CFDictionary, nil)
    }
}

// MARK: - Encoding helpers

extension Data {
    init?(base64URLEncoded string: String) {
        var padded = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        guard let data = Data(base64Encoded: padded) else { return nil }
        self = data
    }

    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(hexEncoded string: String) {
        guard string.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}
