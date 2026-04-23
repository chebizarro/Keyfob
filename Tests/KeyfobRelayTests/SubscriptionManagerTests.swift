// ──────────────────────────────────────────────────────────────────
// SubscriptionManagerTests.swift — Tests for EOSE-aware subscriptions
// ──────────────────────────────────────────────────────────────────

import XCTest
@testable import KeyfobRelay

// MARK: - EOSE / Phase Tests

final class SubscriptionManagerTests: XCTestCase {

    private var mockTransport: MockWebSocketTransport!
    private var connection: RelayConnection!
    private var manager: SubscriptionManager!

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
        manager = SubscriptionManager(connection: connection)
    }

    override func tearDown() {
        connection.disconnect()
        connection = nil
        mockTransport = nil
        manager = nil
        super.tearDown()
    }

    // MARK: - Phase Tracking

    func testInitialPhaseIsCatchingUp() throws {
        let handle = try manager.subscribe(
            filters: [NostrFilter(kinds: [1])],
            callbacks: ManagedSubscriptionCallbacks()
        )
        XCTAssertEqual(manager.phase(for: handle), .catchingUp)
    }

    func testEOSETransitionsToLive() throws {
        let eoseReceived = expectation(description: "EOSE")
        let phaseIsLive = expectation(description: "phase is live")

        let handle = try manager.subscribe(
            filters: [NostrFilter(kinds: [1])],
            callbacks: ManagedSubscriptionCallbacks(
                onEOSE: { eoseReceived.fulfill() },
                onPhaseChange: { phase in
                    if phase == .live { phaseIsLive.fulfill() }
                }
            )
        )

        mockTransport.enqueue(#"["EOSE","kf:0"]"#)
        wait(for: [eoseReceived, phaseIsLive], timeout: 2.0)
        XCTAssertEqual(manager.phase(for: handle), .live)
    }

    // MARK: - Historical vs Realtime Events

    func testEventsBeforeEOSEAreHistorical() throws {
        var events: [ManagedEvent] = []
        let lock = NSLock()
        let twoEvents = expectation(description: "two events")

        let _ = try manager.subscribe(
            filters: [NostrFilter(kinds: [1])],
            callbacks: ManagedSubscriptionCallbacks(
                onEvent: { me in
                    lock.lock()
                    events.append(me)
                    let count = events.count
                    lock.unlock()
                    if count == 2 { twoEvents.fulfill() }
                }
            )
        )

        mockTransport.enqueue("""
        ["EVENT","kf:0",{"id":"h1","pubkey":"pk","created_at":100,"kind":1,"tags":[],"content":"historical1","sig":"s"}]
        """)
        mockTransport.enqueue("""
        ["EVENT","kf:0",{"id":"h2","pubkey":"pk","created_at":101,"kind":1,"tags":[],"content":"historical2","sig":"s"}]
        """)

        wait(for: [twoEvents], timeout: 2.0)

        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events[0].isHistorical)
        XCTAssertTrue(events[1].isHistorical)
        XCTAssertEqual(events[0].event.id, "h1")
        XCTAssertEqual(events[1].event.id, "h2")
    }

    func testEventsAfterEOSEAreRealtime() throws {
        var events: [ManagedEvent] = []
        let lock = NSLock()
        let realtimeEvent = expectation(description: "realtime event")

        let _ = try manager.subscribe(
            filters: [NostrFilter(kinds: [1])],
            callbacks: ManagedSubscriptionCallbacks(
                onEvent: { me in
                    lock.lock()
                    events.append(me)
                    let count = events.count
                    lock.unlock()
                    // First event is historical, second (after EOSE) is realtime
                    if count == 2 { realtimeEvent.fulfill() }
                }
            )
        )

        // Historical event
        mockTransport.enqueue("""
        ["EVENT","kf:0",{"id":"h1","pubkey":"pk","created_at":100,"kind":1,"tags":[],"content":"old","sig":"s"}]
        """)
        // EOSE boundary
        mockTransport.enqueue(#"["EOSE","kf:0"]"#)
        // Realtime event
        mockTransport.enqueue("""
        ["EVENT","kf:0",{"id":"r1","pubkey":"pk","created_at":200,"kind":1,"tags":[],"content":"new","sig":"s"}]
        """)

        wait(for: [realtimeEvent], timeout: 2.0)

        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events[0].isHistorical, "First event should be historical")
        XCTAssertFalse(events[1].isHistorical, "Second event should be realtime")
    }

    // MARK: - EOSE Behavior

    func testCloseAfterEOSE() throws {
        let phaseClosed = expectation(description: "phase closed")

        let handle = try manager.subscribe(
            filters: [NostrFilter(kinds: [1])],
            eoseBehavior: .closeAfterEOSE,
            callbacks: ManagedSubscriptionCallbacks(
                onPhaseChange: { phase in
                    if phase == .closed { phaseClosed.fulfill() }
                }
            )
        )

        mockTransport.enqueue(#"["EOSE","kf:0"]"#)
        wait(for: [phaseClosed], timeout: 2.0)

        // Subscription should be removed from manager
        XCTAssertNil(manager.phase(for: handle))
        XCTAssertEqual(manager.activeCount, 0)
    }

    func testTransitionToLiveKeepsSubscriptionOpen() throws {
        let eoseReceived = expectation(description: "EOSE")

        let handle = try manager.subscribe(
            filters: [NostrFilter(kinds: [1])],
            eoseBehavior: .transitionToLive,
            callbacks: ManagedSubscriptionCallbacks(
                onEOSE: { eoseReceived.fulfill() }
            )
        )

        mockTransport.enqueue(#"["EOSE","kf:0"]"#)
        wait(for: [eoseReceived], timeout: 2.0)

        // Subscription should still be active
        XCTAssertEqual(manager.phase(for: handle), .live)
        XCTAssertEqual(manager.activeCount, 1)
    }

    // MARK: - CLOSED Reason Parsing

    func testClosedAuthRequired() throws {
        let closedCalled = expectation(description: "closed")
        var capturedReason: ClosedReason?

        let _ = try manager.subscribe(
            filters: [NostrFilter(kinds: [1])],
            callbacks: ManagedSubscriptionCallbacks(
                onClosed: { reason in
                    capturedReason = reason
                    closedCalled.fulfill()
                }
            )
        )

        mockTransport.enqueue(#"["CLOSED","kf:0","auth-required: please authenticate"]"#)
        wait(for: [closedCalled], timeout: 2.0)

        XCTAssertEqual(capturedReason, .authRequired("auth-required: please authenticate"))
    }

    func testClosedRateLimited() throws {
        let closedCalled = expectation(description: "closed")
        var capturedReason: ClosedReason?

        let _ = try manager.subscribe(
            filters: [NostrFilter(kinds: [1])],
            callbacks: ManagedSubscriptionCallbacks(
                onClosed: { reason in
                    capturedReason = reason
                    closedCalled.fulfill()
                }
            )
        )

        mockTransport.enqueue(#"["CLOSED","kf:0","rate-limited: slow down"]"#)
        wait(for: [closedCalled], timeout: 2.0)

        XCTAssertEqual(capturedReason, .rateLimited("rate-limited: slow down"))
    }

    func testClosedError() throws {
        let closedCalled = expectation(description: "closed")
        var capturedReason: ClosedReason?

        let _ = try manager.subscribe(
            filters: [NostrFilter(kinds: [1])],
            callbacks: ManagedSubscriptionCallbacks(
                onClosed: { reason in
                    capturedReason = reason
                    closedCalled.fulfill()
                }
            )
        )

        mockTransport.enqueue(#"["CLOSED","kf:0","error: internal"]"#)
        wait(for: [closedCalled], timeout: 2.0)

        XCTAssertEqual(capturedReason, .error("error: internal"))
    }

    func testClosedBlocked() {
        let reason = ClosedReason.parse("blocked: content policy")
        XCTAssertEqual(reason, .blocked("blocked: content policy"))
    }

    func testClosedOther() {
        let reason = ClosedReason.parse("some other reason")
        XCTAssertEqual(reason, .other("some other reason"))
    }

    func testClosedReasonMessage() {
        let reasons: [ClosedReason] = [
            .authRequired("auth-required: need auth"),
            .rateLimited("rate-limited: slow"),
            .error("error: bad"),
            .blocked("blocked: nope"),
            .other("something")
        ]
        let expected = [
            "auth-required: need auth",
            "rate-limited: slow",
            "error: bad",
            "blocked: nope",
            "something"
        ]
        for (reason, msg) in zip(reasons, expected) {
            XCTAssertEqual(reason.message, msg)
        }
    }

    // MARK: - Close From Client

    func testClientCloseRemovesSubscription() throws {
        let handle = try manager.subscribe(
            filters: [NostrFilter(kinds: [1])],
            callbacks: ManagedSubscriptionCallbacks()
        )
        XCTAssertEqual(manager.activeCount, 1)

        try manager.close(handle)
        XCTAssertEqual(manager.activeCount, 0)
        XCTAssertNil(manager.phase(for: handle))
    }

    func testCloseIdempotent() throws {
        let handle = try manager.subscribe(
            filters: [NostrFilter(kinds: [1])],
            callbacks: ManagedSubscriptionCallbacks()
        )
        try manager.close(handle)
        try manager.close(handle) // Should be no-op, not crash
    }

    // MARK: - Multiple Subscriptions

    func testMultipleSubscriptionsTrackedIndependently() throws {
        let eose1 = expectation(description: "EOSE sub1")
        let eose2 = expectation(description: "EOSE sub2")

        let h1 = try manager.subscribe(
            filters: [NostrFilter(kinds: [1])],
            callbacks: ManagedSubscriptionCallbacks(
                onEOSE: { eose1.fulfill() }
            )
        )
        let h2 = try manager.subscribe(
            filters: [NostrFilter(kinds: [7])],
            callbacks: ManagedSubscriptionCallbacks(
                onEOSE: { eose2.fulfill() }
            )
        )

        XCTAssertEqual(manager.activeCount, 2)

        // Only EOSE for first subscription
        mockTransport.enqueue(#"["EOSE","kf:0"]"#)
        wait(for: [eose1], timeout: 2.0)

        XCTAssertEqual(manager.phase(for: h1), .live)
        XCTAssertEqual(manager.phase(for: h2), .catchingUp)

        mockTransport.enqueue(#"["EOSE","kf:1"]"#)
        wait(for: [eose2], timeout: 2.0)

        XCTAssertEqual(manager.phase(for: h2), .live)
    }

    // MARK: - Phase Change Callback Sequence

    func testPhaseChangeCallbackSequence() throws {
        var phases: [SubscriptionPhase] = []
        let lock = NSLock()
        let closedPhase = expectation(description: "closed phase")

        let _ = try manager.subscribe(
            filters: [NostrFilter(kinds: [1])],
            callbacks: ManagedSubscriptionCallbacks(
                onPhaseChange: { phase in
                    lock.lock()
                    phases.append(phase)
                    lock.unlock()
                    if phase == .closed { closedPhase.fulfill() }
                }
            )
        )

        // EOSE → live, then relay CLOSED → closed
        mockTransport.enqueue(#"["EOSE","kf:0"]"#)
        mockTransport.enqueue(#"["CLOSED","kf:0","done"]"#)

        wait(for: [closedPhase], timeout: 2.0)

        // Should see: catchingUp (initial), live (EOSE), closed (CLOSED)
        XCTAssertEqual(phases, [.catchingUp, .live, .closed])
    }
}

// MARK: - Reconnect Phase Reset Tests

final class SubscriptionManagerReconnectTests: XCTestCase {

    func testReconnectResetsPhaseToCatchingUp() {
        let mock1 = MockWebSocketTransport()
        let mock2 = MockWebSocketTransport()
        var index = 0
        let iLock = NSLock()
        let transports = [mock1, mock2]

        let conn = RelayConnection(
            url: URL(string: "wss://test.relay")!,
            reconnectPolicy: ReconnectPolicy(
                baseDelay: 0.05,
                maxDelay: 0.5,
                stableThreshold: 30.0
            ),
            transportFactory: { _ in
                iLock.lock()
                let t = index < transports.count ? transports[index] : MockWebSocketTransport()
                index += 1
                iLock.unlock()
                return t
            }
        )

        let mgr = SubscriptionManager(connection: conn)
        conn.connect()

        let handle = try! mgr.subscribe(
            filters: [NostrFilter(kinds: [1])],
            callbacks: ManagedSubscriptionCallbacks()
        )

        // Receive EOSE → live
        mock1.enqueue(#"["EOSE","kf:0"]"#)

        let eoseWait = expectation(description: "wait for EOSE processing")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { eoseWait.fulfill() }
        wait(for: [eoseWait], timeout: 1.0)

        XCTAssertEqual(mgr.phase(for: handle), .live)

        // Trigger reconnect
        let reconnected = expectation(description: "reconnected")
        conn.observeState { state in
            if state == .connected { reconnected.fulfill() }
        }
        mock1.enqueueDisconnect()
        wait(for: [reconnected], timeout: 3.0)

        // Phase should have reset to catchingUp
        XCTAssertEqual(mgr.phase(for: handle), .catchingUp)

        conn.disconnect()
    }
}

// MARK: - ClosedReason Unit Tests

final class ClosedReasonTests: XCTestCase {

    func testParseAuthRequired() {
        let r = ClosedReason.parse("auth-required: need auth")
        XCTAssertEqual(r, .authRequired("auth-required: need auth"))
    }

    func testParseRateLimited() {
        let r = ClosedReason.parse("rate-limited: too fast")
        XCTAssertEqual(r, .rateLimited("rate-limited: too fast"))
    }

    func testParseError() {
        let r = ClosedReason.parse("error: internal server error")
        XCTAssertEqual(r, .error("error: internal server error"))
    }

    func testParseBlocked() {
        let r = ClosedReason.parse("blocked: content policy violation")
        XCTAssertEqual(r, .blocked("blocked: content policy violation"))
    }

    func testParseOther() {
        let r = ClosedReason.parse("subscription ended")
        XCTAssertEqual(r, .other("subscription ended"))
    }

    func testParseEmpty() {
        let r = ClosedReason.parse("")
        XCTAssertEqual(r, .other(""))
    }
}
