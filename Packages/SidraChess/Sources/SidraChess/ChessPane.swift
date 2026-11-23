import SwiftUI
import ChessKit
import SidraDesign
@_exported import SidraChessCore

/// The Chess tab: you against Sidra's engine. The board takes all the height it can; the narrow
/// right column (engine, round, opening, moves, actions) collapses to give the board the width.
/// Each round starts from a card where you pick the engine's level and your colour (mock-up 3 of
/// design/html/12-chess.html, as changed on 2026-11-14).
public struct ChessPane: View {
    @State private var store = ChessStore.shared
    public init() {}

    static let column: CGFloat = 280

    public var body: some View {
        GeometryReader { g in
            let side = !store.sideCollapsed
            // Side by side unless the column would leave the board smaller than the space under it (a phone in portrait).
            let row = !side || g.size.width - Self.column >= min(g.size.height, 420)
            Group {
                if row {
                    HStack(spacing: 0) {
                        boardArea(min(g.size.height, g.size.width - (side ? Self.column : 0)) - 28)
                        if side {
                            Rectangle().fill(SidraColor.hairline).frame(width: 1)
                            fitting { SideColumn(store: store) }.frame(width: Self.column)
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        boardArea(min(g.size.width, g.size.height * 0.62) - 28)
                        Rectangle().fill(SidraColor.hairline).frame(height: 1)
                        fitting { SideColumn(store: store) }
                    }
                }
            }
            .overlay { if store.cardShown { RoundCard(store: store) } }
            .overlay { if store.promotion != nil { PromotionPicker(store: store) } }
        }
        .background(SidraColor.pane)
    }

    /// The column as it is when it fits; in a short pane it scrolls, so its buttons never fall off the bottom.
    private func fitting(@ViewBuilder _ column: () -> some View) -> some View {
        let c = column()
        return ViewThatFits(in: .vertical) {
            c
            ScrollView { c.frame(minHeight: 520) }
        }
    }

    private func boardArea(_ size: CGFloat) -> some View {
        // Taken pieces flank the board, white's on the left, black's on the right; the board gives up their width.
        let w = min(40, max(20, size * 0.07)), board = max(size - 2 * (w + 6), 1)
        return HStack(spacing: 6) {
            CapturedColumn(pieces: store.captured(.white), width: w).frame(height: board)
            BoardView(store: store, size: board)   // the space there is, never more, so the controls stay in the pane
            CapturedColumn(pieces: store.captured(.black), width: w).frame(height: board)
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                if store.sideCollapsed {
                    IconButton("sidebar.right", label: "Show the side panel", size: 30) { store.sideCollapsed = false }
                        .padding(6)
                }
            }
    }
}

// MARK: - Board

struct BoardView: View {
    let store: ChessStore
    let size: CGFloat
    /// Drag and drop: the square a piece was picked up from, and where the finger is.
    @State private var dragFrom: Square?
    @State private var finger: CGPoint?
    /// True while the engine's last move slides from its old square to its new one (SlidingPiece).
    @State private var sliding = false
    /// Keyboard focus: a thin jade outline instead of the system's dark focus fill.
    @FocusState private var focused: String?

    private func point(_ s: Square, cell: CGFloat) -> CGPoint {
        let file = s.file.number - 1, rank = s.rank.value
        let col = store.flipped ? 7 - file : file, row = store.flipped ? rank - 1 : 8 - rank
        return CGPoint(x: (CGFloat(col) + 0.5) * cell, y: (CGFloat(row) + 0.5) * cell)
    }
    private func square(at p: CGPoint, cell: CGFloat) -> Square? {
        let col = Int(p.x / cell), row = Int(p.y / cell)
        guard (0..<8).contains(col), (0..<8).contains(row) else { return nil }
        let file = store.flipped ? 7 - col : col, rank = store.flipped ? row + 1 : 8 - row
        return Square("\("abcdefgh"[file])\(rank)")
    }

