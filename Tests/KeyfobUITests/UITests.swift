import XCTest
@testable import KeyfobUI
@testable import KeyfobCore

final class UITests: XCTestCase {
    func testConsentViewInit() {
        let e = NostrEvent(kind: 1, pubkey: "abc", created_at: 0, tags: [], content: "hello", id: nil, sig: nil)
        _ = ConsentView(origin: "example.com", event: e, onApprove: { _ in }, onDeny: { })
    }

    func testConsentViewWithComplexEvent() {
        let e = NostrEvent(
            kind: 42,
            pubkey: "aabbccdd",
            created_at: 1700000000,
            tags: [["p", "xyz"], ["e", "123"]],
            content: "Complex content with \"quotes\" and\nnewlines",
            id: nil,
            sig: nil
        )
        var approvedDecision: ConsentDecision?
        var denied = false

        _ = ConsentView(
            origin: "nostr.example.com",
            event: e,
            onApprove: { decision in approvedDecision = decision },
            onDeny: { denied = true },
            onError: { msg in XCTFail("Unexpected error: \(msg)") }
        )

        // View should construct without crashing for complex events
        XCTAssertNil(approvedDecision)
        XCTAssertFalse(denied)
    }

    func testConsentDecisionValues() {
        let decision = ConsentDecision(useSession: true, ttl: 300)
        XCTAssertTrue(decision.useSession)
        XCTAssertEqual(decision.ttl, 300)

        let perRequest = ConsentDecision(useSession: false, ttl: 0)
        XCTAssertFalse(perRequest.useSession)
    }
}
