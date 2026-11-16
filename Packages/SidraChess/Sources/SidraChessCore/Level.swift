import Foundation
import Synchronization

final class StopFlag: Sendable { let value = Atomic<Bool>(false) }

/// The six engine levels of the round card. The Elo is the label the user picks by, not a measured
/// rating: the engine's real ceiling is far below 2800 (see the spec, F20).
public enum ChessLevel: Int, CaseIterable, Codable, Sendable, Identifiable {
    case beginner, casual, club, strong, expert, master

    public var id: Int { rawValue }
    public var name: String { ["Beginner", "Casual", "Club", "Strong", "Expert", "Master"][rawValue] }
    public var elo: Int { [800, 1200, 1600, 2000, 2400, 2800][rawValue] }

    /// How the engine plays at this level.
    public struct Play: Sendable {
        /// Search depth in plies (iterative deepening stops earlier when the time runs out).
        public var depth: Int
        public var seconds: Double
        /// Weak levels score every move and pick at random among those within this many centipawns of the best.
        public var margin: Int
        /// Chance of a plain random legal move instead: the deliberate blunder.
        public var blunder: Double
        public var book: Bool
    }

    public var play: Play {
        switch self {
        case .beginner: Play(depth: 1, seconds: 2, margin: 180, blunder: 0.2, book: false)
        case .casual: Play(depth: 2, seconds: 2, margin: 70, blunder: 0.07, book: false)
        case .club: Play(depth: 3, seconds: 2, margin: 25, blunder: 0.02, book: true)
        case .strong: Play(depth: 5, seconds: 1, margin: 0, blunder: 0, book: true)
        case .expert: Play(depth: 64, seconds: 2, margin: 0, blunder: 0, book: true)
        case .master: Play(depth: 64, seconds: 4, margin: 0, blunder: 0, book: true)
        }
    }

    /// One step up after a win, down after a loss, the same after a draw.
    public func suggested(after result: RoundResult) -> ChessLevel {
        switch result {
        case .win: ChessLevel(rawValue: min(rawValue + 1, 5))!
        case .loss: ChessLevel(rawValue: max(rawValue - 1, 0))!
        case .draw: self
        }
    }
}

public enum RoundResult: String, Codable, Sendable { case win = "W", loss = "L", draw = "D" }

public enum ChessEngine {
    /// The engine's move (LAN, "e7e8q") for the position after `lans` from `fen`, or nil when it has none.
    /// Runs off the main actor; cancelling the calling task stops the search.
    public static func move(fen: String = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", lans: [String], level: ChessLevel,
                            seed: UInt64 = .random(in: 0...UInt64.max)) async -> String? {
        // The search runs detached (off the main actor), so the caller's cancellation reaches it through a flag.
        let stop = StopFlag()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                var rng = SplitMix(seed)
                return think(fen: fen, lans: lans, level: level, rng: &rng, cancelled: { stop.value.load(ordering: .relaxed) })
            }.value
        } onCancel: { stop.value.store(true, ordering: .relaxed) }
    }

    static func think(fen: String, lans: [String], level: ChessLevel, rng: inout SplitMix,
                      cancelled: @escaping () -> Bool = { false }) -> String? {
        guard let b = Board88(fen: fen) else { return nil }
        for l in lans where !b.play(lan: l) { return nil }
        let moves = b.legalMoves()
        guard !moves.isEmpty else { return nil }
        let p = level.play
        if Double.random(in: 0..<1, using: &rng) < p.blunder { return Board88.lan(moves.randomElement(using: &rng)!) }
        let s = Search(b)
        s.cancelled = cancelled
        s.deadline = DispatchTime.now().uptimeNanoseconds + UInt64(p.seconds * 1e9)
        if p.margin > 0 {
            let scored = s.scoreAll(depth: p.depth)
            if s.stopped && cancelled() { return nil }
            let best = scored.map(\.score).max()!
            // Never miss a mate in one, even at Beginner: that reads as broken, not as weak.
            let pool = best > Search.mate - 1000 ? scored.filter { $0.score == best } : scored.filter { $0.score >= best - p.margin }
            return Board88.lan(pool.randomElement(using: &rng)!.move)
        }
        let r = s.best(maxDepth: p.depth)
        if cancelled() { return nil }
        return Board88.lan(r.move)
    }

    /// Search to a fixed depth with no time limit, for tests.
    static func search(fen: String, depth: Int) -> (lan: String, score: Int, depth: Int)? {
        guard let b = Board88(fen: fen), !b.legalMoves().isEmpty else { return nil }
        let r = Search(b).best(maxDepth: depth)
        return (Board88.lan(r.move), r.score, r.depth)
    }
}

/// A small seedable generator so tests are repeatable.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
