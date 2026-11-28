#if os(iOS) || os(visionOS)
import SwiftUI
import UIKit
import SidraDesign

/// The card over the bottom of a terminal for a `TerminalNote`: its text, and one large button per choice.
struct TerminalNoteCard: View {
    let note: TerminalNote
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let tag = note.tag {
                Label(tag, systemImage: "lightbulb").font(SidraFont.ui(12, weight: .bold)).foregroundStyle(SidraColor.gold)
            }
            if !note.text.isEmpty {
                ScrollView { Text(note.text).font(SidraFont.ui(14)).foregroundStyle(SidraColor.text).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 160).fixedSize(horizontal: false, vertical: true)
            }
            // Side by side when they fit, else stacked.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                VStack(alignment: .leading, spacing: 8) { buttons }
            }
        }
        .padding(14)
        .background(SidraColor.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(SidraColor.gold.opacity(0.5)))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }

    @ViewBuilder private var buttons: some View {
        ForEach(note.choices, id: \.key) { c in
            Button(c.label) { pick(c.key) }
                .buttonStyle(SidraButtonStyle(c.key == "1" ? .primary : .secondary))   // the first choice leads
                .frame(minHeight: 44)
                .accessibilityIdentifier("terminal-note-\(c.key)")
        }
    }
}

#endif
