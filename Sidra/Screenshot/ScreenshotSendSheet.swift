#if os(iOS)
import SwiftUI
import UIKit
import SidraDesign
import SidraWorkspace
import SidraTerminal

/// Send screenshot (mockup https://claude.ai/artifact/NjHS595W53VDXSMWX2SPDP, 2026-11-19): the sessions on
/// the left with the one you were in picked, the screenshot on the right. Draw around the part that
/// matters; Send pastes that cut-out (outside the shape transparent) into the session as an image.
struct ScreenshotSendSheet: View {
    let image: UIImage
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// Built from herdr's live snapshots, so agents appear once a just-started Sidra has read them.
    private var targets: [ScreenshotTarget] { ScreenshotTarget.all(app) }
    /// Your pick; until then the session you were in.
    @State private var chosen: String?
    private var picked: String? {
        get { chosen.flatMap { c in targets.contains { $0.id == c } ? c : nil } ?? ScreenshotTarget.current(app, in: targets) }
        nonmutating set { chosen = newValue }
    }
    /// The shape, in the image's pixels. Empty: the whole screenshot.
    @State private var shape: [CGPoint] = []
    @State private var drawing: [CGPoint]?
    @State private var history: [[CGPoint]] = []
    @State private var preview: UIImage?
    /// 1 = the whole screenshot fits; pinch, −/+ or ⌘+/⌘− zoom up to 8×. `pan` moves the zoomed image.
    @State private var zoom: CGFloat = 1
    @State private var zoomAtPinch: CGFloat?
    @State private var pan: CGSize = .zero
    @State private var panAtDrag: CGSize?
    @State private var moving = false

    private var pixels: CGSize { image.cgImage.map { CGSize(width: $0.width, height: $0.height) } ?? image.size }
    private var target: ScreenshotTarget? { targets.first { $0.id == picked } }

