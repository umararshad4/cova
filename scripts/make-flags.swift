#!/usr/bin/env swift
import CryptoKit
import Foundation

// Signs a kill-switch payload with the same key that signs licences.
//
//   swift scripts/make-flags.swift <private-key-hex> [feature ...] [--versions 1.2.0,1.2.1]
//
// Feature names: lockScreen, audioTap, mediaHelper, routes.
// With no features named, it signs an all-clear — which is how you turn a feature back on.

func data(hex string: String) -> Data? {
    guard string.count % 2 == 0 else { return nil }
    var bytes = [UInt8](); var i = string.startIndex
    while i < string.endIndex {
        let j = string.index(i, offsetBy: 2)
        guard let b = UInt8(string[i..<j], radix: 16) else { return nil }
        bytes.append(b); i = j
    }
    return Data(bytes)
}

func base64URL(_ d: Data) -> String {
    d.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

var args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first, let raw = data(hex: first),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
else {
    FileHandle.standardError.write("usage: make-flags.swift <private-key-hex> [feature ...] [--versions a,b]\n".data(using: .utf8)!)
    exit(2)
}
args.removeFirst()

var versions: [String]?
if let index = args.firstIndex(of: "--versions"), index + 1 < args.count {
    versions = args[index + 1].split(separator: ",").map(String.init)
    args.removeSubrange(index...(index + 1))
}

var object: [String: Any] = [
    "issued": Date().timeIntervalSince1970,
    "disabled": args,
]
if let versions { object["versions"] = versions }

let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
let signature = try key.signature(for: json)
print("\(base64URL(json)).\(base64URL(signature))")
