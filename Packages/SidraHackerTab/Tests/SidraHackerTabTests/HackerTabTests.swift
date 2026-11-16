import XCTest
@testable import SidraHackerTab

final class HackerTabTests: XCTestCase {
    func testCommentHTMLBecomesText() {
        let a = HN.attributed("a &amp; b &#x27;c&#x27;<p>d <i>e</i> <a href=\"https:&#x2F;&#x2F;x.io\">x</a>")
        XCTAssertEqual(String(a.characters), "a & b 'c'\n\nd e x")
        XCTAssertTrue(a.runs.contains { $0.link == URL(string: "https://x.io") })
    }

    func testDotOnlyForStoriesNotSeenBefore() {
        XCTAssertFalse(HackerNews.isFresh([1, 2, 3], seen: [1, 2, 3, 4]), "a story dropping out is not news")
        XCTAssertFalse(HackerNews.isFresh([3, 1, 2], seen: [1, 2, 3]), "reordering is not news")
        XCTAssertTrue(HackerNews.isFresh([1, 2, 5], seen: [1, 2, 3]), "a new story in the top 30 is")
    }
}
