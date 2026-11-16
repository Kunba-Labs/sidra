import Foundation
import Observation
import ChessKit

/// The chess tab's state: the game in play, the rounds so far and the user's choices. One for the
/// app's life, so switching tabs never loses a game; rounds, level and the game in play persist.
@MainActor @Observable
public final class ChessStore {
    public static let shared = ChessStore()

    public struct Round: Codable, Equatable, Sendable {
        public var result: RoundResult
        public var level: ChessLevel
    }
    public enum Side: String, Codable, CaseIterable, Sendable { case white = "White", black = "Black", random = "Random" }

    // Persisted
    public private(set) var rounds: [Round] = []
    public var level: ChessLevel = .casual { didSet { save() } }
    public var side: Side = .white { didSet { save() } }
    public var sideCollapsed = false { didSet { save() } }

    // The game
    public private(set) var board = Board()
    public private(set) var lans: [String] = []
    public private(set) var sans: [String] = []
    /// Every piece taken this game, in order; recorded as moves are played and rebuilt by replay (undo, restore).
    public private(set) var taken: [Piece] = []
    public private(set) var userWhite = true
    public private(set) var gameLevel: ChessLevel = .casual
    public private(set) var inPlay = false
    public private(set) var thinking = false
    /// "Checkmate: you win round 4." Shown on the next round's card.
    public private(set) var outcome: String?
    public var cardShown = true
    public var flipped = false
    /// Counts the engine's moves, so the board can slide each one in.
    public private(set) var engineMoves = 0
    public var selected: Square?
    public var promotion: (from: Square, to: Square)?