    var body: some View {
        let cell = size / 8
        let last = store.lastMove
        let targets = store.selected.map(store.targets(from:)) ?? []
        let check = store.checkedKing
        VStack(spacing: 0) {
            ForEach(0..<8, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { col in
                        let file = store.flipped ? 7 - col : col
                        let rank = store.flipped ? row + 1 : 8 - row
                        let sq = Square("\("abcdefgh"[file])\(rank)")
                        // A piece being dragged, or the engine's piece still sliding in, is drawn on top instead.
                        let hidden = sq == dragFrom || (sliding && last?.1 == sq)
                        SquareView(square: sq, piece: hidden ? nil : store.board.position.piece(at: sq), cell: cell,
                                   light: (file + rank) % 2 == 1,
                                   last: last.map { $0.0 == sq || $0.1 == sq } ?? false,
                                   selected: store.selected == sq, target: targets.contains(sq), check: check == sq,
                                   rankLabel: col == 7 ? "\(rank)" : nil, fileLabel: row == 7 ? "abcdefgh"[file] : nil)
                            .onTapGesture { store.tap(sq) }
                            // Keyboard: Tab or arrows reach a square, Space or Return picks it.
                            .focusable()
                            .focusEffectDisabled()
                            .focused($focused, equals: sq.notation)
                            .overlay { if focused == sq.notation { Rectangle().strokeBorder(SidraColor.jade.opacity(0.6), lineWidth: 2) } }
                            .onKeyPress(keys: [.space, .return]) { _ in store.tap(sq); return .handled }
                            .accessibilityAction { store.tap(sq) }
                    }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if sliding, let l = last, let piece = store.board.position.piece(at: l.1) {
                SlidingPiece(piece: piece, cell: cell, from: point(l.0, cell: cell), to: point(l.1, cell: cell)) { sliding = false }
                    .id(store.engineMoves)
            }
            if let from = dragFrom, let f = finger, let piece = store.board.position.piece(at: from) {
                PieceGlyph(piece: piece, size: cell * 1.15).frame(width: cell * 1.15, height: cell * 1.15)
                    .position(f).allowsHitTesting(false)
            }
        }
        // Pick a piece up and drop it on a square; a tap still selects and moves.
        .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .onChanged { v in
                if dragFrom == nil {
                    guard let from = square(at: v.startLocation, cell: cell), store.userToMove,
                          let p = store.board.position.piece(at: from), (p.color == .white) == store.userWhite else { return }
                    if store.selected != from { store.tap(from) }
                    dragFrom = from
                }
                finger = v.location
            }
            .onEnded { v in
                if dragFrom != nil, let to = square(at: v.location, cell: cell), to != dragFrom { store.tap(to) }
                dragFrom = nil; finger = nil
            })
        .onChange(of: store.engineMoves) { _, _ in
            sliding = true
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: SidraRadius.popup, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SidraRadius.popup, style: .continuous).strokeBorder(SidraColor.hairline2))
    }
}

/// The engine's piece gliding from its old square to its new one. It is drawn at `from` first and only
/// animates on appear, so the start is always on screen (setting 0 then 1 in one update never moves).
struct SlidingPiece: View {
    let piece: Piece
    let cell: CGFloat
    let from, to: CGPoint
    let done: () -> Void
    @State private var t: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        PieceGlyph(piece: piece, size: cell).frame(width: cell, height: cell)
            .position(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            .allowsHitTesting(false)
            .onAppear {
                if still { done(); return }
                withAnimation(.easeInOut(duration: 0.5)) { t = 1 } completion: { done() }
            }
    }
}

/// One side's taken pieces, queen first, small and stacked down a slim column beside the board.
struct CapturedColumn: View {
    let pieces: [Piece]
    let width: CGFloat
    var body: some View {
        GeometryReader { g in
            // Each piece takes 3/4 of its size in the stack; shrink them when 15 would not fit the board's height.
            let size = min(width, pieces.isEmpty ? width : g.size.height / (CGFloat(pieces.count) * 0.75 + 0.25))
            VStack(spacing: -size * 0.25) {
                ForEach(Array(pieces.enumerated()), id: \.offset) { _, p in PieceGlyph(piece: p, size: size).frame(width: size, height: size) }
            }
            .frame(width: width, alignment: .top)
        }
        .frame(width: width)
        .accessibilityElement()
        .accessibilityLabel(pieces.isEmpty ? "" : "Taken \(pieces.first!.color == .white ? "white" : "black"): " + pieces.map { SquareView.name($0.kind) }.joined(separator: ", "))
    }
}

extension ChessStore {
    /// The pieces of `color` taken this game, queen first.
    func captured(_ color: Piece.Color) -> [Piece] {
        let order: [Piece.Kind] = [.queen, .rook, .bishop, .knight, .pawn]
        return taken.filter { $0.color == color }.sorted { (order.firstIndex(of: $0.kind) ?? 9) < (order.firstIndex(of: $1.kind) ?? 9) }
    }
}

struct SquareView: View {
    let square: Square
    let piece: Piece?
    let cell: CGFloat
    let light, last, selected, target, check: Bool
    let rankLabel, fileLabel: String?

