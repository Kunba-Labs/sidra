import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import SidraWorkspace
import SidraTerminal

/// Menu bar and Cmd-HUD shortcuts. Every command is registered in `CommandRegistry`, so the
/// palette (⌘⇧P) and the shortcuts sheet show the same names and keys.
struct WorkspaceCommands: Commands {
    let app: AppModel
    private var store: WorkspaceStore { app.workspace }

    /// SwiftUI re-creates `Commands` on every scene update. Registering each time mutated the
    /// observable registry that `body` reads, which re-invalidated the scene: a 100% CPU loop after
    /// any workspace change. Register once per AppModel instead.
    nonisolated(unsafe) private static var registeredFor: ObjectIdentifier?

    init(app: AppModel) {
        self.app = app
        if Self.registeredFor != ObjectIdentifier(app) {
            Self.registeredFor = ObjectIdentifier(app)
            CommandRegistry.shared.replaceAll(Self.all(app))
        }
    }

    var body: some Commands {
        CommandGroup(replacing: .textEditing) {}   // the system Find items would take Cmd-F from the terminal's find bar
        CommandGroup(before: .toolbar) { items("View") }   // Bigger / Smaller / Default Text Size (Mac)
        CommandMenu("Tab") { items("Tab") }
        CommandMenu("Pane") { items("Pane") }
        CommandMenu("Go") { items("Go") }
        CommandMenu("Theasa") { items("Theasa") }
    }

    private func items(_ area: String) -> some View {
        ForEach(CommandRegistry.shared.commands.filter { $0.area == area }) { c in
            Button(c.title) { CommandRegistry.shared.run(c.id) }.keyboardShortcut(c.shortcut)
        }
    }

    static func all(_ app: AppModel) -> [SidraCommand] {
        var store: WorkspaceStore { app.workspace }   // resolved per run: commands register once, windows come and go
        /// A split repeats the focused pane's kind: another shell on that host, another herdr client.
        func splitFocused(_ axis: SplitAxis) {
            guard let focused = store.focusedPane else { return }
            store.split(focused.id, axis: axis, newPane: app.newPane(kind: focused.kind))
        }
        /// In a herdr pane, ⌘[ and ⌘] walk its spaces (the chip row) instead of the window's panes.
        func herdrSpace(_ offset: Int) -> Bool {
            guard let p = store.focusedPane, case .herdr = p.kind,
                  let m = MuxMonitors.shared.monitor(for: p, app: app), let spaces = m.snapshot?.workspaces, !spaces.isEmpty else { return false }
            let n = spaces.count
            let i = spaces.firstIndex { $0.id == m.snapshot?.focused_workspace_id } ?? 0
            Task { await m.focus(app, spaces[((i + offset) % n + n) % n]) }
            return true
        }
        var c: [SidraCommand] = [
            .init("tab.new", "New Tab…", area: "Tab", key: "t") { app.sheet = .newTab },
            .init("tab.close", "Close Tab", area: "Tab", key: "w") { if let id = store.activeTabID { store.requestCloseTab(id) } },
            .init("tab.next", "Next Tab", area: "Tab", key: "]", modifiers: [.command, .shift]) { store.selectTab(offset: 1) },
            .init("tab.prev", "Previous Tab", area: "Tab", key: "[", modifiers: [.command, .shift]) { store.selectTab(offset: -1) },
            // ⌃⇥ and ⌃⇧⇥ walk every tab, as in a browser (Waseem, 2026-11-18). Recent files moved to ⌃`.
            .init("tab.nextCtrl", "Next Tab (⌃⇥)", area: "Tab", key: .tab, modifiers: .control) { store.selectTab(offset: 1) },
            .init("tab.prevCtrl", "Previous Tab (⌃⇧⇥)", area: "Tab", key: .tab, modifiers: [.control, .shift]) { store.selectTab(offset: -1) },
        ]
        for n in 1..<10 { c.append(.init("tab.\(n)", "Tab \(n)", area: "Tab", key: KeyEquivalent(Character("\(n)"))) { store.selectTab(index: n - 1) }) }
        c += [
            .init("pane.splitRight", "Split Right", area: "Pane", key: "d") { splitFocused(.horizontal) },
            .init("pane.splitDown", "Split Down", area: "Pane", key: "d", modifiers: [.command, .shift]) { splitFocused(.vertical) },
            .init("pane.maximize", "Maximize Pane", area: "Pane", key: .return, modifiers: [.command, .shift]) { if let id = store.focusedPane?.id { store.toggleMaximize(pane: id) } },
            .init("pane.close", "Close Pane", area: "Pane", key: "w", modifiers: [.command, .shift]) { if let id = store.focusedPane?.id { store.requestClose(pane: id) } },
            .init("pane.next", "Focus Next Pane", area: "Pane", key: "]") { if !herdrSpace(1) { store.focusPane(offset: 1) } },
            .init("pane.prev", "Focus Previous Pane", area: "Pane", key: "[") { if !herdrSpace(-1) { store.focusPane(offset: -1) } },
        ]
        for n in 1..<10 { c.append(.init("pane.\(n)", "Focus Pane \(n)", area: "Pane", key: KeyEquivalent(Character("\(n)")), modifiers: .control) { store.focusPane(index: n - 1) }) }
        c += [
            .init("go.shortcuts", "Keyboard Shortcuts…", area: "Go", key: "/", modifiers: [.command, .shift]) { app.sheet = .shortcuts },
            // Cmd-F never reaches a first responder's key commands on iPad; the menu key does.
            .init("go.find", "Find", area: "Go", key: "f") {
                if TheasaCommands.focused(app) { TheasaCommands.search(app) }   // Theasa's popover sits over every pane
                else if case .terminal = store.focusedPane?.kind { NotificationCenter.default.post(name: .sidraTerminalFind, object: nil) }
            },
            .init("go.back", "Back", area: "Go", key: ".") { if TheasaCommands.focused(app) { TheasaCommands.back(app) } },
            .init("go.newWindow", "New Window", area: "Go") { app.openNewWindow?() },
            .init("go.settings", "Settings…", area: "Go", key: ",") { app.sheet = .settings },
        ]
        #if os(macOS)
        // Terminal text size for every pane, as in Ghostty and Terminal.
        c += [
            .init("view.biggerText", "Bigger Text", area: "View", key: "=", label: "⌘+") { TerminalFont.step(1) },
            .init("view.smallerText", "Smaller Text", area: "View", key: "-") { TerminalFont.step(-1) },
            .init("view.actualSize", "Default Text Size", area: "View", key: "0") { TerminalFont.resetSize() },
            .init("go.dictate", "Dictate", area: "Go", key: "v", modifiers: [.command, .option]) { VoiceInput.shared.toggle() },
        ]
        #endif
        c += TheasaCommands.all(app)
        return c
    }
}

extension Notification.Name {
    static let sidraTerminalFind = Notification.Name("sidraTerminalFind")
}
