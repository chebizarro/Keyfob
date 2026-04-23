// ──────────────────────────────────────────────────────────────────
// PublishInspectorTests.swift — Tests for OK inspection and retry
// ──────────────────────────────────────────────────────────────────

import XCTest
@testable import KeyfobRelay

// MARK: - OKRejection Parsing Tests

final class OKRejectionTests: XCTestCase {

    func testParseDuplicate() {
        let r = OKRejection.parse("duplicate: already have this event")
        XCTAssertEqual(r, .duplicate("duplicate: already have this event"))
        XCTAssertFalse(r.isRetryable)
    }

    func testParseBlocked() {
        let r = OKRejection.parse("blocked: content policy")
        XCTAssertEqual(r, .blocked("blocked: content policy"))
        XCTAssertFalse(r.isRetryable)
    }

    func testParseRateLimited() {
        let r = OKRejection.parse("rate-limited: slow down")
        XCTAssertEqual(r, .rateLimited("rate-limited: slow down"))
        XCTAssertTrue(r.isRetryable)
    }

    func testParseInvalid() {
        let r = OKRejection.parse("invalid: bad signature")
        XCTAssertEqual(r, .invalid("invalid: bad signature"))
        XCTAssertFalse(r.isRetryable)
    }

    func testParseError() {
        let r = OKRejection.parse("error: internal server error")
        XCTAssertEqual(r, .error("error: internal server error"))
        XCTAssertTrue(r.isRetryable)
    }

    func testParseAuthRequired() {
        let r = OKRejection.parse("auth-required: need auth")
        XCTAssertEqual(r, .authRequired("auth-required: need auth"))
        XCTAssertTrue(r.isRetryable)
    }

    func testParseOther() {
        let r = OKRejection.parse("some unknown reason")
        XCTAssertEqual(r, .other("some unknown reason"))
        XCTAssertFalse(r.isRetryable)
    }

    func testParseEmpty() {
        let r = OKRejection.parse("")
        XCTAssertEqual(r, .other(""))
    }

    func testMessage() {
        let r = OKRejection.blocked("blocked: nope")
        XCTAssertEqual(r.message, "blocked: nope")
    }
}

// MARK: - PublishInspector Tests

final class PublishInspectorTests: XCTestCase {

    private var mockTransport: MockWebSocketTransport!
    private var connection: RelayConnection!
    private var inspector: PublishInspector!

    private let sampleEvent = RelayEvent(
        id: "pub-test-1", pubkey: "pk", created_at: 100,
        kind: 1, tags: [], content: "test", sig: "sig"
    )

    override func setUp() {
        super.setUp()
        mockTransport = MockWebSocketTransport()
        let transport = mockTransport!
        connection = RelayConnection(
            url: URL(string: "wss://test.relay")!,
            reconnectPolicy: .disabled,
            transportFactory: { _ in transport }
        )
        connection.connect()
        inspector = PublishInspector(connection: connection)
        inspector.publishTimeout = 2.0 // Fast for tests
        inspector.rateLimitBackoff = 0.1
        inspector.errorBaseBackoff = 0.05
        inspector.errorMaxRetries = 3
    }

    override func tearDown() {
        connection.disconnect()
        connection = nil
        mockTransport = nil
        inspector = nil
        super.tearDown()
    }

    // MARK: - Accepted

    func testPublishAccepted() async {
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.mockTransport.enqueue(#"["OK","pub-test-1",true,""]"#)
        }

        let outcome = await inspector.publish(event: sampleEvent)
        XCTAssertEqual(outcome, .accepted)
    }

    func testPublishCallbackFired() async {
        var captured: (RelayEvent, PublishOutcome, Int)?
        let lock = NSLock()
        inspector.onPublishResult = { event, outcome, attempt in
            lock.lock()
            captured = (event, outcome, attempt)
            lock.unlock()
        }

        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.mockTransport.enqueue(#"["OK","pub-test-1",true,""]"#)
        }

        let outcome = await inspector.publish(event: sampleEvent)
        XCTAssertEqual(outcome, .accepted)

        lock.lock()
        XCTAssertEqual(captured?.0.id, "pub-test-1")
        XCTAssertEqual(captured?.1, .accepted)
        XCTAssertEqual(captured?.2, 1)
        lock.unlock()
    }

    // MARK: - Duplicate (benign)

    func testDuplicateTreatedAsAccepted() async {
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.mockTransport.enqueue(#"["OK","pub-test-1",false,"duplicate: already have this event"]"#)
        }

        let outcome = await inspector.publish(event: sampleEvent)
        XCTAssertEqual(outcome, .accepted)
    }

    // MARK: - Blocked (no retry)

    func testBlockedNotRetried() async {
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.mockTransport.enqueue(#"["OK","pub-test-1",false,"blocked: content policy"]"#)
        }

        let outcome = await inspector.publish(event: sampleEvent)
        XCTAssertEqual(outcome, .rejected(.blocked("blocked: content policy")))
    }

