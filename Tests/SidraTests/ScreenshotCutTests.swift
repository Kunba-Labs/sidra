import XCTest
import UIKit
@testable import Sidra

final class ScreenshotCutTests: XCTestCase {
    /// A triangle cut from a solid 100 × 80 image: cropped to the triangle's box, opaque inside, clear outside.
    func testCutKeepsTheShapeAndClearsTheRest() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let red = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 80), format: format).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
        }
        let cut = try XCTUnwrap(ScreenshotCut.cut(red, shape: [CGPoint(x: 10, y: 10), CGPoint(x: 70, y: 10), CGPoint(x: 10, y: 50)]))
        let cg = try XCTUnwrap(cut.cgImage)
        XCTAssertEqual(cg.width, 60)
        XCTAssertEqual(cg.height, 40)
        XCTAssertGreaterThan(alpha(cg, x: 5, y: 5), 250, "inside the triangle")
        XCTAssertLessThan(alpha(cg, x: 55, y: 35), 5, "outside the triangle")
        XCTAssertEqual(ScreenshotCut.cut(red, shape: [])?.cgImage?.width, 100, "no shape: the whole image")
    }

    private func alpha(_ cg: CGImage, x: Int, y: Int) -> UInt8 {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: -x, y: y - cg.height + 1, width: cg.width, height: cg.height))
        return px[3]
    }
}
