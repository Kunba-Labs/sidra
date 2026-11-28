import SwiftUI
import SidraDesign
import SidraWorkspace

/// The voice orb (design/html/15-voice-orb.html, Waseem 2026-11-28: "a floating orb with questions hanging out of
/// the orb, more bubbly, reflect my voice as a synth animation"). One body and seven lobes that melt into it:
/// each lobe follows one band of whoever speaks. A loud band throws off droplets. Flat Sidra gradient, no glow.
struct VoiceOrb: View {
    var size: CGFloat
    var bands: [Double]
    var muted = false
    var thinking = false

    /// What one frame carries to the next. A class, so drawing can update it.
    private final class Sim {
        var smooth = [Double](repeating: 0, count: 7)
        var drops: [(angle: Double, distance: Double, radius: Double, speed: Double, life: Double)] = []
    }
    @State private var sim = Sim()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { timeline in
            Canvas { g, canvas in draw(&g, canvas, timeline.date.timeIntervalSinceReferenceDate) }
        }
        .frame(width: size * 2.3, height: size * 2.3)
        .accessibilityHidden(true)
    }

    private func draw(_ g: inout GraphicsContext, _ canvas: CGSize, _ t: Double) {
        let c = Double(canvas.width) / 2, S = Double(size), R = S * 0.31
        for i in 0..<7 {
            // Waiting on an answer: the lobes turn over slowly without a voice.
            let target = muted ? 0 : max(i < bands.count ? bands[i] : 0, thinking ? 0.22 + 0.16 * sin(t * 3.4 + Double(i) * 1.3) : 0)
            sim.smooth[i] += (target - sim.smooth[i]) * (target > sim.smooth[i] ? 0.45 : 0.12)
        }
        let level = sim.smooth.reduce(0, +) / 7
        var balls: [(x: Double, y: Double, r: Double)] = [(0, 0, R * (1 + level * 0.22 + 0.03 * sin(t * 1.7)))]
        for i in 0..<7 {
            let k = Double(i), v = sim.smooth[i]
            let a = k / 7 * 2 * .pi + t * (0.35 + 0.07 * k) * (i % 2 == 1 ? 1 : -1) + sin(t * 0.9 + k) * 0.5
            let d = R * (0.42 + 0.95 * v + 0.10 * sin(t * 2.3 + k * 1.9)), r = R * (0.30 + 0.42 * v + 0.04 * sin(t * 3.1 + k))
            balls.append((cos(a) * d, sin(a) * d, r))
            if v > 0.62, sim.drops.count < 14, Double.random(in: 0..<1) < 0.10 {
                sim.drops.append((a, d + r * 0.6, R * Double.random(in: 0.07...0.14), R * Double.random(in: 0.9...1.9), 1))
            }
        }
        func field(_ x: Double, _ y: Double) -> Double {
            var f = 0.0
            for b in balls { let dx = x - b.x, dy = y - b.y; f += b.r * b.r / (dx * dx + dy * dy + 1e-6) }
            return f
        }
        // The outline: along each ray from the centre, the farthest point still inside the melted shape.
        let steps = 132
        let pts: [CGPoint] = (0..<steps).map { k in
            let th = Double(k) / Double(steps) * 2 * .pi, ux = cos(th), uy = sin(th)
            var lo = R * 0.3, hi = S * 1.1
            for _ in 0..<13 { let mid = (lo + hi) / 2; if field(ux * mid, uy * mid) > 1 { lo = mid } else { hi = mid } }
            return CGPoint(x: c + ux * lo, y: c + uy * lo)
        }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        var path = Path()
        path.move(to: mid(pts[0], pts[1]))
        for k in 0..<steps { let q = pts[(k + 1) % steps]; path.addQuadCurve(to: mid(q, pts[(k + 2) % steps]), control: q) }
        path.closeSubpath()
        let fill: GraphicsContext.Shading = muted ? .color(Color(hex: 0x3a414c))
            : .linearGradient(Gradient(stops: SidraGradient.stops), startPoint: CGPoint(x: c - S * 0.9, y: c), endPoint: CGPoint(x: c + S * 0.9, y: c))
        g.fill(path, with: fill)
        for i in sim.drops.indices.reversed() {
            sim.drops[i].distance += sim.drops[i].speed * 0.016
            sim.drops[i].life -= 0.022
            let p = sim.drops[i]
            if p.life <= 0 { sim.drops.remove(at: i); continue }
            let r = p.radius * p.life
            g.fill(Path(ellipseIn: CGRect(x: c + cos(p.angle) * p.distance - r, y: c + sin(p.angle) * p.distance - r, width: r * 2, height: r * 2)), with: fill)
        }
    }
}

