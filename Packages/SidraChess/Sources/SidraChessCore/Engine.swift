//  Sidra's own chess engine: a 0x88 board with make/unmake, negamax alpha-beta with iterative
//  deepening, a transposition table, quiescence on captures, null-move pruning, late-move
//  reductions, MVV-LVA, killer and history move ordering, and piece-square tables.
//
//  ponytail: a material + piece-square evaluation (no pawn structure, mobility or king safety)
//  is the strength ceiling; those terms are where to add strength.

import Foundation

/// Squares are 0x88: rank * 16 + file, a1 = 0, h8 = 119. Pieces: 1 pawn … 6 king, black negative.
final class Board88 {
    struct Undo { var move: Int32; var captured: Int8; var castle: Int; var ep: Int; var half: Int; var hash: UInt64 }

    var sq = [Int8](repeating: 0, count: 128)
    var side: Int8 = 1
    var castle = 0          // 1 K, 2 Q, 4 k, 8 q
    var ep = -1             // the square a pawn may capture onto en passant
    var half = 0
    var kings = [4, 116]    // [white, black]
    var hash: UInt64 = 0
    var hashes: [UInt64] = []
    var undos: [Undo] = []

    static let startFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

    init?(fen: String) {
        let f = fen.split(separator: " ")
        guard f.count >= 4 else { return nil }
        var r = 7, file = 0
        for ch in f[0] {
            if ch == "/" { r -= 1; file = 0; continue }
            if let n = ch.wholeNumberValue { file += n; continue }
            guard r >= 0, file < 8, let k = "pnbrqk".firstIndex(of: Character(ch.lowercased())) else { return nil }
            let kind = Int8("pnbrqk".distance(from: "pnbrqk".startIndex, to: k) + 1)
            let s = r * 16 + file
            sq[s] = ch.isUppercase ? kind : -kind
            if kind == 6 { kings[ch.isUppercase ? 0 : 1] = s }
            file += 1
        }
        side = f[1] == "b" ? -1 : 1
        for c in f[2] { castle |= ["K": 1, "Q": 2, "k": 4, "q": 8][c] ?? 0 }
        if f[3] != "-", f[3].count == 2 {
            let b = Array(f[3].utf8)
            ep = Int(b[1] - 49) * 16 + Int(b[0] - 97)
        }
        half = f.count > 4 ? Int(f[4]) ?? 0 : 0
        hash = computeHash()
    }

    // MARK: Zobrist

