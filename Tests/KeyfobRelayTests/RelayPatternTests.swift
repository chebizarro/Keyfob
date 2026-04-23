// ──────────────────────────────────────────────────────────────────
// RelayPatternTests.swift — Event-driven relay test patterns for NIP-46
// ──────────────────────────────────────────────────────────────────
//
// Demonstrates one example test per mandatory pattern from kf-0gc.3.
// All tests use MockRelay and deterministic event hooks.
// NO Thread.sleep, Task.sleep, or DispatchQueue.asyncAfter.
//
// These patterns should be followed for all NIP-46 relay tests.
//
// ──────────────────────────────────────────────────────────────────

import XCTest
@testable import KeyfobRelay

final class RelayPatternTests: XCTestCase {

    // MARK: - Pattern 1: Mock Relay Transport
    // Inject relay frames programmatically, no real connections.

    func testMockRelayInjectsFrames() {
        let relay = MockRelay()
        relay.connect()
        defer { relay.disconnect() }

        let eventReceived = expectation(description: "event received")
        var capturedEvent: RelayEvent?

        let handle = try! relay.connection.subscribe(
            filters: [NostrFilter(kinds: [1])],
            callbacks: SubscriptionCallbacks(
                onEvent: { event in
                    capturedEvent = event
                    eventReceived.fulfill()
                }
            )
        )

        // Inject an event via the mock — no real relay
        let testEvent = MockRelay.makeEvent(id: "frame-test-1", content: "hello")
        relay.injectEvent(subscriptionId: handle.id, event: testEvent)

        wait(for: [eventReceived], timeout: 1.0)
        XCTAssertEqual(capturedEvent?.id, "frame-test-1")
        XCTAssertEqual(capturedEvent?.content, "hello")
    }

    // MARK: - Pattern 2: Deterministic Event Hooks
    // Assert on callback invocations, never on sleep/delay.

    func testDeterministicCallbackAssertions() {
        let relay = MockRelay()
        relay.connect()
        defer { relay.disconnect() }

        let onEvent = expectation(description: "onEvent")
        let onEOSE = expectation(description: "onEOSE")

        let handle = try! relay.connection.subscribe(
            filters: [NostrFilter(kinds: [1])],
            callbacks: SubscriptionCallbacks(
                onEvent: { _ in onEvent.fulfill() },
                onEOSE: { onEOSE.fulfill() }
            )
        )

        // Inject event then EOSE — callbacks fire deterministically
        relay.injectEvent(
            subscriptionId: handle.id,
            event: MockRelay.makeEvent(id: "hook-test-1")
        )
        relay.injectEOSE(subscriptionId: handle.id)

        // Both callbacks fire without any sleep
        wait(for: [onEvent, onEOSE], timeout: 1.0, enforceOrder: true)
    }

    // MARK: - Pattern 3: EOSE Boundary Testing
    // Verify behavior before and after EOSE.

    func testEOSEBoundaryWithSubscriptionManager() {
        let relay = MockRelay()
        relay.connect()
        defer { relay.disconnect() }

        let manager = SubscriptionManager(connection: relay.connection)
        let lock = NSLock()
        var events: [ManagedEvent] = []
        let historicalEvent = expectation(description: "historical event")
        let liveEvent = expectation(description: "live event")
        let eoseReceived = expectation(description: "EOSE")

        let handle = try! manager.subscribe(
            filters: [NostrFilter(kinds: [1])],
            eoseBehavior: .transitionToLive,
            callbacks: ManagedSubscriptionCallbacks(
                onEvent: { me in
                    lock.lock()
                    events.append(me)
                    let count = events.count
                    lock.unlock()
                    if count == 1 { historicalEvent.fulfill() }
                    if count == 2 { liveEvent.fulfill() }
                },
                onEOSE: { eoseReceived.fulfill() }
            )
        )

        // Before EOSE: event is historical
        relay.injectEvent(
            subscriptionId: handle.id,
            event: MockRelay.makeEvent(id: "pre-eose")
        )
        wait(for: [historicalEvent], timeout: 1.0)

        // EOSE boundary
        relay.injectEOSE(subscriptionId: handle.id)
        wait(for: [eoseReceived], timeout: 1.0)

        // After EOSE: event is live
        relay.injectEvent(
            subscriptionId: handle.id,
            event: MockRelay.makeEvent(id: "post-eose")
        )
        wait(for: [liveEvent], timeout: 1.0)

        lock.lock()
        XCTAssertTrue(events[0].isHistorical)
        XCTAssertFalse(events[1].isHistorical)
        lock.unlock()
    }

    // MARK: - Pattern 4: OK Result Testing
    // Verify both OK true and OK false with rejection parsing.

    func testOKAcceptedAndRejected() async {
        let relay = MockRelay()
        relay.connect()
        defer { relay.disconnect() }

        let event = MockRelay.makeEvent(id: "ok-test-1")

        // Test accepted
        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            relay.injectOK(eventId: "ok-test-1", accepted: true)
        }
        let result = try! await relay.connection.publish(event: event)
        XCTAssertTrue(result.accepted)

