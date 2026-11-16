import XCTest
import SidraSSH
@testable import Sidra

final class SSHKeyLifecycleTests: XCTestCase {
    /// An empty key index is a real state: nothing is regenerated behind the user's back.
    func testDeletingEveryKeyDoesNotRegenerateTheDefault() throws {
        guard let url = SSHKeyManager.indexURL else { throw XCTSkip("no App Support") }
        let backup = try? Data(contentsOf: url)
        defer { if let backup { try? backup.write(to: url) } else { try? FileManager.default.removeItem(at: url) } }
        for k in SSHKeyManager.keys() where k.name == "lifecycle-test" { SSHKeyManager.delete(k.id) }
        let k = try SSHKeyManager.generate(name: "lifecycle-test")
        XCTAssertNotNil(SSHKeyManager.record(id: k.id))
        SSHKeyManager.delete(k.id)
        XCTAssertThrowsError(try SSHKeyManager.privateKey(id: k.id))
        // Remove every remaining record from the index: the default must not come back on read.
        try Data("[]".utf8).write(to: url)
        XCTAssertTrue(SSHKeyManager.keys().isEmpty)
        XCTAssertThrowsError(try SSHKeyManager.privateKey(id: nil))
    }
}