    static let keys: [UInt64] = {
        var s: UInt64 = 0x5D1D_2A_C4E55
        return (0..<(13 * 128 + 16 + 128 + 1)).map { _ in
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }()
    @inline(__always) static func pieceKey(_ p: Int8, _ s: Int) -> UInt64 { keys[(Int(p) + 6) * 128 + s] }
    @inline(__always) static func castleKey(_ c: Int) -> UInt64 { keys[13 * 128 + c] }
    @inline(__always) static func epKey(_ s: Int) -> UInt64 { s < 0 ? 0 : keys[13 * 128 + 16 + s] }
    static var sideKey: UInt64 { keys[13 * 128 + 16 + 128] }

    func computeHash() -> UInt64 {
        var h: UInt64 = 0
        for s in 0..<128 where s & 0x88 == 0 && sq[s] != 0 { h ^= Self.pieceKey(sq[s], s) }
        h ^= Self.castleKey(castle) ^ Self.epKey(ep)
        if side == -1 { h ^= Self.sideKey }
        return h
    }

    // MARK: Moves (from | to << 7 | promotion kind << 14)

    @inline(__always) static func from(_ m: Int32) -> Int { Int(m & 127) }
    @inline(__always) static func to(_ m: Int32) -> Int { Int((m >> 7) & 127) }
    @inline(__always) static func promo(_ m: Int32) -> Int8 { Int8((m >> 14) & 7) }
    @inline(__always) static func move(_ f: Int, _ t: Int, _ p: Int8 = 0) -> Int32 { Int32(f | t << 7 | Int(p) << 14) }

    static func lan(_ m: Int32) -> String {
        func name(_ s: Int) -> String { String(UnicodeScalar(UInt8(97 + s & 7))) + String(s >> 4 + 1) }
        let p = promo(m)
        return name(from(m)) + name(to(m)) + (p == 0 ? "" : ["", "", "n", "b", "r", "q"][Int(p)])
    }

    static let knight = [14, 18, 31, 33, -14, -18, -31, -33]
    static let kingDirs = [1, 15, 16, 17, -1, -15, -16, -17]
    static let diag = [15, 17, -15, -17]
    static let ortho = [1, 16, -1, -16]

    func attacked(_ s: Int, by c: Int8) -> Bool {
        let a = s - 15 * Int(c), b = s - 17 * Int(c)
        if a & 0x88 == 0 && sq[a] == c { return true }
        if b & 0x88 == 0 && sq[b] == c { return true }
        for d in Self.knight { let t = s + d; if t & 0x88 == 0 && sq[t] == 2 * c { return true } }
        for d in Self.kingDirs { let t = s + d; if t & 0x88 == 0 && sq[t] == 6 * c { return true } }
        for d in Self.diag {
            var t = s + d
            while t & 0x88 == 0 {
                let p = sq[t]
                if p != 0 { if p == 3 * c || p == 5 * c { return true }; break }
                t += d
            }
        }
        for d in Self.ortho {
            var t = s + d
            while t & 0x88 == 0 {
                let p = sq[t]
                if p != 0 { if p == 4 * c || p == 5 * c { return true }; break }
                t += d
            }
        }
        return false
    }

    var inCheck: Bool { attacked(kings[side == 1 ? 0 : 1], by: -side) }

    /// Pseudo-legal moves appended to `out`; `make` rejects the ones that leave the king in check.
    func generate(_ out: inout [Int32], capturesOnly: Bool) {
        let c = side
        for s in 0..<120 where s & 0x88 == 0 {
            let p = sq[s]
            guard p != 0, (p > 0) == (c > 0) else { continue }
            switch abs(p) {
            case 1:
                let fwd = 16 * Int(c), last = c == 1 ? 7 : 0, start = c == 1 ? 1 : 6
                let t = s + fwd
                if t & 0x88 == 0 && sq[t] == 0 {
                    if t >> 4 == last { for k: Int8 in [5, 4, 3, 2] { out.append(Self.move(s, t, k)) } }
                    else if !capturesOnly {
                        out.append(Self.move(s, t))
                        if s >> 4 == start && sq[t + fwd] == 0 { out.append(Self.move(s, t + fwd)) }
                    }
                }
                for d in [fwd - 1, fwd + 1] {
                    let t = s + d
                    guard t & 0x88 == 0 else { continue }
                    if sq[t] != 0 && (sq[t] > 0) != (c > 0) || t == ep {
                        if t >> 4 == last { for k: Int8 in [5, 4, 3, 2] { out.append(Self.move(s, t, k)) } }
                        else { out.append(Self.move(s, t)) }
                    }
                }
            case 2: steps(s, Self.knight, slide: false, &out, capturesOnly)
            case 3: steps(s, Self.diag, slide: true, &out, capturesOnly)
            case 4: steps(s, Self.ortho, slide: true, &out, capturesOnly)
            case 5: steps(s, Self.diag, slide: true, &out, capturesOnly); steps(s, Self.ortho, slide: true, &out, capturesOnly)
            default:
                steps(s, Self.kingDirs, slide: false, &out, capturesOnly)
                if !capturesOnly { castles(s, &out) }
            }
        }
    }

    @inline(__always) private func steps(_ s: Int, _ dirs: [Int], slide: Bool, _ out: inout [Int32], _ capturesOnly: Bool) {
        let c = side
        for d in dirs {
            var t = s + d
            while t & 0x88 == 0 {
                let p = sq[t]
                if p == 0 { if !capturesOnly { out.append(Self.move(s, t)) } }
                else { if (p > 0) != (c > 0) { out.append(Self.move(s, t)) }; break }
                if !slide { break }
                t += d
            }
        }
    }

    private func castles(_ s: Int, _ out: inout [Int32]) {
        let base = side == 1 ? 0 : 112, kBit = side == 1 ? 1 : 4, qBit = side == 1 ? 2 : 8
        guard s == base + 4, castle & (kBit | qBit) != 0, !attacked(s, by: -side) else { return }
        if castle & kBit != 0, sq[base + 5] == 0, sq[base + 6] == 0, sq[base + 7] == 4 * side,
           !attacked(base + 5, by: -side), !attacked(base + 6, by: -side) { out.append(Self.move(s, base + 6)) }
        if castle & qBit != 0, sq[base + 3] == 0, sq[base + 2] == 0, sq[base + 1] == 0, sq[base] == 4 * side,
           !attacked(base + 3, by: -side), !attacked(base + 2, by: -side) { out.append(Self.move(s, base + 2)) }
    }

    /// Castling rights kept after a move touches a square.
    static let castleMask: [Int] = (0..<128).map { s in
        switch s { case 0: 15 & ~2; case 4: 15 & ~3; case 7: 15 & ~1; case 112: 15 & ~8; case 116: 15 & ~12; case 119: 15 & ~4; default: 15 }
    }

    /// Plays a pseudo-legal move; returns false (and takes it back) if it leaves the mover in check.
    @discardableResult
    func make(_ m: Int32) -> Bool {
        let f = Self.from(m), t = Self.to(m), pr = Self.promo(m)
        let p = sq[f]
        var captured = sq[t]
        undos.append(Undo(move: m, captured: captured, castle: castle, ep: ep, half: half, hash: hash))
        hashes.append(hash)
        var h = hash ^ Self.castleKey(castle) ^ Self.epKey(ep) ^ Self.sideKey
        h ^= Self.pieceKey(p, f)
        if captured != 0 { h ^= Self.pieceKey(captured, t) }
        if abs(p) == 1 && t == ep {   // en passant
            let cs = t - 16 * Int(side)
            captured = sq[cs]
            undos[undos.count - 1].captured = captured
            h ^= Self.pieceKey(captured, cs)
            sq[cs] = 0
        }
        let placed = pr != 0 ? pr * side : p
        sq[t] = placed; sq[f] = 0
        h ^= Self.pieceKey(placed, t)
        if abs(p) == 6 {
            kings[side == 1 ? 0 : 1] = t
            if t - f == 2 { sq[t - 1] = sq[t + 1]; sq[t + 1] = 0; h ^= Self.pieceKey(4 * side, t + 1) ^ Self.pieceKey(4 * side, t - 1) }
            if f - t == 2 { sq[t + 1] = sq[t - 2]; sq[t - 2] = 0; h ^= Self.pieceKey(4 * side, t - 2) ^ Self.pieceKey(4 * side, t + 1) }
        }
        castle &= Self.castleMask[f] & Self.castleMask[t]
        ep = abs(p) == 1 && abs(t - f) == 32 ? (f + t) / 2 : -1
        half = abs(p) == 1 || captured != 0 ? 0 : half + 1
        h ^= Self.castleKey(castle) ^ Self.epKey(ep)
        hash = h
        side = -side
        if attacked(kings[side == 1 ? 1 : 0], by: side) { unmake(); return false }
        return true
    }

    func unmake() {
        let u = undos.removeLast()
        hashes.removeLast()
        side = -side
        let f = Self.from(u.move), t = Self.to(u.move)
        var p = sq[t]
        if Self.promo(u.move) != 0 { p = side }
        sq[f] = p
        if abs(p) == 1 && t == u.ep {
            sq[t] = 0
            sq[t - 16 * Int(side)] = u.captured
        } else {
            sq[t] = u.captured
        }
        if abs(p) == 6 {
            kings[side == 1 ? 0 : 1] = f
            if t - f == 2 { sq[t + 1] = sq[t - 1]; sq[t - 1] = 0 }
            if f - t == 2 { sq[t - 2] = sq[t + 1]; sq[t + 1] = 0 }
        }
        castle = u.castle; ep = u.ep; half = u.half; hash = u.hash
    }

    func makeNull() {
        undos.append(Undo(move: 0, captured: 0, castle: castle, ep: ep, half: half, hash: hash))
        hashes.append(hash)
        hash ^= Self.epKey(ep) ^ Self.sideKey
        ep = -1; side = -side
    }

    func unmakeNull() {
        let u = undos.removeLast()
        hashes.removeLast()
        side = -side; ep = u.ep; hash = u.hash
    }

    var lastCaptured: Int8 { undos.last?.captured ?? 0 }

    /// The position occurred before with the same side to move (one repeat counts as a draw in search).
    var isRepetition: Bool {
        var i = hashes.count - 2
        let stop = max(0, hashes.count - half)
        while i >= stop { if hashes[i] == hash { return true }; i -= 2 }
        return false
    }

    func legalMoves() -> [Int32] {
        var all: [Int32] = []
        generate(&all, capturesOnly: false)
        return all.filter { m in
            guard make(m) else { return false }
            unmake(); return true
        }
    }

    func play(lan: String) -> Bool {
        guard let m = legalMoves().first(where: { Self.lan($0) == lan }) else { return false }
        return make(m)
    }

    // MARK: Evaluation (centipawns, from the side to move)

    static let value: [Int] = [0, 100, 320, 330, 500, 900, 0]

    /// Simplified evaluation tables (Tomasz Michniewski), a8 first, from white's side.
    static let pst: [[Int]] = [
        [],
        [0, 0, 0, 0, 0, 0, 0, 0, 50, 50, 50, 50, 50, 50, 50, 50, 10, 10, 20, 30, 30, 20, 10, 10, 5, 5, 10, 25, 25, 10, 5, 5,
         0, 0, 0, 20, 20, 0, 0, 0, 5, -5, -10, 0, 0, -10, -5, 5, 5, 10, 10, -20, -20, 10, 10, 5, 0, 0, 0, 0, 0, 0, 0, 0],
        [-50, -40, -30, -30, -30, -30, -40, -50, -40, -20, 0, 0, 0, 0, -20, -40, -30, 0, 10, 15, 15, 10, 0, -30, -30, 5, 15, 20, 20, 15, 5, -30,
         -30, 0, 15, 20, 20, 15, 0, -30, -30, 5, 10, 15, 15, 10, 5, -30, -40, -20, 0, 5, 5, 0, -20, -40, -50, -40, -30, -30, -30, -30, -40, -50],
        [-20, -10, -10, -10, -10, -10, -10, -20, -10, 0, 0, 0, 0, 0, 0, -10, -10, 0, 5, 10, 10, 5, 0, -10, -10, 5, 5, 10, 10, 5, 5, -10,
         -10, 0, 10, 10, 10, 10, 0, -10, -10, 10, 10, 10, 10, 10, 10, -10, -10, 5, 0, 0, 0, 0, 5, -10, -20, -10, -10, -10, -10, -10, -10, -20],
        [0, 0, 0, 0, 0, 0, 0, 0, 5, 10, 10, 10, 10, 10, 10, 5, -5, 0, 0, 0, 0, 0, 0, -5, -5, 0, 0, 0, 0, 0, 0, -5,
         -5, 0, 0, 0, 0, 0, 0, -5, -5, 0, 0, 0, 0, 0, 0, -5, -5, 0, 0, 0, 0, 0, 0, -5, 0, 0, 0, 5, 5, 0, 0, 0],
        [-20, -10, -10, -5, -5, -10, -10, -20, -10, 0, 0, 0, 0, 0, 0, -10, -10, 0, 5, 5, 5, 5, 0, -10, -5, 0, 5, 5, 5, 5, 0, -5,
         0, 0, 5, 5, 5, 5, 0, -5, -10, 5, 5, 5, 5, 5, 0, -10, -10, 0, 5, 0, 0, 0, 0, -10, -20, -10, -10, -5, -5, -10, -10, -20],
        [-30, -40, -40, -50, -50, -40, -40, -30, -30, -40, -40, -50, -50, -40, -40, -30, -30, -40, -40, -50, -50, -40, -40, -30, -30, -40, -40, -50, -50, -40, -40, -30,
         -20, -30, -30, -40, -40, -30, -30, -20, -10, -20, -20, -20, -20, -20, -20, -10, 20, 20, 0, 0, 0, 0, 20, 20, 20, 30, 10, 0, 0, 10, 30, 20],
    ]
    static let kingEnd: [Int] = [
        -50, -40, -30, -20, -20, -30, -40, -50, -30, -20, -10, 0, 0, -10, -20, -30, -30, -10, 20, 30, 30, 20, -10, -30, -30, -10, 30, 40, 40, 30, -10, -30,
        -30, -10, 30, 40, 40, 30, -10, -30, -30, -10, 20, 30, 30, 20, -10, -30, -30, -30, 0, 0, 0, 0, -30, -30, -50, -30, -30, -30, -30, -30, -30, -50]
    static let phaseWeight: [Int] = [0, 0, 1, 1, 2, 4, 0]

    func evaluate() -> Int {
        var mg = 0, eg = 0, phase = 0
        var bishops = [0, 0]
        for s in 0..<120 where s & 0x88 == 0 {
            let p = sq[s]
            if p == 0 { continue }
            let k = Int(abs(p)), white = p > 0
            let i = white ? (7 - s >> 4) * 8 + s & 7 : (s >> 4) * 8 + s & 7
            let sign = white ? 1 : -1
            phase += Self.phaseWeight[k]
            if k == 3 { bishops[white ? 0 : 1] += 1 }
            if k == 6 { mg += sign * Self.pst[6][i]; eg += sign * Self.kingEnd[i]; continue }
            var v = Self.value[k] + Self.pst[k][i]
            mg += sign * v; eg += sign * v
            if k == 1 { eg += sign * (white ? s >> 4 : 7 - s >> 4) * 8 }   // pawns count more as they run in the endgame
        }
        let bp = (bishops[0] >= 2 ? 30 : 0) - (bishops[1] >= 2 ? 30 : 0)
        let ph = min(phase, 24)
        let score = (mg * ph + eg * (24 - ph)) / 24 + bp
        return side == 1 ? score : -score
    }

    var hasPieces: Bool {
        for s in 0..<120 where s & 0x88 == 0 {
            let p = sq[s]
            if p != 0, (p > 0) == (side > 0), abs(p) > 1, abs(p) < 6 { return true }
        }
        return false
    }
}

// MARK: - Search

/// One search over one position. Not thread-safe; make one per search, off the main actor.
final class Search {
    static let mate = 100_000, inf = 1_000_000
    let b: Board88
    var nodes = 0
    var stopped = false
    var deadline: UInt64 = .max
    var cancelled: () -> Bool = { false }
    var rootBest: Int32 = 0
    private var buf: [Int32] = []
    private var order: [Int] = []
    private var killers = [[Int32]](repeating: [0, 0], count: 128)
    private var history = [Int](repeating: 0, count: 128 * 128)

