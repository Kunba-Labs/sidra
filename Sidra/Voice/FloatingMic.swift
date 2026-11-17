import SwiftUI
import SidraDesign
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The floating green mic at the window's bottom right, on iPad and Mac: hold to talk, release to
/// insert at the terminal's cursor, slide left to cancel. Above it while listening: the words so far
/// over a live spectrogram. Shown while a terminal or herdr pane has focus, and while dictating.
struct FloatingMic: View {
    let showMic: Bool
    @State private var voice = VoiceInput.shared
    @State private var window: PlatformWindow?

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            // Only the window that is dictating shows the card.
            if voice.isActive, window != nil, voice.window === window || voice.window == nil {
                VoiceCard(voice: voice)
                    .frame(maxWidth: 520)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if showMic || (voice.isActive && voice.window === window) {
                MicKey(voice: voice, window: window)
            }
        }
        .padding(.trailing, 24).padding(.bottom, 24 + SidraSpace.paneFooterHeight).padding(.leading, 16)   // above the pane footer
        .background(WindowReader(window: $window).frame(width: 0, height: 0))
        .animation(.easeOut(duration: 0.18), value: voice.isActive)
    }
}

/// The round green key: hold to talk, release to insert, slide left to cancel.
struct MicKey: View {
    let voice: VoiceInput
    let window: PlatformWindow?
    @State private var holding = false

    var body: some View {
        let recording = voice.phase == .recording
        Group {
            if voice.isBusy { GradientSpinner(size: 16) }
            else { Image(systemName: voice.cancelling ? "xmark" : "mic.fill").font(.system(size: 18)) }
        }
        .foregroundStyle(voice.isBusy ? SidraColor.text : Color(hex: 0x06140e))
        .frame(width: 48, height: 48)
        .background(voice.cancelling ? SidraColor.red : voice.isBusy ? SidraColor.raised : recording ? Color(hex: 0x7ff0bd) : SidraColor.jade,
                    in: Circle())
        .overlay(Circle().strokeBorder(SidraColor.jade.opacity(voice.isBusy ? 0.5 : 0), lineWidth: 1.5))
        .overlay(Circle().strokeBorder(SidraColor.jade.opacity(recording ? 0.35 : 0), lineWidth: 4).padding(-4))
        .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                if !holding { holding = true; voice.press(in: window) }
                if voice.phase == .recording { voice.cancelling = v.translation.width < -70 }
            }
            .onEnded { _ in holding = false; voice.release(cancel: voice.cancelling) })
        .accessibilityLabel(recording ? "Stop and insert" : "Hold to talk")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { recording ? voice.release(cancel: false) : voice.press(in: window) }   // VoiceOver: tap to start, tap again to stop
        .help("Hold to talk; release to insert at the cursor, slide left to cancel")
    }
}

/// While listening: the words so far over a spectrogram. Before that, getting ready; after a failure, why.
struct VoiceCard: View {
    let voice: VoiceInput

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch voice.phase {
            case .preparing(let s):
                HStack(spacing: 10) {
                    GradientSpinner(size: 14)
                    Text(s).font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted)
                }
            case .failed(let why):
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 15)).foregroundStyle(SidraColor.yellow)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Voice input stopped").font(SidraFont.ui(14, weight: .bold)).foregroundStyle(SidraColor.text)
                        Text(why).font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted).fixedSize(horizontal: false, vertical: true)
                        Button("Close") { voice.dismissMessage() }.buttonStyle(.sidraSecondary)
                    }
                }
            default:
                Text(voice.partial.isEmpty ? "Listening…" : voice.partial)
                    .font(SidraFont.mono(14)).foregroundStyle(voice.partial.isEmpty ? SidraColor.muted : SidraColor.text)
                    .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading).frame(height: 60, alignment: .topLeading)
                Spectrogram(columns: voice.columns).frame(height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(SidraColor.hairline))
                HStack {
                    Text(voice.phase == .transcribing ? "writing it out"
                         : voice.hasTarget ? "release to insert" : "release to copy (no terminal has focus)").foregroundStyle(SidraColor.muted)
                    Spacer()
                    Text("slide left to cancel").foregroundStyle(SidraColor.dim)
                }
                .font(SidraFont.ui(11))
            }
        }
        .padding(14)
        .background(SidraColor.popup, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(SidraColor.hairline2))
        .shadow(color: .black.opacity(0.55), radius: 30, y: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dictation")
    }
}

/// Time runs right to left like a tape: the newest sound enters at the right edge.
struct Spectrogram: View {
    let columns: [[Float]]
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0x0f1216)))
            let n = VoiceInput.maxColumns, bins = VoiceInput.bins
            let cw = size.width / CGFloat(n), rh = size.height / CGFloat(bins)
            let start = n - columns.count
            for (i, col) in columns.enumerated() {
                let x = CGFloat(start + i) * cw
                for (b, v) in col.enumerated() where v > 0.04 {
                    let a = Double(pow(v, 0.8))
                    let c = Color(red: (15 + a * 112) / 255, green: (18 + a * 222) / 255, blue: (22 + a * 167) / 255)
                    ctx.fill(Path(CGRect(x: x, y: size.height - CGFloat(b + 1) * rh, width: cw + 0.5, height: rh + 0.5)), with: .color(c))
                }
            }
            ctx.fill(Path(CGRect(x: size.width - 3, y: 0, width: 3, height: size.height)), with: .color(SidraColor.jade.opacity(0.5)))
        }
        .accessibilityHidden(true)
    }
}

/// The window a SwiftUI view sits in.
private struct WindowReader: PlatformViewRepresentable {
    @Binding var window: PlatformWindow?
    #if os(macOS)
    func makeNSView(context: Context) -> NSView { Probe(window: $window) }
    func updateNSView(_ v: NSView, context: Context) {}
    #else
    func makeUIView(context: Context) -> UIView { Probe(window: $window) }
    func updateUIView(_ v: UIView, context: Context) {}
    #endif
    final class Probe: PlatformView {
        @Binding var found: PlatformWindow?
        init(window: Binding<PlatformWindow?>) { _found = window; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        #if os(macOS)
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); let w = window; DispatchQueue.main.async { self.found = w } }
        #else
        override func didMoveToWindow() { super.didMoveToWindow(); let w = window; DispatchQueue.main.async { self.found = w } }
        #endif
    }
}
