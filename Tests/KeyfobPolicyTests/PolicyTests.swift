import XCTest
@testable import KeyfobPolicy

final class PolicyTests: XCTestCase {
    func testPreflightNoThrow() throws {
        // For now, preflight is a no-op
        XCTAssertNoThrow(try PolicyEngine.shared.preflight(origin: "test"))
    }
}