    private static let ttBits = 18
    private let ttMask = UInt64((1 << ttBits) - 1)
    private var ttKey = [UInt64](repeating: 0, count: 1 << ttBits)
    private var ttMove = [Int32](repeating: 0, count: 1 << ttBits)
    private var ttScore = [Int32](repeating: 0, count: 1 << ttBits)
    private var ttDepth = [Int8](repeating: 0, count: 1 << ttBits)
    private var ttFlag = [UInt8](repeating: 0, count: 1 << ttBits)   // 1 exact, 2 lower, 3 upper

    init(_ b: Board88) {
        self.b = b
        buf.reserveCapacity(8192); order.reserveCapacity(8192)
    }

    private func checkStop() {
        if DispatchTime.now().uptimeNanoseconds >= deadline || cancelled() { stopped = true }
    }

    private func toTT(_ s: Int, _ ply: Int) -> Int { s > Self.mate - 1000 ? s + ply : s < -Self.mate + 1000 ? s - ply : s }
    private func fromTT(_ s: Int, _ ply: Int) -> Int { s > Self.mate - 1000 ? s - ply : s < -Self.mate + 1000 ? s + ply : s }

    /// Orders the moves in buf[start...] by writing a score per move into `order`.
    private func scoreMoves(from start: Int, ttm: Int32, ply: Int) {
        order.removeSubrange(min(start, order.count)...)
        for i in start..<buf.count {
            let m = buf[i]
            let victim = b.sq[Board88.to(m)], attacker = Int(abs(b.sq[Board88.from(m)]))
            var s: Int
            if m == ttm { s = 10_000_000 }
            else if victim != 0 || (attacker == 1 && Board88.to(m) == b.ep) { s = 1_000_000 + Int(abs(victim)) * 10 - attacker }
            else if Board88.promo(m) != 0 { s = 900_000 + Int(Board88.promo(m)) }
            else if ply < 128 && m == killers[ply][0] { s = 800_000 }
            else if ply < 128 && m == killers[ply][1] { s = 700_000 }
            else { s = history[Board88.from(m) * 128 + Board88.to(m)] }
            order.append(s)
        }
    }

