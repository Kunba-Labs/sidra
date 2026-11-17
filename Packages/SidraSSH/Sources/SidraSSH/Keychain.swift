import Foundation
import Security
import Crypto
import Citadel
import NIOCore
import NIOSSH

/// Thin Keychain wrapper for passwords, tokens and the SSH private key. Generic passwords,
/// `kSecAttrAccessibleAfterFirstUnlock` so background reconnects can read them.
public enum KeychainStore {
    static let service = "nl.sadiq.sidra"

    public static func set(_ data: Data, for key: String) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public static func set(_ string: String, for key: String) throws {
        try set(Data(string.utf8), for: key)
    }

    public static func data(for key: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: key,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    public static func string(for key: String) -> String? {
        data(for: key).flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func remove(_ key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
    }

    public enum KeychainError: Error { case status(OSStatus) }
}

/// One Sidra SSH key: metadata here, the Ed25519 seed in the Keychain under `ssh-key-<id>`.
public struct SSHKeyRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var created: Date
    /// Ask for Face ID or the passcode before the key signs a login.
    public var confirmOnUse: Bool
    public var publicKey: String
    public var fingerprint: String
    /// The private half is a Secure Enclave handle bound to this device; it cannot be exported.
    public var secureEnclave: Bool?
    /// Offered by the SSH agent inside the VM. Off by default: anything running in the VM, the coding agent included, can ask it to sign.
    public var sharedWithVM: Bool?
    public var isSecureEnclave: Bool { secureEnclave == true }
    public var isSharedWithVM: Bool { sharedWithVM == true }
    public init(id: UUID = UUID(), name: String, created: Date = Date(), confirmOnUse: Bool = false, publicKey: String, fingerprint: String, secureEnclave: Bool? = nil, sharedWithVM: Bool? = nil) {
        self.id = id; self.name = name; self.created = created; self.confirmOnUse = confirmOnUse; self.publicKey = publicKey; self.fingerprint = fingerprint
        self.secureEnclave = secureEnclave; self.sharedWithVM = sharedWithVM
    }
}

/// Sidra's SSH identities: Ed25519 keys in the Keychain, a JSON index of their public halves in
/// Application Support/ssh-keys.json. `loadOrCreate()` keeps the original one-key behaviour.
public enum SSHKeyManager {
    static let legacyKeychainKey = "ssh-identity-ed25519"
    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-0000000000ED")!

    public static var indexURL: URL? {
        FileManager.default.sshSupport?.appendingPathComponent("ssh-keys.json")
    }

    public static func keys() -> [SSHKeyRecord] {
        if let url = indexURL, let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([SSHKeyRecord].self, from: data) {
            return list   // an empty list after deleting every key is a real state, not a first run
        }
        // First run or pre-index install: adopt the legacy single key as "Sidra key".
        guard let key = try? loadOrCreate() else { return [] }
        let rec = SSHKeyRecord(id: defaultID, name: "Sidra key", publicKey: openSSHPublicKey(key), fingerprint: fingerprint(key))
        save([rec])
        return [rec]
    }

