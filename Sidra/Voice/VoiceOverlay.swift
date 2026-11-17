#if os(macOS)
import SwiftUI
import SidraDesign

/// The listening card at the bottom of the window: level bars, the words so far, and what Return and
/// Esc do. Hidden when idle.
struct VoiceOverlay: View {
    @State private var voice = VoiceInput.shared
    @State private var window: NSWindow?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear.frame(width: 0, height: 0).background(WindowReader(window: $window))
            // Only the window that is dictating shows it; the keys go there too.
            if voice.isActive, window != nil, voice.window === window { card }
        }
    }

    private var card: some View {
        Group {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "mic.fill").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(voice.phase == .recording ? SidraColor.jade : SidraColor.muted)
                    bars
                    Spacer(minLength: 8)
                    Text(status).font(SidraFont.ui(12)).foregroundStyle(SidraColor.muted).lineLimit(2)
                }
                if !voice.partial.isEmpty {
                    Text(voice.partial).font(SidraFont.mono(13)).foregroundStyle(SidraColor.text)
                        .lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    if voice.phase == .recording {
                        Button("Insert ↩") { voice.finish(insert: true) }.buttonStyle(.sidraPrimary)
                        Button("Cancel ⎋") { voice.finish(insert: false) }.buttonStyle(.sidraSecondary)
                    } else if case .failed = voice.phase {
                        Button("Close") { voice.finish(insert: false) }.buttonStyle(.sidraSecondary)
                    } else if case .preparing = voice.phase {
                        Button("Cancel ⎋") { voice.finish(insert: false) }.buttonStyle(.sidraSecondary)
                    }
                    Spacer()
                    Text(voice.engine == .whisper && voice.whisperOnDisk ? "Whisper, on this Mac" : "Apple dictation, on this Mac")
                        .font(SidraFont.ui(11.5)).foregroundStyle(SidraColor.dim)
                }
            }
            .padding(14)
            .frame(maxWidth: 520)
            .background(SidraColor.popup, in: RoundedRectangle(cornerRadius: SidraRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: SidraRadius.card, style: .continuous).strokeBorder(SidraColor.hairline2))
            .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
            .padding(.horizontal, 16)   // a narrow window keeps the card inside it
            .padding(.bottom, 28)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Dictation")
        }
    }

    private var status: String {
        switch voice.phase {
        case .idle: ""
        case .preparing(let s): s
        case .recording: String(format: "%d:%02d · ", Int(voice.elapsed) / 60, Int(voice.elapsed) % 60)
            + (voice.hasTarget ? "Return inserts at the cursor" : "No terminal has focus: Return copies it")
        case .transcribing: "Writing it out…"
        case .failed(let s): s
        }
    }

    /// The last levels as bars, quietest at the floor.
    private var bars: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(voice.levels.suffix(32).enumerated()), id: \.offset) { _, v in
                Capsule().fill(SidraColor.jade.opacity(0.85)).frame(width: 3, height: 3 + CGFloat(v) * 18)
            }
        }
        .frame(height: 22, alignment: .center)
        .accessibilityHidden(true)
    }
}

/// The NSWindow a SwiftUI view sits in.
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?
    func makeNSView(context: Context) -> NSView { Probe(window: $window) }
    func updateNSView(_ v: NSView, context: Context) {}
    final class Probe: NSView {
        @Binding var found: NSWindow?
        init(window: Binding<NSWindow?>) { _found = window; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); let w = window; DispatchQueue.main.async { self.found = w } }
    }
}

/// The title bar's mic: starts dictation, or inserts what was said.
struct VoiceButton: View {
    @State private var voice = VoiceInput.shared
    var body: some View {
        Button { voice.toggle() } label: {
            Group {
                if voice.isBusy { GradientSpinner(size: 13) }
                else {
                    Image(systemName: voice.phase == .recording ? "mic.fill" : "mic")
                        .font(.system(size: 15))
                        .foregroundStyle(voice.phase == .recording ? SidraColor.jade : SidraColor.muted)
                }
            }
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(voice.isBusy)
        .help(voice.isBusy ? "Getting ready…" : "Dictate into the terminal (⌥⌘V)")
        .accessibilityLabel(voice.isBusy ? "Dictation getting ready" : voice.phase == .recording ? "Insert dictation" : "Dictate")
    }
}
#endif
