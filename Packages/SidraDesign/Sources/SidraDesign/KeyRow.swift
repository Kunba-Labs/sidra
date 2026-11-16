import UIKit
import GameController

/// Whether a hardware keyboard is attached. The key row is only offered without one; owners
/// observe `GCKeyboardDidConnect` / `GCKeyboardDidDisconnect` and call `reloadInputViews()`.
public enum HardwareKeyboard {
    public static var attached: Bool { GCKeyboard.coalesced != nil }
    public static func observe(_ target: Any, _ selector: Selector) {
        NotificationCenter.default.addObserver(target, selector: selector, name: .GCKeyboardDidConnect, object: nil)
        NotificationCenter.default.addObserver(target, selector: selector, name: .GCKeyboardDidDisconnect, object: nil)
    }
}

/// Extra key row above the software keyboard: Esc, Tab, Ctrl, Alt, arrows and the symbols a shell
/// and an editor need. Offered only when `HardwareKeyboard.attached` is false. `onKey` receives a
/// token; the owner maps it to bytes or edits.
public final class SidraKeyRow: UIInputView {
    public enum Key: String, CaseIterable {
        case esc = "esc", tab = "tab", ctrl = "ctrl", alt = "alt"
        case up = "↑", down = "↓", left = "←", right = "→"
        case pipe = "|", tilde = "~", backslash = "\\", dash = "-", slash = "/"
        case braceL = "{", braceR = "}", bracketL = "[", bracketR = "]", lt = "<", gt = ">", paste = "paste"
    }

    public var onKey: ((Key, _ ctrl: Bool, _ alt: Bool) -> Void)?
    /// What the paste key says: ⌘V where the far side is a Mac or the editor, ^V for a Linux shell.
    /// Either way it runs Sidra's paste (an image becomes a remote file path).
    public var pasteLabel = "⌘V" { didSet { refreshPaste() } }
    /// Whether the owner pastes images (terminals upload them); the editor pastes text only.
    public var pastesImages = false { didSet { refreshPaste() } }
    public private(set) var ctrlArmed = false
    public private(set) var altArmed = false
    private var buttons: [Key: UIButton] = [:]

    public init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 44),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -6),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -12),
        ])
        for key in Key.allCases {
            let b = UIButton(type: .system)
            var cfg = UIButton.Configuration.filled()
            cfg.title = key.rawValue
            cfg.baseBackgroundColor = UIColor(hex: 0x191e25)
            cfg.baseForegroundColor = UIColor(hex: 0xd9dde3)
            cfg.cornerStyle = .medium
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
            cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var a = attrs
                a.font = UIFont(name: "JetBrainsMono-Regular", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
                return a
            }
            if key == .paste { cfg.title = pasteLabel }
            b.configuration = cfg
            b.accessibilityLabel = key.rawValue == "esc" ? "Escape" : key == .paste ? "Paste" : key.rawValue
            b.addAction(UIAction { [weak self] _ in self?.tapped(key) }, for: .touchUpInside)
            stack.addArrangedSubview(b)
            buttons[key] = b
        }
        NotificationCenter.default.addObserver(self, selector: #selector(refreshPaste), name: UIPasteboard.changedNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshPaste), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // The paste key turns blue while the clipboard holds something. Checking hasStrings/hasImages
    // does not read the clipboard, so it never shows the paste permission prompt.
    public override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow != nil { refreshPaste() }
    }

    @objc private func refreshPaste() {
        let full = UIPasteboard.general.hasStrings || (pastesImages && UIPasteboard.general.hasImages)
        guard let b = buttons[.paste] else { return }
        b.configuration?.title = pasteLabel
        b.configuration?.baseBackgroundColor = full ? UIColor(SidraColor.blue) : UIColor(hex: 0x191e25)
        b.configuration?.baseForegroundColor = full ? UIColor(hex: 0x0f1216) : UIColor(hex: 0xd9dde3)
    }

    private func tapped(_ key: Key) {
        switch key {
        case .ctrl:
            ctrlArmed.toggle()
            buttons[.ctrl]?.configuration?.baseBackgroundColor = ctrlArmed ? UIColor(hex: 0x5ad6a0) : UIColor(hex: 0x191e25)
            buttons[.ctrl]?.configuration?.baseForegroundColor = ctrlArmed ? UIColor(hex: 0x0f1216) : UIColor(hex: 0xd9dde3)
        case .alt:
            altArmed.toggle()
            buttons[.alt]?.configuration?.baseBackgroundColor = altArmed ? UIColor(hex: 0x5ad6a0) : UIColor(hex: 0x191e25)
            buttons[.alt]?.configuration?.baseForegroundColor = altArmed ? UIColor(hex: 0x0f1216) : UIColor(hex: 0xd9dde3)
        default:
            onKey?(key, ctrlArmed, altArmed)
            if ctrlArmed { tapped(.ctrl) }
            if altArmed { tapped(.alt) }
        }
    }

    /// Consumes an armed modifier for the next typed character. Returns the modifiers that were armed.
    public func consumeModifiers() -> (ctrl: Bool, alt: Bool) {
        let r = (ctrlArmed, altArmed)
        if ctrlArmed { tapped(.ctrl) }
        if altArmed { tapped(.alt) }
        return r
    }
}
