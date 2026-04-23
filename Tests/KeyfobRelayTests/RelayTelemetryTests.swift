// ──────────────────────────────────────────────────────────────────
// RelayTelemetryTests.swift — Tests for relay lifecycle telemetry
// ──────────────────────────────────────────────────────────────────

import XCTest
@testable import KeyfobRelay

// MARK: - Telemetry Collector

/// Thread-safe collector for telemetry events emitted during tests.
private final class TelemetryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [RelayTelemetryEvent] = []

    var events: [RelayTelemetryEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }

    var handler: @Sendable (RelayTelemetryEvent) -> Void {
        { [weak self] event in
            guard let self else { return }
            self.lock.lock()
            self._events.append(event)
            self.lock.unlock()
        }
    }

    func descriptions(matching prefix: String) -> [String] {
        events.map(\.description).filter { $0.contains(prefix) }
    }

    func matching(_ predicate: (RelayTelemetryEvent) -> Bool) -> [RelayTelemetryEvent] {
        events.filter(predicate)
    }
}

// MARK: - Telemetry Event Tests (enum + description)

final class RelayTelemetryEventTests: XCTestCase {

    private let relay = URL(string: "wss://test.relay")!

    func testConnectedDescription() {
        let event = RelayTelemetryEvent.connected(relay: relay)
        XCTAssertTrue(event.description.contains("[Relay] connected"))
        XCTAssertTrue(event.description.contains("wss://test.relay"))
    }

    func testDisconnectedDescription() {
        let event = RelayTelemetryEvent.disconnected(relay: relay, reason: "explicit")
        XCTAssertTrue(event.description.contains("[Relay] disconnected"))
        XCTAssertTrue(event.description.contains("reason=explicit"))
    }

    func testReconnectAttemptDescription() {
        let event = RelayTelemetryEvent.reconnectAttempt(relay: relay, attempt: 3, delayMs: 4000)
        XCTAssertTrue(event.description.contains("attempt=3"))
        XCTAssertTrue(event.description.contains("delay=4000ms"))
    }

    func testReconnectSuccessDescription() {
        let event = RelayTelemetryEvent.reconnectSuccess(relay: relay, attempt: 2)
        XCTAssertTrue(event.description.contains("reconnect succeeded"))
        XCTAssertTrue(event.description.contains("attempt=2"))
    }

    func testReconnectGaveUpDescription() {
        let event = RelayTelemetryEvent.reconnectGaveUp(relay: relay, attempts: 5)
        XCTAssertTrue(event.description.contains("gave up"))
        XCTAssertTrue(event.description.contains("5 attempts"))
    }

    func testSubscriptionOpenedDescription() {
        let event = RelayTelemetryEvent.subscriptionOpened(relay: relay, subscriptionId: "kf:0", filterCount: 2)
        XCTAssertTrue(event.description.contains("REQ"))
        XCTAssertTrue(event.description.contains("subId=kf:0"))
        XCTAssertTrue(event.description.contains("filters=2"))
    }

    func testEoseReceivedDescription() {
        let event = RelayTelemetryEvent.eoseReceived(relay: relay, subscriptionId: "kf:1")
        XCTAssertTrue(event.description.contains("EOSE"))
        XCTAssertTrue(event.description.contains("subId=kf:1"))
    }

    func testSubscriptionClosedDescription() {
        let event = RelayTelemetryEvent.subscriptionClosed(relay: relay, subscriptionId: "kf:0", reason: "auth-required:")
        XCTAssertTrue(event.description.contains("CLOSED"))
        XCTAssertTrue(event.description.contains("reason=auth-required:"))
    }

    func testSubscriptionRestoredDescription() {
        let event = RelayTelemetryEvent.subscriptionRestored(relay: relay, subscriptionId: "kf:0")
        XCTAssertTrue(event.description.contains("subscription restored"))
        XCTAssertTrue(event.description.contains("subId=kf:0"))
    }

    func testAuthChallengeReceivedDescription() {
        let event = RelayTelemetryEvent.authChallengeReceived(relay: relay)
        XCTAssertTrue(event.description.contains("AUTH challenge received"))
    }

