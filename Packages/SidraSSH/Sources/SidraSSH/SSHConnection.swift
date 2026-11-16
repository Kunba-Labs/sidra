import Foundation
import Citadel
import NIOCore
import NIOSSH
import NIOPosix
import Crypto
import LocalAuthentication

/// Bytes in and out of one remote PTY. Produced by `SSHConnection.openShell`.

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
}

private final class EventLoopTaskExecutor: TaskExecutor, @unchecked Sendable {
    private let loop: any EventLoop
    init(_ loop: any EventLoop) { self.loop = loop }
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        loop.execute { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}

/// Opens a connected socket to a host some way other than the system's network stack.
public protocol SSHDialer: Sendable {
    func dial(host: String, port: Int) async throws -> Int32
}

public final class PTYSession: @unchecked Sendable {
    public let output: AsyncStream<Data>
    public let exit: AsyncStream<Int?>
    private let outputContinuation: AsyncStream<Data>.Continuation
    private let exitContinuation: AsyncStream<Int?>.Continuation
    private let lock = NSLock()
    private var closeContinuation: CheckedContinuation<Void, Never>?
    private var closed = false
    /// Why the session ended when that was not the remote shell exiting.
    public private(set) var endReason: String?
    func setEndReason(_ r: String) { lock.lock(); endReason = r; lock.unlock() }
    /// Everything headed to the remote goes through one stream drained by one task, so bytes
    /// leave in call order, including input typed before the channel was attached.
    private enum Outbound { case data(Data), size(Int, Int) }
    private let outbound: AsyncStream<Outbound>
    private let outboundContinuation: AsyncStream<Outbound>.Continuation
    private var pump: Task<Void, Never>?

    public init() {
        var oc: AsyncStream<Data>.Continuation!
        output = AsyncStream(bufferingPolicy: .unbounded) { oc = $0 }
        outputContinuation = oc
        var ec: AsyncStream<Int?>.Continuation!
        exit = AsyncStream { ec = $0 }
        exitContinuation = ec
        var bc: AsyncStream<Outbound>.Continuation!
        outbound = AsyncStream(bufferingPolicy: .unbounded) { bc = $0 }
        outboundContinuation = bc
    }

    /// Send keystrokes or pasted bytes to the remote shell.
    public func write(_ data: Data) {
        outboundContinuation.yield(.data(data))
    }

    public func resize(cols: Int, rows: Int) {
        outboundContinuation.yield(.size(cols, rows))
    }

    public func close() {
        lock.lock()
        let c = closeContinuation
        closeContinuation = nil
        closed = true
        lock.unlock()
        c?.resume()
    }

    // MARK: driver side

    private var startup: Data?
    func prependStartup(_ data: Data) { lock.lock(); startup = data; lock.unlock() }

    func attach(_ writer: TTYStdinWriter) {
        lock.lock(); defer { lock.unlock() }
        guard pump == nil else { return }
        let first = startup
        pump = Task { [outbound] in
            if let first { try? await writer.write(ByteBuffer(bytes: first)) }
            for await item in outbound {
                switch item {
                case .data(let d): try? await writer.write(ByteBuffer(bytes: d))
                case .size(let c, let r): try? await writer.changeSize(cols: c, rows: r, pixelWidth: 0, pixelHeight: 0)
                }
            }
        }
    }

    /// The channel ended by itself, as opposed to `close()` from this side.
    func closeFromRemote() {
        lock.lock()
        let c = closeContinuation
        closeContinuation = nil
        closed = true
        remoteEnded = true
        lock.unlock()
        c?.resume()
    }
    private var remoteEnded = false
    private var finished = false
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    var closedLocally: Bool { lock.lock(); defer { lock.unlock() }; return closed && !remoteEnded }

    func emit(_ buffer: ByteBuffer) {
        outputContinuation.yield(Data(buffer.readableBytesView))
    }

    func finish(exitCode: Int?) {
        lock.lock()
        let already = finished
        finished = true
        lock.unlock()
        guard !already else { return }
        outboundContinuation.finish()
        pump?.cancel()
        outputContinuation.finish()
        exitContinuation.yield(exitCode)
        exitContinuation.finish()
    }

    /// Suspends until `close()` is called. Used to keep Citadel's `withPTY` closure alive.
    func waitUntilClosed() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if closed {
                lock.unlock()
                c.resume()
                return
            }
            closeContinuation = c
            lock.unlock()
        }
    }
}

