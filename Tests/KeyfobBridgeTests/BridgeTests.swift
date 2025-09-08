import XCTest
@testable import KeyfobBridge

final class BridgeTests: XCTestCase {
    func testURLRouterRejectsInvalid() {
        XCTAssertThrowsError(try URLRouter.parse(URL(string: "keyfob://badhost")!))
    }
}
