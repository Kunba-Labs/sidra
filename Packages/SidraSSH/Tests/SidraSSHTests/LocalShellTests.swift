#if os(macOS)
import XCTest
@testable import SidraSSH

/// localhost on a Mac runs here, not over SSH.
final class LocalShellTests: XCTestCase {
    func testLocalhostIsThisMac() {
        let p = SSHHostProfile(id: UUID(), alias: "mac", host: "localhost", user: "", auth: .key, startupCommand: "", trustOnFirstUse: false)
        XCTAssertTrue(p.isThisMac)
        var q = p; q.host = "devbox.local"
        XCTAssertFalse(q.isThisMac)
    }

    func testRunCollectsOutputAndExitCode() async throws {
        let ok = try await LocalShell.run("echo hi; echo err >&2", timeout: .seconds(20))
        XCTAssertEqual(ok.stdoutText, "hi\n")
        XCTAssertEqual(ok.stderrText, "err\n")
        XCTAssertEqual(ok.exitCode, 0)
        let fail = try await LocalShell.run("exit 3", timeout: .seconds(20))
        XCTAssertEqual(fail.exitCode, 3)
        // A timeout ends the command's whole process group: the shell, its foreground and background children.
        do { _ = try await LocalShell.run("sleep 3031 & sleep 3030; :", timeout: .seconds(1)); XCTFail("no timeout") } catch {}
        try await Task.sleep(for: .seconds(3))   // SIGTERM, then SIGKILL after 2 s for what ignores it
        // "[s]leep" matches the sleeps but not this pgrep's own shell, whose command line holds the brackets.
        let left = try await LocalShell.run("pgrep -f '[s]leep 303[01]' || true", timeout: .seconds(10))
        XCTAssertEqual(left.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines), "", "the timed-out command is still running")
    }

    /// The login shell starts on a PTY, its output arrives, and closing the session ends the shell.
    /// (No typed command: a user's shell setup may drop typeahead sent before its first prompt.)
    func testShellStartsAndEndsOnClose() async throws {
        let s = LocalShell.open(cols: 80, rows: 24, startup: nil)
        var it = s.output.makeAsyncIterator()
        let first = await it.next()
        XCTAssertNotNil(first, "the shell printed nothing")
        s.close()
        let exit = expectation(description: "the shell ended")
        Task { while await it.next() != nil {}; exit.fulfill() }
        await fulfillment(of: [exit], timeout: 10)
    }

    /// A daemon that keeps stdout open does not hold run past the shell's exit.
    func testRunReturnsWhenADaemonKeepsThePipe() async throws {
        let started = Date()
        let r = try await LocalShell.run("echo up; (sleep 3033 &) ; exit 0", timeout: .seconds(60))
        XCTAssertEqual(r.stdoutText, "up\n")
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
        _ = try await LocalShell.run("pkill -f '[s]leep 3033' || true", timeout: .seconds(10))
    }

    /// Cancelling the caller stops the command at once, not at its timeout.
    func testRunStopsOnCancel() async throws {
        let started = Date()
        let t = Task { try await LocalShell.run("sleep 3032", timeout: .seconds(60)) }
        try await Task.sleep(for: .milliseconds(500))
        t.cancel()
        _ = await t.result
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// Run on connect runs as the shell's own command; afterwards the pane is a normal login shell.
    func testStartupCommandRunsThenShellContinues() async throws {
        let s = LocalShell.open(cols: 80, rows: 24, startup: "echo sidra-$((6*7))")
        let box = TextBox()
        let reader = Task { for await c in s.output { box.add(String(decoding: c, as: UTF8.self)) } }
        try await waitFor { box.text.contains("sidra-42") }
        try await Task.sleep(for: .seconds(2))   // the exec'd login shell reaches its prompt
        s.write(Data("echo again-$((5*5))\n".utf8))
        try await waitFor { box.text.contains("again-25") }
        reader.cancel()
        s.close()
    }

    private func waitFor(_ ok: () -> Bool, seconds: Double = 15) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !ok() { guard Date() < end else { return XCTFail("timed out") }; try await Task.sleep(for: .milliseconds(100)) }
    }
}

final class TextBox: @unchecked Sendable {
    private let lock = NSLock(); private var t = ""
    func add(_ s: String) { lock.withLock { t += s } }
    var text: String { lock.withLock { t } }
}
#endif