public struct CommandResult: Sendable {
    public var stdout: Data
    public var stderr: Data
    public var exitCode: Int
    public init(stdout: Data, stderr: Data, exitCode: Int) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// One SSH connection to a host profile. Shells and commands multiplex over it.
public actor SSHConnection {
    public nonisolated let profile: SSHHostProfile
    private var client: SSHClient?
    private var connecting: Task<Void, Error>?
    public private(set) var state: SSHConnectionState = .disconnected
    private var stateContinuations: [UUID: AsyncStream<SSHConnectionState>.Continuation] = [:]

    private var keepalive: Task<Void, Never>?
    private var ptys: [PTYSession] = []
    /// Set when the keepalive gave up, so the panes that die with the link can say why.
    private var lostReason: String?
    private let jumpProfile: SSHHostProfile?
    private var jumpConnection: SSHConnection?
    private var agentForward: Task<Void, Never>?

    /// True only for the app's one VM connection: other connections must not repoint the VM's socket at themselves.
    private let servesVMAgent: Bool

    /// How the bytes get there when it isn't plain TCP: the app's embedded tailnet node.
    private let dialer: (any SSHDialer)?

    public init(profile: SSHHostProfile, jump: SSHHostProfile? = nil, servesVMAgent: Bool = false, dialer: (any SSHDialer)? = nil) {
        self.dialer = dialer
        self.profile = profile
        self.jumpProfile = jump
        self.servesVMAgent = servesVMAgent
    }

    public var isConnected: Bool { client?.isConnected == true }

    public func states() -> AsyncStream<SSHConnectionState> {
        let id = UUID()
        return AsyncStream { continuation in
            stateContinuations[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) { stateContinuations[id] = nil }

    private func setState(_ s: SSHConnectionState) {
        state = s
        for c in stateContinuations.values { c.yield(s) }
    }

    /// Callers that race here share one in-flight attempt instead of each opening a client.
    public func connect() async throws {
        if client?.isConnected == true { return }
        if let t = connecting { try await t.value; return }
        let t = Task { try await self.connectOnce() }
        connecting = t
        defer { connecting = nil }
        try await t.value
    }

    private func connectOnce() async throws {
        if client?.isConnected == true { return }
        setState(.connecting)
        let auth: SSHAuthenticationMethod
        switch profile.auth {
        case .password:
            let pw = KeychainStore.string(for: profile.passwordKey) ?? ""
            auth = .passwordBased(username: profile.user, password: pw)
        case .key:
            let method = try SSHKeyManager.authentication(id: profile.keyID, user: profile.user)
            if SSHKeyManager.record(id: profile.keyID)?.confirmOnUse == true {
                try await Self.confirmKeyUse(host: profile.host, reason: "Use the Sidra SSH key to log in to \(profile.host)")
            }
            auth = method
        }
        let validator = KnownHostsValidator(host: profile.host, port: profile.port, trustOnFirstUse: profile.trustOnFirstUse)
        var settings = SSHClientSettings(host: profile.host, port: profile.port,
                                         authenticationMethod: { auth },
                                         hostKeyValidator: .custom(validator))
        settings.connectTimeout = .seconds(15)
        do {
            let c: SSHClient
            if let jumpProfile {
                let j = SSHConnection(profile: jumpProfile)
                try await j.connect()
                jumpConnection = j
                guard let via = await j.client else { throw SSHError.notConnected }
                c = try await via.jump(to: settings)
            } else if let dialer {
                let fd = try await dialer.dial(host: profile.host, port: profile.port)
                let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton).withConnectedSocket(fd).get()
                // Citadel adds its handlers synchronously here, which NIO only allows on the channel's event loop.
                c = try await withTaskExecutorPreference(EventLoopTaskExecutor(channel.eventLoop)) {
                    try await SSHClient.connect(on: channel, settings: settings)
                }
            } else {
                c = try await SSHClient.connect(to: settings)
            }
            client = c
            lostReason = nil
            c.onDisconnect { [weak self] in
                Task { await self?.setState(.disconnected) }
            }
            setState(.connected)
            startKeepalive(c)
            if servesVMAgent { Task { try? await self.refreshAgentBridge() } }
        } catch {
            setState(.failed(describe(error)))
            throw error
        }
    }

    /// Set once by the app: shows the fingerprint sheet for an unknown host and returns the decision.
    public static func setHostKeyPrompt(_ prompt: @escaping @Sendable (HostKeyPrompt) async -> Bool) {
        KnownHostsValidator.prompt = prompt
    }

    /// Set by the app: an in-app confirmation used when the device has no passcode or Face ID policy.
    nonisolated(unsafe) static var keyUseConfirmation: (@Sendable (String) async -> Bool)?
    public static func setKeyUseConfirmation(_ handler: @escaping @Sendable (String) async -> Bool) { keyUseConfirmation = handler }

    /// Face ID or passcode before a confirm-on-use key signs; without any policy the app's own
    /// confirmation sheet decides, and with neither the login is refused.
    static func confirmKeyUse(host: String, reason: String) async throws {
        let ctx = LAContext()
        var err: NSError?
        #if targetEnvironment(simulator)
        let canAsk = false   // the Simulator has no real Face ID or passcode to check
        #else
        let canAsk = ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err)
        #endif
        guard canAsk else {
            guard let ask = keyUseConfirmation else { throw SSHError.confirmationDeclined }
            if await ask(host) { return }
            throw SSHError.confirmationDeclined
        }
        let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        if !ok { throw SSHError.confirmationDeclined }
    }

    /// Shorter than the 15 s Citadel waits for a channel, so its local timeout is never mistaken for an answer.
    static let keepaliveWindow: Duration = .seconds(12)
    static let keepaliveMisses = 3

    /// Citadel has no SSH-level keepalive, so a link that went silent would leave panes frozen.
    /// A probe that gets any answer counts, a refused channel included: only silence is a miss.
    private func startKeepalive(_ c: SSHClient) {
        keepalive?.cancel()
        keepalive = Task { [weak self] in
            var misses = 0
            while !Task.isCancelled, c.isConnected {
                let answered = KeepaliveFlag()
                let probe = Task { _ = try? await c.executeCommand("true"); answered.set() }
                try? await Task.sleep(for: Self.keepaliveWindow)
                let heard = answered.isSet   // before cancelling: a cancelled probe also finishes
                probe.cancel()
                guard !Task.isCancelled else { return }
                misses = heard ? 0 : misses + 1
                if misses >= Self.keepaliveMisses { await self?.drop(c); return }
            }
        }
    }

    private func drop(_ c: SSHClient) async {
        let silence = Int(Self.keepaliveWindow.components.seconds) * Self.keepaliveMisses
        let reason = "\(profile.host) stopped answering for \(silence) s. The network may have changed or the host is down."
        lostReason = reason
        // Ended here, not by the channel: closing a connection to a silent peer can wait a long time.
        for pty in ptys { pty.setEndReason(reason); pty.finish(exitCode: nil) }
        ptys = []
        Task { try? await c.close() }
        if client === c { client = nil }
        setState(.failed(reason))
    }

    /// Serves the SSH agent inside the VM over a reverse forward, or tears it down when no key is shared.
    public func refreshAgentBridge() async throws {
        agentForward?.cancel()
        agentForward = nil
        try await connect()
        guard let client else { throw SSHError.notConnected }
        let shared = SSHKeyManager.keys().filter(\.isSharedWithVM).map(\.publicKey)
        guard !shared.isEmpty else { _ = try await run(VMAgentScript.stop); return }
        var lastError: Error = SSHError.notConnected
        // Citadel matches forwarded channels on the requested port, so port 0 cannot be used.
        for port in (0..<5).map({ _ in Int.random(in: 49152...65000) }) {
            let ready = OnceContinuation()
            let task = Task {
                do {
                    try await client.withRemotePortForward(host: "127.0.0.1", port: port, onOpen: { _ in
                        let r = try await client.executeAllowingFailure(VMAgentScript.start(port: port, publicKeys: shared))
                        guard r.code == 0 else { throw SSHError.agentBridge(r.text.isEmpty ? "exit \(r.code)" : r.text) }
                        ready.finish(nil)
                    }, handleChannel: { channel, _ in
                        channel.pipeline.addHandler(AgentChannelHandler(identities: { SSHKeyManager.vmAgentIdentities() }))
                    })
                } catch { ready.finish(error) }
            }
            if let error = await ready.wait() { task.cancel(); lastError = error; continue }
            agentForward = task
            return
        }
        throw lastError
    }

    public func disconnect() async {
        keepalive?.cancel()
        agentForward?.cancel()
        agentForward = nil
        try? await client?.close()
        client = nil
        await jumpConnection?.disconnect()
        jumpConnection = nil
        setState(.disconnected)
    }

    /// Opens an interactive shell with a PTY. The returned session streams output until closed.
    public func openShell(cols: Int, rows: Int, command: String? = nil) async throws -> PTYSession {
        try await connect()
        guard let client else { throw SSHError.notConnected }
        let session = PTYSession()
        ptys = ptys.filter { !$0.isFinished } + [session]
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true, term: "xterm-256color",
            terminalCharacterWidth: cols, terminalRowHeight: rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0,
            terminalModes: .init([.ECHO: 1]))
        let startup = command ?? (profile.startupCommand.isEmpty ? nil : profile.startupCommand)
        let host = profile.host
        Task.detached { [weak self] in
            do {
                try await client.withPTY(request) { inbound, outbound in
                    // The startup command joins the same ordered queue, ahead of anything typed since.
                    if let startup { session.prependStartup(Data((startup + "\n").utf8)) }
                    session.attach(outbound)
                    let reader = Task {
                        do {
                            for try await event in inbound {
                                switch event {
                                case .stdout(let b): session.emit(b)
                                case .stderr(let b): session.emit(b)
                                }
                            }
                        } catch {
                            // channel ended; openShell works out whether the connection went with it
                        }
                        session.closeFromRemote()
                    }
                    await session.waitUntilClosed()
                    reader.cancel()
                }
                // The channel ended. That is a normal exit unless the connection went with it.
                try? await Task.sleep(for: .milliseconds(200))
                if client.isConnected || session.closedLocally { session.finish(exitCode: 0); return }
                session.setEndReason(await self?.lostReason ?? "The connection to \(host) closed.")
                session.finish(exitCode: nil)
            } catch {
                if session.closedLocally { session.finish(exitCode: 0); return }
                try? await Task.sleep(for: .milliseconds(200))
                let lost = await self?.lostReason
                session.setEndReason(client.isConnected ? describe(error) : lost ?? "The connection to \(host) closed.")
                if client.isConnected { session.emit(ByteBuffer(string: "\r\n\u{1b}[31m[sidra] \(describe(error))\u{1b}[0m\r\n")) }   // a lost link is the banner's job
                session.finish(exitCode: nil)
            }
        }
        return session
    }