    func testAuthResponseSentDescription() {
        let event = RelayTelemetryEvent.authResponseSent(relay: relay)
        XCTAssertTrue(event.description.contains("AUTH response sent"))
    }

    func testAuthSucceededDescription() {
        let event = RelayTelemetryEvent.authSucceeded(relay: relay)
        XCTAssertTrue(event.description.contains("AUTH succeeded"))
    }

    func testAuthFailedDescription() {
        let event = RelayTelemetryEvent.authFailed(relay: relay, message: "invalid signature")
        XCTAssertTrue(event.description.contains("AUTH failed"))
        XCTAssertTrue(event.description.contains("invalid signature"))
    }

    func testEventPublishedDescription() {
        let event = RelayTelemetryEvent.eventPublished(relay: relay, eventId: "abc123", kind: 1)
        XCTAssertTrue(event.description.contains("EVENT published"))
        XCTAssertTrue(event.description.contains("id=abc123"))
        XCTAssertTrue(event.description.contains("kind=1"))
    }

    func testPublishAcceptedDescription() {
        let event = RelayTelemetryEvent.publishAccepted(relay: relay, eventId: "abc123")
        XCTAssertTrue(event.description.contains("OK accepted"))
        XCTAssertTrue(event.description.contains("id=abc123"))
    }

    func testPublishRejectedDescription() {
        let event = RelayTelemetryEvent.publishRejected(relay: relay, eventId: "abc123", reason: "rate-limited")
        XCTAssertTrue(event.description.contains("OK rejected"))
        XCTAssertTrue(event.description.contains("reason=rate-limited"))
    }
}

// MARK: - Connection Lifecycle Telemetry

final class RelayConnectionTelemetryTests: XCTestCase {

    private var mockTransport: MockWebSocketTransport!
    private var connection: RelayConnection!
    private var collector: TelemetryCollector!

    override func setUp() {
        super.setUp()
        mockTransport = MockWebSocketTransport()
        collector = TelemetryCollector()
        let transport = mockTransport!
        connection = RelayConnection(
            url: URL(string: "wss://test.relay")!,
            reconnectPolicy: .disabled,
            transportFactory: { _ in transport }
        )
        connection.telemetry = collector.handler
    }

    override func tearDown() {
        connection.disconnect()
        connection = nil
        mockTransport = nil
        collector = nil
        super.tearDown()
    }

    // MARK: - Connect / Disconnect

    func testConnectEmitsConnectedTelemetry() {
        connection.connect()

        let connected = collector.matching {
            if case .connected = $0 { return true }
            return false
        }
        XCTAssertEqual(connected.count, 1)
    }

    func testDisconnectEmitsDisconnectedTelemetry() {
        connection.connect()
        connection.disconnect()

        let disconnected = collector.matching {
            if case .disconnected(_, let reason) = $0 { return reason == "explicit" }
            return false
        }
        XCTAssertEqual(disconnected.count, 1)
    }

    func testConnectThenDisconnectEmitsBothEvents() {
        connection.connect()
        connection.disconnect()

        // Should have exactly: connected, disconnected(explicit)
        let descriptions = collector.events.map(\.description)
        XCTAssertTrue(descriptions.contains { $0.contains("connected") })
        XCTAssertTrue(descriptions.contains { $0.contains("reason=explicit") })
    }

    // MARK: - Subscription Telemetry

    func testSubscribeEmitsSubscriptionOpened() throws {
        connection.connect()
        _ = try connection.subscribe(
            filters: [NostrFilter(kinds: [1]), NostrFilter(kinds: [4])],
            callbacks: SubscriptionCallbacks()
        )

        let opened = collector.matching {
            if case .subscriptionOpened(_, let subId, let count) = $0 {
                return subId == "kf:0" && count == 2
            }
            return false
        }
        XCTAssertEqual(opened.count, 1)
    }

