import Foundation
import CloudKit
import Observation
import SidraDesign

/// iCloud sync of what you teach Sidra (Waseem, 2026-11-28): quick prompts and the keyboard's learning (your
/// words and which follows which, learned commands, swipe picks), across every Sidra signed in to your iCloud.
///
/// Each device keeps one record in your private CloudKit database (container iCloud.nl.sadiq.sidra, zone
/// "Sidra"), a JSON payload. A sync reads every device's record and merges: counts take the larger value (two
/// devices that learned the same word do not double it), quick prompts take the newest edit, so a deleted
/// prompt stays deleted. Then it writes this device's merged state back.
///
/// Off on the Mac for now: its Developer ID build (tools/package-mac.py) is signed without a provisioning
/// profile, and an iCloud entitlement without one stops the app from launching.
@MainActor @Observable
final class CloudSync {
    static let shared = CloudSync()
    static let containerID = "iCloud.nl.sadiq.sidra"

    /// The app carries the iCloud entitlement (project.yml). Without it, touching CloudKit ends the app.
    /// ponytail: a flag, flipped once the container exists in the developer portal.
    static let entitled = false

    static var enabled: Bool {
        guard entitled else { return false }
        #if DEBUG
        if DemoMode.isOn { return false }
        #endif
        return !Platform.isMac
    }

    /// For Settings: when the last sync finished, or why it did not.
    private(set) var lastSynced: Date? = UserDefaults.standard.object(forKey: "sidra.syncAt") as? Date
    private(set) var problem: String?

    @ObservationIgnored private var running = false
    @ObservationIgnored private lazy var container = CKContainer(identifier: Self.containerID)
    private let zone = CKRecordZone.ID(zoneName: "Sidra")

    /// This installation's record name, made once.
    private var device: String {
        if let d = UserDefaults.standard.string(forKey: "sidra.syncDevice") { return d }
        let d = UUID().uuidString
        UserDefaults.standard.set(d, forKey: "sidra.syncDevice")
        return d
    }

    struct Payload: Codable {
        var quickPrompts: String?
        var quickPromptsAt: Date?
        var learned: [String: Int] = [:]
        var swipe: [String: Int] = [:]
        var words: [String: Int] = [:]
        var pairs: [String: [String: Int]] = [:]
    }

    /// At launch, on coming to the front and on going to the back. Runs one at a time, at most every 20 s.
    func sync(force: Bool = false) {
        guard Self.enabled, !running else { return }
        if !force, let last = lastSynced, Date().timeIntervalSince(last) < 20 { return }
        running = true
        Task {
            defer { running = false }
            do {
                guard try await container.accountStatus() == .available else { problem = "Sign in to iCloud to sync."; return }
                let db = container.privateCloudDatabase
                if !UserDefaults.standard.bool(forKey: "sidra.syncZone") {
                    _ = try await db.modifyRecordZones(saving: [CKRecordZone(zoneID: zone)], deleting: [])
                    UserDefaults.standard.set(true, forKey: "sidra.syncZone")
                }
                for p in try await fetchAll(db) { Self.merge(p) }
                try await save(Self.local(), to: db)
                lastSynced = Date(); problem = nil
                UserDefaults.standard.set(lastSynced, forKey: "sidra.syncAt")
            } catch let e as CKError where e.code == .zoneNotFound || e.code == .userDeletedZone {
                UserDefaults.standard.set(false, forKey: "sidra.syncZone")   // made again next time
                problem = "iCloud data was reset. Syncing again."
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func fetchAll(_ db: CKDatabase) async throws -> [Payload] {
        var out: [Payload] = [], token: CKServerChangeToken?, more = true
        while more {
            let r = try await db.recordZoneChanges(inZoneWith: zone, since: token)
            for case .success(let m) in r.modificationResultsByID.values {
                guard m.record.recordType == "Prefs", let url = (m.record["payload"] as? CKAsset)?.fileURL,
                      let d = try? Data(contentsOf: url), let p = try? JSONDecoder().decode(Payload.self, from: d) else { continue }
                out.append(p)
            }
            token = r.changeToken; more = r.moreComing
        }
        return out
    }

    private func save(_ p: Payload, to db: CKDatabase) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sidra-sync-\(UUID().uuidString).json")
        try JSONEncoder().encode(p).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let r = CKRecord(recordType: "Prefs", recordID: CKRecord.ID(recordName: device, zoneID: zone))
        r["payload"] = CKAsset(fileURL: url)
        r["device"] = Platform.deviceName
        _ = try await db.modifyRecords(saving: [r], deleting: [], savePolicy: .allKeys)   // only this device writes this record
    }

    // MARK: Local state

    static func local() -> Payload {
        let d = UserDefaults.standard
        let w = WordModel.shared.counts()
        var p = Payload(quickPrompts: d.string(forKey: "sidra.quickPrompts"), quickPromptsAt: d.object(forKey: "sidra.quickPromptsAt") as? Date,
                        words: w.words, pairs: w.pairs)
        #if os(iOS) || os(visionOS)
        p.learned = FloatingKeyboard.shared.learnedCounts; p.swipe = FloatingKeyboard.shared.swipeHistory
        #endif
        return p
    }

    static func merge(_ p: Payload) {
        let d = UserDefaults.standard
        if let at = p.quickPromptsAt, let list = p.quickPrompts, at > (d.object(forKey: "sidra.quickPromptsAt") as? Date ?? .distantPast) {
            d.set(list, forKey: "sidra.quickPrompts")   // the sheet's @AppStorage follows
            d.set(at, forKey: "sidra.quickPromptsAt")
        }
        #if os(iOS) || os(visionOS)
        FloatingKeyboard.shared.mergeSynced(learned: p.learned, swipe: p.swipe)
        #endif
        WordModel.shared.merge(words: p.words, pairs: p.pairs)
    }

    /// The larger count of each key: devices that learned the same thing do not add it twice.
    nonisolated static func maxMerge(_ a: inout [String: Int], _ b: [String: Int]) {
        for (k, v) in b where v > a[k] ?? 0 { a[k] = v }
    }
}