    private var engineTask: Task<Void, Never>?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if DEBUG
        if defaults.bool(forKey: "chess.reset") { for k in ["chess.rounds", "chess.level", "chess.side", "chess.sideCollapsed", "chess.game"] { defaults.removeObject(forKey: k) } }
        #endif
        let game = defaults.string(forKey: "chess.game")
        if let d = defaults.data(forKey: "chess.rounds"), let r = try? JSONDecoder().decode([Round].self, from: d) { rounds = r }
        level = ChessLevel(rawValue: defaults.integer(forKey: "chess.level")) ?? .casual
        side = Side(rawValue: defaults.string(forKey: "chess.side") ?? "") ?? .white
        sideCollapsed = defaults.bool(forKey: "chess.sideCollapsed")
        if let g = game {   // "w|2|e2e4 e7e5"
            let f = g.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if f.count == 3 {
                userWhite = f[0] == "w"
                flipped = !userWhite   // a game as Black comes back with Black at the bottom
                gameLevel = ChessLevel(rawValue: Int(f[1]) ?? 1) ?? .casual
                replay(f[2].split(separator: " ").map(String.init))
                inPlay = true
                cardShown = false
                engineIfDue()
            }
        }
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(rounds), forKey: "chess.rounds")
        defaults.set(level.rawValue, forKey: "chess.level")
        defaults.set(side.rawValue, forKey: "chess.side")
        defaults.set(sideCollapsed, forKey: "chess.sideCollapsed")
        if inPlay { defaults.set("\(userWhite ? "w" : "b")|\(gameLevel.rawValue)|\(lans.joined(separator: " "))", forKey: "chess.game") }
        else { defaults.removeObject(forKey: "chess.game") }
    }

    // MARK: Rounds

    public var roundNumber: Int { rounds.count + 1 }
    public var wins: Int { rounds.filter { $0.result == .win }.count }
    public var losses: Int { rounds.filter { $0.result == .loss }.count }
    public var draws: Int { rounds.filter { $0.result == .draw }.count }

    /// The level the card proposes: one step from the last round's level by its result.
    public var suggested: ChessLevel { rounds.last.map { $0.level.suggested(after: $0.result) } ?? .casual }
    public var suggestion: String {
        guard let last = rounds.last else { return "First round: Casual is a fair start." }
        let s = last.level.suggested(after: last.result)
        switch last.result {
        case .win: return s == last.level ? "You won at \(last.level.name), the top level." : "You won the last round at \(last.level.name): one step up suggested."
        case .loss: return s == last.level ? "You lost at \(last.level.name), the easiest level." : "You lost the last round at \(last.level.name): one step down suggested."
        case .draw: return "A draw at \(last.level.name): same level suggested."
        }
    }

    public func start() {
        engineTask?.cancel()
        userWhite = side == .random ? Bool.random() : side == .white
        gameLevel = level
        replay([])
        flipped = !userWhite
        outcome = nil
        inPlay = true
        cardShown = false
        save()
        engineIfDue()
    }

    public func resign() { finish(.loss, "You resigned round \(roundNumber).") }

    /// Back to the round card; a game in play counts as resigned.
    public func newRound() {
        if inPlay && !lans.isEmpty { resign() } else { inPlay = false; engineTask?.cancel(); thinking = false; save() }
        level = suggested
        cardShown = true
    }

    private func finish(_ r: RoundResult, _ text: String) {
        engineTask?.cancel()
        thinking = false
        rounds.append(Round(result: r, level: gameLevel))
        inPlay = false
        outcome = text
        selected = nil
        level = suggested
        cardShown = true
        save()
    }

    // MARK: Moves

    public var userToMove: Bool { inPlay && !thinking && (board.position.sideToMove == .white) == userWhite }
    public var opening: Opening? { Openings.shared.name(for: sans) }
    public var lastMove: (Square, Square)? {
        guard let l = lans.last else { return nil }
        return (Square(String(l.prefix(2))), Square(String(l.dropFirst(2).prefix(2))))
    }
    public var checkedKing: Square? {
        let c: Piece.Color
        switch board.state {
        case .check(let x), .checkmate(let x): c = x
        default: return nil
        }
        return board.position.pieces.first { $0.kind == .king && $0.color == c }?.square
    }

    public func targets(from s: Square) -> [Square] { board.legalMoves(forPieceAt: s) }

    public func tap(_ s: Square) {
        guard userToMove else { return }
        let mine = board.position.piece(at: s).map { ($0.color == .white) == userWhite } ?? false
        if let from = selected, from != s, targets(from: from).contains(s) {
            selected = nil
            let piece = board.position.piece(at: from)
            if piece?.kind == .pawn && (s.rank.value == 8 || s.rank.value == 1) { promotion = (from, s); return }
            userMove(lan: from.notation + s.notation)
        } else {
            selected = mine && selected != s ? s : nil
        }
    }

    public func promote(to kind: Piece.Kind) {
        guard let p = promotion else { return }
        promotion = nil
        userMove(lan: p.from.notation + p.to.notation + kind.rawValue.lowercased())
    }

    private func userMove(lan: String) {
        guard apply(lan) else { return }
        save()
        if !checkEnd() { engineIfDue() }
    }

    /// Plays a LAN move on the board; false if it is not legal.
    @discardableResult
    private func apply(_ lan: String) -> Bool {
        guard lan.count >= 4 else { return false }
        let a = Square(String(lan.prefix(2))), b = Square(String(lan.dropFirst(2).prefix(2)))
        guard var mv = board.move(pieceAt: a, to: b) else { return false }
        if case .promotion(let pending) = board.state {
            let k: Piece.Kind
            switch lan.dropFirst(4).first ?? "q" {
            case "r": k = .rook
            case "b": k = .bishop
            case "n": k = .knight
            default: k = .queen
            }
            mv = board.completePromotion(of: pending, to: k)
        }
        lans.append(lan)
        sans.append(mv.san)
        if case .capture(let p) = mv.result { taken.append(p) }
        return true
    }

    private func replay(_ moves: [String]) {
        board = Board()
        lans = []; sans = []; taken = []
        selected = nil; promotion = nil
        for l in moves where !apply(l) { break }
    }

    /// Ends the round if the board says so. True when it ended.
    private func checkEnd() -> Bool {
        let n = roundNumber
        switch board.state {
        case .checkmate(let loser):
            let won = (loser == .white) != userWhite
            finish(won ? .win : .loss, won ? "Checkmate: you win round \(n)." : "Checkmate: the engine wins round \(n).")
        case .draw(let reason):
            let why: String
            switch reason {
            case .stalemate: why = "stalemate"
            case .repetition: why = "threefold repetition"
            case .fiftyMoves: why = "the fifty-move rule"
            case .insufficientMaterial: why = "insufficient material"
            case .agreement: why = "agreement"
            }
            finish(.draw, "Round \(n) is a draw by \(why).")
        default: return false
        }
        return true
    }

    private func engineIfDue() {
        guard inPlay, (board.position.sideToMove == .white) != userWhite else { return }
        thinking = true
        let lans = lans, sans = sans, level = gameLevel, position = board.position
        // A human-looking pause (2026-11-14: "a bit fake thinking time a few sec"): 1.5-3.5 s in all,
        // however fast the search was, so the answer never lands before you have looked up.
        let pause = Double.random(in: 1.5...3.5)
        engineTask = Task { [weak self] in
            let began = ContinuousClock.now
            var move: String?
            if level.play.book, let san = Openings.shared.continuations(after: sans).randomElement(),
               let m = SANParser.parse(move: san, in: position) {
                move = m.start.notation + m.end.notation + (m.promotedPiece.map { $0.kind.rawValue.lowercased() } ?? "")
            }
            if move == nil { move = await ChessEngine.move(lans: lans, level: level) }
            let left = pause - (ContinuousClock.now - began).seconds
            if left > 0, !CommandLine.arguments.contains("-chess.fast") { try? await Task.sleep(for: .seconds(left)) }
            guard let self, !Task.isCancelled, self.lans == lans else { return }
            self.thinking = false
            if let move, self.apply(move) {
                self.engineMoves += 1
                self.save()
                _ = self.checkEnd()
            }
        }
    }

    /// Takes back your last move and the engine's answer (or just yours while it thinks).
    public var canUndo: Bool {
        inPlay && (thinking ? !lans.isEmpty : lans.count >= (userWhite ? 2 : 3))
    }

    public func undo() {
        guard canUndo else { return }
        let n = thinking ? 1 : 2
        engineTask?.cancel()
        thinking = false
        replay(Array(lans.dropLast(n)))
        save()
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
