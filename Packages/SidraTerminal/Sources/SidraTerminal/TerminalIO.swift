import Foundation

/// The byte pipe a terminal surface talks to: a PTY on a VM, an SSH channel, or a serial line.
public protocol TerminalIO: AnyObject, Sendable {
    var output: AsyncStream<Data> { get }
    func write(_ data: Data)
    func resize(cols: Int, rows: Int)
    func close()
}

/// Echoes input back and replies to a few sequences. Deterministic tests and previews.
public final class LoopbackTerminalIO: TerminalIO, @unchecked Sendable {
    public let output: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    public private(set) var cols = 80
    public private(set) var rows = 24
    public private(set) var written = Data()

    public init(banner: String = "") {
        var c: AsyncStream<Data>.Continuation!
        output = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
        if !banner.isEmpty { continuation.yield(Data(banner.utf8)) }
    }

    public func write(_ data: Data) {
        written.append(data)
        // Echo, turning CR into CRLF the way a cooked tty does.
        var echo = Data()
        for b in data {
            if b == 0x0d { echo.append(contentsOf: [0x0d, 0x0a]) } else { echo.append(b) }
        }
        continuation.yield(echo)
    }

    public func feed(_ text: String) { continuation.yield(Data(text.utf8)) }
    public func resize(cols: Int, rows: Int) { self.cols = cols; self.rows = rows }
    public func close() { continuation.finish() }
}

/// Which emulation core draws a pane. libghostty-vt is the product; SwiftTerm is the fallback
/// behind the same surface API.
public enum TerminalEngineKind: String, Codable, CaseIterable, Sendable {
    case ghostty
    case swiftTerm
}
