import SwiftUI
import SidraDesign
import SidraWorkspace
import SidraSSH

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
    @Environment(AppModel.self) private var app
    private var a: Assistant { Assistant.shared }
    private var boardSquares: [ActivityBoard.Square] { ActivityBoard.squares(app: app, store: app.workspace) }

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
        case .spaces(let rows) where !boardSquares.isEmpty:
            // The activity board's own squares (Waseem, 2026-11-28: "it has to look like our dashboard"): one per
            // agent, the last turn to end first; a tap shows that agent.
            let squares = boardSquares
            CardLabel("Last activity", trailing: squares.count == 1 ? "1 agent" : "\(squares.count) agents")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(squares) { sq in
                    AgentSquare(square: sq) {
                        app.workspace.select(tab: sq.tab)
                        Task { await sq.monitor.focusAgent(app, pane: sq.agent.pane_id) }
                        a.picked(sq.space?.label ?? sq.agent.workspace_id)
                    }
                }
            }
            .task { var seen = Set<String>(); for sq in squares where seen.insert(sq.monitor.key).inserted { await sq.monitor.loadModels(app) } }
            let _ = rows
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

/// The title bar's way in: it starts a session, and during one it opens the text view.
struct AssistantButton: View {
    @Environment(AppModel.self) private var app
    @State private var a = Assistant.shared
    var body: some View {
        Button {
            if a.active { a.showThread = true } else { a.start(a.mode, host: HerdrHost(app: app)) }
        } label: {
            Circle().fill(SidraGradient.horizontal).frame(width: 16, height: 16).frame(width: 30, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel("Voice assistant").accessibilityIdentifier("assistant-button")
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