    func testEOSEEmitsEoseReceivedTelemetry() throws {
        connection.connect()
        let eoseReceived = expectation(description: "EOSE received")
        _ = try connection.subscribe(
            filters: [NostrFilter(kinds: [1])],
            callbacks: SubscriptionCallbacks(onEOSE: { eoseReceived.fulfill() })
        )

        mockTransport.enqueue(#"["EOSE","kf:0"]"#)
        wait(for: [eoseReceived], timeout: 2.0)

        let eose = collector.matching {
            if case .eoseReceived(_, let subId) = $0 { return subId == "kf:0" }
            return false
        }
        XCTAssertEqual(eose.count, 1)
    }

    func testCLOSEDEmitsSubscriptionClosedTelemetry() throws {
        connection.connect()
        let closed = expectation(description: "CLOSED received")
        _ = try connection.subscribe(
            filters: [NostrFilter(kinds: [1])],
            callbacks: SubscriptionCallbacks(onClosed: { _ in closed.fulfill() })
        )

        mockTransport.enqueue(#"["CLOSED","kf:0","rate-limited"]"#)
        wait(for: [closed], timeout: 2.0)

        let closedEvents = collector.matching {
            if case .subscriptionClosed(_, let subId, let reason) = $0 {
                return subId == "kf:0" && reason == "rate-limited"
            }
            return false
        }
        XCTAssertEqual(closedEvents.count, 1)
    }

    // MARK: - Publish Telemetry

    func testPublishAcceptedEmitsTelemetry() async throws {
        connection.connect()

        let event = RelayEvent(
            id: "pub1", pubkey: "pk", created_at: 100,
            kind: 1, tags: [], content: "hello", sig: "sig"
        )

        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            mockTransport.enqueue(#"["OK","pub1",true,""]"#)
        }

        let result = try await connection.publish(event: event)
        XCTAssertTrue(result.accepted)

        // Should have eventPublished and publishAccepted
        let published = collector.matching {
            if case .eventPublished(_, let id, let kind) = $0 {
                return id == "pub1" && kind == 1
            }
            return false
        }
        XCTAssertEqual(published.count, 1)

        let accepted = collector.matching {
            if case .publishAccepted(_, let id) = $0 { return id == "pub1" }
            return false
        }
        XCTAssertEqual(accepted.count, 1)
    }

    func testPublishRejectedEmitsTelemetry() async throws {
        connection.connect()

        let event = RelayEvent(
            id: "pub2", pubkey: "pk", created_at: 100,
            kind: 1, tags: [], content: "spam", sig: "sig"
        )

        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            mockTransport.enqueue(#"["OK","pub2",false,"blocked: spam"]"#)
        }

        let result = try await connection.publish(event: event)
        XCTAssertFalse(result.accepted)

        let rejected = collector.matching {
            if case .publishRejected(_, let id, let reason) = $0 {
                return id == "pub2" && reason == "blocked: spam"
            }
            return false
        }
        XCTAssertEqual(rejected.count, 1)
    }

    // MARK: - AUTH Telemetry

    func testAuthChallengeEmitsTelemetry() {
        connection.connect()

        let authReceived = expectation(description: "auth challenge")
        connection.onAuthChallenge = { _ in authReceived.fulfill() }

        mockTransport.enqueue(#"["AUTH","challenge-abc"]"#)
        wait(for: [authReceived], timeout: 2.0)

        let challenges = collector.matching {
            if case .authChallengeReceived = $0 { return true }
            return false
        }
        XCTAssertEqual(challenges.count, 1)
    }

    func testAuthFullFlowEmitsTelemetry() {
        let signer = MockAuthSigner()
        connection.authSigner = signer

        connection.connect()

        let authenticated = expectation(description: "authenticated")
        connection.onAuthStateChange = { state in
            if state == .authenticated {
                authenticated.fulfill()
            }
        }

        // Send AUTH challenge
        mockTransport.enqueue(#"["AUTH","challenge-xyz"]"#)

        // Wait for AUTH response to be sent, then inject OK
        let authSent = expectation(description: "auth sent")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            // Find the auth event ID from sent messages
            let authMsgs = self.mockTransport.sentMessages.filter { $0.contains("22242") }
            if let authMsg = authMsgs.first,
               let data = authMsg.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
               arr.count >= 2,
               let eventDict = arr[1] as? [String: Any],
               let eventId = eventDict["id"] as? String {
                self.mockTransport.enqueue("""
                ["OK","\(eventId)",true,""]
                """)
            }
            authSent.fulfill()
        }
        wait(for: [authSent], timeout: 2.0)
        wait(for: [authenticated], timeout: 3.0)

        // Should see: authChallengeReceived, authResponseSent, authSucceeded
        let challengeEvents = collector.matching {
            if case .authChallengeReceived = $0 { return true }
            return false
        }
        XCTAssertEqual(challengeEvents.count, 1)

        let responseSent = collector.matching {
            if case .authResponseSent = $0 { return true }
            return false
        }
        XCTAssertEqual(responseSent.count, 1)

        let succeeded = collector.matching {
            if case .authSucceeded = $0 { return true }
            return false
        }
        XCTAssertEqual(succeeded.count, 1)
    }

    func testAuthFailedEmitsTelemetry() {
        let signer = MockAuthSigner()
        connection.authSigner = signer

        connection.connect()

        let failed = expectation(description: "auth failed")
        connection.onAuthStateChange = { state in
            if case .failed = state {
                failed.fulfill()
            }
        }

        // Send AUTH challenge
        mockTransport.enqueue(#"["AUTH","challenge-fail"]"#)

        // Wait for AUTH response, then reject it
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let authMsgs = self.mockTransport.sentMessages.filter { $0.contains("22242") }
            if let authMsg = authMsgs.first,
               let data = authMsg.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
               arr.count >= 2,
               let eventDict = arr[1] as? [String: Any],
               let eventId = eventDict["id"] as? String {
                self.mockTransport.enqueue("""
                ["OK","\(eventId)",false,"invalid: bad sig"]
                """)
            }
        }

        wait(for: [failed], timeout: 3.0)

        let failedEvents = collector.matching {
            if case .authFailed(_, let msg) = $0 { return msg == "invalid: bad sig" }
            return false
        }
        XCTAssertEqual(failedEvents.count, 1)
    }

    // MARK: - Connection Loss Telemetry

    func testConnectionLossEmitsDisconnectedTelemetry() {
        connection.connect()

        let disconnected = expectation(description: "disconnected state")
        connection.observeState { state in
            if state == .disconnected { disconnected.fulfill() }
        }

        mockTransport.enqueueDisconnect()
        wait(for: [disconnected], timeout: 2.0)

        let lostEvents = collector.matching {
            if case .disconnected(_, let reason) = $0 { return reason == "connectionLost" }
            return false
        }
        XCTAssertEqual(lostEvents.count, 1)
    }
}

// MARK: - Reconnect Telemetry Tests

final class ReconnectTelemetryTests: XCTestCase {

    func testReconnectEmitsAttemptAndSuccessTelemetry() {
        let mock1 = MockWebSocketTransport()
        let mock2 = MockWebSocketTransport()
        let collector = TelemetryCollector()

        var index = 0
        let lock = NSLock()
        let transports = [mock1, mock2]

        let conn = RelayConnection(
            url: URL(string: "wss://test.relay")!,
            reconnectPolicy: ReconnectPolicy(
                baseDelay: 0.05,
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
        conn.telemetry = collector.handler

        let reconnected = expectation(description: "reconnected")
        var seenReconnecting = false
        conn.observeState { state in
            if state == .reconnecting { seenReconnecting = true }
            if seenReconnecting && state == .connected {
                reconnected.fulfill()
            }
        }

        conn.connect()
        mock1.enqueueDisconnect()
        wait(for: [reconnected], timeout: 3.0)

        // Should have: connected, disconnected(connectionLost), reconnectAttempt, reconnectSuccess, connected
        let attempts = collector.matching {
            if case .reconnectAttempt(_, let attempt, _) = $0 { return attempt == 1 }
            return false
        }
        XCTAssertEqual(attempts.count, 1, "Should emit exactly one reconnect attempt")

        let successes = collector.matching {
            if case .reconnectSuccess(_, let attempt) = $0 { return attempt == 1 }
            return false
        }
        XCTAssertEqual(successes.count, 1, "Should emit exactly one reconnect success")

        // Connection loss should have been logged
        let lostEvents = collector.matching {
            if case .disconnected(_, let reason) = $0 { return reason == "connectionLost" }
            return false
        }
        XCTAssertEqual(lostEvents.count, 1)

        conn.disconnect()
    }

    func testReconnectRestoresSubscriptionWithTelemetry() {
        let mock1 = MockWebSocketTransport()
        let mock2 = MockWebSocketTransport()
        let collector = TelemetryCollector()

        var index = 0
        let lock = NSLock()
        let transports = [mock1, mock2]

        let conn = RelayConnection(
            url: URL(string: "wss://test.relay")!,
            reconnectPolicy: ReconnectPolicy(
                baseDelay: 0.05,
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
        conn.telemetry = collector.handler

        conn.connect()

        // Create a subscription
        _ = try? conn.subscribe(
            filters: [NostrFilter(kinds: [1])],
            callbacks: SubscriptionCallbacks()
        )

        // Wait for REQ to be sent
        let reqSent = expectation(description: "REQ sent")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { reqSent.fulfill() }
        wait(for: [reqSent], timeout: 1.0)

        let reconnected = expectation(description: "reconnected")
        var seenReconnecting = false
        conn.observeState { state in
            if state == .reconnecting { seenReconnecting = true }
            if seenReconnecting && state == .connected {
                reconnected.fulfill()
            }
        }

        // Drop connection
        mock1.enqueueDisconnect()
        wait(for: [reconnected], timeout: 3.0)

        // Wait for subscription restore
        let restoreWait = expectation(description: "restore wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { restoreWait.fulfill() }
        wait(for: [restoreWait], timeout: 1.0)

        // Should have subscriptionRestored event for kf:0
        let restored = collector.matching {
            if case .subscriptionRestored(_, let subId) = $0 { return subId == "kf:0" }
            return false
        }
        XCTAssertEqual(restored.count, 1, "Should emit subscriptionRestored for kf:0")

        conn.disconnect()
    }

    // MARK: - Telemetry ordering

    func testTelemetryEventsInCorrectOrder() {
        let mock1 = MockWebSocketTransport()
        let mock2 = MockWebSocketTransport()
        let collector = TelemetryCollector()

        var index = 0
        let lock = NSLock()
        let transports = [mock1, mock2]

        let conn = RelayConnection(
            url: URL(string: "wss://test.relay")!,
            reconnectPolicy: ReconnectPolicy(
                baseDelay: 0.05,
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
        conn.telemetry = collector.handler

        let reconnected = expectation(description: "reconnected")
        var seenReconnecting = false
        conn.observeState { state in
            if state == .reconnecting { seenReconnecting = true }
            if seenReconnecting && state == .connected {
                reconnected.fulfill()
            }
        }

        conn.connect()
        mock1.enqueueDisconnect()
        wait(for: [reconnected], timeout: 3.0)

        // Verify ordering: connected → disconnected → reconnectAttempt → reconnectSuccess → connected
        let events = collector.events
        var connectedIdx: Int?
        var disconnectedIdx: Int?
        var attemptIdx: Int?
        var successIdx: Int?

        for (i, ev) in events.enumerated() {
            switch ev {
            case .connected:
                if connectedIdx == nil { connectedIdx = i }
            case .disconnected:
                disconnectedIdx = i
            case .reconnectAttempt:
                attemptIdx = i
            case .reconnectSuccess:
                successIdx = i
            default: break
            }
        }

        if let c = connectedIdx, let d = disconnectedIdx, let a = attemptIdx, let s = successIdx {
            XCTAssertLessThan(c, d, "connected should come before disconnected")
            XCTAssertLessThan(d, a, "disconnected should come before reconnectAttempt")
            XCTAssertLessThan(a, s, "reconnectAttempt should come before reconnectSuccess")
        } else {
            XCTFail("Missing expected telemetry events: connected=\(connectedIdx as Any), disconnected=\(disconnectedIdx as Any), attempt=\(attemptIdx as Any), success=\(successIdx as Any)")
        }

        conn.disconnect()
    }
}
