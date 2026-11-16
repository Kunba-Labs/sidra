import Foundation
import Observation
import UIKit

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

    private var grace = UIBackgroundTaskIdentifier.invalid
    /// iPadOS allows about 30 s after leaving: enough for a short build to finish and notify.
    /// ponytail: longer runs need BGContinuedProcessingTask, which needs the device VM (M5).
    func beginGrace() {
        guard !ids.isEmpty, grace == .invalid else { return }
        grace = UIApplication.shared.beginBackgroundTask(withName: "sidra.busy") { [weak self] in MainActor.assumeIsolated { self?.endGrace() } }
    }
    func endGrace() {
        guard grace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(grace)
        grace = .invalid
    }
    func isBusy(_ id: UUID) -> Bool { ids.contains(id) }
}
