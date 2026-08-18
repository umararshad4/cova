#!/usr/bin/env swift
import CryptoKit
import Foundation

// Generates the Ed25519 pair that signs licence blobs, and signs individual licences for testing.
//
//   swift scripts/make-license-key.swift --generate
//   swift scripts/make-license-key.swift --sign <private-key-hex> <email> [machine-uuid] [days]
//
// In production the private key lives in the checkout Worker's secrets and never touches this
// machine — this script exists so the format can be exercised end to end before that is wired up.

func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

func data(hex string: String) -> Data? {
    guard string.count % 2 == 0 else { return nil }
    var bytes = [UInt8]()
    var i = string.startIndex
    while i < string.endIndex {
        let j = string.index(i, offsetBy: 2)
        guard let b = UInt8(string[i..<j], radix: 16) else { return nil }
        bytes.append(b); i = j
    }
    return Data(bytes)
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "--generate":
    let key = Curve25519.Signing.PrivateKey()
    print("private (Worker secret, never commit): \(hex(key.rawRepresentation))")
    print("public  (paste into License.publicKeyHex): \(hex(key.publicKey.rawRepresentation))")

case "--sign":
    guard args.count >= 3, let raw = data(hex: args[1]),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else {
        FileHandle.standardError.write("usage: --sign <private-hex> <email> [machine] [days]\n".data(using: .utf8)!)
        exit(2)
    }
    let email = args[2]
    let machine = args.count > 3 ? args[3] : ""
    let days = args.count > 4 ? Double(args[4]) ?? 45 : 45

    let payload: [String: Any] = [
        "tier": "pro",
        "email": email,
        "machine": machine,
        "issued": Date().timeIntervalSince1970,
        "expires": Date().addingTimeInterval(days * 86_400).timeIntervalSince1970,
        "seats": 3,
    ]
    let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let signature = try key.signature(for: json)
    print("\(base64URL(json)).\(base64URL(signature))")

default:
    print("""
    usage:
      make-license-key.swift --generate
      make-license-key.swift --sign <private-key-hex> <email> [machine-uuid] [days]
    """)
}
