import SwiftUI
import SidraDesign
import SidraWorkspace
import SidraSSH

/// The blob: a flat shape in the Sidra gradient that moves with the voice. No glow, no highlight
/// (design/html/14-voice-modes.html). The rings are thin solid lines.
struct VoiceBlob: View {
    var size: CGFloat
    var level: Double = 0
    var rings = true
    /// Waiting on the backend: the blob turns slowly and stays small.
    var thinking = false
    @State private var start = Date()

    struct Outline: Shape {
        var phase: Double, wobble: Double
        func path(in rect: CGRect) -> Path {
            let c = CGPoint(x: rect.midX, y: rect.midY), base = min(rect.width, rect.height) / 2
            var p = Path()
            for i in 0...96 {
                let a = Double(i) / 96 * 2 * .pi
                let d = 0.055 * sin(3 * a + phase) + 0.040 * sin(5 * a - phase * 1.27) + 0.028 * sin(2 * a + phase * 0.6)
                let r = base * (1 + wobble * d)
                let pt = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
            return p
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSince(start)
            let phase = t * (thinking ? 2.6 : 1.4), wobble = 0.7 + level * 1.6
            ZStack {
                if rings {
                    Outline(phase: phase * 0.7, wobble: wobble * 0.6).stroke(Color(hex: 0x6f6480), lineWidth: 1).frame(width: size * 1.54, height: size * 1.54)
                    Outline(phase: phase * 0.85, wobble: wobble * 0.8).stroke(Color(hex: 0xf2a487), lineWidth: 1.5).frame(width: size * 1.26, height: size * 1.26)
                }
                Outline(phase: phase, wobble: wobble).fill(SidraGradient.horizontal).frame(width: size, height: size)
            }
            .scaleEffect(1 + level * 0.1)
            .frame(width: size * (rings ? 1.6 : 1), height: size * (rings ? 1.6 : 1))
        }
        .accessibilityHidden(true)
    }
}

/// The assistant's screen: the blob and one line, a card when a tool needs your eyes, or the thread.
struct AssistantScreen: View {
    @Environment(AppModel.self) private var app
    @State private var a = Assistant.shared
    @State private var draft = ""
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 0) {
            top
            switch a.phase {
            case .failed(let message): failed(message)
            case .connecting, .off: Spacer(); GradientSpinner(size: 22); Text("Connecting…").font(SidraFont.ui(14)).foregroundStyle(SidraColor.muted).padding(.top, 12); Spacer()
            case .ready:
                if a.showThread || !a.voiceOn { thread; composer }
                else if let card = a.card { mini; cardSheet(card) }
                else { stage; controls }
            }
        }
        .background(SidraColor.ground.ignoresSafeArea())
        .accessibilityIdentifier("assistant-screen")
    }

    // MARK: Top

    private var top: some View {
        HStack(spacing: 8) {
            Text(a.active ? (HerdrHost(app: app).frontSpace() ?? "Sidra") : "Sidra").font(SidraFont.ui(14, weight: .semibold)).foregroundStyle(SidraColor.text).lineLimit(1)
            Spacer()
            HStack(spacing: 2) {
                ForEach(AssistantMode.allCases, id: \.self) { m in
                    Button { a.setMode(m) } label: {
                        Text(m == .plan ? "Plan" : "Code").font(SidraFont.ui(13, weight: .semibold))
                            .foregroundStyle(a.mode == m ? SidraColor.text : SidraColor.muted)
                            .padding(.horizontal, 13).frame(height: 28)
                            .background(a.mode == m ? Color(hex: 0x1d222a) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .gradientBorder(radius: 8, active: a.mode == m, inactive: .clear)
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("assistant-mode-\(m.rawValue)")
                }
            }
            .padding(3)
            .background(SidraColor.panel, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(SidraColor.hairline))
            Spacer()
            square("chevron.down", "Hide the assistant") { a.open = false }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func square(_ symbol: String, _ label: String, size: CGFloat = 34, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size * 0.4, weight: .medium)).foregroundStyle(SidraColor.muted)
                .frame(width: size, height: size)
                .background(SidraColor.raised, in: RoundedRectangle(cornerRadius: size * 0.33, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: size * 0.33, style: .continuous).strokeBorder(SidraColor.hairline))
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Text(message).font(SidraFont.ui(15)).foregroundStyle(SidraColor.text).multilineTextAlignment(.center).padding(.horizontal, 30)
            HStack(spacing: 10) {
                Button("Open Settings") { a.open = false; app.sheet = .settings }.buttonStyle(.sidraSecondary)
                Button("Close") { a.stop() }.buttonStyle(.sidraSecondary)
            }
            Spacer()
        }
    }

    // MARK: Voice

    private var stage: some View {
        VStack(spacing: 0) {
            Text(a.said.isEmpty ? " " : a.said).font(SidraFont.ui(24, weight: .bold)).foregroundStyle(SidraColor.textBright)
                .multilineTextAlignment(.center).lineLimit(4).minimumScaleFactor(0.7).padding(.top, 30).padding(.horizontal, 26)
                .accessibilityIdentifier("assistant-said")
            Spacer(minLength: 10)
            VoiceBlob(size: 200, level: a.level, thinking: a.thinking)
            Spacer(minLength: 10)
            VStack(spacing: 8) {
                HStack(spacing: 7) {
                    Circle().fill(a.holding ? SidraColor.jade : SidraColor.dim).frame(width: 7, height: 7)
                    Text(a.holding ? "LISTENING" : a.thinking ? "WORKING" : "HOLD THE MIC TO TALK").font(SidraFont.ui(11.5, weight: .semibold)).tracking(0.6)
                        .foregroundStyle(a.holding ? SidraColor.jade : SidraColor.dim)
                }
                Text(a.heard.isEmpty ? " " : "“" + a.heard.trimmingCharacters(in: .whitespaces) + "”").font(SidraFont.ui(16, weight: .medium)).foregroundStyle(Color(hex: 0xaab2bd))
                    .multilineTextAlignment(.center).lineLimit(3).padding(.horizontal, 26)
            }
            Spacer(minLength: 10)
            if !a.plan.isEmpty {
                Button { a.showThread = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "list.bullet.rectangle").font(.system(size: 13))
                        Text("Plan so far").font(SidraFont.ui(13, weight: .semibold)).foregroundStyle(SidraColor.text)
                        Text("· \(a.plan.count) lines settled").font(SidraFont.ui(13))
                    }
                    .foregroundStyle(SidraColor.muted).padding(.horizontal, 14).frame(height: 40)
                    .background(SidraColor.panel, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(SidraColor.hairline))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 26) {
            square("character.cursor.ibeam", "Text view", size: 50) { a.showThread = true }.accessibilityIdentifier("assistant-text")
            MicButton(size: 76)
            square("xmark", "End the session", size: 50) { a.stop() }.accessibilityIdentifier("assistant-end")
        }
        .padding(.top, 16).padding(.bottom, 28)
    }

    private var mini: some View {
        HStack(spacing: 22) {
            VoiceBlob(size: 52, level: a.level, thinking: a.thinking)
            Text(a.said).font(SidraFont.ui(18, weight: .bold)).foregroundStyle(SidraColor.textBright).lineLimit(3).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22).padding(.vertical, 10)
    }

    private func cardSheet(_ card: AssistantCard) -> some View {
        VStack(spacing: 0) {
            Capsule().fill(Color(hex: 0x3a414c)).frame(width: 40, height: 5).padding(.vertical, 10)
            ScrollView { AssistantCardView(card: card, underBlob: true).padding(.horizontal, 16).padding(.bottom, 12) }
            HStack(spacing: 14) {
                square("character.cursor.ibeam", "Text view", size: 44) { a.showThread = true }
                Spacer()
                MicButton(size: 56)
                Spacer()
                square("chevron.down", "Hide the card", size: 44) { a.dismissCard() }
            }
            .padding(.horizontal, 22).padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SidraColor.panel, in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24, style: .continuous))
        .overlay(UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24, style: .continuous).strokeBorder(SidraColor.hairline2))
        .padding(.horizontal, 10).padding(.top, 4)
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: Text

    private var thread: some View {
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
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(SidraColor.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(SidraColor.hairline))
                    }
                    ForEach(a.thread) { item in
                        switch item.body {
                        case .user(let t):
                            Text(t).font(SidraFont.ui(15, weight: .medium)).foregroundStyle(SidraColor.text)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(SidraColor.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(SidraColor.hairline))
                                .frame(maxWidth: .infinity, alignment: .trailing).padding(.leading, 50)
                        case .assistant(let t):
                            Text((try? AttributedString(markdown: t, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(t))
                                .font(SidraFont.ui(15, weight: .medium)).foregroundStyle(SidraColor.text).textSelection(.enabled)
                        case .card(let c):
                            AssistantCardView(card: c).padding(14)
                                .background(SidraColor.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(SidraColor.hairline))
                        }
                    }
                    if a.thinking { GradientSpinner(size: 14).id("spin") }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 16).padding(.top, 8)
            }
            .onChange(of: a.thread.count, initial: true) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
        }
        .accessibilityIdentifier("assistant-thread")
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField(a.mode == .plan ? "Message Sidra" : "Tell the agent", text: $draft, axis: .vertical).lineLimit(1...4)
                .font(SidraFont.ui(15)).foregroundStyle(SidraColor.text).focused($typing)
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(SidraColor.panel, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(SidraColor.hairline))
                .onSubmit(sendDraft).accessibilityIdentifier("assistant-field")
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, a.voiceOn {
                // Back to voice.
                Button { typing = false; a.showThread = false } label: { VoiceBlob(size: 40, level: a.level, rings: false) }
                    .buttonStyle(.plain).accessibilityLabel("Voice")
            } else {
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold)).foregroundStyle(Color(hex: 0x06140e))
                        .frame(width: 40, height: 40).background(SidraColor.jade, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain).accessibilityLabel("Send").accessibilityIdentifier("assistant-send")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func sendDraft() { a.send(draft); draft = "" }
}

