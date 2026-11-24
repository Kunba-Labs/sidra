import SwiftUI
import SidraDesign
import SidraWorkspace
import SidraSSH

/// Pick a machine, see what herdr runs there, open its spaces in a pane.
struct HerdrConnectSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// The picked machine; a placeholder id until one exists (see `picked`).
    @State private var target: TerminalTarget = .ssh(hostID: UUID())
    @State private var probe: HerdrProbe?
    @State private var probing = false
    @State private var probeError: String?
    @State private var session = "default"
    @State private var confirmInstall = false
    @State private var installing = false
    @State private var alert: SidraAlert?
    @State private var logos = MuxMonitor(target: .ssh(hostID: UUID()), session: nil)
    @State private var adding: SSHHostProfile?
    @State private var editing: SSHHostProfile?
    @State private var prompter = HostKeyPrompter.shared
    @State private var password = ""

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ProcessIcon(.herdr, size: 30)
                Text("Connect to herdr").font(SidraFont.ui(19, weight: .bold)).foregroundStyle(SidraColor.text)
            }
            Text("Sidra signs in over SSH, finds herdr on that machine and shows its spaces. Your agents keep running there when the \(Platform.deviceName) sleeps.")
                .font(SidraFont.ui(13)).foregroundStyle(SidraColor.muted).padding(.top, 6)
            SectionLabel("Machine").padding(.top, 16)
            VStack(spacing: 8) {
                ForEach(app.hosts.hosts) { h in
                    machine(.ssh(hostID: h.id), title: h.alias, chips: ["SSH host", "\(h.user)@\(h.host)\(h.port == 22 ? "" : ":\(h.port)")"], symbol: "desktopcomputer", edit: h)
                }
                Button {
                    // herdr is the shell here, so no startup command.
                    adding = SSHHostProfile(alias: "", host: "", user: "", auth: .key, startupCommand: "", trustOnFirstUse: false)
                } label: {
                    Label("Add machine", systemImage: "plus").font(SidraFont.ui(13.5, weight: .semibold)).foregroundStyle(SidraColor.muted)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SidraColor.hairline, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain).accessibilityIdentifier("herdr-add-machine")
            }
            if picked {
                SectionLabel("Found on \(app.herdrMachineName(target))").padding(.top, 16)
                found
            }
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.sidraSecondary)
                if probe?.version == nil, probe != nil {
                    Button(installing ? "Installing…" : "Install herdr") { confirmInstall = true }.buttonStyle(.sidraPrimary).disabled(installing)
                } else {
                    Button("Open spaces") { open() }.buttonStyle(.sidraPrimary).disabled(probe?.version == nil)
                        .accessibilityIdentifier("herdr-open")
                }
            }
            .padding(.top, 18)
        }
        .padding(24)
        }
        .frame(maxWidth: 640)
        .frame(maxHeight: 680)
        .fixedSize(horizontal: false, vertical: true)
        .sidraSheetBackground()
        .task(id: target) { await runProbe() }
        .onAppear {
            if !picked, let first = app.hosts.hosts.first { target = .ssh(hostID: first.id) }
            #if DEBUG
            if CommandLine.arguments.contains("-sidra.addMachine") { adding = SSHHostProfile(alias: "", host: "", user: "", auth: .key, startupCommand: "", trustOnFirstUse: false) }
            #endif
        }
        .sidraAlert($alert)
        .sheet(item: $adding) { h in HostEditor(profile: h, password: $password) { saved, pw in
            app.hosts.upsert(saved, password: pw.isEmpty ? nil : pw)
            adding = nil
            target = .ssh(hostID: saved.id)
        }.environment(app) }
        .sheet(item: $editing) { h in HostEditor(profile: h, password: $password) { saved, pw in
            app.hosts.upsert(saved, password: pw.isEmpty ? nil : pw)
            editing = nil
            // Same target id, so the probe task would not rerun on its own.
            if target == .ssh(hostID: saved.id) { Task { await runProbe() } } else { target = .ssh(hostID: saved.id) }
        }.environment(app) }
        .keyUseConfirmation()
        // A first connection asks to trust the host key; without this it would wait unseen.
        .sheet(item: Binding(get: { editing == nil && adding == nil ? prompter.pending.map { PromptBox(prompt: $0) } : nil }, set: { _ in })) { box in
            HostKeySheet(prompt: box.prompt) { prompter.decide($0) }
        }
        .onAppear { prompter.install() }
        .alert("Install herdr on \(app.herdrMachineName(target))?", isPresented: $confirmInstall) {
            Button("Install") { Task { await install() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Runs herdr's own installer (herdr.dev/install.sh), which puts herdr in ~/.local/bin. herdr is open source under Apache 2.0.")
        }
    }

    @ViewBuilder private var found: some View {
        if probing {
            HStack(spacing: 8) { GradientSpinner(size: 12); Text("Looking for herdr…").font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted) }
                .padding(12)
        } else if let probeError {
            Text(probeError).font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.yellow).padding(12)
        } else if let p = probe {
            VStack(alignment: .leading, spacing: 10) {
                if let v = p.version {
                    let version = FooterChip([.init(v, label: "herdr", color: SidraColor.jade)])
                    let server = FooterChip([.init(p.running ? "running" : "starts when you open it", label: "server")])
                    // One row when it fits; on a phone, one line per group.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { version; server; if let s = p.snapshot { spaces(s); FooterChip([.init("\(s.agents.count)", label: "agents")]) } }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) { version; server }
                            if let s = p.snapshot {
                                HStack(spacing: 6) { FooterChip([.init("\(s.workspaces.count)", label: "spaces")]); FooterChip([.init("\(s.agents.count)", label: "agents")]) }
                                HStack(spacing: 4) { ForEach(s.workspaces.prefix(8)) { ws in HerdrLogoView(name: ws.label, image: logos.logo(for: ws), size: 14) } }
                            }
                        }
                    }
                    if p.sessions.count > 1 {
                        Picker("Session", selection: $session) { ForEach(p.sessions, id: \.self) { Text($0) } }
                            .pickerStyle(.segmented).frame(maxWidth: 360)
                    }
                } else {
                    Text("herdr is not installed on this machine.").font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(SidraColor.jade.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
    }

    private func spaces(_ s: MuxSnapshot) -> some View {
        HStack(spacing: 4) {
            ForEach(s.workspaces.prefix(8)) { ws in HerdrLogoView(name: ws.label, image: logos.logo(for: ws), size: 14) }
            FooterChip([.init("\(s.workspaces.count)", label: "spaces")])
        }
    }

    private func machine(_ t: TerminalTarget, title: String, chips: [String], symbol: String, edit: SSHHostProfile? = nil) -> some View {
        let on = t == target
        return Button { target = t } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(SidraColor.muted)
                    .frame(width: 34, height: 34).background(SidraColor.tabActive, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(SidraFont.ui(13, weight: .bold)).foregroundStyle(SidraColor.text)
                    FooterChip(chips.map { .init($0, color: SidraColor.muted) })
                }
                Spacer()
                if edit != nil { Color.clear.frame(width: 34, height: 34) }   // room for the edit button laid over the card
                Circle().strokeBorder(on ? SidraColor.orange : SidraColor.dim, lineWidth: on ? 5 : 1.5).frame(width: 18, height: 18)
            }
            .padding(12)
            .background(SidraColor.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .gradientBorder(radius: 12, active: on)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
        .overlay(alignment: .trailing) {
            if let edit {
                Button { editing = edit } label: {
                    Image(systemName: "pencil").font(.system(size: 14)).foregroundStyle(SidraColor.muted)
                        .frame(width: 34, height: 34).contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.trailing, 42)
                .accessibilityLabel("Edit \(title)")
            }
        }
    }

    /// A saved host is picked (the sheet opens on the first one).
    private var picked: Bool { if case .ssh(let id) = target { app.hosts.host(id) != nil } else { false } }

    private func runProbe() async {
        guard picked else { probe = nil; return }
        let asked = target
        probing = true; probeError = nil; probe = nil
        defer { if asked == target { probing = false } }
        do {
            let p = try await HerdrProbe.run(app, asked)
            // The SSH call outlives task cancellation; a probe for a machine no longer picked is dropped.
            guard asked == target, !Task.isCancelled else { return }
            probe = p
            session = p.sessions.contains("default") ? "default" : (p.sessions.first ?? "default")
            if p.snapshot != nil {
                logos = MuxMonitor(target: target, session: nil)
                await logos.refresh(app)
            }
        } catch {
            guard asked == target, !Task.isCancelled else { return }
            probeError = SSHFailure.describe(error, host: app.herdrMachineName(asked)).detail
        }
    }

    private func install() async {
        installing = true
        defer { installing = false }
        do {
            let r = try await app.herdrRun(target, "f=$(mktemp) && curl -fsSL https://herdr.dev/install.sh -o \"$f\" && sh \"$f\"; s=$?; rm -f \"$f\"; exit $s")
            if r.exitCode != 0 {
                alert = SidraAlert(title: "herdr did not install", detail: "The installer stopped with status \(r.exitCode).", rawOutput: r.stdoutText + r.stderrText)
                return
            }
            await runProbe()
        } catch {
            alert = .from(error, title: "herdr did not install")
        }
    }

    private func open() {
        app.openTab(kind: .herdr(target: target, session: session == "default" ? nil : session))
        dismiss()
    }

    private struct PromptBox: Identifiable { let prompt: HostKeyPrompt; var id: String { "\(prompt.host):\(prompt.port)" } }
}
