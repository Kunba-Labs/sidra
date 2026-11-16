import Foundation
import SidraSSH

/// An SSH server for the live tests: SIDRA_TEST_SSH=user:password@host:port, default
/// sidra:sidra@localhost:2222. Tests that need it skip when it does not answer.
enum TestHost {
    private static let raw = ProcessInfo.processInfo.environment["SIDRA_TEST_SSH"] ?? "sidra:sidra@localhost:2222"
    private static let cred = raw.components(separatedBy: "@").first ?? ""
    private static let addr = raw.components(separatedBy: "@").dropFirst().first ?? "localhost:2222"
    static let password = cred.components(separatedBy: ":").dropFirst().joined(separator: ":")

    static let profile = SSHHostProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000007e57")!, alias: "test-host",
        host: addr.components(separatedBy: ":")[0], port: Int(addr.components(separatedBy: ":").last ?? "") ?? 22,
        user: cred.components(separatedBy: ":")[0], auth: .password, startupCommand: "", trustOnFirstUse: true)

    static func storePassword() { try? KeychainStore.set(password, for: profile.passwordKey) }
}
