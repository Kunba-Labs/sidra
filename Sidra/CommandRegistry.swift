import SwiftUI

/// One command, shared by the menu bar, the palette and the shortcuts sheet.
struct SidraCommand: Identifiable {
    let id: String
    let title: String
    let area: String
    let shortcut: KeyboardShortcut?
    /// Shown when the binding lives in UIKit (F-keys, Cmd-S in the text view) rather than SwiftUI.
    let shortcutLabel: String?
    let action: @MainActor () -> Void

    init(_ id: String, _ title: String, area: String, key: KeyEquivalent? = nil, modifiers: EventModifiers = .command, label: String? = nil, action: @escaping @MainActor () -> Void) {
        self.id = id; self.title = title; self.area = area
        self.shortcut = key.map { KeyboardShortcut($0, modifiers: modifiers) }
        self.shortcutLabel = label
        self.action = action
    }

    var keyLabel: String {
        if let shortcutLabel { return shortcutLabel }
        guard let shortcut else { return "" }
        var s = ""
        if shortcut.modifiers.contains(.control) { s += "⌃" }
        if shortcut.modifiers.contains(.option) { s += "⌥" }
        if shortcut.modifiers.contains(.shift) { s += "⇧" }
        if shortcut.modifiers.contains(.command) { s += "⌘" }
        switch shortcut.key {
        case .return: s += "↩"
        case .tab: s += "⇥"
        case .escape: s += "⎋"
        case .space: s += "Space"
        default: s += String(shortcut.key.character).uppercased()
        }
        return s
    }
}

/// Every command the app offers. Commands.swift fills it; the palette and shortcuts sheet read it.
@MainActor
@Observable
final class CommandRegistry {
    static let shared = CommandRegistry()
    private(set) var commands: [SidraCommand] = []
    private(set) var recents: [String] = UserDefaults.standard.stringArray(forKey: "sidra.recentCommands") ?? []

    func replaceAll(_ cmds: [SidraCommand]) {
        if cmds.map(\.id) != commands.map(\.id) { commands = cmds } else { commands = cmds }
    }

    func run(_ id: String) {
        guard let c = commands.first(where: { $0.id == id }) else { return }
        recents.removeAll { $0 == id }
        recents.insert(id, at: 0)
        if recents.count > 12 { recents.removeLast(recents.count - 12) }
        UserDefaults.standard.set(recents, forKey: "sidra.recentCommands")
        c.action()
    }

    var areas: [String] { var seen: [String] = []; for c in commands where !seen.contains(c.area) { seen.append(c.area) }; return seen }
}
