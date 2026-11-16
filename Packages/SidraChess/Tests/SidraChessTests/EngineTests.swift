import XCTest
import ChessKit
@testable import SidraChessCore

final class EngineTests: XCTestCase {
    private func perft(_ b: Board88, _ d: Int) -> Int {
        if d == 0 { return 1 }
        var n = 0
        for m in b.legalMoves() { b.make(m); n += perft(b, d - 1); b.unmake() }
        return n
    }

    /// Move generation matches the published perft counts: castling, en passant, promotions, pins, checks.
    func testPerft() {
        XCTAssertEqual(perft(Board88(fen: Board88.startFEN)!, 4), 197_281)
        let kiwipete = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"
        XCTAssertEqual(perft(Board88(fen: kiwipete)!, 3), 97_862)
        XCTAssertEqual(perft(Board88(fen: "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1")!, 5), 674_624)
        XCTAssertEqual(perft(Board88(fen: "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1")!, 4), 422_333)
    }

    /// make/unmake restores the hash exactly, so the transposition table and repetition see the same position.
    func testHashRestored() {
        let b = Board88(fen: "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1")!
        for m in b.legalMoves() {
            b.make(m)
            XCTAssertEqual(b.hash, b.computeHash(), Board88.lan(m))
            b.unmake()
        }
        XCTAssertEqual(b.hash, b.computeHash())
    }

    func testMateInOne() {
        // Back-rank mate: Re8#.
        XCTAssertEqual(ChessEngine.search(fen: "6k1/5ppp/8/8/8/8/5PPP/4R1K1 w - - 0 1", depth: 2)?.lan, "e1e8")
        // Scholar's mate: Qxf7#.
        XCTAssertEqual(ChessEngine.search(fen: "r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4", depth: 2)?.lan, "h5f7")
    }

    func testMateInTwo() {
        // 1. Nf6+ gxf6 2. Bxf7#.
        let r = ChessEngine.search(fen: "r2qkb1r/pp2nppp/3p4/2pNN1B1/2BnP3/3P4/PPP2PPP/R2bK2R w KQkq - 1 1", depth: 4)
        XCTAssertEqual(r?.lan, "d5f6")
        XCTAssertGreaterThan(r?.score ?? 0, Search.mate - 10)
    }

    /// Every level answers with a move ChessKit accepts as legal, through a whole game against itself.
    func testNeverIllegal() {
        var rng = SplitMix(7)
        for level in [ChessLevel.beginner, .casual, .club] {
            var board = Board()
            var lans: [String] = []
            for _ in 0..<80 {
                if case .checkmate = board.state { break }
                if case .draw = board.state { break }
                guard let lan = ChessEngine.think(fen: Board88.startFEN, lans: lans, level: level, rng: &rng) else {
                    XCTFail("\(level) gave no move with legal moves left"); return
                }
                let a = Square(String(lan.prefix(2))), b = Square(String(lan.dropFirst(2).prefix(2)))
                XCTAssertTrue(board.canMove(pieceAt: a, to: b), "\(level) played illegal \(lan) after \(lans)")
                guard let mv = board.move(pieceAt: a, to: b) else { return }
                if case .promotion = board.state { board.completePromotion(of: mv, to: .queen) }
                lans.append(lan.count == 5 ? String(lan.prefix(4)) + "q" : lan)
            }
        }
    }

    /// Levels differ by depth and time: Strong stops at depth 5, Expert goes deeper in its two seconds.
    func testLevelsRespectDepthAndTime() {
        let fen = "r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4"
        let b = Board88(fen: fen)!
        let s = Search(b)
        s.deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        XCTAssertEqual(s.best(maxDepth: 5).depth, 5)

        let t0 = Date()
        var rng = SplitMix(1)
        XCTAssertNotNil(ChessEngine.think(fen: fen, lans: [], level: .expert, rng: &rng))
        let took = Date().timeIntervalSince(t0)
        XCTAssertLessThan(took, ChessLevel.expert.play.seconds + 0.5, "Expert overran its time")
        XCTAssertGreaterThan(took, ChessLevel.expert.play.seconds - 0.3, "Expert stopped before its time")

        let deep = Search(Board88(fen: fen)!)
        deep.deadline = DispatchTime.now().uptimeNanoseconds + UInt64(ChessLevel.expert.play.seconds * 1e9)
        let r = deep.best(maxDepth: 64)
        print("Expert reached depth \(r.depth), \(deep.nodes) nodes in \(ChessLevel.expert.play.seconds) s")
        XCTAssertGreaterThan(r.depth, 5)
    }

    /// Beginner throws pieces away sometimes; Strong takes a hanging queen every time.
    func testWeakLevelsAreWeaker() {
        let fen = "rnb1kbnr/pppp1ppp/8/4p1q1/3P4/2N5/PPP1PPPP/R1BQKBNR w KQkq - 0 1"   // Bxg5 wins the queen
        var rng = SplitMix(3)
        let strong = (0..<5).map { _ in ChessEngine.think(fen: fen, lans: [], level: .strong, rng: &rng) }
        XCTAssertEqual(Set(strong), ["c1g5"])
        let beginner = Set((0..<30).map { _ in ChessEngine.think(fen: fen, lans: [], level: .beginner, rng: &rng)! })
        XCTAssertGreaterThan(beginner.count, 1, "Beginner always played the same move")
    }

    func testCancelStopsTheSearch() async {
        let t = Task { await ChessEngine.move(lans: [], level: .master) }
        try? await Task.sleep(for: .milliseconds(200))
        let t0 = Date()
        t.cancel()
        _ = await t.value
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.5)
    }

    func testOpeningBook() {
        XCTAssertEqual(Openings.shared.name(for: ["e4", "e5", "Nf3", "Nc6", "Bb5"])?.name, "Ruy Lopez")
        XCTAssertTrue(Openings.shared.continuations(after: []).contains("e4"))
    }

    func testSuggestedLevel() {
        XCTAssertEqual(ChessLevel.club.suggested(after: .win), .strong)
        XCTAssertEqual(ChessLevel.club.suggested(after: .loss), .casual)
        XCTAssertEqual(ChessLevel.master.suggested(after: .win), .master)
        XCTAssertEqual(ChessLevel.beginner.suggested(after: .loss), .beginner)
    }
}
