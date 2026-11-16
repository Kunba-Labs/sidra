import Foundation

/// A remote host the user can open shells on. Credentials never live here: passwords sit in the
/// Keychain under `passwordKey`, private keys under the key manager.
public struct SSHHostProfile: Codable, Identifiable, Hashable, Sendable {
    public enum Auth: Codable, Hashable, Sendable {
        case password
        case key
    }

    public var id: UUID
    public var alias: String
    public var host: String
    public var port: Int
    public var user: String
    public var auth: Auth
    /// Run on connect, e.g. `tmux new -A -s sidra`. Empty means a plain login shell.
    public var startupCommand: String
    /// Hosts on the same LAN (the sidra-vm container) need no host key pinning prompt.
    public var trustOnFirstUse: Bool
    /// Which Sidra key signs for this host; nil means the default (first) key.
    public var keyID: UUID?
    /// Non-nil makes this host's panes mosh-compatible sessions instead of plain SSH.
    public var mosh: MoshSettings?
    /// Another saved host to tunnel through. One hop.
    public var jumpHostID: UUID?
    /// The ssh_config text the user pasted; `SSHConfigText` applies it to the fields above on save.
    public var rawConfig: String?

    public init(id: UUID = UUID(), alias: String, host: String, port: Int = 22, user: String,
                auth: Auth = .key, startupCommand: String = "", trustOnFirstUse: Bool = true, keyID: UUID? = nil,
                mosh: MoshSettings? = nil, jumpHostID: UUID? = nil, rawConfig: String? = nil) {
        self.id = id
        self.mosh = mosh
        self.jumpHostID = jumpHostID
        self.rawConfig = rawConfig
        self.keyID = keyID
        self.alias = alias
        self.host = host
        self.port = port
        self.user = user
        self.auth = auth
        self.startupCommand = startupCommand
        self.trustOnFirstUse = trustOnFirstUse
    }

    public var passwordKey: String { "ssh-password-\(id.uuidString)" }
}

public struct MoshSettings: Codable, Hashable, Sendable {
    /// Empty means `mosh-server` on the host's PATH.
    public var serverPath: String
    /// `mosh-server -p` range; a NAT or firewall must let these UDP ports through.
    public var portRange: String
    public init(serverPath: String = "", portRange: String = "60000:61000") { self.serverPath = serverPath; self.portRange = portRange }
}

/// Applies the keywords Sidra understands from a pasted ssh_config block.
public enum SSHConfigText {
    /// Unknown keywords are ignored and returned so the editor can say which ones did nothing.
    /// ProxyJump is matched against the aliases of saved hosts.
    @discardableResult
    public static func apply(_ text: String, to p: inout SSHHostProfile, hosts: [SSHHostProfile]) -> [String] {
        var ignored: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
            guard parts.count == 2 else { ignored.append(line); continue }
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t=\""))
            switch parts[0].lowercased() {
            case "host": if p.alias.isEmpty { p.alias = value }
            case "hostname": p.host = value
            case "user": p.user = value
            case "port": if let n = Int(value), (1...65535).contains(n) { p.port = n } else { ignored.append(line) }
            case "proxyjump":
                if let j = hosts.first(where: { $0.alias == value && $0.id != p.id }) { p.jumpHostID = j.id } else { ignored.append(line) }
            default: ignored.append(line)
            }
        }
        return ignored
    }
}

public enum SSHConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}