    var body: some View {
        ZStack {
            Rectangle().fill(light ? SidraColor.Board.light : SidraColor.Board.dark)
            if last { Rectangle().fill(SidraColor.gold.opacity(0.16)) }
            if check { Rectangle().fill(SidraColor.red.opacity(0.3)) }   // flat, no glow (2026-11-14)
            if let piece { PieceGlyph(piece: piece, size: cell) }
            if target {
                if piece == nil { Circle().fill(SidraColor.jade.opacity(0.55)).frame(width: cell * 0.22, height: cell * 0.22) }
                else { Circle().strokeBorder(SidraColor.jade.opacity(0.6), lineWidth: max(3, cell * 0.06)).padding(cell * 0.04) }
            }
            if selected { Rectangle().strokeBorder(SidraColor.jade, lineWidth: 3) }
        }
        .overlay(alignment: .bottomTrailing) { label(rankLabel).padding(.trailing, 4).padding(.bottom, 2) }
        .overlay(alignment: .bottomLeading) { label(fileLabel).padding(.leading, 4).padding(.bottom, 2) }
        .frame(width: cell, height: cell)
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel(square.notation + (piece.map { ", \($0.color == .white ? "white" : "black") \(Self.name($0.kind))" } ?? ""))
        .accessibilityIdentifier("square-\(square.notation)")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private func label(_ s: String?) -> some View {
        if let s { Text(s).font(SidraFont.mono(max(9, cell * 0.12), weight: .semibold)).foregroundStyle(SidraColor.dim) }
    }

    static func name(_ k: Piece.Kind) -> String {
        switch k { case .pawn: "pawn"; case .knight: "knight"; case .bishop: "bishop"; case .rook: "rook"; case .queen: "queen"; case .king: "king" }
    }
}

/// Unicode chess glyphs, drawn twice: the solid shape filled, the outline shape over it for an edge.
/// U+FE0E keeps the pawn from turning into an emoji.
struct PieceGlyph: View {
    let piece: Piece
    let size: CGFloat

    static func glyphs(_ k: Piece.Kind) -> (solid: String, outline: String) {
        switch k {
        case .king: ("\u{265A}", "\u{2654}")
        case .queen: ("\u{265B}", "\u{2655}")
        case .rook: ("\u{265C}", "\u{2656}")
        case .bishop: ("\u{265D}", "\u{2657}")
        case .knight: ("\u{265E}", "\u{2658}")
        case .pawn: ("\u{265F}", "\u{2659}")
        }
    }

    /// Both colours use the solid glyph set (the outline set draws unevenly, the white king hollow):
    /// white is a light fill with a dark edge, black a dark fill with a light edge, both from Sidra's palette.
    var body: some View {
        let g = Self.glyphs(piece.kind), white = piece.color == .white
        let glyph = Text(g.solid + "\u{FE0E}").font(.system(size: size * 0.74))
        let w = max(1, size * 0.022)
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                let a = Double(i) * .pi / 4
                glyph.foregroundStyle(white ? SidraColor.ground : SidraColor.muted).offset(x: cos(a) * w, y: sin(a) * w)
            }
            glyph.foregroundStyle(white ? SidraColor.textBright : Color(hex: 0x15181d))
        }
        .shadow(color: .black.opacity(0.35), radius: 0, y: 1.5)
        .accessibilityHidden(true)
    }
}

// MARK: - Side column