    /// A card over 96% of the screen (Waseem, 2026-11-19), shown as a full-screen cover since a sheet
    /// cannot be sized that freely.
    var body: some View {
        GeometryReader { geo in
            card
                .frame(width: geo.size.width * 0.96, height: geo.size.height * 0.96)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(SidraColor.hairline2))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black.opacity(0.5).ignoresSafeArea())
        .presentationBackground(.clear)
    }

    private var card: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Send screenshot").font(SidraFont.ui(15, weight: .bold)).foregroundStyle(SidraColor.text)
                Text(verbatim: "\(Int(pixels.width)) × \(Int(pixels.height))").font(SidraFont.mono(12)).foregroundStyle(SidraColor.muted)
                Spacer()
                IconButton("xmark", label: "Cancel") { dismiss() }
            }
            .padding(.horizontal, 18).frame(height: 50)
            Divider().overlay(SidraColor.hairline)
            HStack(spacing: 0) {
                list.frame(width: 260)
                Rectangle().fill(SidraColor.hairline).frame(width: 1)
                VStack(spacing: 0) {
                    tools
                    Divider().overlay(SidraColor.hairline)
                    canvas.padding(16)
                }
            }
            Divider().overlay(SidraColor.hairline)
            footer
        }
        .background(SidraColor.raised)
        .onAppear { updatePreview() }
        .background { keys }
        .onReceive(NotificationCenter.default.publisher(for: .sidraScreenshotZoom)) { note in
            switch note.object as? String { case "0": setZoom(1); case "-": setZoom(zoom / 1.5); case "=": setZoom(zoom * 1.5); default: break }
        }
    }

    // MARK: Sessions

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                let current = picked
                ForEach(groups, id: \.name) { g in
                    Text(g.name.uppercased()).font(SidraFont.ui(10.5, weight: .semibold)).tracking(0.8).foregroundStyle(SidraColor.dim)
                        .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 4)
                    ForEach(g.items) { row($0, on: $0.id == current) }
                }
                if targets.isEmpty {
                    Text("No terminal or herdr tab is open. Open one, then send the screenshot again.")
                        .font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted).padding(12)
                }
            }
            .padding(8)
        }
    }

    private var groups: [(name: String, items: [ScreenshotTarget])] {
        var out: [(name: String, items: [ScreenshotTarget])] = []
        for t in targets {
            if let i = out.firstIndex(where: { $0.name == t.group }) { out[i].items.append(t) } else { out.append((t.group, [t])) }
        }
        return out
    }

    private func row(_ t: ScreenshotTarget, on: Bool) -> some View {
        Button { picked = t.id } label: {
            HStack(spacing: 9) {
                t.icon.frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title).font(SidraFont.ui(13, weight: on ? .bold : .medium)).foregroundStyle(on ? SidraColor.text : SidraColor.muted).lineLimit(1)
                    Text(t.detail).font(SidraFont.ui(11.5)).foregroundStyle(SidraColor.dim).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let s = t.status, s != .unknown { HerdrStatusIcon(status: s, size: 9) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            // Picked: the gradient underline the herdr space chips use, no fill (Waseem, 2026-11-19).
            .overlay(alignment: .bottom) {
                if on { UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2).fill(SidraGradient.horizontal).frame(height: 2).padding(.horizontal, 10) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(t.title), \(t.detail)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Drawing

    private var tools: some View {
        HStack(spacing: 8) {
            toolToggle("Draw", "pencil.and.outline", on: !moving) { moving = false }
            toolToggle("Move", "hand.draw", on: moving) { moving = true }
            Rectangle().fill(SidraColor.hairline2).frame(width: 1, height: 20).padding(.horizontal, 4)
            IconButton("minus.magnifyingglass", label: "Zoom out") { setZoom(zoom / 1.5) }
            Text(verbatim: "\(Int((zoom * 100).rounded()))%").font(SidraFont.mono(12)).foregroundStyle(SidraColor.muted).frame(minWidth: 44)
            IconButton("plus.magnifyingglass", label: "Zoom in") { setZoom(zoom * 1.5) }
            Button("Fit") { setZoom(1) }.buttonStyle(.sidraSecondary).disabled(zoom == 1 && pan == .zero)
            Spacer()
            Button("Undo") { shape = history.popLast() ?? []; updatePreview() }
                .buttonStyle(.sidraSecondary).disabled(shape.isEmpty)
            Button("Whole screenshot") { if !shape.isEmpty { history.append(shape) }; shape = []; updatePreview() }
                .buttonStyle(.sidraSecondary).disabled(shape.isEmpty)
        }
        .padding(.horizontal, 14).frame(height: 48)
    }

    private func toolToggle(_ title: String, _ icon: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(SidraFont.ui(12.5, weight: on ? .bold : .regular))
                .foregroundStyle(on ? SidraColor.text : SidraColor.muted)
                .padding(.horizontal, 10).frame(height: 30)
                .overlay(alignment: .bottom) {
                    if on { UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2).fill(SidraGradient.horizontal).frame(height: 2).padding(.horizontal, 8) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func setZoom(_ z: CGFloat) {
        withAnimation(.easeOut(duration: 0.15)) {
            zoom = min(8, max(1, z))
            if zoom == 1 { pan = .zero }
        }
    }

    private var canvas: some View {
        GeometryReader { geo in
            let fit = shown(fitted(in: geo.size), in: geo.size)
            let toView = { (p: CGPoint) in CGPoint(x: fit.minX + p.x / pixels.width * fit.width, y: fit.minY + p.y / pixels.height * fit.height) }
            let toImage = { (p: CGPoint) in CGPoint(x: min(max(0, (p.x - fit.minX) / fit.width * pixels.width), pixels.width),
                                                    y: min(max(0, (p.y - fit.minY) / fit.height * pixels.height), pixels.height)) }
            ZStack {
                Image(uiImage: image).resizable().frame(width: fit.width, height: fit.height).position(x: fit.midX, y: fit.midY)
                Canvas { ctx, _ in
                    let pts = (drawing ?? shape).map(toView)
                    guard pts.count > 2 else { return }
                    var outline = Path(); outline.addLines(pts); outline.closeSubpath()
                    if drawing == nil {   // outside the shape dims once it is closed
                        var dim = Path(CGRect(origin: .zero, size: geo.size)); dim.addPath(outline)
                        ctx.fill(dim, with: .color(SidraColor.ground.opacity(0.62)), style: FillStyle(eoFill: true))
                    }
                    ctx.stroke(outline, with: .linearGradient(Gradient(stops: SidraGradient.stops), startPoint: CGPoint(x: fit.minX, y: 0), endPoint: CGPoint(x: fit.maxX, y: 0)),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                if moving || zoomAtPinch != nil {   // Move pans; a pinch in progress draws nothing
                    if moving { if panAtDrag == nil { panAtDrag = pan }; pan = clamped((panAtDrag ?? .zero) + v.translation, geo.size) }
                    return
                }
                let p = toImage(v.location)
                if drawing == nil { drawing = [p] }
                else if let last = drawing?.last, hypot(p.x - last.x, p.y - last.y) > pixels.width / 400 / zoom { drawing?.append(p) }
            }.onEnded { _ in
                panAtDrag = nil
                if let d = drawing, d.count > 3 { history.append(shape); shape = d; updatePreview() }
                drawing = nil
            })
            .simultaneousGesture(MagnifyGesture().onChanged { v in
                if zoomAtPinch == nil { zoomAtPinch = zoom; drawing = nil }
                zoom = min(8, max(1, (zoomAtPinch ?? 1) * v.magnification))
                pan = clamped(pan, geo.size)
            }.onEnded { _ in
                zoomAtPinch = nil
                if zoom == 1 { withAnimation(.easeOut(duration: 0.15)) { pan = .zero } }
            })
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityLabel("Screenshot. Draw around the part to send.")
    }

    /// The fitted rect zoomed about the middle, then moved by `pan`.
    private func shown(_ fit: CGRect, in size: CGSize) -> CGRect {
        let w = fit.width * zoom, h = fit.height * zoom
        return CGRect(x: (size.width - w) / 2 + pan.width, y: (size.height - h) / 2 + pan.height, width: w, height: h)
    }

    /// Panning stops where the zoomed image's edge meets the frame's.
    private func clamped(_ p: CGSize, _ size: CGSize) -> CGSize {
        let fit = fitted(in: size)
        let mx = max(0, (fit.width * zoom - size.width) / 2), my = max(0, (fit.height * zoom - size.height) / 2)
        return CGSize(width: min(mx, max(-mx, p.width)), height: min(my, max(-my, p.height)))
    }

    private func fitted(in size: CGSize) -> CGRect {
        let s = min(size.width / pixels.width, size.height / pixels.height)
        let w = pixels.width * s, h = pixels.height * s
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    // MARK: Cut and send

    private func cut() -> UIImage? { ScreenshotCut.cut(image, shape: shape) }

    private func updatePreview() { preview = cut() }

    private var footer: some View {
        HStack(spacing: 12) {
            Group {
                if let preview { Image(uiImage: preview).resizable().scaledToFit() } else { Color.clear }
            }
            .frame(width: 64, height: 44)
            .background(SidraColor.pane, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(SidraColor.hairline2))
            if let p = preview?.cgImage {
                Text(verbatim: "\(shape.isEmpty ? "Whole" : "Cut") \(p.width) × \(p.height) px").font(SidraFont.mono(12)).foregroundStyle(SidraColor.muted)
            }
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(.sidraSecondary).keyboardShortcut(.cancelAction)
            Button(target.map { "Send to \($0.title)" } ?? "Send") { send() }
                .buttonStyle(.sidraPrimary).keyboardShortcut(.defaultAction).disabled(target == nil)
        }
        .padding(.horizontal, 18).frame(height: 64)
    }

    /// ↑ and ↓ move the pick; ⌘+, ⌘− and ⌘0 zoom.
    private var keys: some View {
        Group {
            Button("") { step(-1) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("") { step(1) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("") { setZoom(zoom * 1.5) }.keyboardShortcut("=", modifiers: .command)
            Button("") { setZoom(zoom / 1.5) }.keyboardShortcut("-", modifiers: .command)
            Button("") { setZoom(1) }.keyboardShortcut("0", modifiers: .command)
        }
        .opacity(0).accessibilityHidden(true)
    }

    private func step(_ d: Int) {
        let all = targets
        guard !all.isEmpty else { return }
        let i = all.firstIndex { $0.id == picked } ?? -d
        picked = all[max(0, min(all.count - 1, i + d))].id
    }

    private func send() {
        guard let t = target, let png = cut()?.pngData() else { return }
        let store = app.workspace
        store.select(tab: t.tabID)
        store.focus(pane: t.paneID)
        dismiss()
        Task { @MainActor in
            if let pane = store.tabs.flatMap(\.panes).first(where: { $0.id == t.paneID }), let m = MuxMonitors.shared.monitor(for: pane, app: app) {
                if let agent = t.agentPane { await m.focusAgent(app, pane: agent) }
                else if let ws = t.space, let w = m.snapshot?.workspaces.first(where: { $0.id == ws }) { await m.focus(app, w) }
            }
            guard let io = TerminalLink.of(t.paneID).session, let view = TerminalPaneView.ghostty(for: io) else {
                app.toast("\(t.title) is not connected, so the screenshot was not sent")
                return
            }
            view.pasteImage(png, here: true)
        }
    }
}

enum ScreenshotCut {
    /// The box around `shape` (in the image's pixels), with everything outside the shape transparent
    /// (Waseem, 2026-11-19). Fewer than three points: the whole image.
    static func cut(_ image: UIImage, shape: [CGPoint]) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let full = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        guard shape.count > 2 else { return UIImage(cgImage: cg) }
        let path = UIBezierPath()
        path.move(to: shape[0]); shape.dropFirst().forEach(path.addLine); path.close()
        let box = path.bounds.intersection(full).integral
        guard box.width >= 2, box.height >= 2 else { return UIImage(cgImage: cg) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        return UIGraphicsImageRenderer(size: box.size, format: format).image { ctx in
            ctx.cgContext.translateBy(x: -box.minX, y: -box.minY)
            path.addClip()
            UIImage(cgImage: cg).draw(in: full)
        }
    }
}

/// Where a screenshot can go: a terminal pane, or one agent (or agentless space) inside a herdr pane.
struct ScreenshotTarget: Identifiable, Hashable {
    let id: String
    let tabID: UUID
    let paneID: UUID
    let agentPane: String?
    let space: String?
    let title: String
    let detail: String
    let status: MuxStatus?
    let group: String
    let logo: UIImage?
    let processIcon: ProcessIcon.Kind

    @ViewBuilder var icon: some View {
        if space != nil || agentPane != nil { HerdrLogoView(name: title, image: logo, size: 20) } else { ProcessIcon(processIcon, size: 20) }
    }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    /// The window's terminal and herdr panes, herdr's spaces in its bar order.
    @MainActor static func all(_ app: AppModel) -> [ScreenshotTarget] {
        var out: [ScreenshotTarget] = []
        for tab in app.workspace.tabs {
            for pane in tab.panes {
                switch pane.kind {
                case .terminal:
                    out.append(.init(id: pane.id.uuidString, tabID: tab.id, paneID: pane.id, agentPane: nil, space: nil, title: pane.title,
                                     detail: "shell" + (pane.project.map { " · \($0)" } ?? ""), status: nil, group: "Tabs", logo: nil, processIcon: tab.icon))
                case .herdr:
                    guard let m = MuxMonitors.shared.monitor(for: pane, app: app), let s = m.snapshot else { continue }
                    let group = "herdr" + (pane.project.map { " on \($0)" } ?? "")
                    for ws in s.workspaces {
                        let agents = s.agents(in: ws.id)
                        if agents.isEmpty {
                            out.append(.init(id: "\(pane.id)/\(ws.id)", tabID: tab.id, paneID: pane.id, agentPane: nil, space: ws.id, title: ws.label,
                                             detail: "shell", status: nil, group: group, logo: m.logo(for: ws), processIcon: tab.icon))
                        }
                        for a in agents {
                            let what = a.terminal_title_stripped.flatMap { $0.isEmpty ? nil : $0 } ?? HerdrStatusIcon.label(a.agent_status)
                            out.append(.init(id: "\(pane.id)/\(a.pane_id)", tabID: tab.id, paneID: pane.id, agentPane: a.pane_id, space: ws.id,
                                             title: agents.count > 1 ? "\(ws.label) · \(a.agent)" : ws.label, detail: "\(a.agent) · \(what)",
                                             status: a.agent_status, group: group, logo: m.logo(for: ws), processIcon: tab.icon))
                        }
                    }
                default: continue
                }
            }
        }
        return out
    }

    /// The session you were in: the focused pane, and in herdr its focused agent (or the first in its space).
    @MainActor static func current(_ app: AppModel, in targets: [ScreenshotTarget]) -> String? {
        guard let pane = app.workspace.focusedPane else { return targets.first?.id }
        let mine = targets.filter { $0.paneID == pane.id }
        if let s = MuxMonitors.shared.byPane[pane.id]?.snapshot {
            return (mine.first { $0.agentPane != nil && $0.agentPane == s.focused_pane_id }
                    ?? mine.first { $0.space == s.focused_workspace_id }
                    ?? mine.first ?? targets.first)?.id
        }
        return (mine.first ?? targets.first)?.id
    }
}
private func + (a: CGSize, b: CGSize) -> CGSize { CGSize(width: a.width + b.width, height: a.height + b.height) }
#endif
