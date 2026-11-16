import XCTest
import SidraSSH
@testable import Sidra

/// Against the test SSH host (see TestHost). Skips when it is not reachable.
final class SSHConnectionLiveTests: XCTestCase {
    private func connection() async throws -> SSHConnection {
        TestHost.storePassword()
        let c = SSHConnection(profile: TestHost.profile)
        do { try await c.connect() } catch { throw XCTSkip("test host not reachable: \(error)") }
        return c
    }

    func testRunHonoursTimeout() async throws {
        let c = try await connection()
        let start = Date()
        do {
            _ = try await c.run("sleep 20", timeout: .seconds(1))
            XCTFail("expected a timeout")
        } catch {
            XCTAssertTrue(describeError(error).hasPrefix("Timed out"), describeError(error))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        let ok = try await c.run("echo still-alive")
        XCTAssertTrue(ok.stdoutText.contains("still-alive"), "connection survives a timed-out command")
        await c.disconnect()
    }

    func testConcurrentConnectSharesOneAttempt() async throws {
        TestHost.storePassword()
        let c = SSHConnection(profile: TestHost.profile)
        do {
            try await withThrowingTaskGroup(of: Void.self) { g in
                for _ in 0..<4 { g.addTask { try await c.connect() } }
                try await g.waitForAll()
            }
        } catch { throw XCTSkip("test host not reachable: \(error)") }
        let r = try await c.run("echo one")
        XCTAssertTrue(r.stdoutText.contains("one"))
        await c.disconnect()
    }

    func testPTYWritesLeaveInOrder() async throws {
        let c = try await connection()
        let s = try await c.openShell(cols: 80, rows: 24, command: "cat")
        for i in 0..<30 { s.write(Data("line\(i)\n".utf8)) }   // queued before and after the channel attaches
        var seen = ""
        var streamEnded = true
        let collector = Task {
            for await chunk in s.output {
                seen += String(decoding: chunk, as: UTF8.self)
                if seen.contains("line29") { streamEnded = false; break }
            }
        }
        _ = await withTaskGroup(of: Void.self) { g in
            g.addTask { await collector.value }
            g.addTask { try? await Task.sleep(for: .seconds(8)); collector.cancel() }
            await g.next()
            g.cancelAll()
        }
        s.close()
        let positions = (0..<30).compactMap { seen.range(of: "line\($0)\r\n")?.lowerBound ?? seen.range(of: "line\($0)\n")?.lowerBound }
        XCTAssertEqual(positions.count, 30, "every line echoed back (stream ended early: \(streamEnded)); tail: \(seen.suffix(300).debugDescription)")
        XCTAssertEqual(positions, positions.sorted(), "lines arrive in the order they were written")
        await c.disconnect()
    }
}