struct SideColumn: View {
    @Bindable var store: ChessStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProcessIcon(.chess, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Engine").font(SidraFont.ui(13.5, weight: .bold)).foregroundStyle(SidraColor.text)
                    Text("\(store.gameLevel.name) \(store.gameLevel.elo)").font(SidraFont.ui(12)).foregroundStyle(SidraColor.muted)
                }
                Spacer(minLength: 4)
                status
                IconButton("sidebar.right", label: "Hide the side panel", size: 26) { store.sideCollapsed = true }
            }
            FlowChips(items: chips)
            if store.thinking { GradientProgress(0.35).frame(height: 3).modifier(Indeterminate()) }
            MoveList(store: store)
            HStack(spacing: 10) {
                Text(store.userWhite ? "W" : "B").font(SidraFont.ui(13, weight: .bold)).foregroundStyle(SidraColor.Process.glyph)
                    .frame(width: 28, height: 28).background(SidraColor.jade, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("You").font(SidraFont.ui(13.5, weight: .bold)).foregroundStyle(SidraColor.text)
                Text(store.userWhite ? "white" : "black").font(SidraFont.ui(12)).foregroundStyle(SidraColor.muted)
            }
            HStack(spacing: 6) {
                Button { store.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.sidraDark).disabled(!store.canUndo).opacity(store.canUndo ? 1 : 0.45)
                Button { store.flipped.toggle() } label: { Label("Flip", systemImage: "arrow.up.arrow.down") }
                    .buttonStyle(.sidraDark)
                Button("Resign") { store.resign() }
                    .buttonStyle(.sidraDark).disabled(!store.inPlay || store.lans.isEmpty).opacity(store.inPlay && !store.lans.isEmpty ? 1 : 0.45)
            }
            .labelStyle(CompactLabel())
            Button { store.newRound() } label: { Text("New round").frame(maxWidth: .infinity) }
                .buttonStyle(.sidraPrimary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var status: some View {
        let text = !store.inPlay ? "round over" : store.thinking ? "thinking…" : "your move"
        return Text(text).font(SidraFont.mono(12, weight: .semibold))
            .foregroundStyle(store.thinking ? SidraColor.muted : store.inPlay ? SidraColor.jade : SidraColor.dim)
            .accessibilityIdentifier("chess.status")
    }

    private var chips: [Chip] {
        let points = { (halves: Int) in "\(halves / 2)" + (halves % 2 == 1 ? "½" : "") }   // a draw is half a point each
        var c = [Chip(lead: "Round", value: "\(store.roundNumber)"),
                 Chip(lead: "You", value: "\(points(2 * store.wins + store.draws)) – \(points(2 * store.losses + store.draws))", trail: "engine")]
        if let o = store.opening { c.append(Chip(lead: nil, value: nil, trail: o.name)) }
        return c
    }
}

struct Chip: Hashable { var lead: String?; var value: String?; var trail: String? = nil }

/// Chips that wrap onto the next line in a narrow column.
struct FlowChips: View {
    let items: [Chip]
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { c in
                HStack(spacing: 5) {
                    if let l = c.lead { Text(l).foregroundStyle(SidraColor.muted) }
                    if let v = c.value { Text(v).font(SidraFont.ui(12, weight: .bold)).foregroundStyle(SidraColor.text) }
                    if let t = c.trail { Text(t).foregroundStyle(SidraColor.muted).lineLimit(1) }
                }
                .font(SidraFont.ui(12))
                .padding(.horizontal, 9).frame(height: 26)
                .background(SidraColor.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(SidraColor.hairline))
            }
        }
    }
}

struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.icon.font(.system(size: 11, weight: .bold)); configuration.title }
    }
}

/// Slides the progress bar back and forth while the engine thinks.
struct Indeterminate: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content.offset(x: on ? 120 : -60).clipped()
            .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { on = true } }
    }
}

struct MoveList: View {
    let store: ChessStore
    var body: some View {
        let sans = store.sans
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<(sans.count + 1) / 2, id: \.self) { i in
                        HStack(spacing: 0) {
                            Text("\(i + 1).").foregroundStyle(SidraColor.dim).frame(width: 34, alignment: .leading)
                            cell(2 * i, sans).frame(maxWidth: .infinity, alignment: .leading)
                            cell(2 * i + 1, sans).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 22)
                        .id(i)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .onChange(of: sans.count) { _, n in withAnimation { proxy.scrollTo(max(0, (n - 1) / 2), anchor: .bottom) } }
        }
        .font(SidraFont.mono(13))
        .foregroundStyle(SidraColor.text)
        .frame(maxHeight: .infinity)
        .background(SidraColor.ground2, in: RoundedRectangle(cornerRadius: SidraRadius.popup, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SidraRadius.popup, style: .continuous).strokeBorder(SidraColor.hairline))
        .overlay { if sans.isEmpty { Text("No moves yet").font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.dim) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Moves: " + sans.joined(separator: " "))
        .accessibilityIdentifier("chess.moves")
    }

