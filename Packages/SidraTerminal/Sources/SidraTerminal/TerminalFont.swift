#if os(macOS)
import AppKit
import SidraDesign

/// The Mac terminal font: family and size in UserDefaults, shared by every pane and changed live
/// (Settings, ⌘+ ⌘− ⌘0). The default is the user's own terminal font when Ghostty is set up
/// (font-family, font-size, adjust-cell-height), else JetBrains Mono 14.
public enum TerminalFont {
    public static let familyKey = "sidra.terminalFontFamily"
    public static let sizeKey = "sidra.terminalFontSize"
    public static let sizes: ClosedRange<CGFloat> = 8...40

    public struct Defaults: Sendable { public var family: String; public var size: CGFloat; public var extraLineHeight: CGFloat }
    /// Read once: Ghostty's config, if any, else Sidra's own font.
    public static let defaults: Defaults = {
        var d = Defaults(family: "JetBrains Mono", size: 14, extraLineHeight: 0)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [home.appending(path: ".config/ghostty/config"),
                     home.appending(path: "Library/Application Support/com.mitchellh.ghostty/config")]
        for url in paths {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let c = GhosttyConfig(text)
            if let f = c.first("font-family"), NSFont(name: f, size: 12) != nil || NSFontManager.shared.availableMembers(ofFontFamily: f) != nil { d.family = f }
            if let s = c.first("font-size").flatMap(Double.init), s > 0 { d.size = CGFloat(s) }
            // Only the absolute form (points); a percentage is left at the font's own height.
            if let a = c.first("adjust-cell-height"), !a.hasSuffix("%"), let v = Double(a) { d.extraLineHeight = CGFloat(v) }
            break
        }
        return d
    }()

    public static var family: String { UserDefaults.standard.string(forKey: familyKey) ?? defaults.family }
    public static var size: CGFloat {
        let s = UserDefaults.standard.double(forKey: sizeKey)
        return s > 0 ? CGFloat(s) : defaults.size
    }

    public static func setSize(_ s: CGFloat) { UserDefaults.standard.set(Double(min(max(s, sizes.lowerBound), sizes.upperBound)), forKey: sizeKey) }
    public static func step(_ by: CGFloat) { setSize(size + by) }
    public static func resetSize() { UserDefaults.standard.removeObject(forKey: sizeKey) }
    public static func setFamily(_ f: String?) { UserDefaults.standard.set(f, forKey: familyKey) }

    /// Installed fixed-pitch families, for the Settings picker.
    public static var monospacedFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.filter { fam in
            guard let first = NSFontManager.shared.availableMembers(ofFontFamily: fam)?.first, let name = first[0] as? String,
                  let font = NSFont(name: name, size: 12) else { return false }
            return font.isFixedPitch
        }
    }

    /// Regular and bold faces of `family` at `size`; falls back to the bundled font, then the system mono.
    static func faces(family: String, size: CGFloat) -> (regular: NSFont, bold: NSFont) {
        let fm = NSFontManager.shared
        let regular = fm.font(withFamily: family, traits: [], weight: 5, size: size)
            ?? NSFont(name: "JetBrainsMono-Regular", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        let bold = fm.convert(regular, toHaveTrait: .boldFontMask)
        return (regular, bold.fontDescriptor.symbolicTraits.contains(.bold) ? bold : .monospacedSystemFont(ofSize: size, weight: .bold))
    }
}

/// `key = value` lines of a Ghostty config; the first value per key.
struct GhosttyConfig {
    private var values: [String: String] = [:]
    init(_ text: String) {
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.hasPrefix("#"), let eq = l.firstIndex(of: "=") else { continue }
            let key = l[..<eq].trimmingCharacters(in: .whitespaces)
            var value = l[l.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            if values[key] == nil, !value.isEmpty { values[key] = value }
        }
    }
    func first(_ key: String) -> String? { values[key] }
}
#endif