extension AssistantCard {
    /// Lists and findings need the screen: they come up as a sheet. The rest hangs out of the orb.
    var isPopup: Bool {
        switch self {
        case .choice, .question, .turn: false
        default: true
        }
    }
}

/// A bubble's surface: a solid raised shape, or glass on Apple Vision Pro.
private struct BubbleSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    func body(content: Content) -> some View {
        #if os(visionOS)
        content.glassBackgroundEffect(in: shape)
        #else
        content.background(SidraColor.raised, in: shape).overlay(shape.strokeBorder(SidraColor.hairline2)).shadow(color: .black.opacity(0.4), radius: 12, y: 8)
        #endif
    }
}
private extension View {
    func bubble(_ radius: CGFloat = 22) -> some View { modifier(BubbleSurface(shape: RoundedRectangle(cornerRadius: radius, style: .continuous))) }
    func pill() -> some View { modifier(BubbleSurface(shape: Capsule())) }
}

/// The orb over the workspace, and the talk that hangs out of it.
struct OrbLayer: View {
    @Environment(AppModel.self) private var app
    @State private var a = Assistant.shared
    private var orbSize: CGFloat { Platform.isPhone ? 84 : 104 }

    var body: some View {
        if a.phase != .off {
            VStack(alignment: .trailing, spacing: 8) {
                bubbles
                HStack(spacing: 8) {
                    round("character.cursor.ibeam", "Text view") { a.showThread = true }.accessibilityIdentifier("assistant-text")
                    round("xmark", "End the voice session") { a.stop() }.accessibilityIdentifier("assistant-end")
                    orb
                }
            }
            .frame(maxWidth: Platform.isPhone ? 330 : 430, alignment: .trailing)
            .padding(.trailing, 6).padding(.bottom, Platform.isPhone ? 58 : 18)
            .animation(.spring(response: 0.38, dampingFraction: 0.7), value: a.said)
            .animation(.spring(response: 0.38, dampingFraction: 0.7), value: a.card)
            .transition(.scale(scale: 0.4, anchor: .bottomTrailing).combined(with: .opacity))
        }
    }

    /// A tap mutes or opens the microphone. Touch and hold for the modes and the end.
    private var orb: some View {
        Color.clear.frame(width: orbSize * 1.25, height: orbSize * 1.25)
            .overlay { VoiceOrb(size: orbSize, bands: a.bands, muted: a.voiceOn && !a.listening, thinking: a.thinking || a.phase == .connecting).allowsHitTesting(false) }
            .contentShape(Circle())
            .onTapGesture { a.toggleMic() }
            .contextMenu {
                Button("Plan mode", systemImage: a.mode == .plan ? "checkmark" : "list.bullet") { a.setMode(.plan) }
                Button("Code mode", systemImage: a.mode == .code ? "checkmark" : "chevron.left.forwardslash.chevron.right") { a.setMode(.code) }
                Button("Text view", systemImage: "character.cursor.ibeam") { a.showThread = true }
                Divider()
                Button("End the session", systemImage: "xmark") { a.stop() }
                Button("End and forget", systemImage: "trash", role: .destructive) { a.stop(forget: true) }
            }
            .accessibilityElement()
            .accessibilityLabel(a.listening ? "Voice orb, listening. Activate to mute." : "Voice orb, muted. Activate to listen.")
            .accessibilityAddTraits(.isButton).accessibilityIdentifier("assistant-orb")
    }

