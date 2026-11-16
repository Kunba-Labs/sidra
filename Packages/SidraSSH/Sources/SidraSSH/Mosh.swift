import Foundation
import MoshCore
import MoshBootstrap

/// A mosh-compatible terminal session over UDP. Same surface as `PTYSession`.
public final class MoshPTY: @unchecked Sendable {
    public let output: AsyncStream<Data>
    public let exit: AsyncStream<Int?>
    /// Why the session ended when that was not the shell exiting.
    public private(set) var endReason: String?
    public let port: UInt16

    private let session: MoshClientSession
    private let host: String
    private let outputC: AsyncStream<Data>.Continuation
    private let exitC: AsyncStream<Int?>.Continuation
    private let outbound: AsyncStream<MoshClientOp>
    private let outboundC: AsyncStream<MoshClientOp>.Continuation
    private let lock = NSLock()
    private var heard = false
    private var finished = false

    /// mosh never gives up on a silent network, so a server that cannot be reached at all would be a blank pane forever.
    static let firstContactTimeout: Duration = .seconds(10)

    init(session: MoshClientSession, host: String, port: UInt16) {
        self.session = session; self.host = host; self.port = port
        var o: AsyncStream<Data>.Continuation!, e: AsyncStream<Int?>.Continuation!, b: AsyncStream<MoshClientOp>.Continuation!
        output = AsyncStream(bufferingPolicy: .unbounded) { o = $0 }
        exit = AsyncStream { e = $0 }
        outbound = AsyncStream(bufferingPolicy: .unbounded) { b = $0 }
        outputC = o; exitC = e; outboundC = b
    }

    public func write(_ data: Data) { outboundC.yield(.keystrokes(data)) }
    public func resize(cols: Int, rows: Int) { outboundC.yield(.resize(cols: Int32(cols), rows: Int32(rows))) }

    public func close() {
        endReason = nil
        let s = session
        Task { await s.stop() }
    }

    /// Called around app suspension: the UDP socket does not survive it, the session does.
    public func suspend() { let s = session; Task { _ = try? await s.prepareForApplicationBackground() } }
    public func resume() { let s = session; Task { try? await s.resumeFromApplicationBackground() } }

    func start(cols: Int, rows: Int) async throws {
        let ops = await session.hostOpStream()
        try await session.start()
        Task { [self, outbound, session] in
            for await op in outbound { try? await session.enqueue(op) }
        }
        Task { [self] in
            for await op in ops {
                guard case .hostBytes(let bytes) = op else { continue }
                lock.withLock { heard = true }
                outputC.yield(bytes)
            }
            await finish()
        }
        Task { [self] in
            try? await Task.sleep(for: Self.firstContactTimeout)
            guard lock.withLock({ !heard && !finished }) else { return }
            endReason = "mosh-server started, but nothing came back on UDP port \(port) of \(host). A firewall or NAT must let that port range through."
            await session.stop()
        }
        resize(cols: cols, rows: rows)
    }

    private func finish() async {
        guard lock.withLock({ let first = !finished; finished = true; return first }) else { return }
        if case .failed(let f) = await session.state { endReason = "The mosh-compatible session failed: \(f)" }
        outboundC.finish()
        outputC.finish()
        exitC.yield(endReason == nil ? 0 : nil)
        exitC.finish()
    }
}

extension SSHConnection {
    /// Starts mosh-server over this SSH connection, then leaves SSH behind: the session runs on UDP.
    public func openMosh(cols: Int, rows: Int) async throws -> MoshPTY {
        guard let settings = profile.mosh else { throw SSHError.notConnected }
        let info = try await startMoshServer(settings)
        let session = MoshClientSession(endpoint: MoshEndpoint(host: profile.host, port: info.port, keyBase64_22: info.key))
        let pty = MoshPTY(session: session, host: profile.host, port: info.port)
        try await pty.start(cols: cols, rows: rows)
        return pty
    }

    func startMoshServer(_ settings: MoshSettings) async throws -> MoshServerConnectInfo {
        let server = settings.serverPath.isEmpty ? "mosh-server" : settings.serverPath
        let shell = profile.startupCommand.isEmpty ? "" : " -- /bin/sh -lc \(quoted(profile.startupCommand))"
        func command(_ locale: String) -> String {
            "\(quoted(server)) new -s -c 256 -l LANG=\(locale) -p \(quoted(settings.portRange))\(shell)"
        }
        var r = try await run("LANG=en_US.UTF-8 \(command("en_US.UTF-8")) 2>&1", timeout: .seconds(20))
        if r.stdoutText.contains("UTF-8") && !r.stdoutText.contains("MOSH CONNECT") {   // ponytail: some hosts only have C.UTF-8
            r = try await run("LANG=C.UTF-8 \(command("C.UTF-8")) 2>&1", timeout: .seconds(20))
        }
        do { return try MoshServerOutputParser.parse(r.stdoutText) }
        catch MoshBootstrapError.missingServer {
            throw SSHError.mosh("mosh-server is not installed on \(profile.host). Install the mosh package there, or set its path in the host profile.")
        } catch {
            throw SSHError.mosh("mosh-server did not start on \(profile.host): \(r.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private nonisolated func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
