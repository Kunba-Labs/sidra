import XCTest
import OSLog
import SidraDesign
import SidraSSH
@testable import Sidra

final class LifecycleTests: XCTestCase {
    @MainActor func testRedrawGateLimitsTo10HzAndZeroIsUnlimited() async throws {
        var draws = 0
        let gate = RedrawGate(interval: { 0.1 })
        for _ in 0..<100 { gate.request { draws += 1 }; try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertLessThanOrEqual(draws, 13)
        XCTAssertGreaterThanOrEqual(draws, 5)
        var all = 0
        let open = RedrawGate(interval: { 0 })
        for _ in 0..<50 { open.request { all += 1 } }
        XCTAssertEqual(all, 50)
    }

    func testRouteSurvivesUserInfo() {
        let id = UUID()
        XCTAssertEqual(Notifier.Route(userInfo: Notifier.Route.pane(id).userInfo), .pane(id))
        XCTAssertNil(Notifier.Route(userInfo: [:]))
    }

    func testVPNScopedKeys() {
        XCTAssertTrue(PlatformStatus.vpnActive(scoped: ["en0", "utun4"]) == false, "utun alone is every iPad's system tunnel prefix check")
        XCTAssertTrue(PlatformStatus.vpnActive(scoped: ["en0", "ipsec0"]))
        XCTAssertTrue(PlatformStatus.vpnActive(scoped: ["tun0"]))
        XCTAssertFalse(PlatformStatus.vpnActive(scoped: ["en0", "pdp_ip0"]))
    }

    func testDataLayoutExcludesFromBackup() throws {
        DataLayout.apply()
        for name in DataLayout.excluded {
            let v = try DataLayout.folder(name)!.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(v.isExcludedFromBackup, true, name)
        }
    }

    func testLogExportContainsThisProcess() throws {
        let marker = "sidra-export-\(UUID().uuidString)"
        Logger(subsystem: "nl.sadiq.sidra", category: "test").log("\(marker, privacy: .public)")
        Thread.sleep(forTimeInterval: 1)
        let text = try String(contentsOf: LogExport.write(), encoding: .utf8)
        XCTAssertTrue(text.contains(marker))
    }
}