    private func round(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(SidraColor.muted).frame(width: 40, height: 40)
        }
        .buttonStyle(.plain).pill().accessibilityLabel(label)
    }

    // MARK: Bubbles

    @ViewBuilder private var bubbles: some View {
        switch a.phase {
        case .off: EmptyView()
        case .connecting: line("Connecting…")
        case .failed(let message):
            line(message)
            HStack(spacing: 8) {
                chip("Settings") { a.stop(); app.sheet = .settings }
                chip("Close") { a.stop() }
            }
        case .ready:
            switch a.card {
            case .choice(let question, let options, let recommended):
                line(a.said.isEmpty ? question : a.said)
                ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                    option(i + 1, o.title, recommended: recommended == i + 1) { a.send("Option \(i + 1): \(o.title)") }.padding(.trailing, CGFloat(i) * 14)
                }
            case .question(let space, let question, let options):
                VStack(alignment: .leading, spacing: 5) {
                    Label("The agent in \(space) waits for you", systemImage: "exclamationmark.triangle.fill").font(SidraFont.ui(12.5, weight: .semibold)).foregroundStyle(SidraColor.gold)
                    Text(question).font(SidraFont.ui(17, weight: .bold)).foregroundStyle(SidraColor.textBright).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 15).padding(.vertical, 12).bubble()
                ForEach(Array(options.enumerated()), id: \.offset) { i, o in option(i + 1, o, recommended: false) { a.send(o) }.padding(.trailing, CGFloat(i) * 14) }
            case .turn(let space, let summary, let verdict, let hint):
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Circle().fill(verdict == "broken" ? SidraColor.red : verdict == "watch" ? SidraColor.yellow : SidraColor.jade).frame(width: 8, height: 8)
                        Text(space + " · " + (verdict == "broken" ? "Broken" : verdict == "watch" ? "Check this" : "Clean")).font(SidraFont.ui(12.5, weight: .semibold)).foregroundStyle(SidraColor.muted)
                    }
                    Text(summary).font(SidraFont.ui(16, weight: .semibold)).foregroundStyle(SidraColor.textBright).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 15).padding(.vertical, 12).bubble()
                if let hint {
                    (Text("Did you know? ").font(SidraFont.ui(14.5, weight: .bold)).foregroundStyle(SidraColor.gold) + Text(hint).font(SidraFont.ui(14.5, weight: .medium)).foregroundStyle(SidraColor.text))
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 15).padding(.vertical, 11).bubble().padding(.trailing, 16)
                    chip("Tell the agent") { a.send("Tell the agent: \(hint)") }.padding(.trailing, 30)
                }
            default:
                if !a.said.isEmpty { line(a.said) }
            }
            tail
            heard
        }
    }

    private func line(_ text: String) -> some View {
        Text(text).font(SidraFont.ui(18, weight: .bold)).foregroundStyle(SidraColor.textBright).lineLimit(5).minimumScaleFactor(0.8)
            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 15).padding(.vertical, 12).bubble(24)
            .transition(.scale(scale: 0.3, anchor: .bottomTrailing).combined(with: .opacity))
            .id(text).accessibilityIdentifier("assistant-said")
    }

    private func option(_ n: Int, _ title: String, recommended: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text("\(n)").font(SidraFont.ui(12.5, weight: .bold)).foregroundStyle(SidraColor.muted).frame(width: 26, height: 26).background(Color(hex: 0x232a33), in: Circle())
                Text(title).font(SidraFont.ui(14.5, weight: .semibold)).foregroundStyle(SidraColor.text).lineLimit(2).multilineTextAlignment(.leading)
                if recommended {
                    Text("Recommended").font(SidraFont.ui(10, weight: .bold)).foregroundStyle(Color(hex: 0x06140e))
                        .padding(.horizontal, 7).padding(.vertical, 2).background(SidraColor.jade, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.leading, 9).padding(.trailing, 14).padding(.vertical, 9)
        }
        .buttonStyle(.plain).pill()
        .overlay { if recommended { Capsule().strokeBorder(SidraGradient.horizontal, lineWidth: 1.5) } }
        .accessibilityIdentifier("assistant-option-\(n)")
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(SidraFont.ui(14, weight: .semibold)).foregroundStyle(SidraColor.text).padding(.horizontal, 16).padding(.vertical, 10) }
            .buttonStyle(.plain).pill()
    }

    /// Two small bubbles that lead from the talk down to the orb.
    private var tail: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Circle().frame(width: 10, height: 10)
            Circle().frame(width: 6, height: 6).padding(.trailing, 10)
        }
        .foregroundStyle(SidraColor.raised).padding(.trailing, 26).accessibilityHidden(true)
    }

    private var heard: some View {
        let muted = a.voiceOn && !a.listening
        let text = !a.voiceOn ? "Voice is off. Tap Aa to type." : muted ? "Muted. Tap the orb." : a.heard.isEmpty ? (a.thinking ? "Working" : "Listening") : a.heard.trimmingCharacters(in: .whitespaces)
        return HStack(spacing: 8) {
            Circle().fill(a.listening ? SidraColor.jade : SidraColor.dim).frame(width: 7, height: 7)
            Text(text).font(SidraFont.ui(13.5, weight: .medium)).foregroundStyle(Color(hex: 0xaab2bd)).lineLimit(2)
        }
        .padding(.horizontal, 13).padding(.vertical, 8).pill()
    }
}

