import Foundation
import Observation

/// Host profiles, persisted as JSON. Passwords go to the Keychain, never into this file.
@MainActor
@Observable
public final class HostStore {
    public private(set) var hosts: [SSHHostProfile]
    private let url: URL?

    public init(url: URL? = HostStore.defaultURL) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([SSHHostProfile].self, from: data) {
            hosts = saved
        } else {
            hosts = []
        }
    }

    public nonisolated static var defaultURL: URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent("hosts.json")
    }

    public func host(_ id: UUID) -> SSHHostProfile? { hosts.first { $0.id == id } }

    public func upsert(_ profile: SSHHostProfile, password: String? = nil) {
        if let i = hosts.firstIndex(where: { $0.id == profile.id }) { hosts[i] = profile } else { hosts.append(profile) }
        if let password { try? KeychainStore.set(password, for: profile.passwordKey) }
        save()
    }

    public func remove(_ id: UUID) {
        if let p = host(id) { KeychainStore.remove(p.passwordKey) }
        hosts.removeAll { $0.id == id }
        save()
    }

    private func save() {
        guard let url, let data = try? JSONEncoder().encode(hosts) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
