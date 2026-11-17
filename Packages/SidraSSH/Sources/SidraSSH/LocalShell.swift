#if os(macOS)
import Foundation
import SwiftTerm

/// This Mac's own shell and commands, for a host profile whose host is localhost: no SSH server,
/// no keys. The shell is the user's login shell on a PTY (SwiftTerm's forkpty `LocalProcess`);
/// commands run through that shell's login mode so PATH matches a Terminal window.
enum LocalShell {
    static var shell: String {
        if let pw = getpwuid(getuid()), let s = pw.pointee.pw_shell { return String(cString: s) }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// A fresh login environment, as login(1) gives Terminal's shells: only the user's basics pass through.
    /// Sidra's own environment does not, so a Sidra started from inside herdr or tmux does not make every
    /// local shell look nested. PATH starts at the system default; the login shell's profile extends it.
    static var environment: [String] {
        let inherited = ProcessInfo.processInfo.environment
        let keep = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING"]
        var env = inherited.filter { keep.contains($0.key) || $0.key.hasPrefix("LC_") }
        env["SHELL"] = shell
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Sidra"
        return env.map { "\($0.key)=\($0.value)" }
    }

    static func open(cols: Int, rows: Int, startup: String?) -> PTYSession {
        let session = PTYSession()
        let driver = Driver(session: session, cols: cols, rows: rows)
        // Run on connect is the shell's own command, not typed input: a shell setup that discards
        // typeahead before its first prompt (zsh instant prompts, some plugins) cannot lose it.
        driver.start(startup: startup)
        session.attach(write: { await driver.send($0) }, resize: { await driver.resize(cols: $0, rows: $1) })
        Task.detached {
            await session.waitUntilClosed()   // the pane closed, or the shell exited (processTerminated closes too)
            await driver.terminate()
        }
        return session
    }

    /// Runs `command` in a login shell and collects its output. The shell leads its own process group,
    /// so a timeout ends the command and everything it started, not only the shell.
    static func run(_ command: String, timeout: Duration) async throws -> CommandResult {
        var outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EMFILE) }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EMFILE)
        }
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        for fd in outPipe + errPipe { posix_spawn_file_actions_addclose(&actions, fd) }
        posix_spawn_file_actions_addchdir_np(&actions, FileManager.default.homeDirectoryForCurrentUser.path)
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)   // pgid = the shell's pid
        // Default dispositions and an empty mask: the app's blocked or ignored signals must not keep SIGTERM out.
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all); sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)
        let argv = [shell, "-l", "-c", command].map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, shell, &actions, &attr, argv, envp)
        close(outPipe[1]); close(errPipe[1])
        guard rc == 0 else { close(outPipe[0]); close(errPipe[0]); throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .EIO) }

        let once = Flag()
        // Set once a timeout's SIGKILL has gone out. Until then the shell stays unreaped, so its pid,
        // and with it the group id, cannot be handed to another process.
        let escalated = DispatchSemaphore(value: 0)
        let box = ContinuationBox()
        /// The deadline or the caller's cancellation: end the group and resume at once, without waiting on the pipes.
        let stop: @Sendable (Error) -> Void = { error in
            guard once.claim() else { return }
            kill(-pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { kill(-pid, SIGKILL); escalated.signal() }
            box.resume(throwing: error)
        }
        return try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { (c: CheckedContinuation<CommandResult, Error>) in
            box.set(c)
            let timer = Task.detached {
                try? await Task.sleep(for: timeout)
                if !Task.isCancelled { stop(SSHConnection.SSHError.timedOut(command)) }
            }
            let output = PipeReader(out: outPipe[0], err: errPipe[0])
            Thread.detachNewThread {
                // Wait for the shell itself, not for pipe EOF: a daemon it started may keep a pipe open.
                // WNOWAIT leaves it a zombie, so a pending SIGKILL to its group cannot reach a recycled id.
                var info = siginfo_t()
                while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
                // The command is done once the shell is: the deadline no longer applies to draining the pipes.
                timer.cancel()
                let finishedFirst = once.claim()
                output.waitForEOF(grace: 2)   // late output from children still finishing
                let (stdout, stderr) = output.finish()
                if !finishedFirst { escalated.wait() }   // timed out or cancelled: the SIGKILL goes out before the reap
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                let code = (status & 0x7f) == 0 ? Int((status >> 8) & 0xff) : 128 + Int(status & 0x7f)
                if finishedFirst { box.resume(returning: CommandResult(stdout: stdout, stderr: stderr, exitCode: code)) }
            }
          }
        } onCancel: { stop(CancellationError()) }
    }

    /// Collects both pipes as data arrives, so reading never blocks the reaper.
    final class PipeReader: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data(), open = 2
        private let done = DispatchSemaphore(value: 0)
        private let handles: [FileHandle]
        init(out o: Int32, err e: Int32) {
            handles = [FileHandle(fileDescriptor: o, closeOnDealloc: true), FileHandle(fileDescriptor: e, closeOnDealloc: true)]
            for (i, h) in handles.enumerated() {
                h.readabilityHandler = { [weak self] h in
                    let d = h.availableData
                    guard let self else { return }
                    if d.isEmpty {
                        h.readabilityHandler = nil
                        if self.lock.withLock({ self.open -= 1; return self.open == 0 }) { self.done.signal() }
                    } else {
                        self.lock.withLock { if i == 0 { self.out.append(d) } else { self.err.append(d) } }
                    }
                }
            }
        }
        /// Both pipes at EOF, or `grace` seconds passed.
        func waitForEOF(grace: Double) { _ = done.wait(timeout: .now() + grace) }
        /// Stops reading (a pipe a daemon still holds is dropped) and returns what arrived.
        func finish() -> (Data, Data) {
            for h in handles { h.readabilityHandler = nil; try? h.close() }
            return lock.withLock { (out, err) }
        }
    }

    /// The continuation, reachable from the cancellation handler, which runs outside its closure.
    /// A cancellation that lands before `set` is held and delivered when the continuation arrives.
    final class ContinuationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var c: CheckedContinuation<CommandResult, Error>?
        private var early: Result<CommandResult, Error>?
        func set(_ c: CheckedContinuation<CommandResult, Error>) {
            let pending: Result<CommandResult, Error>? = lock.withLock { if let e = early { return e }; self.c = c; return nil }
            if let pending { c.resume(with: pending) }
        }
        func resume(throwing e: Error) { deliver(.failure(e)) }
        func resume(returning r: CommandResult) { deliver(.success(r)) }
        private func deliver(_ r: Result<CommandResult, Error>) {
            let target: CheckedContinuation<CommandResult, Error>? = lock.withLock { if let c { self.c = nil; return c }; early = r; return nil }
            target?.resume(with: r)
        }
    }

    /// True for the first caller only: the timeout and the result race to resume once.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var taken = false
        func claim() -> Bool { lock.withLock { defer { taken = true }; return !taken } }
    }

    /// Owns the LocalProcess; its callbacks arrive on one serial queue, in order.
    final class Driver: LocalProcessDelegate, @unchecked Sendable {
        private let session: PTYSession
        private var size: winsize
        private let queue = DispatchQueue(label: "sidra.localshell")
        /// Made in init, not lazily: a lazy LocalProcess(delegate: self) came out as two instances.
        private var process: LocalProcess!

        init(session: PTYSession, cols: Int, rows: Int) {
            self.session = session
            size = winsize(ws_row: UInt16(max(rows, 1)), ws_col: UInt16(max(cols, 1)), ws_xpixel: 0, ws_ypixel: 0)
            process = LocalProcess(delegate: self, dispatchQueue: queue)
        }

        func start(startup: String?) {
            let shell = LocalShell.shell
            // A leading "-" in argv[0] makes it a login shell, as Terminal does. With a startup command the
            // interactive login shell runs it, then becomes a plain login shell when it ends.
            let quoted = "'" + shell.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let args = startup.map { ["-i", "-c", "\($0)\nexec \(quoted) -l"] } ?? []
            process.startProcess(executable: shell, args: args, environment: LocalShell.environment,
                                 execName: "-" + (shell as NSString).lastPathComponent,
                                 currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        }

        func send(_ data: Data) async { queue.async { self.process.send(data: ArraySlice([UInt8](data))) } }
        func resize(cols: Int, rows: Int) async {
            queue.async {
                self.size = winsize(ws_row: UInt16(max(rows, 1)), ws_col: UInt16(max(cols, 1)), ws_xpixel: 0, ws_ypixel: 0)
                _ = self.process.updateWindowSize(&self.size)
            }
        }
        /// SIGHUP, as when a terminal window closes (an interactive shell ignores SIGTERM); SIGKILL after
        /// 3 s if the shell is still there. LocalProcess reaps it and processTerminated finishes the session.
        func terminate() async {
            queue.async {
                // One read of the pid, checked positive: a cleared pid of 0 would signal Sidra's own group.
                let pid = self.process.shellPid
                guard self.process.running, pid > 0 else { return }
                kill(pid, SIGHUP)
                self.queue.asyncAfter(deadline: .now() + 3) {
                    // Same shell only if LocalProcess still holds this pid unreaped.
                    if self.process.running, self.process.shellPid == pid { kill(pid, SIGKILL) }
                }
            }
        }

        func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
            session.finish(exitCode: exitCode.map(Int.init))
            session.close()   // releases the close-wait in `open`, so the driver is freed
        }
        func dataReceived(slice: ArraySlice<UInt8>) { session.emit(Data(slice)) }
        /// No PTY or no fork: the pane ends with the reason instead of waiting for a shell that never came.
        func processFailedToStart(_ source: LocalProcess, error: LocalProcessError) {
            session.setEndReason("This Mac's shell did not start: \(error)")
            session.finish(exitCode: nil)
            session.close()
        }
        func getWindowSize() -> winsize { size }
    }
}
#endif
