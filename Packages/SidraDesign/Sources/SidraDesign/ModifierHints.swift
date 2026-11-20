import SwiftUI
#if os(macOS)
import AppKit
#else
import GameController
import UIKit
#endif

/// The number keys that pick a tab: 1–9, then 0, - and = (shown as +) for tabs 10 to 12 (Waseem, 2026-11-19).
public enum TabKeys {
    public static let keys: [Character] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="]
    public static func label(_ index: Int) -> String? {
        keys.indices.contains(index) ? (keys[index] == "=" ? "+" : String(keys[index])) : nil
    }
}

/// Which of ⌘ and ⌃ is held on its own, after a short hold, so the tabs can show the keys that pick them.
/// Any other key hides the hints, so a quick ⌘C never flashes them. Leaving the app (⌘Tab) hides them too:
/// the ⌘ release then goes to the other app, and the hints stayed up (2026-11-20).
@MainActor @Observable public final class ModifierHold {
    public static let shared = ModifierHold()
    public private(set) var command = false
    public private(set) var control = false
    @ObservationIgnored private var held: (cmd: Bool, ctrl: Bool) = (false, false)
    @ObservationIgnored private var pending: DispatchWorkItem?

    private init() {
        #if os(macOS)
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] e in
            if e.type == .keyDown { self?.otherKey() } else {
                let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
                self?.changed(cmd: f == .command, ctrl: f == .control)
            }
            return e
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ModifierHold.shared.reset() }
        }
        #else
        hook()
        NotificationCenter.default.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ModifierHold.shared.hook() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ModifierHold.shared.reset() }
        }
        #endif
    }

    #if !os(macOS)
    private var down: Set<GCKeyCode> = []
    private func hook() {
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = { _, _, code, pressed in
            MainActor.assumeIsolated {
                let s = ModifierHold.shared
                if pressed { s.down.insert(code) } else { s.down.remove(code) }
                let cmds: Set<GCKeyCode> = [.leftGUI, .rightGUI], ctrls: Set<GCKeyCode> = [.leftControl, .rightControl]
                if pressed, !cmds.contains(code), !ctrls.contains(code) { s.otherKey(); return }
                s.changed(cmd: !s.down.isDisjoint(with: cmds) && s.down.isSubset(of: cmds),
                          ctrl: !s.down.isDisjoint(with: ctrls) && s.down.isSubset(of: ctrls))
            }
        }
    }
    #endif

    private func changed(cmd: Bool, ctrl: Bool) {
        pending?.cancel(); pending = nil
        held = (cmd, ctrl)
        command = false; control = false
        guard cmd || ctrl else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.command = self.held.cmd; self.control = self.held.ctrl
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    /// The app lost focus: nothing is known to be held any more.
    private func reset() {
        held = (false, false)
        #if !os(macOS)
        down = []
        #endif
        otherKey()
    }

    private func otherKey() {
        pending?.cancel(); pending = nil
        command = false; control = false
    }
}

/// The small key badge drawn on a tab while its modifier is held: "⌘1", "⌃0".
public struct KeyHint: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text).font(SidraFont.ui(10.5, weight: .semibold)).monospacedDigit()
            .foregroundStyle(SidraColor.ground)
            .padding(.horizontal, 5).frame(height: 16)
            .background(SidraColor.jade, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .fixedSize()
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}