    // MARK: - Invalid (no retry)

    func testInvalidNotRetried() async {
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.mockTransport.enqueue(#"["OK","pub-test-1",false,"invalid: bad signature"]"#)
        }

        let outcome = await inspector.publish(event: sampleEvent)
        XCTAssertEqual(outcome, .rejected(.invalid("invalid: bad signature")))
    }

    // MARK: - Rate Limited (retry once)

    func testRateLimitedRetriedOnce() async {
        var okCount = 0
        let okLock = NSLock()

        // First: rate-limited, second: accepted
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.mockTransport.enqueue(#"["OK","pub-test-1",false,"rate-limited: slow down"]"#)
            // After retry backoff, the second publish sends another EVENT
            // and we need to send OK for it too
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.mockTransport.enqueue(#"["OK","pub-test-1",true,""]"#)
        }

        inspector.onPublishResult = { _, outcome, attempt in
            okLock.lock()
            okCount += 1
            okLock.unlock()
        }

        let outcome = await inspector.publish(event: sampleEvent)
        XCTAssertEqual(outcome, .accepted)
    }

    func testRateLimitedFailsAfterOneRetry() async {
        // Both attempts return rate-limited
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.mockTransport.enqueue(#"["OK","pub-test-1",false,"rate-limited: slow down"]"#)
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.mockTransport.enqueue(#"["OK","pub-test-1",false,"rate-limited: still too fast"]"#)
        }

        let outcome = await inspector.publish(event: sampleEvent)
        XCTAssertEqual(outcome, .rejected(.rateLimited("rate-limited: still too fast")))
    }

    // MARK: - Error (retry with backoff)

    func testErrorRetriedWithBackoff() async {
        // First two: error, third: accepted
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.mockTransport.enqueue(#"["OK","pub-test-1",false,"error: internal"]"#)
            try? await Task.sleep(nanoseconds: 200_000_000)
            self.mockTransport.enqueue(#"["OK","pub-test-1",false,"error: still broken"]"#)
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.mockTransport.enqueue(#"["OK","pub-test-1",true,""]"#)
        }

        let outcome = await inspector.publish(event: sampleEvent)
        XCTAssertEqual(outcome, .accepted)
    }

    func testErrorExhaustsRetries() async {
        // All 4 attempts (1 initial + 3 retries) return error
        Task {
            for i in 0..<4 {
                try? await Task.sleep(nanoseconds: UInt64((100 + i * 200) * 1_000_000))
                self.mockTransport.enqueue(#"["OK","pub-test-1",false,"error: fail \#(i)"]"#)
            }
        }

        let outcome = await inspector.publish(event: sampleEvent)
        if case .rejected(.error) = outcome {
            // Expected
        } else {
            XCTFail("Expected .rejected(.error), got \(outcome)")
        }
    }

    // MARK: - Timeout

    func testTimeoutWhenNoOK() async {
        inspector.publishTimeout = 0.3 // 300ms

        let outcome = await inspector.publish(event: sampleEvent)
        XCTAssertEqual(outcome, .timeout)
    }

    // MARK: - Auth Required (wait for auth, retry)

    func testAuthRequiredWaitsAndRetries() async {
        // Set up a mock signer
        let signer = MockAuthSigner()
        connection.authSigner = signer

        // First: auth-required rejection
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.mockTransport.enqueue(#"["OK","pub-test-1",false,"auth-required: authenticate first"]"#)
            // Relay sends AUTH challenge
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.mockTransport.enqueue(##"["AUTH","test-challenge"]"##)
            // Relay accepts the auth event
            try? await Task.sleep(nanoseconds: 200_000_000)
            self.mockTransport.enqueue(#"["OK","auth-evt-1",true,""]"#)
            // After auth, retry publish succeeds
            try? await Task.sleep(nanoseconds: 200_000_000)
            self.mockTransport.enqueue(#"["OK","pub-test-1",true,""]"#)
        }

        let outcome = await inspector.publish(event: sampleEvent)
        XCTAssertEqual(outcome, .accepted)
    }

    func testAuthRequiredFailsWhenAuthFails() async {
        let signer = MockAuthSigner()
        connection.authSigner = signer

        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.mockTransport.enqueue(#"["OK","pub-test-1",false,"auth-required: need auth"]"#)
            // Auth challenge
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.mockTransport.enqueue(##"["AUTH","challenge"]"##)
            // Auth rejected
            try? await Task.sleep(nanoseconds: 200_000_000)
            self.mockTransport.enqueue(#"["OK","auth-evt-1",false,"restricted: denied"]"#)
        }

        inspector.authWaitTimeout = 2.0
        let outcome = await inspector.publish(event: sampleEvent)
        XCTAssertEqual(outcome, .rejected(.authRequired("auth-required: need auth")))
    }
}