    /// Runs a non-interactive command and collects its output.
    public func run(_ command: String, timeout: Duration = .seconds(600)) async throws -> CommandResult {
        try await connect()
        guard let client else { throw SSHError.notConnected }
        let work = Task<CommandResult, Error> {
            var out = Data(), err = Data()
            var code = 0
            do {
                let streams = try await client.executeCommandStream(command)
                for try await event in streams {
                    try Task.checkCancellation()
                    switch event {
                    case .stdout(let b): out.append(contentsOf: b.readableBytesView)
                    case .stderr(let b): err.append(contentsOf: b.readableBytesView)
                    }
                }
            } catch let e as SSHClient.CommandFailed {
                code = e.exitCode
            }
            return CommandResult(stdout: out, stderr: err, exitCode: code)
        }
        // Not a task group: that would wait for a stalled stream after the timeout fired.
        let once = ResumeOnce()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, Error>) in
            let timer = Task {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, once.claim() else { return }
                work.cancel()   // ends the exec stream, which closes its channel
                continuation.resume(throwing: SSHError.timedOut(command))
            }
            Task {
                let result = await work.result
                timer.cancel()
                if once.claim() { continuation.resume(with: result) }
            }
        }
    }

    public enum SSHError: Error, LocalizedError {
        case notConnected
        case confirmationDeclined
        case timedOut(String)
        case mosh(String)
        case agentBridge(String)
        public var errorDescription: String? {
            switch self {
            case .notConnected: "Not connected"
            case .confirmationDeclined: "Key use was not confirmed"
            case .timedOut(let c): "Timed out: \(c.prefix(60))"
            case .mosh(let why): why
            case .agentBridge(let why): "The SSH agent bridge did not start in the VM: \(why)"
            }
        }
    }
}

func describe(_ error: Error) -> String {
    if let l = error as? LocalizedError, let d = l.errorDescription { return d }
    return String(describing: error)
}

final class KeepaliveFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Resumes its waiter exactly once, whichever side comes first.
final class OnceContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Error?, Never>?
    private var result: Error??
    func finish(_ error: Error?) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = .some(error)
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(returning: error)
    }
    func wait() async -> Error? {
        await withCheckedContinuation { c in
            lock.lock()
            if let result { lock.unlock(); c.resume(returning: result) } else { waiter = c; lock.unlock() }
        }
    }
}

extension SSHClient {
    /// Runs a command and reports its exit status instead of throwing on a non-zero one.
    func executeAllowingFailure(_ command: String) async throws -> (code: Int, text: String) {
        var text = ""
        do {
            for try await event in try await executeCommandStream(command) {
                switch event {
                case .stdout(let b), .stderr(let b): text += String(buffer: b)
                }
            }
            return (0, text)
        } catch let e as SSHClient.CommandFailed {
            return (e.exitCode, text)
        }
    }
}
