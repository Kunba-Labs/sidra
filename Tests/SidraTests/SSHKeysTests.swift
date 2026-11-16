import XCTest
import SidraSSH
@testable import Sidra

final class SSHKeysTests: XCTestCase {
    func testKnownHostsParseAndKey() {
        let text = "# comment\nhost.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGFiYw==\n[lan.local]:2222 ecdsa-sha2-nistp256 AAAA\n"
        let map = KnownHosts.parse(text)
        XCTAssertEqual(map.count, 2)
        XCTAssertEqual(map["host.example"], "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGFiYw==")
        XCTAssertEqual(KnownHosts.key(host: "lan.local", port: 2222), "[lan.local]:2222")
        XCTAssertEqual(KnownHosts.key(host: "host.example", port: 22), "host.example")
        XCTAssertTrue(KnownHosts.fingerprint("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGFiYw==").hasPrefix("SHA256:"))
    }

    func testImportRejectsEncryptedAndForeignKeys() {
        XCTAssertThrowsError(try SSHKeyManager.importOpenSSH("-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----", name: "x")) {
            XCTAssertEqual(($0 as? LocalizedError)?.errorDescription?.contains("OpenSSH") , true)
        }
        XCTAssertThrowsError(try SSHKeyManager.importOpenSSH("not a key", name: "x"))
    }

    func testFailureClassification() {
        XCTAssertEqual(SSHFailure.describe(AppError.message("allAuthenticationOptionsFailed"), host: "h").kind, .auth)
        XCTAssertEqual(SSHFailure.describe(AppError.message("connectTimeout(15s)"), host: "h").kind, .unreachable)
        XCTAssertEqual(SSHFailure.describe(AppError.message("Operation not permitted (-65570)"), host: "h").kind, .localNetwork)
        XCTAssertEqual(SSHFailure.describe(HostKeyChanged(host: "h", port: 22, oldFingerprint: "SHA256:a", newKey: "ssh-ed25519 AAAA"), host: "h").kind, .hostKeyChanged)
    }
}