    /// Swaps the best remaining move to index i.
    @inline(__always) private func pick(_ i: Int) {
        var best = i
        for j in (i + 1)..<buf.count where order[j] > order[best] { best = j }
        if best != i { buf.swapAt(i, best); order.swapAt(i, best) }
    }

    func quiesce(_ alphaIn: Int, _ beta: Int, _ ply: Int) -> Int {
        nodes &+= 1
        if nodes & 2047 == 0 { checkStop() }
        if stopped { return 0 }
        var alpha = alphaIn
        let stand = b.evaluate()
        if stand >= beta || ply >= 100 { return stand }
        if stand > alpha { alpha = stand }
        let start = buf.count
        b.generate(&buf, capturesOnly: true)
        scoreMoves(from: start, ttm: 0, ply: 127)
        var i = start
        while i < buf.count {
            pick(i)
            let m = buf[i]; i += 1
            guard b.make(m) else { continue }
            let s = -quiesce(-beta, -alpha, ply + 1)
            b.unmake()
            if stopped { break }
            if s >= beta { alpha = s; break }
            if s > alpha { alpha = s }
        }
        buf.removeSubrange(start...)
        return alpha
    }

    func search(_ depthIn: Int, _ alphaIn: Int, _ beta: Int, _ ply: Int, nullOK: Bool = true) -> Int {
        nodes &+= 1
        if nodes & 2047 == 0 { checkStop() }
        if stopped { return 0 }
        if ply > 0 && (b.half >= 100 || b.isRepetition) { return 0 }
        var alpha = alphaIn
        let inCheck = b.inCheck
        let depth = inCheck ? depthIn + 1 : depthIn
        if depth <= 0 { return quiesce(alpha, beta, ply) }
        if ply >= 100 { return b.evaluate() }

        let idx = Int(b.hash & ttMask)
        var ttm: Int32 = 0
        if ttKey[idx] == b.hash {
            ttm = ttMove[idx]
            if ply > 0 && Int(ttDepth[idx]) >= depth {
                let s = fromTT(Int(ttScore[idx]), ply)
                switch ttFlag[idx] {
                case 1: return s
                case 2 where s >= beta: return s
                case 3 where s <= alpha: return s
                default: break
                }
            }
        }

        if nullOK && !inCheck && depth >= 3 && ply > 0 && beta < Self.mate - 1000 && b.hasPieces && b.evaluate() >= beta {
            b.makeNull()
            let s = -search(depth - 3, -beta, -beta + 1, ply + 1, nullOK: false)
            b.unmakeNull()
            if stopped { return 0 }
            if s >= beta { return beta }
        }

        let start = buf.count
        b.generate(&buf, capturesOnly: false)
        scoreMoves(from: start, ttm: ttm, ply: ply)
        var best = -Self.inf, bestMove: Int32 = 0, legal = 0
        var i = start
        while i < buf.count {
            pick(i)
            let m = buf[i]; i += 1
            guard b.make(m) else { continue }
            legal += 1
            let quiet = b.lastCaptured == 0 && Board88.promo(m) == 0
            var s: Int
            if legal == 1 {
                s = -search(depth - 1, -beta, -alpha, ply + 1)
            } else {
                let r = depth >= 3 && legal > 4 && quiet && !inCheck && !b.inCheck ? 1 : 0
                s = -search(depth - 1 - r, -alpha - 1, -alpha, ply + 1)
                if s > alpha && (r > 0 || s < beta) && !stopped { s = -search(depth - 1, -beta, -alpha, ply + 1) }
            }
            b.unmake()
            if stopped { break }
            if s > best {
                best = s; bestMove = m
                if s > alpha {
                    alpha = s
                    if ply == 0 { rootBest = m }
                    if s >= beta {
                        if quiet && ply < 128 {
                            if killers[ply][0] != m { killers[ply][1] = killers[ply][0]; killers[ply][0] = m }
                            history[Board88.from(m) * 128 + Board88.to(m)] += depth * depth
                        }
                        break
                    }
                }
            }
        }
        buf.removeSubrange(start...)
        if stopped { return 0 }
        if legal == 0 { return inCheck ? -Self.mate + ply : 0 }
        ttKey[idx] = b.hash
        ttMove[idx] = bestMove
        ttScore[idx] = Int32(toTT(best, ply))
        ttDepth[idx] = Int8(clamping: depth)
        ttFlag[idx] = best <= alphaIn ? 3 : best >= beta ? 2 : 1
        return best
    }

    /// Iterative deepening to `maxDepth` or until the deadline. Returns the best move, its score and
    /// the deepest finished iteration.
    func best(maxDepth: Int) -> (move: Int32, score: Int, depth: Int) {
        var score = 0, done = 0
        for d in 1...max(1, maxDepth) {
            let s = search(d, -Self.inf, Self.inf, 0)
            if stopped { break }
            score = s; done = d
            if abs(s) > Self.mate - 1000 { break }   // a forced mate found: deeper search changes nothing
        }
        if rootBest == 0 { rootBest = b.legalMoves().first ?? 0 }
        return (rootBest, score, done)
    }

    /// Every legal root move scored at `depth` (full window), for the weak levels' choice among good moves.
    func scoreAll(depth: Int) -> [(move: Int32, score: Int)] {
        b.legalMoves().map { m in
            b.make(m)
            let s = -search(depth - 1, -Self.inf, Self.inf, 1)
            b.unmake()
            return (m, s)
        }
    }
}
