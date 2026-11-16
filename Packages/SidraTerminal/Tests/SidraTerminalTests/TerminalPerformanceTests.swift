import XCTest
@testable import SidraTerminal

/// Per-key cost of the VT path: encode the key, feed the echoed byte, build a frame.
/// Simulator numbers are indicative only; the device run decides the 16 ms budget.
final class TerminalPerformanceTests: XCTestCase {
    func testKeyEncodeFeedFramePerKey() {
        let e = GhosttyEngine(cols: 200, rows: 50)
        e.feed(Data(String(repeating: "x", count: 200 * 40).utf8))
        let options = XCTMeasureOptions(); options.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: options) {
            for i in 0..<1000 {
                let bytes = e.encode(.text(String(UnicodeScalar(UInt8(97 + i % 26)))))
                e.feed(bytes)
                _ = e.frame(force: true)
            }
        }
    }
}