/// Hold to talk. Jade, like dictation's mic.
private struct MicButton: View {
    let size: CGFloat
    @State private var a = Assistant.shared
    var body: some View {
        Image(systemName: "mic.fill").font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(Color(hex: 0x06140e))
            .frame(width: size, height: size)
            .background(a.holding ? Color(hex: 0x7ff0bd) : SidraColor.jade, in: RoundedRectangle(cornerRadius: size * 0.34, style: .continuous))
            .scaleEffect(a.holding ? 1.06 : 1).animation(.easeOut(duration: 0.12), value: a.holding)
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in a.hold(true) }.onEnded { _ in a.hold(false) })
            .accessibilityLabel("Hold to talk").accessibilityAddTraits(.isButton).accessibilityIdentifier("assistant-mic")
    }
}

struct CardLabel: View {
    let text: String
    var trailing: String?
    init(_ text: String, trailing: String? = nil) { self.text = text; self.trailing = trailing }
    var body: some View {
        HStack {
            Text(text.uppercased()).font(SidraFont.ui(11.5, weight: .semibold)).tracking(0.7).foregroundStyle(SidraColor.dim)
            Spacer()
            if let trailing { Text(trailing).font(SidraFont.ui(12)).foregroundStyle(SidraColor.muted) }
        }
    }
}

