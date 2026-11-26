import Foundation

public enum TheasaError: LocalizedError, Sendable, Equatable {
    case badURL
    case noToken
    case unauthorized
    case http(Int, String)
    case unreachable(String)

    public var errorDescription: String? {
        switch self {
        case .badURL: "Check the server address."
        case .noToken: "Sign in to Substrate to make changes."
        case .unauthorized: "Substrate did not accept your sign-in. Sign in again."
        case .http(let code, let msg): msg.isEmpty ? "The server answered \(code)." : msg
        case .unreachable(let why): "No connection to Substrate. \(why)"
        }
    }
}

/// Every request to the configured server carries `Authorization: Bearer <token>`; only /health is open. Every request times out after
/// 10 s so a dead server shows an error, never a spinner that waits forever.
public struct TheasaClient: Sendable {
    public let base: URL
    public let token: String?
    /// Substrate's app API (`…/api/v1`, 2026-11-26): the same screens, Theasa's paths mapped by `url(_:)`.
    public let substrate: Bool
    let session: URLSession

    public init(base: URL, token: String?, substrate: Bool = false, session: URLSession = TheasaClient.defaultSession) {
        self.base = base
        self.token = token?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.substrate = substrate
        self.session = session
    }

    /// Theasa's `/api/…` paths on Substrate's app API (docs/app-api.md in the substrate repo): the work log under
    /// `/log`, repos for projects, `/agents`, and `/live` for the change stream. Ranges are today|week|month|all
    /// and days are the reader's, so `tz` (the IANA zone) goes along.
    static func substratePath(_ path: String) -> String {
        let map = [("/api/pulse", "/log/pulse"), ("/api/projects", "/log/repos"), ("/api/turns", "/log/turns"), ("/api/search", "/log/search"),
                   ("/api/watch", "/log/watch"), ("/api/decisions", "/log/decisions"), ("/api/jobs", "/log/jobs"),
                   ("/api/agents", "/agents"), ("/api/events", "/live")]
        guard let (from, to) = map.first(where: { path == $0.0 || path.hasPrefix($0.0 + "/") || path.hasPrefix($0.0 + "?") }) else { return path }
        var p = to + path.dropFirst(from.count)
        p = p.replacingOccurrences(of: "range=30d", with: "range=month").replacingOccurrences(of: "&agent=all", with: "")
        if p.hasPrefix("/log/pulse") || p.hasPrefix("/log/repos") {
            p += (p.contains("?") ? "&" : "?") + "tz=" + encodeSegment(TimeZone.current.identifier)   // IANA: each date gets its own offset
        }
        return p
    }

    /// Debug demo mode only: URL protocols that answer before the network (set before the first request).
    nonisolated(unsafe) public static var extraProtocolClasses: [AnyClass] = []

    public static let defaultSession: URLSession = {
        let c = URLSessionConfiguration.default
        if !extraProtocolClasses.isEmpty { c.protocolClasses = extraProtocolClasses + (c.protocolClasses ?? []) }
        c.timeoutIntervalForRequest = 10
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    /// Accepts "host:port", "http://host:port" or with a trailing slash.
    public static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.contains("://") { s = "http://" + s }
        guard let u = URL(string: s), let scheme = u.scheme, ["http", "https"].contains(scheme), u.host != nil else { return nil }
        return u
    }

