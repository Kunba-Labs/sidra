import XCTest
@testable import Sidra
import SidraWorkspace

final class SmokeTests: XCTestCase {
    /// Every kind on the new-tab sheet maps to a pane icon, and the six are the baseline's whole set.
    func testNewTabKindsCoverTheBaseline() {
        XCTAssertEqual(NewTabKind.allCases.map(\.rawValue), ["herdr", "ssh", "theasa", "pipelines", "hackertab", "chess"])
        XCTAssertEqual(Set(NewTabKind.allCases.map(\.icon)).count, 6)
    }

    /// HackerTab and Chess open once; a second request selects the open tab.
    @MainActor func testSingleTabsOpenOnce() {
        let app = AppModel()
        app.workspace = WorkspaceStore(state: WorkspaceState(), storageURL: nil)
        app.openSingle(.chess)
        app.openSingle(.hackertab)
        app.openSingle(.chess)
        XCTAssertEqual(app.workspace.tabs.map(\.icon), [.chess, .hackertab])
        XCTAssertEqual(app.workspace.activeTab?.icon, .chess)
    }
}
