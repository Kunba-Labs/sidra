import XCTest
@testable import Sidra

/// iCloud sync's merge: counts take the larger value (no double counting), quick prompts the newest edit.
@MainActor final class CloudSyncTests: XCTestCase {
    func testCountsTakeTheLargerValue() {
        var a = ["git": 3, "cargo": 1]
        CloudSync.maxMerge(&a, ["git": 2, "cargo": 5, "herdr": 1])
        XCTAssertEqual(a, ["git": 3, "cargo": 5, "herdr": 1])
    }

    func testNewestQuickPromptsWin() {
        let d = UserDefaults.standard
        let keepList = d.string(forKey: "sidra.quickPrompts"), keepAt = d.object(forKey: "sidra.quickPromptsAt")
        defer { d.set(keepList, forKey: "sidra.quickPrompts"); d.set(keepAt, forKey: "sidra.quickPromptsAt") }
        d.set(#"["local"]"#, forKey: "sidra.quickPrompts"); d.set(Date(timeIntervalSince1970: 200), forKey: "sidra.quickPromptsAt")
        CloudSync.merge(.init(quickPrompts: #"["older"]"#, quickPromptsAt: Date(timeIntervalSince1970: 100)))
        XCTAssertEqual(d.string(forKey: "sidra.quickPrompts"), #"["local"]"#, "an older edit elsewhere does not replace this one")
        CloudSync.merge(.init(quickPrompts: #"["newer"]"#, quickPromptsAt: Date(timeIntervalSince1970: 300)))
        XCTAssertEqual(d.string(forKey: "sidra.quickPrompts"), #"["newer"]"#)
    }
}
