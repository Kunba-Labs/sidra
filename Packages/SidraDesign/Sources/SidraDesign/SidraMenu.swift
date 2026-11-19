import SwiftUI

/// One row of a `SidraMenu`.
public struct SidraMenuItem: Identifiable {
    public let id = UUID()
    public var title: String
    public var systemImage: String?
    public var identifier: String?
    public var action: () -> Void
    public init(_ title: String, systemImage: String? = nil, identifier: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.identifier = identifier; self.action = action
    }
}

/// A titled group of rows; sections are split by a hairline.
public struct SidraMenuSection: Identifiable {
    public let id = UUID()
    public var title: String?
    public var items: [SidraMenuItem]
    public init(_ title: String? = nil, _ items: [SidraMenuItem]) { self.title = title; self.items = items }
}

/// Sidra's dropdown: a plain trigger and a popover in the app's own surfaces, the same on iPad and
/// Mac (the system menu draws a grey bezel and its own material on the Mac). Keyboard as in a system
/// menu: ↑ ↓ move, Return picks, typing jumps to the first row that starts with the typed letters, Esc closes.
public struct SidraMenu<Label: View>: View {
    let sections: [SidraMenuSection]
    @ViewBuilder let label: () -> Label
    @State private var open = false

    public init(_ sections: [SidraMenuSection], @ViewBuilder label: @escaping () -> Label) {
        self.sections = sections; self.label = label
    }

    public var body: some View {
        Button { open.toggle() } label: { label() }
            .buttonStyle(.plain)
            // No arrowEdge: a pinned edge opens above even with no room there (the herdr bar near the
            // top of the screen squeezed the + menu into a scroll); the system picks the side with space.
            .popover(isPresented: $open) {
                SidraMenuList(sections: sections) { open = false }
                    .presentationCompactAdaptation(.popover)
                    .presentationBackground(SidraColor.popup)
            }
    }
}

/// The popover body, also usable inside other popovers.
public struct SidraMenuList: View {
    let sections: [SidraMenuSection]
    let close: () -> Void
    /// The highlighted row: hover and the arrow keys move the same one.
    @State private var selected: UUID?
    @State private var typed = ""
    @State private var typedAt = Date.distantPast
    @FocusState private var focused: Bool

    public init(sections: [SidraMenuSection], close: @escaping () -> Void) { self.sections = sections; self.close = close }

    private var items: [SidraMenuItem] { sections.flatMap(\.items) }

    public var body: some View {
        // Long lists (font families) scroll; the keyboard highlight is kept in view.
        ScrollViewReader { scroller in
        ScrollView {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.element.id) { i, section in
                if i > 0 { Rectangle().fill(SidraColor.hairline2).frame(height: 1).padding(.vertical, 5).padding(.horizontal, 8) }
                if let t = section.title {
                    Text(t).font(SidraFont.ui(11.5, weight: .bold)).foregroundStyle(SidraColor.dim)
                        .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(section.items) { item in
                    Row(item: item, on: selected == item.id, hover: { if $0 { selected = item.id } }) { pick(item) }.id(item.id)
                }
            }
        }
        .padding(6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onChange(of: selected) { _, id in if let id { scroller.scrollTo(id) } }
        }
        .frame(minWidth: 200, maxHeight: 440, alignment: .leading)
        .fixedSize(horizontal: false, vertical: items.count <= 12)
        .background(SidraColor.popup)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) { if let item = items.first(where: { $0.id == selected }) { pick(item) }; return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(characters: .alphanumerics.union(.whitespaces)) { press in find(press.characters); return .handled }
    }

    private func pick(_ item: SidraMenuItem) { close(); item.action() }

    /// One step, wrapping; from nothing, ↓ starts at the top and ↑ at the bottom.
    private func move(_ by: Int) {
        let all = items
        guard !all.isEmpty else { return }
        let i = all.firstIndex { $0.id == selected }.map { ($0 + by + all.count) % all.count } ?? (by > 0 ? 0 : all.count - 1)
        selected = all[i].id
    }

    /// Type-to-find: letters typed within a second add up; the first row whose title starts with them wins.
    private func find(_ chars: String) {
        if Date().timeIntervalSince(typedAt) > 1 { typed = "" }
        typed += chars.lowercased(); typedAt = Date()
        if let hit = items.first(where: { $0.title.lowercased().hasPrefix(typed) }) { selected = hit.id }
    }

    private struct Row: View {
        let item: SidraMenuItem
        let on: Bool
        let hover: (Bool) -> Void
        let pick: () -> Void
        var body: some View {
            Button(action: pick) {
                HStack(spacing: 10) {
                    if let s = item.systemImage {
                        Image(systemName: s).font(.system(size: 13)).foregroundStyle(SidraColor.muted).frame(width: 18)
                    }
                    Text(item.title).font(SidraFont.ui(13.5)).foregroundStyle(SidraColor.text)
                    Spacer(minLength: 12)
                }
                .padding(.horizontal, 10).frame(height: 32)
                .background(on ? SidraColor.tabActive : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)   // the list holds focus and handles the keys; rows are pointer and VoiceOver targets
            .onHover(perform: hover)
            .accessibilityIdentifier(item.identifier ?? item.title)
            .accessibilityAddTraits(on ? .isSelected : [])
        }
    }
}
