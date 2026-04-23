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
    var pingShouldSucceed: Bool = true

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

    func sendPing() async throws {
        if pingShouldSucceed {
            return // Pong received immediately
        }
        // Block until cancelled (for timeout testing).
        // Task.sleep respects cancellation, so the task group in
        // pingOnce() can cancel us when the timeout fires.
        try await Task.sleep(nanoseconds: UInt64(Int64.max))
    }

    func cancel() {
        lock.lock()
        _cancelled = true
        let receiveWaiters = _receiveWaiters
        _receiveWaiters.removeAll()
        lock.unlock()
        for w in receiveWaiters {
            w.resume(throwing: URLError(.cancelled))
        }
    }

    /// Reset for reuse (new connection after reconnect).
    func reset() {
        lock.lock()
        _sent.removeAll()
        _incoming.removeAll()
        _cancelled = false
        _receiveWaiters.removeAll()
        lock.unlock()
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
            reconnectPolicy: .disabled,
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

// MARK: - Reconnect Tests

final class ReconnectTests: XCTestCase {

    /// Helper to create a reconnect-enabled connection with a transport factory
    /// that returns fresh mock transports for each connection attempt.
    private func makeReconnectableConnection(
        transports: [MockWebSocketTransport],
        policy: ReconnectPolicy? = nil
    ) -> (RelayConnection, [MockWebSocketTransport]) {
        var index = 0
        let lock = NSLock()

        let conn = RelayConnection(
            url: URL(string: "wss://test.relay")!,
            reconnectPolicy: policy ?? ReconnectPolicy(
                baseDelay: 0.05,  // Fast for tests
                maxDelay: 0.5,
                stableThreshold: 0.2
            ),
            transportFactory: { _ in
                lock.lock()
                let t = index < transports.count ? transports[index] : MockWebSocketTransport()
                index += 1
                lock.unlock()
                return t
            }
        )
        return (conn, transports)
    }

    func testConnectionDropTriggersReconnecting() {
        let mock1 = MockWebSocketTransport()
        let mock2 = MockWebSocketTransport()
        let (conn, _) = makeReconnectableConnection(transports: [mock1, mock2])

        let reconnectingObserved = expectation(description: "reconnecting state")
        conn.observeState { state in
            if state == .reconnecting {
                reconnectingObserved.fulfill()
            }
        }

        conn.connect()
        XCTAssertEqual(conn.state, .connected)

        // Simulate connection drop
        mock1.enqueueDisconnect()

        wait(for: [reconnectingObserved], timeout: 2.0)
        conn.disconnect()
    }

    func testReconnectRestoresConnection() {
        let mock1 = MockWebSocketTransport()
        let mock2 = MockWebSocketTransport()
        let (conn, _) = makeReconnectableConnection(transports: [mock1, mock2])

        let reconnected = expectation(description: "reconnected")
        var stateHistory: [RelayConnectionState] = []
        conn.observeState { state in
            stateHistory.append(state)
            // After reconnecting, we should see connected again
            if stateHistory.contains(.reconnecting) && state == .connected {
                reconnected.fulfill()
            }
        }

        conn.connect()

        // Simulate connection drop
        mock1.enqueueDisconnect()

        wait(for: [reconnected], timeout: 3.0)
        XCTAssertEqual(conn.state, .connected)
        conn.disconnect()
    }

    func testReconnectRestoresSubscriptions() {
        let mock1 = MockWebSocketTransport()
        let mock2 = MockWebSocketTransport()
        let (conn, _) = makeReconnectableConnection(transports: [mock1, mock2])

        conn.connect()

        // Create a subscription
        let _ = try? conn.subscribe(
            filters: [NostrFilter(kinds: [1], limit: 10)],
            callbacks: SubscriptionCallbacks()
        )

        // Wait for initial REQ to be sent
        let reqSent = expectation(description: "initial REQ")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { reqSent.fulfill() }
        wait(for: [reqSent], timeout: 1.0)

        let reconnected = expectation(description: "reconnected")
        conn.observeState { state in
            if state == .connected {
                reconnected.fulfill()
            }
        }

        // Simulate drop
        mock1.enqueueDisconnect()

        wait(for: [reconnected], timeout: 3.0)

        // Check that the new transport received a REQ (subscription restored)
        let restoreCheck = expectation(description: "REQ restored")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { restoreCheck.fulfill() }
        wait(for: [restoreCheck], timeout: 1.0)

        let reqMessages = mock2.sentMessages.filter { $0.contains("\"REQ\"") }
        XCTAssertGreaterThanOrEqual(reqMessages.count, 1, "Subscription should be restored on reconnect")
        XCTAssertTrue(reqMessages[0].contains("kf:0"), "Same subscription ID should be reused")

        conn.disconnect()
    }

    func testExplicitlyClosedSubscriptionNotRestored() {
        let mock1 = MockWebSocketTransport()
        let mock2 = MockWebSocketTransport()
        let (conn, _) = makeReconnectableConnection(transports: [mock1, mock2])

        conn.connect()

        let handle = try! conn.subscribe(
            filters: [NostrFilter(kinds: [1])],
            callbacks: SubscriptionCallbacks()
        )

        // Explicitly close the subscription before disconnect
        try? conn.closeSubscription(handle)
        XCTAssertEqual(conn.activeSubscriptionIds, [])

        let reconnected = expectation(description: "reconnected")
        conn.observeState { state in
            if state == .connected {
                reconnected.fulfill()
            }
        }

        // Simulate drop
        mock1.enqueueDisconnect()
        wait(for: [reconnected], timeout: 3.0)

        // Check that no REQ was sent (subscription was explicitly closed)
        let checkDelay = expectation(description: "check")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { checkDelay.fulfill() }
        wait(for: [checkDelay], timeout: 1.0)

        let reqMessages = mock2.sentMessages.filter { $0.contains("\"REQ\"") }
        XCTAssertEqual(reqMessages.count, 0, "Explicitly closed subscription should not be restored")

        conn.disconnect()
    }

    func testExplicitDisconnectCancelsReconnect() {
        let mock1 = MockWebSocketTransport()
        let mock2 = MockWebSocketTransport()

        // Use longer delay so we can interrupt it
        let (conn, _) = makeReconnectableConnection(
            transports: [mock1, mock2],
            policy: ReconnectPolicy(baseDelay: 5.0, maxDelay: 30.0, stableThreshold: 30.0)
        )

        conn.connect()

        let reconnecting = expectation(description: "reconnecting")
        conn.observeState { state in
            if state == .reconnecting {
                reconnecting.fulfill()
            }
        }

        // Simulate drop
        mock1.enqueueDisconnect()
        wait(for: [reconnecting], timeout: 2.0)

        // Explicitly disconnect while reconnecting
        conn.disconnect()
        XCTAssertEqual(conn.state, .disconnected)

        // Wait a bit to confirm we don't transition back to connected
        let staysDisconnected = expectation(description: "stays disconnected")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            staysDisconnected.fulfill()
        }
        wait(for: [staysDisconnected], timeout: 1.0)
        XCTAssertEqual(conn.state, .disconnected)
    }

    func testReconnectUpdatedSinceParameter() {
        let mock1 = MockWebSocketTransport()
        let mock2 = MockWebSocketTransport()
        let (conn, _) = makeReconnectableConnection(transports: [mock1, mock2])

        conn.connect()

        // Create subscription
        let _ = try? conn.subscribe(
            filters: [NostrFilter(kinds: [1])],
            callbacks: SubscriptionCallbacks()
        )

        // Deliver an event so lastEventAt gets tracked
        mock1.enqueue("""
        ["EVENT","kf:0",{"id":"e1","pubkey":"pk","created_at":1700000500,"kind":1,"tags":[],"content":"hello","sig":"s"}]
        """)

        // Wait for event processing
        let processed = expectation(description: "event processed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { processed.fulfill() }
        wait(for: [processed], timeout: 1.0)

        let reconnected = expectation(description: "reconnected")
        conn.observeState { state in
            if state == .connected {
                reconnected.fulfill()
            }
        }

        // Drop connection
        mock1.enqueueDisconnect()
        wait(for: [reconnected], timeout: 3.0)

        // Check the restored REQ includes the since parameter
        let checkDelay = expectation(description: "check restored REQ")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { checkDelay.fulfill() }
        wait(for: [checkDelay], timeout: 1.0)

        let reqMessages = mock2.sentMessages.filter { $0.contains("\"REQ\"") }
        XCTAssertGreaterThanOrEqual(reqMessages.count, 1)
        // The since parameter should be set to 1700000500
        XCTAssertTrue(reqMessages[0].contains("1700000500"),
                      "Restored REQ should include since=lastEventAt. Got: \(reqMessages[0])")

        conn.disconnect()
    }

    func testBackoffIncreasesBetweenAttempts() {
        var policy = ReconnectPolicy(baseDelay: 1.0, maxDelay: 30.0, multiplier: 2.0, jitterFraction: 0.0)
        let d1 = policy.nextDelay()
        let d2 = policy.nextDelay()
        let d3 = policy.nextDelay()

        XCTAssertEqual(d1, 1.0, accuracy: 0.001) // 1 * 2^0
        XCTAssertEqual(d2, 2.0, accuracy: 0.001) // 1 * 2^1
        XCTAssertEqual(d3, 4.0, accuracy: 0.001) // 1 * 2^2
    }

    func testBackoffCapsAtMaxDelay() {
        var policy = ReconnectPolicy(baseDelay: 1.0, maxDelay: 5.0, multiplier: 2.0, jitterFraction: 0.0)
        _ = policy.nextDelay() // 1
        _ = policy.nextDelay() // 2
        _ = policy.nextDelay() // 4
        let d4 = policy.nextDelay() // min(8, 5) = 5

        XCTAssertEqual(d4, 5.0, accuracy: 0.001)
    }

    func testBackoffResetsAfterStableConnection() {
        let mock1 = MockWebSocketTransport()
        let mock2 = MockWebSocketTransport()
        let mock3 = MockWebSocketTransport()

        // Very short stable threshold for testing
        let (conn, _) = makeReconnectableConnection(
            transports: [mock1, mock2, mock3],
            policy: ReconnectPolicy(
                baseDelay: 0.05,
                maxDelay: 0.5,
                stableThreshold: 0.1 // 100ms
            )
        )

        // Single observer that counts connected transitions
        var connectedCount = 0
        let countLock = NSLock()
        let twoReconnects = expectation(description: "two reconnect cycles")

        conn.observeState { state in
            if state == .connected {
                countLock.lock()
                connectedCount += 1
                let count = connectedCount
                countLock.unlock()
                // Initial=1, first reconnect=2, second reconnect=3
                if count == 3 {
                    twoReconnects.fulfill()
                }
            }
        }

        conn.connect() // connectedCount = 1

        _ = try? conn.subscribe(
            filters: [NostrFilter(kinds: [1])],
            callbacks: SubscriptionCallbacks()
        )

        // First drop → reconnect (connectedCount = 2)
        mock1.enqueueDisconnect()

        // Wait for first reconnect + stability threshold
        let stableWait = expectation(description: "stable wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { stableWait.fulfill() }
        wait(for: [stableWait], timeout: 2.0)

        // Second drop → reconnect (connectedCount = 3)
        mock2.enqueueDisconnect()
        wait(for: [twoReconnects], timeout: 3.0)

        XCTAssertEqual(conn.state, .connected)
        conn.disconnect()
    }

    func testDisabledReconnectPolicy() {
        let mock = MockWebSocketTransport()
        let conn = RelayConnection(
            url: URL(string: "wss://test.relay")!,
            reconnectPolicy: .disabled,
            transportFactory: { _ in mock }
        )

        conn.connect()

        let disconnected = expectation(description: "disconnected")
        conn.observeState { state in
            if state == .disconnected {
                disconnected.fulfill()
            }
        }

        // Simulate drop — should go to disconnected, not reconnecting
        mock.enqueueDisconnect()
        wait(for: [disconnected], timeout: 2.0)
        XCTAssertEqual(conn.state, .disconnected)
    }
}

// MARK: - Ping/Pong Tests

final class PingPongTests: XCTestCase {

    func testPingTimeoutTriggersReconnect() {
        let mock1 = MockWebSocketTransport()
        mock1.pingShouldSucceed = false // Pong will never come

        let mock2 = MockWebSocketTransport()

        var index = 0
        let lock = NSLock()
        let transports = [mock1, mock2]

        let conn = RelayConnection(
            url: URL(string: "wss://test.relay")!,
            reconnectPolicy: ReconnectPolicy(
                baseDelay: 0.05,
                maxDelay: 0.5,
                stableThreshold: 30.0
            ),
            transportFactory: { _ in
                lock.lock()
                let t = index < transports.count ? transports[index] : MockWebSocketTransport()
                index += 1
                lock.unlock()
                return t
            }
        )

        // Very short intervals for testing
        conn.pingInterval = 0.1   // Ping every 100ms
        conn.pongTimeout = 0.1    // Wait 100ms for pong

        let reconnecting = expectation(description: "reconnecting after ping timeout")
        conn.observeState { state in
            if state == .reconnecting {
                reconnecting.fulfill()
            }
        }

        conn.connect()
        wait(for: [reconnecting], timeout: 3.0)

        conn.disconnect()
    }

    func testSuccessfulPingKeepsConnectionAlive() {
        let mock = MockWebSocketTransport()
        mock.pingShouldSucceed = true

        let conn = RelayConnection(
            url: URL(string: "wss://test.relay")!,
            reconnectPolicy: .disabled,
            transportFactory: { _ in mock }
        )
        conn.pingInterval = 0.1

        conn.connect()

        // Wait for multiple ping cycles
        let staysConnected = expectation(description: "stays connected")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            staysConnected.fulfill()
        }
        wait(for: [staysConnected], timeout: 2.0)
        XCTAssertEqual(conn.state, .connected)

        conn.disconnect()
    }
}
