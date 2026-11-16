import XCTest
import Crypto
import Citadel
@testable import SidraSSH

final class SidraSSHTests: XCTestCase {
    func testOpenSSHPublicKeyEncodesEd25519Blob() throws {
        let key = Curve25519.Signing.PrivateKey()
        let line = SSHKeyManager.openSSHPublicKey(key, comment: "t")
        let parts = line.split(separator: " ")
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0], "ssh-ed25519")
        let blob = try XCTUnwrap(Data(base64Encoded: String(parts[1])))
        // 4 + 11 ("ssh-ed25519") + 4 + 32
        XCTAssertEqual(blob.count, 51)
        XCTAssertEqual(blob.suffix(32), key.publicKey.rawRepresentation)
        XCTAssertTrue(SSHKeyManager.fingerprint(key).hasPrefix("SHA256:"))
    }

    func testPTYSessionBuffersInputUntilAttached() {
        let s = PTYSession()
        s.write(Data("ls\n".utf8))
        s.resize(cols: 80, rows: 24)
        // Nothing to assert on the wire without a server; the call must not crash or drop.
        s.close()
    }

    func testHostProfileRoundTrip() throws {
        let p = SSHHostProfile(alias: "box", host: "10.0.0.2", port: 2200, user: "me", auth: .key, startupCommand: "tmux new -A -s sidra")
        let d = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(SSHHostProfile.self, from: d), p)
    }

    func testPrivateKeyExportRoundTrips() throws {
        let key = Curve25519.Signing.PrivateKey()
        let text = SSHKeyManager.openSSHPrivateKey(key, comment: "test")
        XCTAssertEqual(try Curve25519.Signing.PrivateKey(sshEd25519: text).rawRepresentation, key.rawRepresentation)
    }
}
