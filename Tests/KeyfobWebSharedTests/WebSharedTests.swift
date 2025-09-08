import XCTest
@testable import KeyfobWebShared

final class WebSharedTests: XCTestCase {
    func testModuleExists() {
        _ = KeyfobWebRuntime.self
    }
}