    static func save(_ list: [SSHKeyRecord]) {
        guard let url = indexURL, let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func keychainKey(_ id: UUID) -> String { id == defaultID ? legacyKeychainKey : "ssh-key-\(id.uuidString)" }

    /// The private key for a record id; nil id or an unknown id falls back to the default key.
    public static func privateKey(id: UUID?) throws -> Curve25519.Signing.PrivateKey {
        let all = keys()
        guard let id, id != defaultID else {
            guard all.contains(where: { $0.id == defaultID }) else { throw KeyError.missing }   // deleted: never regenerate silently
            return try loadOrCreate()
        }
        guard let raw = KeychainStore.data(for: keychainKey(id)) else { throw KeyError.missing }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    }

    public static func record(id: UUID?) -> SSHKeyRecord? {
        let all = keys()
        return all.first { $0.id == id } ?? all.first
    }

    @discardableResult
    public static func generate(name: String) throws -> SSHKeyRecord {
        let key = Curve25519.Signing.PrivateKey()
        let rec = SSHKeyRecord(name: name.isEmpty ? "Key \(keys().count + 1)" : name, publicKey: openSSHPublicKey(key, comment: "sidra@ipad \(name)"), fingerprint: fingerprint(key))
        try KeychainStore.set(key.rawRepresentation, for: keychainKey(rec.id))
        save(keys() + [rec])
        return rec
    }

    /// Imports an OpenSSH private key (`-----BEGIN OPENSSH PRIVATE KEY-----`). Encrypted keys are refused.   // gitleaks:allow (format name in a doc comment)
    @discardableResult
    public static func importOpenSSH(_ text: String, name: String) throws -> SSHKeyRecord {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("BEGIN OPENSSH PRIVATE KEY") else { throw KeyError.notOpenSSH }
        if trimmed.contains("BEGIN RSA PRIVATE KEY") || trimmed.contains("BEGIN EC PRIVATE KEY") { throw KeyError.notOpenSSH }
        let key: Curve25519.Signing.PrivateKey   // gitleaks:allow (a type name)
        do { key = try Curve25519.Signing.PrivateKey(sshEd25519: trimmed) }
        catch {
            let why = String(describing: error).lowercased()
            if why.contains("decryption") || why.contains("encrypted") || why.contains("cipher") { throw KeyError.encrypted }
            if why.contains("unsupported") || why.contains("rsa") || why.contains("ecdsa") { throw KeyError.notEd25519 }
            throw KeyError.malformed(String(describing: error))
        }
        let rec = SSHKeyRecord(name: name.isEmpty ? "Imported key" : name, publicKey: openSSHPublicKey(key, comment: name.isEmpty ? "imported" : name), fingerprint: fingerprint(key))
        try KeychainStore.set(key.rawRepresentation, for: keychainKey(rec.id))
        save(keys() + [rec])
        return rec
    }

    public static func delete(_ id: UUID) {
        KeychainStore.remove(keychainKey(id))
        save(keys().filter { $0.id != id })
    }

    public static func setConfirmOnUse(_ id: UUID, _ on: Bool) {
        var all = keys()
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].confirmOnUse = on
        save(all)
    }

    public static func rename(_ id: UUID, to name: String) {
        var all = keys()
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].name = name
        save(all)
    }