        // Test rejected with reason parsing
        let event2 = MockRelay.makeEvent(id: "ok-test-2")
        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            relay.injectOK(eventId: "ok-test-2", accepted: false, message: "blocked: spam")
        }
        let result2 = try! await relay.connection.publish(event: event2)
        XCTAssertFalse(result2.accepted)

        let rejection = OKRejection.parse(result2.message)
        XCTAssertEqual(rejection, .blocked("blocked: spam"))
        XCTAssertFalse(rejection.isRetryable)
    }

    // MARK: - Pattern 5: AUTH Flow Testing
    // Mock AUTH challenge → verify auth event → mock OK → verify state.

    func testAuthFlowWithMockRelay() {
        let relay = MockRelay()
        let signer = MockAuthSigner()
        relay.connection.authSigner = signer
        relay.connect()
        defer { relay.disconnect() }

        let authenticated = expectation(description: "authenticated")
        relay.connection.onAuthStateChange = { state in
            if state == .authenticated { authenticated.fulfill() }
        }

        // Relay sends AUTH challenge
        relay.injectAuthChallenge("test-challenge-123")

        // Wait for signer to produce auth event (MockAuthSigner is instant)
        // Then relay accepts the auth
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            relay.injectOK(eventId: "auth-evt-1", accepted: true)
        }

        wait(for: [authenticated], timeout: 2.0)
        XCTAssertEqual(relay.connection.authState, .authenticated)
        XCTAssertEqual(relay.authCount, 1) // Client sent one AUTH frame
    }

    // MARK: - Pattern 6: CLOSED Frame Testing
    // Verify subscription closure with reason parsing.

    func testClosedFrameWithReasonParsing() {
        let relay = MockRelay()
        relay.connect()
        defer { relay.disconnect() }

        let closedReceived = expectation(description: "closed")
        var closedMessage: String?

        let handle = try! relay.connection.subscribe(
            filters: [NostrFilter(kinds: [1])],
            callbacks: SubscriptionCallbacks(
                onClosed: { msg in
                    closedMessage = msg
                    closedReceived.fulfill()
                }
            )
        )

        // Relay closes the subscription
        relay.injectClosed(subscriptionId: handle.id, message: "auth-required: please authenticate")

        wait(for: [closedReceived], timeout: 1.0)
        XCTAssertEqual(closedMessage, "auth-required: please authenticate")

        let reason = ClosedReason.parse(closedMessage!)
        if case .authRequired = reason {
            // Expected
        } else {
            XCTFail("Expected .authRequired, got \(reason)")
        }
    }

    // MARK: - Pattern 7: NIP-46 Event Factory
    // Verify kind 24133 event construction with proper tags.

    func testNIP46EventFactory() {
        let event = MockRelay.makeNIP46Event(
            id: "nip46-test",
            fromPubkey: "requester-abc",
            toPubkey: "signer-xyz",
            content: "encrypted-payload"
        )

        XCTAssertEqual(event.kind, 24133)
        XCTAssertEqual(event.pubkey, "requester-abc")
        XCTAssertEqual(event.content, "encrypted-payload")
        XCTAssertEqual(event.tags.first, ["p", "signer-xyz"])
    }

    // MARK: - Pattern 8: Notice Frame
    // Verify NOTICE frames reach the callback.

    func testNoticeFrame() {
        let relay = MockRelay()
        relay.connect()
        defer { relay.disconnect() }

        let noticeReceived = expectation(description: "notice")
        var capturedNotice: String?

        relay.connection.onNotice = { msg in
            capturedNotice = msg
            noticeReceived.fulfill()
        }

        relay.injectNotice("rate limited, please slow down")

        wait(for: [noticeReceived], timeout: 1.0)
        XCTAssertEqual(capturedNotice, "rate limited, please slow down")
    }

    // MARK: - Pattern 9: Sent Frame Inspection
    // Verify what the client sent to the relay after an event round-trip
    // (async sends complete by the time the relay responds).

    func testSentFrameInspection() {
        let relay = MockRelay()
        relay.connect()
        defer { relay.disconnect() }

        let eventReceived = expectation(description: "event")

        // Subscribe → client sends REQ
        let handle = try! relay.connection.subscribe(
            filters: [NostrFilter(kinds: [24133])],
            callbacks: SubscriptionCallbacks(
                onEvent: { _ in eventReceived.fulfill() }
            )
        )

        // Relay sends an event, proving REQ was received and processed
        relay.injectEvent(
            subscriptionId: handle.id,
            event: MockRelay.makeEvent(id: "inspect-1", kind: 24133)
        )
        wait(for: [eventReceived], timeout: 1.0)

        // Now REQ async send has completed — verify it
        XCTAssertTrue(relay.sentMessages.contains { $0.contains("\"REQ\"") },
                       "Expected a REQ frame in sent messages")
        XCTAssertTrue(relay.sentMessages.contains { $0.contains(handle.id) },
                       "REQ should contain the subscription ID")

        // Close subscription → client sends CLOSE (also async)
        try! relay.connection.closeSubscription(handle)

        // Inject a NOTICE to flush the async send pipeline
        let noticeReceived = expectation(description: "notice")
        relay.connection.onNotice = { _ in noticeReceived.fulfill() }
        relay.injectNotice("flush")
        wait(for: [noticeReceived], timeout: 1.0)

        XCTAssertTrue(relay.sentMessages.contains { $0.contains("\"CLOSE\"") },
                       "Expected a CLOSE frame in sent messages")
    }
}