/// One tool's own UI. Taps answer as the user would by voice.
struct AssistantCardView: View {
    let card: AssistantCard
    /// Under the blob the question is already the line beside it.
    var underBlob = false
    private var a: Assistant { Assistant.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        switch card {
        case .choice(let question, let options, let recommended):
            if !question.isEmpty, !underBlob { Text(question).font(SidraFont.ui(17, weight: .bold)).foregroundStyle(SidraColor.textBright) }
            ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                option(i + 1, o.title, o.detail, recommended: recommended == i + 1) { a.send("Option \(i + 1): \(o.title)") }
            }
            Text("Say a number, or tap.").font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.dim).frame(maxWidth: .infinity)
        case .rivals(let source, let rivals, let gap):
            CardLabel(source, trailing: "\(rivals.count) rivals")
            ForEach(Array(rivals.enumerated()), id: \.offset) { _, r in
                HStack(alignment: .top, spacing: 12) {
                    Text(String(r.name.prefix(1)).uppercased()).font(SidraFont.ui(14, weight: .heavy)).foregroundStyle(SidraColor.Process.glyph)
                        .frame(width: 34, height: 34).background(SidraColor.blue, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.name).font(SidraFont.ui(14, weight: .semibold)).foregroundStyle(SidraColor.text)
                        Text(r.finding).font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted)
                    }
                }
            }
            if let gap { notice("Gap", gap, SidraColor.jade) }
        case .findings(let source, let findings):
            CardLabel(source, trailing: findings.isEmpty ? nil : "\(findings.count) findings")
            if findings.isEmpty {
                HStack(spacing: 9) { Image(systemName: "checkmark").foregroundStyle(SidraColor.jade); Text("Clean. Nothing to fix.").font(SidraFont.ui(13.5)).foregroundStyle(SidraColor.text) }
            }
            ForEach(Array(findings.enumerated()), id: \.offset) { _, f in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(f.severity == "high" ? SidraColor.red : f.severity == "medium" ? SidraColor.yellow : SidraColor.dim).frame(width: 8, height: 8)
                        Text(f.title).font(SidraFont.ui(14.5, weight: .semibold)).foregroundStyle(SidraColor.text)
                    }
                    if let d = f.detail { Text(d).font(SidraFont.ui(13)).foregroundStyle(SidraColor.muted) }
                    if let file = f.file { Text(file).font(SidraFont.mono(11.5)).foregroundStyle(SidraColor.dim) }
                    HStack(spacing: 8) {
                        Button("Fix first") { a.send("Fix first: \(f.title)") }.buttonStyle(.sidraSecondary)
                        Button("Park") { a.send("Park: \(f.title)") }.buttonStyle(.sidraSecondary)
                    }
                    .padding(.top, 4)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(SidraColor.raised, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(SidraColor.hairline))
            }
        case .settled(let title, let features, let later, let fixFirst):
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                Text("Plan settled").font(SidraFont.ui(12.5, weight: .semibold))
            }
            .foregroundStyle(Color(hex: 0x06140e)).padding(.horizontal, 11).frame(height: 26).background(SidraColor.jade, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title).font(SidraFont.ui(21, weight: .bold)).foregroundStyle(SidraColor.textBright)
            ForEach(features, id: \.self) { f in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    RoundedRectangle(cornerRadius: 4.5).strokeBorder(SidraColor.dim, lineWidth: 1.5).frame(width: 14, height: 14)
                    Text(f).font(SidraFont.ui(14, weight: .medium)).foregroundStyle(SidraColor.text)
                }
            }
            if !later.isEmpty { Text("Later: " + later.joined(separator: " · ")).font(SidraFont.ui(13)).foregroundStyle(SidraColor.muted) }
            if !fixFirst.isEmpty { notice("Fix first", fixFirst.joined(separator: " · "), SidraColor.red) }
            Button("Start code mode") { a.setMode(.code) }.buttonStyle(.sidraPrimary).padding(.top, 6)
        case .newProject(let name, let folder, let agent):
            CardLabel("New project")
            row("Name", name)
            row("Folder", folder, mono: true, note: "New folder if it is not there.")
            row("Space", name, note: "A new herdr space. Sidra switches to it.")
            row("Agent", CodingAgent.all.first { $0.id == agent }?.name ?? agent, note: "Starts in the folder.")
            HStack(spacing: 8) {
                Button("Create") { a.send("Yes, create it.") }.buttonStyle(.sidraPrimary)
                Button("Change") { a.showThread = true }.buttonStyle(.sidraSecondary)
            }
            .padding(.top, 6)
        case .spaces(let rows):
            CardLabel("herdr", trailing: "\(rows.count) spaces")
            ForEach(rows) { r in
                Button { a.pick(r) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: r.status == "blocked" ? "exclamationmark.triangle.fill" : r.status == "working" ? "circle.lefthalf.filled" : r.status == "done" ? "checkmark" : "circle")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(r.status == "blocked" ? SidraColor.gold : r.status == "working" ? SidraColor.orange : r.status == "done" ? SidraColor.jade : SidraColor.dim)
                            .frame(width: 24, height: 24).background(Color(hex: 0x232a33), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name).font(SidraFont.ui(15, weight: .semibold)).foregroundStyle(SidraColor.text)
                            Text(Self.statusLine(r)).font(SidraFont.ui(13)).foregroundStyle(SidraColor.muted)
                        }
                        Spacer()
                    }
                    .padding(12).background(SidraColor.raised, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(SidraColor.hairline))
                }
                .buttonStyle(.plain)
            }
        case .question(let space, let question, let options):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(SidraColor.gold)
                Text("The agent in \(space) waits for you").font(SidraFont.ui(12.5, weight: .semibold)).foregroundStyle(SidraColor.gold)
            }
            Text(question).font(SidraFont.ui(18, weight: .bold)).foregroundStyle(SidraColor.textBright)
            ForEach(Array(options.enumerated()), id: \.offset) { i, o in option(i + 1, o, nil, recommended: false) { a.send(o) } }
        case .prompt(let space, let text):
            CardLabel("To the agent in \(space)")
            Text(text).font(SidraFont.ui(15, weight: .medium)).foregroundStyle(SidraColor.text).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(SidraColor.raised, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(SidraColor.hairline))
            HStack(spacing: 8) {
                Button("Send") { a.send("Yes, send it.") }.buttonStyle(.sidraPrimary)
                Button("Edit") { a.showThread = true }.buttonStyle(.sidraSecondary)
            }
        case .turn(let space, let summary, let verdict, let didYouKnow):
            HStack(spacing: 8) {
                Circle().fill(verdict == "broken" ? SidraColor.red : verdict == "watch" ? SidraColor.yellow : SidraColor.jade).frame(width: 8, height: 8)
                Text(space).font(SidraFont.ui(12.5, weight: .semibold)).foregroundStyle(SidraColor.text)
                Text(verdict == "broken" ? "Broken" : verdict == "watch" ? "Check this" : "Clean").font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted)
            }
            Text(summary).font(SidraFont.ui(15, weight: .medium)).foregroundStyle(SidraColor.text)
            if let d = didYouKnow {
                notice("Did you know?", d, SidraColor.gold)
                Button("Tell the agent") { a.send("Tell the agent: \(d)") }.buttonStyle(.sidraSecondary)
            }
        }
    }

    static func statusLine(_ r: SpaceRow) -> String {
        let who = CodingAgent.all.first { $0.id == r.agent }?.name ?? r.agent
        guard let who else { return "No agent runs" }
        switch r.status {
        case "blocked": return "\(who) asks a question"
        case "working": return "\(who) works"
        case "done": return "\(who) is done"
        default: return "\(who) is idle"
        }
    }

    private func option(_ n: Int, _ title: String, _ detail: String?, recommended: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Text("\(n)").font(SidraFont.ui(12.5, weight: .bold)).foregroundStyle(SidraColor.muted)
                    .frame(width: 24, height: 24).background(Color(hex: 0x232a33), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title).font(SidraFont.ui(15, weight: .semibold)).foregroundStyle(SidraColor.text).multilineTextAlignment(.leading)
                        if recommended {
                            Text("Recommended").font(SidraFont.ui(10.5, weight: .bold)).foregroundStyle(Color(hex: 0x06140e))
                                .padding(.horizontal, 7).padding(.vertical, 2).background(SidraColor.jade, in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                    if let detail, !detail.isEmpty { Text(detail).font(SidraFont.ui(13)).foregroundStyle(SidraColor.muted).multilineTextAlignment(.leading) }
                }
                Spacer(minLength: 0)
            }
            .padding(13).background(SidraColor.raised, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .gradientBorder(radius: 15, active: recommended)
        }
        .buttonStyle(.plain).accessibilityIdentifier("assistant-option-\(n)")
    }

    /// A solid panel with a coloured label. No tint, no side bar.
    private func notice(_ label: String, _ text: String, _ color: Color) -> some View {
        (Text(label + " ").font(SidraFont.ui(13.5, weight: .semibold)).foregroundStyle(color) + Text(text).font(SidraFont.ui(13.5, weight: .medium)).foregroundStyle(SidraColor.text))
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(SidraColor.raised, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(SidraColor.hairline2))
    }

    private func row(_ label: String, _ value: String, mono: Bool = false, note: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label.uppercased()).font(SidraFont.ui(11.5, weight: .semibold)).tracking(0.6).foregroundStyle(SidraColor.dim).frame(width: 70, alignment: .leading).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(mono ? SidraFont.mono(13, weight: .semibold) : SidraFont.ui(14, weight: .semibold)).foregroundStyle(SidraColor.text)
                if let note { Text(note).font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted) }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Around the screen