    public static func setSharedWithVM(_ id: UUID, _ on: Bool) {
        var all = keys()
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].sharedWithVM = on
        save(all)
    }

    public static var secureEnclaveAvailable: Bool { SecureEnclave.isAvailable }

    /// A P-256 key created inside the Secure Enclave. The Keychain holds only the device-bound handle.
    @discardableResult
    public static func generateSecureEnclave(name: String) throws -> SSHKeyRecord {
        guard secureEnclaveAvailable else { throw KeyError.secureEnclaveUnavailable }
        let key = try SecureEnclave.P256.Signing.PrivateKey()
        let blob = SSHAgentWire.ecdsaPublicBlob(x963: key.publicKey.x963Representation)
        let label = name.isEmpty ? "Secure Enclave key" : name
        let rec = SSHKeyRecord(name: label, publicKey: "ecdsa-sha2-nistp256 \(blob.base64EncodedString()) sidra@ipad \(label)", fingerprint: fingerprint(blob: blob), secureEnclave: true)
        try KeychainStore.set(key.dataRepresentation, for: keychainKey(rec.id))
        save(keys() + [rec])
        return rec
    }

    static func secureEnclaveKey(id: UUID) throws -> SecureEnclave.P256.Signing.PrivateKey {
        guard secureEnclaveAvailable, let handle = KeychainStore.data(for: keychainKey(id)) else { throw KeyError.missing }
        return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: handle)
    }

    /// How `SSHConnection` logs in with the key a profile names.
    static func authentication(id: UUID?, user: String) throws -> SSHAuthenticationMethod {
        if let id, let rec = keys().first(where: { $0.id == id }), rec.isSecureEnclave {
            return .custom(SinglePrivateKeyAuth(user: user, key: NIOSSHPrivateKey(secureEnclaveP256Key: try secureEnclaveKey(id: id))))
        }
        return .ed25519(username: user, privateKey: try privateKey(id: id))
    }

    /// The keys the VM's agent offers, re-read on every request so a toggle applies at once.
    /// A confirm-on-use key asks every time something in the VM wants a signature.
    static func vmAgentIdentities() -> [AgentIdentity] {
        keys().filter(\.isSharedWithVM).compactMap { rec in
            let fields = rec.publicKey.split(separator: " ")
            guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else { return nil }
            return AgentIdentity(blob: blob, comment: rec.name) { data in
                if rec.confirmOnUse { try await SSHConnection.confirmKeyUse(host: "sidra-vm", reason: "A process in the VM wants to sign with \(rec.name)") }
                if rec.isSecureEnclave {
                    let sig = try secureEnclaveKey(id: rec.id).signature(for: data)
                    return SSHAgentWire.ecdsaSignature(raw: sig.rawRepresentation)
                }
                return SSHAgentWire.ed25519Signature(try privateKey(id: rec.id).signature(for: data))
            }
        }
    }

    static func fingerprint(blob: Data) -> String {
        let b64 = Data(SHA256.hash(data: blob)).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(b64)"
    }

    public static func loadOrCreate() throws -> Curve25519.Signing.PrivateKey {
        if let raw = KeychainStore.data(for: legacyKeychainKey), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        try KeychainStore.set(key.rawRepresentation, for: legacyKeychainKey)
        return key
    }

    /// The key as an unencrypted OpenSSH private key file, for the VM's ~/.ssh (2026-11-15:
    /// one identity for hosts and git, copied into the VM). Secure Enclave keys cannot be exported.
    public static func openSSHPrivateKey(_ key: Curve25519.Signing.PrivateKey, comment: String = "sidra@ipad") -> String {
        func string(_ d: Data) -> Data { var n = UInt32(d.count).bigEndian; return Data(bytes: &n, count: 4) + d }
        let pub = key.publicKey.rawRepresentation
        let pubBlob = string(Data("ssh-ed25519".utf8)) + string(pub)
        let check = UInt32.random(in: 0...UInt32.max)
        var n = check.bigEndian
        var priv = Data(bytes: &n, count: 4) + Data(bytes: &n, count: 4)
        priv += string(Data("ssh-ed25519".utf8)) + string(pub) + string(key.rawRepresentation + pub) + string(Data(comment.utf8))
        var pad: UInt8 = 1
        while priv.count % 8 != 0 { priv.append(pad); pad += 1 }
        var count = UInt32(1).bigEndian
        let body = Data("openssh-key-v1".utf8) + Data([0]) + string(Data("none".utf8)) + string(Data("none".utf8)) + string(Data())
            + Data(bytes: &count, count: 4) + string(pubBlob) + string(priv)
        let b64 = body.base64EncodedString()
        let lines = stride(from: 0, to: b64.count, by: 70).map { i -> String in
            let s = b64.index(b64.startIndex, offsetBy: i); return String(b64[s..<(b64.index(s, offsetBy: 70, limitedBy: b64.endIndex) ?? b64.endIndex)])
        }
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n" + lines.joined(separator: "\n") + "\n-----END OPENSSH PRIVATE KEY-----\n"
    }

    public static func openSSHPublicKey(_ key: Curve25519.Signing.PrivateKey, comment: String = "sidra@ipad") -> String {
        var blob = Data()
        func appendString(_ d: Data) {
            var len = UInt32(d.count).bigEndian
            blob.append(Data(bytes: &len, count: 4))
            blob.append(d)
        }
        appendString(Data("ssh-ed25519".utf8))
        appendString(key.publicKey.rawRepresentation)
        return "ssh-ed25519 \(blob.base64EncodedString()) \(comment)"
    }

    /// SHA256 fingerprint in OpenSSH's display form.
    public static func fingerprint(_ key: Curve25519.Signing.PrivateKey) -> String {
        var blob = Data()
        func appendString(_ d: Data) {
            var len = UInt32(d.count).bigEndian
            blob.append(Data(bytes: &len, count: 4))
            blob.append(d)
        }
        appendString(Data("ssh-ed25519".utf8))
        appendString(key.publicKey.rawRepresentation)
        let digest = SHA256.hash(data: blob)
        let b64 = Data(digest).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(b64)"
    }

    public enum KeyError: Error, LocalizedError {
        case missing, notOpenSSH, encrypted, notEd25519, malformed(String), secureEnclaveUnavailable
        public var errorDescription: String? {
            switch self {
            case .missing: "That key is no longer in the Keychain. Pick another key for this host."
            case .notOpenSSH: "Paste an OpenSSH private key (starts with -----BEGIN OPENSSH PRIVATE KEY-----). PEM and PuTTY formats are not supported."
            case .encrypted: "This key is passphrase-protected. Decrypt it first: ssh-keygen -p -N '' -f <key>, then paste again."
            case .notEd25519: "Only Ed25519 keys are supported. Create one with ssh-keygen -t ed25519."
            case .malformed(let why): "The key could not be read: \(why)"
            case .secureEnclaveUnavailable: "This device has no Secure Enclave. The iPad Simulator never does; create the key on the iPad."
            }
        }
    }
}
