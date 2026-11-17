import SwiftUI
import SidraDesign

/// One failure presentation for every flow (spec F11 last row).
///
///     @State private var alert: SidraAlert?
///     ... .sidraAlert($alert)
///     alert = SidraAlert(title: "Flash failed", detail: "esptool could not open the port.",
///                        rawOutput: transcript, primaryLabel: "Retry") { flash() }
///
/// `title` says what failed, `detail` says what to do next in plain words, `rawOutput` is the
/// tool's text behind "Show details" with Copy, `primaryLabel` is the one next step (nil = Done only).
struct SidraAlert: Identifiable {
    let id = UUID()
    var title: String
    var detail: String
    var rawOutput: String? = nil
    var primaryLabel: String? = nil
    var primary: (() -> Void)? = nil
    /// A second way out, for failures with two honest next steps (Retry, Switch model).
    var secondaryLabel: String? = nil
    var secondary: (() -> Void)? = nil

    /// Convenience for a thrown error: the error's description is the detail, no raw output.
    static func from(_ error: Error, title: String, primaryLabel: String? = nil, primary: (() -> Void)? = nil) -> SidraAlert {
        let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return SidraAlert(title: title, detail: String(lines.first ?? ""), rawOutput: lines.count > 1 ? text : nil, primaryLabel: primaryLabel, primary: primary)
    }
}

extension View {
    func sidraAlert(_ item: Binding<SidraAlert?>) -> some View {
        sheet(item: item) { a in SidraAlertSheet(alert: a) }
    }
}

private struct SidraAlertSheet: View {
    let alert: SidraAlert
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        SidraAlertBody(alert: alert) { dismiss() }
            .padding(22)
            .frame(width: 480)
            .background(SidraColor.panel)
            .presentationBackground(SidraColor.panel)
    }
}

/// The alert itself: in the sheet above, or inline where a modal would block other panes (agent).
struct SidraAlertBody: View {
    let alert: SidraAlert
    let close: () -> Void
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(SidraColor.yellow)
                Text(alert.title).font(SidraFont.ui(17, weight: .bold)).foregroundStyle(SidraColor.text)
            }
            Text(alert.detail).font(SidraFont.ui(13)).foregroundStyle(SidraColor.muted).fixedSize(horizontal: false, vertical: true)
            if let raw = alert.rawOutput, !raw.isEmpty {
                Button(showDetails ? "Hide details" : "Show details") { showDetails.toggle() }
                    .font(SidraFont.ui(12, weight: .bold)).foregroundStyle(SidraColor.muted).buttonStyle(.plain)
                if showDetails {
                    ScrollView {
                        Text(raw).font(SidraFont.mono(11.5)).foregroundStyle(SidraColor.terminalText).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                    .frame(maxHeight: 220)
                    .background(Color(hex: 0x0f1216), in: RoundedRectangle(cornerRadius: 8))
                    Button("Copy") { Platform.pasteString = raw }.buttonStyle(.sidraSecondary)
                }
            }
            HStack {
                Spacer()
                Button("Done") { close() }.buttonStyle(.sidraSecondary)
                if let label = alert.secondaryLabel {
                    Button(label) { close(); alert.secondary?() }.buttonStyle(.sidraSecondary)
                }
                if let label = alert.primaryLabel {
                    Button(label) { close(); alert.primary?() }.buttonStyle(.sidraPrimary)
                }
            }.padding(.top, 4)
        }
    }
}
