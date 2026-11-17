import Foundation
import Observation
import SidraDesign
#if canImport(UIKit)
import UIKit
#endif

/// Pane ids with a live process (PTY, build, agent run, serial connection). Closing one asks
/// first. A pane marks itself with two lines:
///     .onChange(of: isRunning, initial: true) { BusyPanes.shared.set(pane.id, busy: isRunning) }
///     .onDisappear { BusyPanes.shared.set(pane.id, busy: false) }
@MainActor
@Observable
final class BusyPanes {
    static let shared = BusyPanes()
    private(set) var ids: Set<UUID> = []
    func set(_ id: UUID, busy: Bool) {
        if busy { ids.insert(id) } else { ids.remove(id) }
        if ids.isEmpty { endGrace() }
    }

    private var grace: Int?
    /// iPadOS allows about 30 s after leaving: enough for a short build to finish and notify.
    /// ponytail: longer runs need BGContinuedProcessingTask, which needs the device VM (M5).
    func beginGrace() {
        guard !ids.isEmpty, grace == nil else { return }
        grace = Platform.beginBackgroundTask("sidra.busy") { [weak self] in self?.endGrace() }
    }
    func endGrace() {
        guard let g = grace else { return }
        Platform.endBackgroundTask(g)
        grace = nil
    }
    func isBusy(_ id: UUID) -> Bool { ids.contains(id) }
}
