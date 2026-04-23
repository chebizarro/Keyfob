// ──────────────────────────────────────────────────────────────────
// RelayConnectionTests.swift — Tests for RelayConnection lifecycle
// ──────────────────────────────────────────────────────────────────

import XCTest
@testable import KeyfobRelay

// MARK: - Mock WebSocket Transport

/// A mock transport that lets tests enqueue server messages and inspect sent messages.
final class MockWebSocketTransport: WebSocketTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [String] = []
    private var _incoming: [String] = []
    private var _cancelled = false
    private var _receiveWaiters: [CheckedContinuation<String, Error>] = []

    /// Messages sent by the client through this transport.
    var sentMessages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _sent
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _cancelled
    }

    /// Enqueue a server message that will be returned by the next `receive()` call.
    func enqueue(_ text: String) {
        lock.lock()
        if let waiter = _receiveWaiters.first {
            _receiveWaiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: text)
        } else {
            _incoming.append(text)
            lock.unlock()
        }
    }

    /// Enqueue an error that will be thrown by the next `receive()` call.
    func enqueueDisconnect() {
        lock.lock()
        if let waiter = _receiveWaiters.first {
            _receiveWaiters.removeFirst()
            lock.unlock()
            waiter.resume(throwing: URLError(.networkConnectionLost))
        } else {
            // We'll handle this by cancelling
            lock.unlock()
            cancel()
        }
    }

    func send(_ text: String) async throws {
        lock.lock()
        guard !_cancelled else {
            lock.unlock()
            throw URLError(.networkConnectionLost)
        }
        _sent.append(text)
        lock.unlock()
    }

    func receive() async throws -> String {
        lock.lock()
        if _cancelled {
            lock.unlock()
            throw URLError(.cancelled)
        }
        if !_incoming.isEmpty {
            let msg = _incoming.removeFirst()
            lock.unlock()
            return msg
        }
        lock.unlock()

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if _cancelled {
                lock.unlock()
                continuation.resume(throwing: URLError(.cancelled))
                return
            }
            if !_incoming.isEmpty {
                let msg = _incoming.removeFirst()
                lock.unlock()
                continuation.resume(returning: msg)
                return
            }
            _receiveWaiters.append(continuation)
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        _cancelled = true
        let waiters = _receiveWaiters
        _receiveWaiters.removeAll()
        lock.unlock()
        for w in waiters {
            w.resume(throwing: URLError(.cancelled))
        }
    }
}

// MARK: - RelayConnection Tests

final class RelayConnectionTests: XCTestCase {

    private var mockTransport: MockWebSocketTransport!
    private var connection: RelayConnection!

    override func setUp() {
        super.setUp()
        mockTransport = MockWebSocketTransport()
        let transport = mockTransport!
        connection = RelayConnection(
            url: URL(string: "wss://test.relay")!,
            transportFactory: { _ in transport }
        )
    }

    override func tearDown() {
        connection.disconnect()
        connection = nil
        mockTransport = nil
        super.tearDown()
    }

    // MARK: - Connection Lifecycle

    func testInitialState() {
        XCTAssertEqual(connection.state, .disconnected)
    }

    func testConnectTransitionsToConnected() {
        var states: [RelayConnectionState] = []
        connection.observeState { states.append($0) }
        connection.connect()
        XCTAssertEqual(connection.state, .connected)
        XCTAssertTrue(states.contains(.connecting))
        XCTAssertTrue(states.contains(.connected))
    }

    func testConnectIdempotent() {
        connection.connect()
        connection.connect() // Should be no-op
        XCTAssertEqual(connection.state, .connected)
    }

    func testDisconnect() {
        connection.connect()
        connection.disconnect()
        XCTAssertEqual(connection.state, .disconnected)
        XCTAssertTrue(mockTransport.isCancelled)
    }

    func testDisconnectWhenNotConnected() {
        // Should be a safe no-op
        connection.disconnect()
        XCTAssertEqual(connection.state, .disconnected)
    }

    // MARK: - Subscribe

    func testSubscribeSendsREQ() throws {
        connection.connect()

        let filter = NostrFilter(kinds: [1], limit: 10)
        let handle = try connection.subscribe(
            filters: [filter],
            callbacks: SubscriptionCallbacks()
        )

        XCTAssertEqual(handle.id, "kf:0")

        // Give async Task a moment to send
        let expectation = self.expectation(description: "REQ sent")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        let sent = mockTransport.sentMessages
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(sent[0].contains("\"REQ\""))
        XCTAssertTrue(sent[0].contains("kf:0"))
    }

    func testSubscribeWhenNotConnected() {
        let filter = NostrFilter(kinds: [1])
        XCTAssertThrowsError(try connection.subscribe(
            filters: [filter],
            callbacks: SubscriptionCallbacks()
        )) { error in
            XCTAssertEqual(error as? RelayConnectionError, .notConnected)
        }
    }

