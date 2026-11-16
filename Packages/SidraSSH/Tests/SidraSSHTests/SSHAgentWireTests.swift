import XCTest
import Crypto
import Citadel
import NIOSSH
@testable import SidraSSH

final class SSHAgentWireTests: XCTestCase {
    private func strings(_ d: Data) -> [Data] {
        var out: [Data] = [], at = d.startIndex
        while d.endIndex - at >= 4 {
            let n = d[at..<at + 4].reduce(0) { $0 << 8 | Int($1) }
            out.append(Data(d[at + 4..<at + 4 + n])); at += 4 + n
        }
        return out
    }

    func testListsIdentitiesAndRefusesUnknownMessages() async {
        let id = AgentIdentity(blob: Data([1, 2]), comment: "k") { _ in Data() }
        let reply = await SSHAgentWire.respond(to: Data([11]), identities: [id])
        XCTAssertEqual(reply.first, 12)
        XCTAssertEqual(reply.dropFirst().prefix(4), Data([0, 0, 0, 1]))
        XCTAssertEqual(strings(Data(reply.dropFirst(5))), [Data([1, 2]), Data("k".utf8)])
        let ext = await SSHAgentWire.respond(to: Data([27]), identities: [id])
        XCTAssertEqual(ext, Data([5]))
        let empty = await SSHAgentWire.respond(to: Data(), identities: [id])
        XCTAssertEqual(empty, Data([5]))
    }

    func testSignRefusalAndUnknownKeyAreFailures() async {
        let id = AgentIdentity(blob: Data([9]), comment: "k") { _ in throw SSHConnection.SSHError.confirmationDeclined }
        let req = Data([13]) + SSHAgentWire.string(Data([9])) + SSHAgentWire.string(Data([7])) + SSHAgentWire.u32(0)
        let declined = await SSHAgentWire.respond(to: req, identities: [id])
        XCTAssertEqual(declined, Data([5]))
        let other = Data([13]) + SSHAgentWire.string(Data([8])) + SSHAgentWire.string(Data([7])) + SSHAgentWire.u32(0)
        let unknown = await SSHAgentWire.respond(to: other, identities: [id])
        XCTAssertEqual(unknown, Data([5]))
        let truncated = Data([13, 0, 0, 0, 200, 1])
        let bad = await SSHAgentWire.respond(to: truncated, identities: [id])
        XCTAssertEqual(bad, Data([5]))
    }

    func testP256SignatureVerifies() async throws {
        let key = P256.Signing.PrivateKey()
        let blob = SSHAgentWire.ecdsaPublicBlob(x963: key.publicKey.x963Representation)
        let id = AgentIdentity(blob: blob, comment: "p") { data in SSHAgentWire.ecdsaSignature(raw: try key.signature(for: data).rawRepresentation) }
        let payload = Data("session-to-sign".utf8)
        for _ in 0..<40 {   // enough rounds that r or s with the high bit set is exercised
            let reply = await SSHAgentWire.respond(to: Data([13]) + SSHAgentWire.string(blob) + SSHAgentWire.string(payload) + SSHAgentWire.u32(0), identities: [id])
            XCTAssertEqual(reply.first, 14)
            let sig = strings(strings(Data(reply.dropFirst()))[0])
            XCTAssertEqual(String(decoding: sig[0], as: UTF8.self), "ecdsa-sha2-nistp256")
            let parts = strings(sig[1])
            func raw(_ m: Data) -> Data { let t = m.drop(while: { $0 == 0 }); return Data(repeating: 0, count: 32 - t.count) + t }
            for m in parts { XCTAssertFalse((m.first ?? 0) & 0x80 != 0, "mpint stays positive") }
            let s = try P256.Signing.ECDSASignature(rawRepresentation: raw(parts[0]) + raw(parts[1]))
            XCTAssertTrue(key.publicKey.isValidSignature(s, for: payload))
        }
    }

    func testFramesSplitAndRejectOversize() {
        var b = SSHAgentWire.string(Data([11])) + SSHAgentWire.string(Data([13, 1])) + Data([0, 0])
        XCTAssertEqual(SSHAgentWire.takeFrames(&b), [Data([11]), Data([13, 1])])
        XCTAssertEqual(b, Data([0, 0]))
        var huge = SSHAgentWire.u32(SSHAgentWire.maxMessage + 1)
        XCTAssertNil(SSHAgentWire.takeFrames(&huge))
    }

    func testSSHConfigTextFillsFieldsAndNamesWhatItIgnored() {
        let jump = SSHHostProfile(alias: "bastion", host: "b", user: "u")
        var p = SSHHostProfile(alias: "", host: "", user: "")
        let ignored = SSHConfigText.apply("Host build\n  HostName 10.0.0.9\n  User dev\n  Port=2200\n  ProxyJump bastion\n  # note\n  ForwardAgent yes\n", to: &p, hosts: [jump])
        XCTAssertEqual(p.alias, "build"); XCTAssertEqual(p.host, "10.0.0.9"); XCTAssertEqual(p.user, "dev"); XCTAssertEqual(p.port, 2200); XCTAssertEqual(p.jumpHostID, jump.id)
        XCTAssertEqual(ignored, ["ForwardAgent yes"])
    }

    func testOlderSavedProfilesAndKeysStillDecode() throws {
        let old = #"{"id":"00000000-0000-0000-0000-000000000001","alias":"a","host":"h","port":22,"user":"u","auth":{"key":{}},"startupCommand":"","trustOnFirstUse":true}"#
        let p = try JSONDecoder().decode(SSHHostProfile.self, from: Data(old.utf8))
        XCTAssertNil(p.mosh)
        let oldKey = #"{"id":"00000000-0000-0000-0000-000000000001","name":"k","created":0,"confirmOnUse":false,"publicKey":"x","fingerprint":"y"}"#
        let k = try JSONDecoder().decode(SSHKeyRecord.self, from: Data(oldKey.utf8))
        XCTAssertFalse(k.isSharedWithVM); XCTAssertFalse(k.isSecureEnclave)
    }
}