/// The text view: the same session as a thread, with typed input, the plan and the mode.
struct AssistantThread: View {
    @State private var a = Assistant.shared
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    ForEach(AssistantMode.allCases, id: \.self) { m in
                        Button { a.setMode(m) } label: {
                            Text(m == .plan ? "Plan" : "Code").font(SidraFont.ui(13, weight: .semibold)).foregroundStyle(a.mode == m ? SidraColor.text : SidraColor.muted)
                                .padding(.horizontal, 13).frame(height: 28)
                                .background(a.mode == m ? Color(hex: 0x1d222a) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .gradientBorder(radius: 8, active: a.mode == m, inactive: .clear)
                        }
                        .buttonStyle(.plain).accessibilityIdentifier("assistant-mode-\(m.rawValue)")
                    }
                }
                .padding(3).background(SidraColor.panel, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(SidraColor.hairline))
                Spacer()
                Button("Forget") { a.stop(forget: true); a.showThread = false }.buttonStyle(.sidraSecondary)
                Button("Done") { a.showThread = false }.buttonStyle(.sidraSecondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !a.plan.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                CardLabel("Plan so far")
                                ForEach(Array(a.plan.enumerated()), id: \.offset) { _, l in
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(l.text).font(SidraFont.ui(14)).foregroundStyle(SidraColor.text)
                                        Text(l.label).font(SidraFont.ui(11.5)).foregroundStyle(SidraColor.dim)
                                    }
                                }
                            }
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading).background(SidraColor.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(SidraColor.hairline))
                        }
                        ForEach(a.thread) { item in
                            switch item.body {
                            case .user(let t):
                                Text(t).font(SidraFont.ui(15, weight: .medium)).foregroundStyle(SidraColor.text).padding(.horizontal, 14).padding(.vertical, 10)
                                    .background(SidraColor.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(SidraColor.hairline))
                                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.leading, 50)
                            case .assistant(let t):
                                Text((try? AttributedString(markdown: t, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(t))
                                    .font(SidraFont.ui(15, weight: .medium)).foregroundStyle(SidraColor.text).textSelection(.enabled)
                            case .card(let c):
                                AssistantCardView(card: c).padding(14).background(SidraColor.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(SidraColor.hairline))
                            }
                        }
                        if a.thinking { GradientSpinner(size: 14) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 16).padding(.top, 4)
                }
                .onChange(of: a.thread.count, initial: true) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            }
            .accessibilityIdentifier("assistant-thread")
            HStack(spacing: 10) {
                TextField(a.mode == .plan ? "Message Sidra" : "Tell the agent", text: $draft, axis: .vertical).lineLimit(1...4)
                    .font(SidraFont.ui(15)).foregroundStyle(SidraColor.text).padding(.horizontal, 14).padding(.vertical, 11)
                    .background(SidraColor.panel, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(SidraColor.hairline))
                    .onSubmit(sendDraft).accessibilityIdentifier("assistant-field")
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold)).foregroundStyle(Color(hex: 0x06140e))
                        .frame(width: 40, height: 40).background(SidraColor.jade, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain).accessibilityLabel("Send").accessibilityIdentifier("assistant-send")
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || a.phase != .ready)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .background(SidraColor.ground.ignoresSafeArea())
    }

    private func sendDraft() { a.send(draft); draft = "" }
}

extension View {
    /// The assistant over a window: the orb with its bubbles, the popup for a tool that needs the screen,
    /// and the text view.
    func assistantLayer(app: AppModel) -> some View {
        let a = Assistant.shared
        return overlay(alignment: .bottomTrailing) { OrbLayer().environment(app) }
            .sheet(isPresented: Binding(get: { a.card?.isPopup == true && !a.showThread }, set: { if !$0 { a.dismissCard() } })) {
                ScrollView { if let card = a.card { AssistantCardView(card: card).padding(18) } }
                    .environment(app)
                    .presentationDetents([.medium, .large]).presentationDragIndicator(.visible).presentationBackground(SidraColor.panel)
                    .frame(minWidth: 380, minHeight: 320)
            }
            .sheet(isPresented: Binding(get: { a.showThread }, set: { a.showThread = $0 })) {
                AssistantThread().environment(app).presentationBackground(SidraColor.ground).frame(minWidth: 420, minHeight: 560)
            }
            .onAppear {
                #if DEBUG
                if let d = UserDefaults.standard.string(forKey: "sidra.assistantDemo") { a.demo(d) }
                #endif
            }
    }
}