    func testMultipleSubscriptionsGetUniqueIds() throws {
        connection.connect()
        let h1 = try connection.subscribe(filters: [NostrFilter()], callbacks: SubscriptionCallbacks())
        let h2 = try connection.subscribe(filters: [NostrFilter()], callbacks: SubscriptionCallbacks())
        XCTAssertEqual(h1.id, "kf:0")
        XCTAssertEqual(h2.id, "kf:1")
        XCTAssertNotEqual(h1, h2)
    }

    // MARK: - Event Routing

    func testEventRoutedToSubscription() throws {
        connection.connect()

        let receivedEvent = expectation(description: "event received")
        var capturedEvent: RelayEvent?

        _ = try connection.subscribe(
            filters: [NostrFilter(kinds: [1])],
            callbacks: SubscriptionCallbacks(
                onEvent: { event in
                    capturedEvent = event
                    receivedEvent.fulfill()
                }
            )
        )

        // Enqueue a server EVENT frame for sub kf:0
        let eventJSON = """
        ["EVENT","kf:0",{"id":"e1","pubkey":"pk1","created_at":100,"kind":1,"tags":[],"content":"test","sig":"s1"}]
        """
        mockTransport.enqueue(eventJSON)

        wait(for: [receivedEvent], timeout: 2.0)
        XCTAssertEqual(capturedEvent?.id, "e1")
        XCTAssertEqual(capturedEvent?.content, "test")
    }

