import XCTest
@testable import KeyfobUI
@testable import KeyfobCore

final class UITests: XCTestCase {
    func testConsentViewInit() {
        let e = NostrEvent(kind: 1, pubkey: "abc", created_at: 0, tags: [], content: "hello", id: nil, sig: nil)
        _ = ConsentView(origin: "example.com", event: e, onApprove: { _ in }, onDeny: { })
    }
}
