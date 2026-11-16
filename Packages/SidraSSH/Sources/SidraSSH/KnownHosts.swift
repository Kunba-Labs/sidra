import Foundation
import Crypto
import NIOCore
import NIOSSH

/// Server host keys Sidra has accepted, one `host:port ssh-ed25519 AAAA…` line each, in
/// Application Support/known_hosts (not secret, not in the repo).
public enum KnownHosts {
    public static var url: URL? {
        (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?
            .appendingPathComponent("known_hosts")
    }

    static func lines() -> [String] {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Parses a known_hosts text into `host:port` → `type base64`.
    public static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let p = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard p.count >= 3, !p[0].hasPrefix("#") else { continue }
            out[p[0]] = "\(p[1]) \(p[2])"
        }
        return out
    }

    public static func key(host: String, port: Int) -> String { port == 22 ? host : "[\(host)]:\(port)" }

    /// The recorded `type base64` for a host, if any.
    public static func entry(host: String, port: Int) -> String? {
        parse(lines().joined(separator: "\n"))[key(host: host, port: port)]
    }

    public static func record(host: String, port: Int, publicKey: String) {
        var map = parse(lines().joined(separator: "\n"))
        map[key(host: host, port: port)] = publicKey
        guard let url else { return }
        let text = map.map { "\($0.key) \($0.value)" }.sorted().joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func forget(host: String, port: Int) {
        var map = parse(lines().joined(separator: "\n"))
        map[key(host: host, port: port)] = nil
        guard let url else { return }
        try? (map.map { "\($0.key) \($0.value)" }.sorted().joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// OpenSSH `type base64` string for a server key. NIOSSH keeps its backing key internal, so the
    /// payload is read through Mirror; a key type we cannot read gives nil (accepted once, never pinned).
    /// ponytail: reflection instead of a fork of NIOSSH; swap for a public serializer when NIOSSH grows one.
    public static func openSSH(_ key: NIOSSHPublicKey) -> String? {
        guard let backing = Mirror(reflecting: key).children.first(where: { $0.label == "backingKey" })?.value,
              let payload = Mirror(reflecting: backing).children.first else { return nil }
        var blob = Data()
        func str(_ d: Data) { var n = UInt32(d.count).bigEndian; blob.append(Data(bytes: &n, count: 4)); blob.append(d) }
        switch payload.label {
        case "ed25519":
            guard let k = payload.value as? Curve25519.Signing.PublicKey else { return nil }
            str(Data("ssh-ed25519".utf8)); str(k.rawRepresentation)
            return "ssh-ed25519 \(blob.base64EncodedString())"
        case "ecdsaP256":
            guard let k = payload.value as? P256.Signing.PublicKey else { return nil }
            str(Data("ecdsa-sha2-nistp256".utf8)); str(Data("nistp256".utf8)); str(k.x963Representation)
            return "ecdsa-sha2-nistp256 \(blob.base64EncodedString())"
        case "ecdsaP384":
            guard let k = payload.value as? P384.Signing.PublicKey else { return nil }
            str(Data("ecdsa-sha2-nistp384".utf8)); str(Data("nistp384".utf8)); str(k.x963Representation)
            return "ecdsa-sha2-nistp384 \(blob.base64EncodedString())"
        default:
            return nil
        }
    }

    /// SHA256 fingerprint of a `type base64` string, OpenSSH display form.
    public static func fingerprint(_ openSSH: String) -> String {
        let b64 = openSSH.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        guard let blob = Data(base64Encoded: b64) else { return "unknown" }
        return "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

/// The server presented a key that differs from the recorded one.
public struct HostKeyChanged: Error, LocalizedError {
    public let host: String
    public let port: Int
    public let oldFingerprint: String
    public let newKey: String
    public init(host: String, port: Int, oldFingerprint: String, newKey: String) {
        self.host = host; self.port = port; self.oldFingerprint = oldFingerprint; self.newKey = newKey
    }
    public var newFingerprint: String { KnownHosts.fingerprint(newKey) }
    public var errorDescription: String? { "Host key for \(host) changed: was \(oldFingerprint), now \(newFingerprint)" }
}

/// Asked once per unknown host when the profile is not trust-on-first-use.
public struct HostKeyPrompt: Sendable {
    public let host: String
    public let port: Int
    public let publicKey: String
    public var fingerprint: String { KnownHosts.fingerprint(publicKey) }
}

/// Citadel host key delegate backed by `KnownHosts`.
final class KnownHostsValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let host: String
    let port: Int
    let trustOnFirstUse: Bool
    /// Set by the app; nil means unknown hosts are refused unless trust-on-first-use.
    nonisolated(unsafe) static var prompt: (@Sendable (HostKeyPrompt) async -> Bool)?

    init(host: String, port: Int, trustOnFirstUse: Bool) {
        self.host = host; self.port = port; self.trustOnFirstUse = trustOnFirstUse
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        guard let presented = KnownHosts.openSSH(hostKey) else {
            // ponytail: RSA and unknown key types cannot be pinned yet, so they are refused rather than
            // accepted blind; ask the server for an ed25519 or ECDSA host key.
            validationCompletePromise.fail(SSHFailure.unsupportedHostKey)
            return
        }
        if let known = KnownHosts.entry(host: host, port: port) {
            if known == presented { validationCompletePromise.succeed(()) }
            else { validationCompletePromise.fail(HostKeyChanged(host: host, port: port, oldFingerprint: KnownHosts.fingerprint(known), newKey: presented)) }
            return
        }
        if trustOnFirstUse {
            KnownHosts.record(host: host, port: port, publicKey: presented)
            validationCompletePromise.succeed(())
            return
        }
        guard let prompt = Self.prompt else { validationCompletePromise.fail(SSHFailure.untrustedHost); return }
        let request = HostKeyPrompt(host: host, port: port, publicKey: presented)
        Task {
            if await prompt(request) {
                KnownHosts.record(host: host, port: port, publicKey: presented)
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(SSHFailure.untrustedHost)
            }
        }
    }
}

/// One classification of a connection error for the UI: what failed and what to do next.
public enum SSHFailure: Error, LocalizedError {
    case untrustedHost
    case unsupportedHostKey
    public var errorDescription: String? {
        switch self {
        case .untrustedHost: "Host key not trusted"
        case .unsupportedHostKey: "The server offered a host key type Sidra cannot verify (only ed25519 and ECDSA are pinned). Enable an ed25519 host key on the server."
        }
    }

    public struct Description: Sendable, Equatable {
        public let title: String
        public let detail: String
        public let kind: Kind
        public enum Kind: Sendable { case auth, unreachable, hostKeyChanged, localNetwork, untrusted, other }
    }

    public static func describe(_ error: Error, host: String) -> Description {
        if let c = error as? HostKeyChanged {
            return .init(title: "Host key for \(host) changed", detail: "Was \(c.oldFingerprint), now \(c.newFingerprint). Accept only if the server was reinstalled or its key rotated on purpose.", kind: .hostKeyChanged)
        }
        if error is SSHFailure { return .init(title: "Host key not trusted", detail: "You declined the fingerprint for \(host). Connect again to see it.", kind: .untrusted) }
        let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        let lower = text.lowercased()
        if lower.contains("allauthenticationoptionsfailed") || lower.contains("authenticationfailed") || lower.contains("permission denied") {
            return .init(title: "\(host) rejected the login", detail: "The key or password was not accepted. Install Sidra's public key in ~/.ssh/authorized_keys on the host, or check the user name and password.", kind: .auth)
        }
        if lower.contains("65570") || lower.contains("local network") || lower.contains("not permitted") {
            return .init(title: "Local network access blocked", detail: "iPadOS blocked Sidra from the local network. Settings → Privacy & Security → Local Network → allow Sidra, then retry.", kind: .localNetwork)
        }
        if lower.contains("connecttimeout") || lower.contains("timed out") || lower.contains("no route") || lower.contains("unreachable") || lower.contains("connection refused") || lower.contains("connectionresetbypeer") || lower.contains("nodename nor servname") || lower.contains("could not resolve") {
            return .init(title: "\(host) did not answer", detail: "Check the address and port, that the host is on and reachable from this network, and that a VPN or Tailscale profile is not hiding the LAN.", kind: .unreachable)
        }
        return .init(title: "Could not connect to \(host)", detail: text, kind: .other)
    }
}