    func testEOSECallbackFired() throws {
        connection.connect()

        let eoseReceived = expectation(description: "EOSE received")

        _ = try connection.subscribe(
            filters: [NostrFilter(kinds: [1])],
            callbacks: SubscriptionCallbacks(
                onEOSE: { eoseReceived.fulfill() }
            )
        )

        mockTransport.enqueue(#"["EOSE","kf:0"]"#)
        wait(for: [eoseReceived], timeout: 2.0)
    }

    func testCLOSEDCallbackFired() throws {
        connection.connect()

        let closedReceived = expectation(description: "CLOSED received")
        var closedMessage: String?

        _ = try connection.subscribe(
            filters: [NostrFilter(kinds: [1])],
            callbacks: SubscriptionCallbacks(
                onClosed: { msg in
                    closedMessage = msg
                    closedReceived.fulfill()
                }
            )
        )

        mockTransport.enqueue(#"["CLOSED","kf:0","auth-required: authenticate"]"#)
        wait(for: [closedReceived], timeout: 2.0)
        XCTAssertEqual(closedMessage, "auth-required: authenticate")
    }

    func testEventForUnknownSubscriptionIgnored() throws {
        connection.connect()

        // Enqueue event for a subscription that doesn't exist
        mockTransport.enqueue("""
        ["EVENT","unknown-sub",{"id":"e1","pubkey":"pk1","created_at":100,"kind":1,"tags":[],"content":"test","sig":"s1"}]
        """)

        // Give the receive loop time to process
        let wait = expectation(description: "wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { wait.fulfill() }
        self.wait(for: [wait], timeout: 1.0)
        // No crash = success
    }

    // MARK: - Close Subscription

    func testCloseSubscriptionSendsCLOSE() throws {
        connection.connect()
        let handle = try connection.subscribe(
            filters: [NostrFilter()],
            callbacks: SubscriptionCallbacks()
        )

        try connection.closeSubscription(handle)

        let expectation = self.expectation(description: "CLOSE sent")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        let closeMsgs = mockTransport.sentMessages.filter { $0.contains("\"CLOSE\"") }
        XCTAssertEqual(closeMsgs.count, 1)
        XCTAssertTrue(closeMsgs[0].contains("kf:0"))
    }

    func testCloseSubscriptionIdempotent() throws {
        connection.connect()
        let handle = try connection.subscribe(
            filters: [NostrFilter()],
            callbacks: SubscriptionCallbacks()
        )
        try connection.closeSubscription(handle)
        // Second close should be a no-op, not throw
        try connection.closeSubscription(handle)
    }

    // MARK: - Publish & OK

    func testPublishSendsEVENTAndReceivesOK() async throws {
        connection.connect()

        let event = RelayEvent(
            id: "pub1", pubkey: "pk", created_at: 100,
            kind: 1, tags: [], content: "hello", sig: "sig"
        )

        // Enqueue OK response after a brief delay
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            mockTransport.enqueue(#"["OK","pub1",true,""]"#)
        }

        let result = try await connection.publish(event: event)
        XCTAssertEqual(result.eventId, "pub1")
        XCTAssertTrue(result.accepted)
    }

    func testPublishRejected() async throws {
        connection.connect()

        let event = RelayEvent(
            id: "pub2", pubkey: "pk", created_at: 100,
            kind: 1, tags: [], content: "spam", sig: "sig"
        )

        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            mockTransport.enqueue(#"["OK","pub2",false,"blocked: content policy"]"#)
        }

        let result = try await connection.publish(event: event)
        XCTAssertEqual(result.eventId, "pub2")
        XCTAssertFalse(result.accepted)
        XCTAssertEqual(result.message, "blocked: content policy")
    }

    func testPublishWhenNotConnected() async {
        let event = RelayEvent(
            id: "pub3", pubkey: "pk", created_at: 100,
            kind: 1, tags: [], content: "test", sig: "sig"
        )
        do {
            _ = try await connection.publish(event: event)
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(error as? RelayConnectionError, .notConnected)
        }
    }

    // MARK: - AUTH & NOTICE Callbacks

    func testAUTHCallback() throws {
        connection.connect()

        let authReceived = expectation(description: "AUTH received")
        var authChallenge: String?
        connection.onAuthChallenge = { challenge in
            authChallenge = challenge
            authReceived.fulfill()
        }

        mockTransport.enqueue(#"["AUTH","challenge-xyz"]"#)
        wait(for: [authReceived], timeout: 2.0)
        XCTAssertEqual(authChallenge, "challenge-xyz")
    }

    func testNOTICECallback() throws {
        connection.connect()

        let noticeReceived = expectation(description: "NOTICE received")
        var noticeMessage: String?
        connection.onNotice = { msg in
            noticeMessage = msg
            noticeReceived.fulfill()
        }

        mockTransport.enqueue(#"["NOTICE","slow down"]"#)
        wait(for: [noticeReceived], timeout: 2.0)
        XCTAssertEqual(noticeMessage, "slow down")
    }

    // MARK: - Active Subscriptions

    func testActiveSubscriptionIds() throws {
        connection.connect()
        XCTAssertEqual(connection.activeSubscriptionIds, [])

        let h1 = try connection.subscribe(filters: [NostrFilter()], callbacks: SubscriptionCallbacks())
        XCTAssertEqual(connection.activeSubscriptionIds, ["kf:0"])

        let h2 = try connection.subscribe(filters: [NostrFilter()], callbacks: SubscriptionCallbacks())
        XCTAssertEqual(Set(connection.activeSubscriptionIds), Set(["kf:0", "kf:1"]))

        try connection.closeSubscription(h1)
        XCTAssertEqual(connection.activeSubscriptionIds, ["kf:1"])

        try connection.closeSubscription(h2)
        XCTAssertEqual(connection.activeSubscriptionIds, [])
    }

    // MARK: - Send Raw Frame

    func testSendRawFrame() throws {
        connection.connect()
        let authEvent = RelayEvent(
            id: "auth1", pubkey: "pk", created_at: 100,
            kind: 22242, tags: [], content: "", sig: "sig"
        )
        try connection.send(.auth(authEvent))

        let expectation = self.expectation(description: "AUTH sent")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        let authMsgs = mockTransport.sentMessages.filter { $0.contains("\"AUTH\"") }
        XCTAssertEqual(authMsgs.count, 1)
    }

    func testSendWhenNotConnected() {
        XCTAssertThrowsError(try connection.send(.close(subscriptionId: "x"))) { error in
            XCTAssertEqual(error as? RelayConnectionError, .notConnected)
        }
    }

    // MARK: - Disconnect Cleans Up Pending OK

    func testDisconnectResumesPendingOK() async throws {
        connection.connect()

        let event = RelayEvent(
            id: "pend1", pubkey: "pk", created_at: 100,
            kind: 1, tags: [], content: "test", sig: "sig"
        )

        // Start publish but don't send OK - then disconnect
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            connection.disconnect()
        }

        do {
            _ = try await connection.publish(event: event)
            XCTFail("Should have thrown on disconnect")
        } catch {
            XCTAssertEqual(error as? RelayConnectionError, .disconnected)
        }
    }

    // MARK: - Unparseable Frames Ignored

    func testUnparseableFrameIgnored() throws {
        connection.connect()

        let eventReceived = expectation(description: "event after garbage")

        _ = try connection.subscribe(
            filters: [NostrFilter(kinds: [1])],
            callbacks: SubscriptionCallbacks(
                onEvent: { _ in eventReceived.fulfill() }
            )
        )

        // Send garbage, then a real event
        mockTransport.enqueue("this is not valid JSON at all")
        mockTransport.enqueue("""
        ["EVENT","kf:0",{"id":"e2","pubkey":"pk","created_at":100,"kind":1,"tags":[],"content":"after garbage","sig":"s"}]
        """)

        wait(for: [eventReceived], timeout: 2.0)
        // If we got here, the garbage frame was safely ignored
    }
}