    /// A server path (`/api/...`, or a relative `icon_url` / `src`) as an absolute URL.
    public func url(_ path: String) -> URL? {
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return URL(string: path) }
        let path = substrate ? Self.substratePath(path) : path
        var b = base.absoluteString
        while b.hasSuffix("/") { b.removeLast() }
        return URL(string: b + (path.hasPrefix("/") ? path : "/" + path))
    }

    /// Pane ids contain ':' (`w4D:pQ`); the server decodeURIComponent()s the segment.
    public static func encodeSegment(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? s
    }

    public static func query(_ s: String) -> String { encodeSegment(s) }

    public func request(_ path: String, post body: [String: Any]? = nil) throws -> URLRequest {
        guard let u = url(path) else { throw TheasaError.badURL }
        var r = URLRequest(url: u)
        // The token goes only to the configured server: an absolute URL elsewhere (an agent's attachment) gets none.
        let ours = u.scheme == base.scheme && u.host == base.host && u.port == base.port
        // Reads carry the token too when there is one: live agents and what they sent need it.
        if ours, let token { r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body {
            guard ours, let token else { throw TheasaError.noToken }
            // Substrate edits a repo with PATCH /log/repos/{id}; Theasa took a POST.
            r.httpMethod = substrate && u.path.range(of: #"/log/repos/\d+$"#, options: .regularExpression) != nil ? "PATCH" : "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    func send(_ r: URLRequest) async throws -> Data {
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: r) } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch {
            throw TheasaError.unreachable(error.localizedDescription)
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw TheasaError.unauthorized }
        guard (200..<300).contains(code) else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? ""
            throw TheasaError.http(code, msg)
        }
        return data
    }

    public func get<T: Decodable>(_ path: String, as: T.Type = T.self) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await send(try request(path)))
    }

    /// Raw bytes, for images the agents sent.
    public func data(_ path: String) async throws -> Data { try await send(try request(path)) }

    public func text(_ path: String) async throws -> String {
        String(decoding: try await send(try request(path)), as: UTF8.self)
    }

    @discardableResult
    public func post(_ path: String, _ body: [String: Any] = [:]) async throws -> [String: Any] {
        let d = try await send(try request(path, post: body))
        return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }

    public func health() async throws -> Health { try await get("/health") }

    /// POST /api/projects/:id/icon: multipart form field `icon`, an image under 1 MB. It locks the icon.
    public func iconRequest(project: Int, image: Data, mime: String) throws -> URLRequest {
        guard let token else { throw TheasaError.noToken }
        guard let u = url("/api/projects/\(project)/icon") else { throw TheasaError.badURL }   // mapped on Substrate
        let boundary = "sidra-\(UUID().uuidString)"
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"icon\"; filename=\"icon\"\r\nContent-Type: \(mime)\r\n\r\n".utf8)
        body += image
        body += Data("\r\n--\(boundary)--\r\n".utf8)
        var r = URLRequest(url: u)
        r.httpMethod = "POST"
        r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        return r
    }

    public func uploadIcon(project: Int, image: Data, mime: String) async throws {
        _ = try await send(try iconRequest(project: project, image: image, mime: mime))
    }

    // MARK: Requests the UI sends

    /// Substrate's agent paths carry the machine too: two Macs can both have a pane `w1:p1`.
    static func agentPath(_ a: LiveAgent) -> String {
        "/api/agents/" + (a.machine_id.map { encodeSegment($0) + "/" } ?? "") + encodeSegment(a.pane_id)
    }
    public static func promptPath(_ a: LiveAgent) -> String { agentPath(a) + "/prompt" }
    public static func keysPath(_ a: LiveAgent) -> String { agentPath(a) + "/keys" }

    /// Sends text to an agent pane. When the agent is blocked on an `ask`, the server presses Esc
    /// first; a 409 means the dialog did not close and nothing was sent.
    public func prompt(_ a: LiveAgent, text: String) async throws { try await post(Self.promptPath(a), ["text": text]) }
    public func keys(_ a: LiveAgent, keys: [String]) async throws { try await post(Self.keysPath(a), ["keys": keys]) }

    // MARK: Live events

    /// Yields once on connect (`data: hello`) and on every `data: change`. Ends when the stream drops;
    /// the caller waits and reconnects.
    public func events() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    guard let u = url("/api/events") else { throw TheasaError.badURL }
                    var r = URLRequest(url: u)
                    r.timeoutInterval = 600   // idle gap between changes; the stream reconnects after it
                    r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, resp) = try await session.bytes(for: r)
                    guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw TheasaError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, "") }
                    // Substrate keeps the stream open with comments and says `data: changed`; either way, refetch.
                    for try await line in bytes.lines where line.hasPrefix("data:") {
                        cont.yield(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