    @ViewBuilder private func cell(_ i: Int, _ sans: [String]) -> some View {
        if i < sans.count {
            let current = i == sans.count - 1
            Text(sans[i])
                .foregroundStyle(current ? SidraColor.Process.glyph : SidraColor.text)
                .padding(.horizontal, current ? 4 : 0)
                .background(current ? SidraColor.gold : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
    }
}

// MARK: - Round card

struct RoundCard: View {
    @Bindable var store: ChessStore

    var body: some View {
        ZStack {
            SidraColor.ground.opacity(0.6).ignoresSafeArea()
            // Scrolls in a short pane, so the level choices and Start stay reachable.
            ViewThatFits(in: .vertical) {
                card
                ScrollView { card }.scrollBounceBehavior(.basedOnSize)
                    .background(SidraColor.raised, in: RoundedRectangle(cornerRadius: SidraRadius.sheet, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: SidraRadius.sheet, style: .continuous))
            }
            .frame(maxWidth: 560)
            .overlay(RoundedRectangle(cornerRadius: SidraRadius.sheet, style: .continuous).strokeBorder(SidraGradient.horizontal, lineWidth: 1))
            .padding(16)
        }
    }

    private var card: some View {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    ProcessIcon(.chess, size: 24)
                    Text("Round \(store.roundNumber)").font(SidraFont.ui(18, weight: .bold)).foregroundStyle(SidraColor.text)
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach(Array(store.rounds.suffix(8).enumerated()), id: \.offset) { _, r in
                            Text(r.result.rawValue).font(SidraFont.mono(11, weight: .bold)).foregroundStyle(SidraColor.Process.glyph)
                                .frame(width: 22, height: 22)
                                .background(r.result == .win ? SidraColor.jade : r.result == .loss ? SidraColor.red : SidraColor.muted,
                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .accessibilityLabel(r.result == .win ? "won" : r.result == .loss ? "lost" : "draw")
                        }
                    }
                }
                if let o = store.outcome {
                    Text(o).font(SidraFont.ui(14, weight: .bold))
                        .foregroundStyle(store.rounds.last?.result == .win ? SidraColor.jade : store.rounds.last?.result == .loss ? SidraColor.red : SidraColor.text)
                        .accessibilityIdentifier("chess.outcome")
                }
                heading("How strong should the engine play?")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], spacing: 6) {
                    ForEach(ChessLevel.allCases) { l in
                        ChoiceChip(title: l.name, detail: "\(l.elo)", on: store.level == l) { store.level = l }
                    }
                }
                Text(store.suggestion).font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted)
                heading("You play")
                HStack(spacing: 6) {
                    ForEach(ChessStore.Side.allCases, id: \.self) { s in
                        ChoiceChip(title: s.rawValue, detail: nil, on: store.side == s) { store.side = s }
                    }
                }
                HStack(spacing: 8) {
                    Spacer()
                    if store.outcome != nil && !store.lans.isEmpty {
                        Button("Review last round") { store.cardShown = false }.buttonStyle(.sidraDark)
                    }
                    Button("Start round \(store.roundNumber)") { store.start() }.buttonStyle(.sidraPrimary)
                }
            }
            .padding(22)
            .background(SidraColor.raised, in: RoundedRectangle(cornerRadius: SidraRadius.sheet, style: .continuous))
    }

    private func heading(_ s: String) -> some View {
        Text(s.uppercased()).font(SidraFont.ui(11, weight: .bold)).tracking(0.7).foregroundStyle(SidraColor.muted)
    }
}

/// A level or colour chip; the picked one gets the gradient border (selection).
struct ChoiceChip: View {
    let title: String
    let detail: String?
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title).font(SidraFont.ui(13, weight: .bold)).lineLimit(1).foregroundStyle(SidraColor.text)
                if let detail { Text(detail).font(SidraFont.ui(13)).foregroundStyle(SidraColor.muted) }
            }
            .padding(.horizontal, 12).frame(minWidth: 0, maxWidth: detail == nil ? nil : .infinity, alignment: .leading).frame(height: 34)
            .background(on ? SidraColor.tabActive : SidraColor.raised, in: RoundedRectangle(cornerRadius: SidraRadius.pill, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SidraRadius.pill, style: .continuous)
                    .strokeBorder(on ? AnyShapeStyle(SidraGradient.horizontal) : AnyShapeStyle(SidraColor.hairline), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(detail.map { "\(title) \($0)" } ?? title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Promotion

struct PromotionPicker: View {
    let store: ChessStore
    var body: some View {
        ZStack {
            SidraColor.ground.opacity(0.5).ignoresSafeArea().onTapGesture { store.promotion = nil }
            VStack(spacing: 12) {
                Text("Promote to").font(SidraFont.ui(13, weight: .bold)).foregroundStyle(SidraColor.text)
                HStack(spacing: 8) {
                    ForEach([Piece.Kind.queen, .rook, .bishop, .knight], id: \.self) { k in
                        Button { store.promote(to: k) } label: {
                            PieceGlyph(piece: Piece(k, color: store.userWhite ? .white : .black, square: .a1), size: 64)
                                .frame(width: 64, height: 64)
                                .background(SidraColor.Board.light, in: RoundedRectangle(cornerRadius: SidraRadius.popup, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(SquareView.name(k))
                    }
                }
            }
            .padding(18)
            .background(SidraColor.popup, in: RoundedRectangle(cornerRadius: SidraRadius.sheet, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: SidraRadius.sheet, style: .continuous).strokeBorder(SidraColor.hairline2))
        }
    }
}

private extension String {
    subscript(i: Int) -> String { String(self[index(startIndex, offsetBy: i)]) }
}
