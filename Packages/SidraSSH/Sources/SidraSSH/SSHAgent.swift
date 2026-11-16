import Foundation
import Citadel
import NIOCore
import NIOSSH

/// One key offered by the VM's agent. `sign` returns the SSH signature blob.
struct AgentIdentity: Sendable {
    var blob: Data
    var comment: String
    var sign: @Sendable (Data) async throws -> Data
}

/// The ssh-agent wire format, draft-miller-ssh-agent: the three messages OpenSSH needs.
enum SSHAgentWire {
    static let failure: UInt8 = 5, requestIdentities: UInt8 = 11, identitiesAnswer: UInt8 = 12, signRequest: UInt8 = 13, signResponse: UInt8 = 14

    static func u32(_ n: Int) -> Data { withUnsafeBytes(of: UInt32(n).bigEndian) { Data($0) } }
    static func string(_ d: Data) -> Data { u32(d.count) + d }
    static func string(_ s: String) -> Data { string(Data(s.utf8)) }

    static func ecdsaPublicBlob(x963: Data) -> Data { string("ecdsa-sha2-nistp256") + string("nistp256") + string(x963) }
    static func ed25519Signature(_ raw: Data) -> Data { string("ssh-ed25519") + string(raw) }

    /// `raw` is r||s, 32 bytes each.
    static func ecdsaSignature(raw: Data) -> Data {
        func mpint(_ d: Data) -> Data {
            var b = Data(d.drop(while: { $0 == 0 }))
            if let first = b.first, first & 0x80 != 0 { b.insert(0, at: 0) }
            return string(b)
        }
        let r = raw.prefix(32), s = raw.suffix(32)
        return string("ecdsa-sha2-nistp256") + string(mpint(r) + mpint(s))
    }

    /// Answers one message body (no length prefix). Anything not understood, or refused, is a failure reply.
    static func respond(to request: Data, identities: [AgentIdentity]) async -> Data {
        let body = Data(request)
        guard let type = body.first else { return Data([failure]) }
        switch type {
        case requestIdentities:
            return identities.reduce(Data([identitiesAnswer]) + u32(identities.count)) { $0 + string($1.blob) + string($1.comment) }
        case signRequest:
            var at = body.startIndex + 1
            func next() -> Data? {
                guard body.endIndex - at >= 4 else { return nil }
                let n = body[at..<at + 4].reduce(0) { $0 << 8 | Int($1) }
                guard n <= body.endIndex - at - 4 else { return nil }
                defer { at += 4 + n }
                return Data(body[at + 4..<at + 4 + n])
            }
            guard let blob = next(), let data = next(), let id = identities.first(where: { $0.blob == blob }),
                  let sig = try? await id.sign(data) else { return Data([failure]) }
            return Data([signResponse]) + string(sig)
        default:
            return Data([failure])
        }
    }

    static let maxMessage = 256 * 1024

    /// Splits complete frames off `buffer`. nil means the peer sent an impossible length.
    static func takeFrames(_ buffer: inout Data) -> [Data]? {
        var out: [Data] = []
        while buffer.count >= 4 {
            let n = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard n <= maxMessage else { return nil }
            guard buffer.count >= 4 + n else { break }
            out.append(Data(buffer.dropFirst(4).prefix(n)))
            buffer = Data(buffer.dropFirst(4 + n))
        }
        return out
    }
}

/// Serves agent requests on one forwarded channel, in order.
final class AgentChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    private var buffer = Data()
    private let frames: AsyncStream<Data>.Continuation
    private let stream: AsyncStream<Data>
    private let identities: @Sendable () -> [AgentIdentity]

    init(identities: @escaping @Sendable () -> [AgentIdentity]) {
        self.identities = identities
        var c: AsyncStream<Data>.Continuation!
        stream = AsyncStream { c = $0 }
        frames = c
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        let (stream, identities) = (stream, identities)
        Task {
            for await frame in stream {
                let reply = await SSHAgentWire.respond(to: frame, identities: identities())
                let out = channel.allocator.buffer(data: SSHAgentWire.string(reply))
                channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(out)), promise: nil)
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .byteBuffer(let bytes) = unwrapInboundIn(data).data else { return }
        buffer.append(contentsOf: bytes.readableBytesView)
        guard let complete = SSHAgentWire.takeFrames(&buffer) else { context.close(promise: nil); return }
        complete.forEach { frames.yield($0) }
    }

    func channelInactive(context: ChannelHandlerContext) { frames.finish(); context.fireChannelInactive() }
}

/// Offers exactly one private key during login. NIOSSH asks again after a rejection; the answer then is "no more".
final class SinglePrivateKeyAuth: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let user: String
    private let key: NIOSSHPrivateKey
    private var offered = false
    init(user: String, key: NIOSSHPrivateKey) { self.user = user; self.key = key }
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !offered, availableMethods.contains(.publicKey) else { nextChallengePromise.succeed(nil); return }
        offered = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: user, serviceName: "", offer: .privateKey(.init(privateKey: key))))
    }
}

/// What runs in the VM: socat bridges a Unix socket to the reverse-forwarded loopback port, because
/// OpenSSH only talks to an agent over a socket and Citadel only offers tcpip-forward.
enum VMAgentScript {
    static let sock = "$HOME/.ssh/sidra-agent.sock"
    private static let unconfig = "[ -f ~/.ssh/config ] && sed -i '/^# sidra-agent$/,/^# \\/sidra-agent$/d' ~/.ssh/config; sed -i '/# sidra-agent$/d' ~/.bashrc ~/.profile 2>/dev/null; rm -f ~/.ssh/sidra-agent-*.pub"
    private static let killOld = "[ -f ~/.ssh/sidra-agent.pid ] && kill \"$(cat ~/.ssh/sidra-agent.pid)\" 2>/dev/null; rm -f ~/.ssh/sidra-agent.pid \(sock)"

    static var stop: String { "\(killOld); \(unconfig); true" }

    /// `IdentityFile` names the path without `.pub`: ssh finds the public half there and signs through the agent, so the keys also work under the
    /// `IdentitiesOnly yes` the VM git key adds to the same config.
    static func start(port: Int, publicKeys: [String]) -> String {
        let writes = publicKeys.enumerated().map { i, k in "printf '%s\\n' '\(k.replacingOccurrences(of: "'", with: ""))' > ~/.ssh/sidra-agent-\(i).pub" }.joined(separator: "; ")
        let files = publicKeys.indices.map { "  IdentityFile ~/.ssh/sidra-agent-\($0)\\n" }.joined()
        let export = "export SSH_AUTH_SOCK=\(sock) # sidra-agent"
        return """
        command -v socat >/dev/null || { echo 'socat is not installed in the VM image' >&2; exit 127; }; \
        mkdir -p ~/.ssh && chmod 700 ~/.ssh; \(killOld); \(unconfig); \(writes); \
        printf '# sidra-agent\\nHost *\\n  IdentityAgent ~/.ssh/sidra-agent.sock\\n\(files)# /sidra-agent\\n' >> ~/.ssh/config; chmod 600 ~/.ssh/config; \
        echo '\(export)' >> ~/.bashrc; echo '\(export)' >> ~/.profile; \
        setsid nohup socat UNIX-LISTEN:\(sock),fork,mode=600,unlink-early TCP:127.0.0.1:\(port) </dev/null >/dev/null 2>&1 & echo $! > ~/.ssh/sidra-agent.pid
        """
    }
}