/// The title bar's way in, and the session's sign when the screen is hidden.
struct AssistantButton: View {
    @Environment(AppModel.self) private var app
    @State private var a = Assistant.shared
    var body: some View {
        Button {
            if a.active { a.open = true } else { a.start(.plan, host: HerdrHost(app: app)) }
        } label: {
            VoiceBlob(size: 18, level: a.active ? a.level : 0, rings: false).frame(width: 30, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel("Voice assistant").accessibilityIdentifier("assistant-button")
    }
}

/// The session lives on while you look at a tab: the blob floats, speaks, and shows its last line.
struct FloatingAssistant: View {
    @State private var a = Assistant.shared
    var body: some View {
        if a.active, !a.open {
            HStack(spacing: 12) {
                if !a.said.isEmpty {
                    Text(a.said).font(SidraFont.ui(13, weight: .medium)).foregroundStyle(SidraColor.text).lineLimit(3)
                        .padding(.horizontal, 13).padding(.vertical, 10).frame(maxWidth: 230, alignment: .leading)
                        .background(SidraColor.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(SidraColor.hairline2))
                }
                Button { a.open = true } label: { VoiceBlob(size: 46, level: a.level, thinking: a.thinking) }
                    .buttonStyle(.plain).accessibilityLabel("Open the voice assistant").accessibilityIdentifier("assistant-floating")
            }
            .padding(.trailing, 14).padding(.bottom, 96)
            .transition(.opacity)
        }
    }
}

extension View {
    /// Presents the assistant over a window: full screen on a phone, a phone-sized sheet elsewhere.
    func assistantLayer(app: AppModel) -> some View {
        let a = Assistant.shared
        let shown = Binding(get: { a.open }, set: { a.open = $0 })
        return overlay(alignment: .bottomTrailing) { FloatingAssistant() }
            #if os(iOS)
            .fullScreenCover(isPresented: Platform.isPhone ? shown : .constant(false)) { AssistantScreen().environment(app) }
            .sheet(isPresented: Platform.isPhone ? .constant(false) : shown) {
                AssistantScreen().environment(app).frame(minWidth: 420, idealWidth: 440, minHeight: 760).presentationBackground(SidraColor.ground)
            }
            #else
            .sheet(isPresented: shown) { AssistantScreen().environment(app).frame(width: 440, height: 820) }
            #endif
            .onAppear {
                #if DEBUG
                if let d = UserDefaults.standard.string(forKey: "sidra.assistantDemo") { a.demo(d) }
                #endif
            }
    }
}

/// Settings › Voice: the assistant's key and whether it speaks.
struct AssistantSettings: View {
    @State private var a = Assistant.shared
    @State private var key = ""
    @State private var saved = KeychainStore.string(for: Assistant.keychainKey)?.isEmpty == false

    var body: some View {
        SettingRow("Voice assistant", detail: "Plan and code by voice. Speech goes to OpenAI while a session runs, at about $0.05 a minute on your key.",
                   isDefault: a.voiceOn, reset: { a.voiceOn = true }) {
            Toggle("", isOn: Binding(get: { a.voiceOn }, set: { a.voiceOn = $0 })).labelsHidden().toggleStyle(GradientToggleStyle())
                .accessibilityLabel("The assistant speaks and listens")
        }
        SettingRow("OpenAI key", detail: saved ? "Saved in the Keychain of this device." : "The assistant needs your own key. It stays in the Keychain of this device.",
                   isDefault: !saved, reset: { KeychainStore.remove(Assistant.keychainKey); saved = false }) {
            HStack(spacing: 8) {
                SecureField(saved ? "Replace the key" : "sk-…", text: $key).textFieldStyle(.plain).font(SidraFont.mono(12)).frame(width: 150)
                    .padding(.horizontal, 10).frame(height: 30).background(Color(hex: 0x0f1216), in: RoundedRectangle(cornerRadius: 8))
                Button("Save") {
                    let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    if (try? KeychainStore.set(k, for: Assistant.keychainKey)) != nil { saved = true; key = "" }
                }
                .buttonStyle(.sidraSecondary).disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
