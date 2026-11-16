import XCTest
import SwiftUI
@testable import SidraDesign

final class TokensTests: XCTestCase {
    func testHexColorChannels() {
        let c = UIColor(hex: 0x5ad6a0)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(Int(round(r * 255)), 0x5a)
        XCTAssertEqual(Int(round(g * 255)), 0xd6)
        XCTAssertEqual(Int(round(b * 255)), 0xa0)
        XCTAssertEqual(a, 1)
    }
    func testGradientHasFourStopsInOrder() {
        XCTAssertEqual(SidraGradient.stops.map(\.location), [0, 0.4, 0.7, 1])
    }
}
