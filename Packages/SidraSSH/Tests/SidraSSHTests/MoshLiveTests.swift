import XCTest
import Crypto
import Citadel
import NIOSSH
@testable import SidraSSH

/// Against a container on localhost:2223 with udp 60100-60110 published (docker/sidra-vm image). Skips when absent.
final class MoshLiveTests: XCTestCase {
    private func docker(_ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["docker"] + args
        try p.run()
        p.waitUntilExit()
    }

    private func profile() throws -> SSHHostProfile {
        var p = SSHHostProfile(id: UUID(uuidString: "00000000-0000-0000-0000-00000000AAA1")!, alias: "mosh-test", host: "127.0.0.1", port: 2223, user: "sidra", auth: .password, trustOnFirstUse: true)
        p.mosh = MoshSettings(portRange: "60100:60110")
        KnownHosts.forget(host: p.host, port: p.port)
        try KeychainStore.set("sidra", for: p.passwordKey)
        return p
    }

    private func connection() async throws -> SSHConnection {
        let c = SSHConnection(profile: try profile())
        do { try await c.connect() } catch { throw XCTSkip("test container not running: \(error)") }
        return c
    }

    final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func add(_ d: Data) { lock.withLock { data.append(d) } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }

    private func wait(for needle: String, in box: OutputBox, seconds: Double) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if box.text.contains(needle) { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    private func firstExit(_ exit: Task<Int??, Never>, within seconds: Double) async -> Int?? {
        final class Slot: @unchecked Sendable { var value: Int??; var set = false }
        let slot = Slot()
        Task { let v = await exit.value; slot.value = v; slot.set = true }
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !slot.set { try? await Task.sleep(for: .milliseconds(200)) }
        return slot.set ? slot.value : .some(-99)
    }

    func testRoundTripResizeSilentLinkAndExit() async throws {
        let c = try await connection()
        let pty = try await c.openMosh(cols: 90, rows: 30)
        let box = OutputBox()
        Task { for await d in pty.output { box.add(d) } }
        let exit = Task { () -> Int?? in for await e in pty.exit { return e }; return nil }

        pty.write(Data("echo mark$((40+2))\n".utf8))
        let echoed = await wait(for: "mark42", in: box, seconds: 15)
        XCTAssertTrue(echoed, "command output arrives: \(box.text.suffix(300))")

        // Decision 2's resize gate.
        pty.resize(cols: 111, rows: 37)
        try await Task.sleep(for: .seconds(1))
        pty.write(Data("clear; stty size | sed 's/ /x/'\n".utf8))
        let sized = await wait(for: "37x111", in: box, seconds: 10)
        XCTAssertTrue(sized, "server sees the new size: \(box.text.suffix(300))")

        // A dead link: the server freezes for 20 s and keystrokes typed meanwhile still arrive afterwards.
        try docker("pause", "sidra-vm-ssh")
        try await Task.sleep(for: .seconds(8))
        pty.write(Data("clear; echo after$((50+5))\n".utf8))
        try await Task.sleep(for: .seconds(12))
        try docker("unpause", "sidra-vm-ssh")
        let survived = await wait(for: "after55", in: box, seconds: 20)
        XCTAssertTrue(survived, "session survives 20 s of silence: \(box.text.suffix(300))")

        pty.write(Data("exit\n".utf8))
        let finished = await firstExit(exit, within: 20)
        XCTAssertEqual(finished, .some(0), "shell exit ends the pane cleanly")
        XCTAssertNil(pty.endReason)
        await c.disconnect()
    }

    func testMissingServerSaysSo() async throws {
        var p = try profile()
        p.mosh = MoshSettings(serverPath: "/nonexistent/mosh-server", portRange: "60100:60110")
        let c = SSHConnection(profile: p)
        do { try await c.connect() } catch { throw XCTSkip("test container not running: \(error)") }
        do { _ = try await c.openMosh(cols: 80, rows: 24); XCTFail("expected failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("not installed"), error.localizedDescription) }
        await c.disconnect()
    }

    /// Same login path as a Secure Enclave key, with a software P-256 key.
    func testP256KeyLogsIn() async throws {
        let c = try await connection()
        let key = P256.Signing.PrivateKey()
        let blob = SSHAgentWire.ecdsaPublicBlob(x963: key.publicKey.x963Representation)
        let r = try await c.run("mkdir -p ~/.ssh; echo 'ecdsa-sha2-nistp256 \(blob.base64EncodedString()) t' >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys")
        XCTAssertEqual(r.exitCode, 0)
        let auth = SSHAuthenticationMethod.custom(SinglePrivateKeyAuth(user: "sidra", key: NIOSSHPrivateKey(p256Key: key)))
        let client = try await SSHClient.connect(to: SSHClientSettings(host: "127.0.0.1", port: 2223, authenticationMethod: { auth }, hostKeyValidator: .acceptAnything()))
        let out = try await client.executeCommand("whoami")
        XCTAssertEqual(String(buffer: out).trimmingCharacters(in: .whitespacesAndNewlines), "sidra")
        try await client.close()
        await c.disconnect()
    }

    func testJumpHostReachesTheTarget() async throws {
        let bastion = try profile()
        var target = SSHHostProfile(id: UUID(uuidString: "00000000-0000-0000-0000-00000000AAA2")!, alias: "inner", host: "127.0.0.1", port: 22, user: "sidra", auth: .password, trustOnFirstUse: true)
        target.jumpHostID = bastion.id
        KnownHosts.forget(host: target.host, port: target.port)
        try KeychainStore.set("sidra", for: target.passwordKey)
        let c = SSHConnection(profile: target, jump: bastion)
        do { try await c.connect() } catch { throw XCTSkip("test container not running: \(error)") }
        let r = try await c.run("echo $SSH_CONNECTION")
        XCTAssertTrue(r.stdoutText.hasPrefix("127.0.0.1"), "the hop arrives from inside the container: \(r.stdoutText)")
        await c.disconnect()
    }

    func testSilentSSHLinkIsDetected() async throws {
        let c = try await connection()
        let shell = try await c.openShell(cols: 80, rows: 24)
        Task { for await _ in shell.output {} }
        let exit = Task { () -> Int?? in for await e in shell.exit { return e }; return nil }
        try docker("pause", "sidra-vm-ssh")
        defer { try? docker("unpause", "sidra-vm-ssh") }
        let code = await firstExit(exit, within: 100)
        XCTAssertEqual(code, .some(nil), "a frozen host ends the pane as lost")
        XCTAssertTrue(shell.endReason?.contains("stopped answering") == true, shell.endReason ?? "no reason")
    }
}
