// ──────────────────────────────────────────────────────────────────
// RelayAuthTests.swift — Tests for NIP-42 AUTH challenge/response
// ──────────────────────────────────────────────────────────────────

import XCTest
@testable import KeyfobRelay

// MARK: - Mock Auth Signer

/// A mock signer that returns a pre-built auth event.
final class MockAuthSigner: RelayAuthSigner, @unchecked Sendable {
    var capturedChallenge: String?
    var capturedRelayURL: URL?
    var shouldFail = false
    var eventToReturn: RelayEvent?

    func signAuthEvent(challenge: String, relayURL: URL) async throws -> RelayEvent {
        capturedChallenge = challenge
        capturedRelayURL = relayURL
        if shouldFail {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "mock signing error"])
        }
        return eventToReturn ?? RelayEvent(
            id: "auth-evt-1",
            pubkey: "mypubkey",
            created_at: 1700000000,
            kind: 22242,
            tags: [["relay", relayURL.absoluteString], ["challenge", challenge]],
            content: "",
            sig: "authsig"
        )
    }
}

// MARK: - Auth Tests

final class RelayAuthTests: XCTestCase {

    private var mockTransport: MockWebSocketTransport!
    private var mockSigner: MockAuthSigner!
    private var connection: RelayConnection!

    override func setUp() {
        super.setUp()
        mockTransport = MockWebSocketTransport()
        mockSigner = MockAuthSigner()
        let transport = mockTransport!
        connection = RelayConnection(
            url: URL(string: "wss://auth.relay.example")!,
            reconnectPolicy: .disabled,
            transportFactory: { _ in transport }
        )
        connection.authSigner = mockSigner
    }

    override func tearDown() {
        connection.disconnect()
        connection = nil
        mockTransport = nil
        mockSigner = nil
        super.tearDown()
    }

    // MARK: - Auth State Transitions

    func testInitialAuthState() {
        XCTAssertEqual(connection.authState, .notRequired)
    }

    func testAuthChallengeTriggersSigningFlow() {
        connection.connect()

        let authenticated = expectation(description: "authenticated")
        connection.onAuthStateChange = { state in
            if state == .authenticated {
                authenticated.fulfill()
            }
        }

        // Relay sends AUTH challenge
        mockTransport.enqueue(#"["AUTH","challenge-abc"]"#)

        // After signing, relay sends OK for the auth event
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            self.mockTransport.enqueue(#"["OK","auth-evt-1",true,""]"#)
        }

        wait(for: [authenticated], timeout: 3.0)

        XCTAssertEqual(connection.authState, .authenticated)
        XCTAssertEqual(mockSigner.capturedChallenge, "challenge-abc")
        XCTAssertEqual(mockSigner.capturedRelayURL, URL(string: "wss://auth.relay.example")!)
    }

    func testAuthStateTransitionsInOrder() {
        connection.connect()

        var stateHistory: [AuthState] = []
        let lock = NSLock()
        let done = expectation(description: "auth complete")

        connection.onAuthStateChange = { state in
            lock.lock()
            stateHistory.append(state)
            lock.unlock()
            if state == .authenticated {
                done.fulfill()
            }
        }

        mockTransport.enqueue(#"["AUTH","challenge-xyz"]"#)

        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            self.mockTransport.enqueue(#"["OK","auth-evt-1",true,""]"#)
        }

        wait(for: [done], timeout: 3.0)

        // Should see: challenged → authenticating → authenticated
        XCTAssertTrue(stateHistory.count >= 3, "Expected at least 3 state transitions, got \(stateHistory.count)")
        XCTAssertEqual(stateHistory[0], .challenged("challenge-xyz"))
        XCTAssertEqual(stateHistory[1], .authenticating)
        XCTAssertEqual(stateHistory[2], .authenticated)
    }

    func testAuthRejected() {
        connection.connect()

        let failed = expectation(description: "auth failed")
        connection.onAuthStateChange = { state in
            if case .failed = state {
                failed.fulfill()
            }
        }

        mockTransport.enqueue(#"["AUTH","challenge-reject"]"#)

        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            self.mockTransport.enqueue(#"["OK","auth-evt-1",false,"restricted: access denied"]"#)
        }

        wait(for: [failed], timeout: 3.0)
        XCTAssertEqual(connection.authState, .failed("restricted: access denied"))
    }

    func testSigningFailure() {
        mockSigner.shouldFail = true
        connection.connect()

        let failed = expectation(description: "signing failed")
        connection.onAuthStateChange = { state in
            if case .failed = state {
                failed.fulfill()
            }
        }

        mockTransport.enqueue(#"["AUTH","challenge-fail"]"#)
        wait(for: [failed], timeout: 3.0)

        if case .failed(let msg) = connection.authState {
            XCTAssertTrue(msg.contains("signing failed"), "Expected signing failure message, got: \(msg)")
        } else {
            XCTFail("Expected .failed state")
        }
    }

    func testWrongKindRejected() {
        // Signer returns kind 1 instead of 22242
        mockSigner.eventToReturn = RelayEvent(
            id: "bad-kind", pubkey: "pk", created_at: 100,
            kind: 1, tags: [], content: "", sig: "sig"
        )
        connection.connect()

        let failed = expectation(description: "wrong kind rejected")
        connection.onAuthStateChange = { state in
            if case .failed = state {
                failed.fulfill()
            }
        }

        mockTransport.enqueue(#"["AUTH","challenge-badkind"]"#)
        wait(for: [failed], timeout: 3.0)

        if case .failed(let msg) = connection.authState {
            XCTAssertTrue(msg.contains("wrong kind"), "Expected wrong kind message, got: \(msg)")
        } else {
            XCTFail("Expected .failed state")
        }
    }

    // MARK: - Auth Response Sent

    func testAuthResponseSentToRelay() {
        connection.connect()

        let authenticating = expectation(description: "authenticating")
        connection.onAuthStateChange = { state in
            if state == .authenticating {
                authenticating.fulfill()
            }
        }

        mockTransport.enqueue(#"["AUTH","challenge-send"]"#)
        wait(for: [authenticating], timeout: 3.0)

        // Give the send task a moment
        let sendCheck = expectation(description: "check sent")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { sendCheck.fulfill() }
        wait(for: [sendCheck], timeout: 1.0)

        let authMessages = mockTransport.sentMessages.filter { $0.contains("\"AUTH\"") }
        XCTAssertEqual(authMessages.count, 1, "Should have sent one AUTH response")
        XCTAssertTrue(authMessages[0].contains("auth-evt-1"))
        XCTAssertTrue(authMessages[0].contains("22242"))
    }

    // MARK: - Callback Fallback

    func testAuthChallengeFallsBackToCallbackWithoutSigner() {
        connection.authSigner = nil
        connection.connect()

        let callbackFired = expectation(description: "callback fired")
        var capturedChallenge: String?
        connection.onAuthChallenge = { challenge in
            capturedChallenge = challenge
            callbackFired.fulfill()
        }

        mockTransport.enqueue(#"["AUTH","fallback-challenge"]"#)
        wait(for: [callbackFired], timeout: 2.0)

        XCTAssertEqual(capturedChallenge, "fallback-challenge")
        XCTAssertEqual(connection.authState, .notRequired)
    }

    // MARK: - Pending Subscription Retry After Auth

    func testClosedAuthRequiredSubscriptionRetriedAfterAuth() {
        connection.connect()

        // Create a subscription
        let eventReceived = expectation(description: "event on retried sub")
        let _ = try? connection.subscribe(
            filters: [NostrFilter(kinds: [1])],
            callbacks: SubscriptionCallbacks(
                onEvent: { _ in eventReceived.fulfill() }
            )
        )

        // Wait for REQ to be sent
        let reqSent = expectation(description: "REQ sent")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { reqSent.fulfill() }
        wait(for: [reqSent], timeout: 1.0)

        // Relay closes the subscription with auth-required
        mockTransport.enqueue(#"["CLOSED","kf:0","auth-required: please authenticate"]"#)

        // Then relay sends AUTH challenge
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.mockTransport.enqueue(##"["AUTH","challenge-retry"]"##)
        }

        // After signing, relay sends OK
        let authenticated = expectation(description: "authenticated")
        connection.onAuthStateChange = { state in
            if state == .authenticated {
                authenticated.fulfill()
            }
        }

        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            self.mockTransport.enqueue(#"["OK","auth-evt-1",true,""]"#)
        }

        wait(for: [authenticated], timeout: 3.0)

        // Subscription should have been restored — check for re-sent REQ
        let retryCheck = expectation(description: "REQ retried")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { retryCheck.fulfill() }
        wait(for: [retryCheck], timeout: 1.0)

        let reqMessages = mockTransport.sentMessages.filter { $0.contains("\"REQ\"") }
        XCTAssertGreaterThanOrEqual(reqMessages.count, 2, "Should have initial + retried REQ")

        // Subscription is back in active set
        XCTAssertTrue(connection.activeSubscriptionIds.contains("kf:0"))

        // Deliver an event to the retried subscription
        mockTransport.enqueue("""
        ["EVENT","kf:0",{"id":"e1","pubkey":"pk","created_at":100,"kind":1,"tags":[],"content":"after auth","sig":"s"}]
        """)

        wait(for: [eventReceived], timeout: 2.0)
    }

    func testClosedAuthRequiredWithoutSignerCallsOnClosed() {
        connection.authSigner = nil
        connection.connect()

        let closedCalled = expectation(description: "onClosed called")
        var closedMessage: String?

        let _ = try? connection.subscribe(
            filters: [NostrFilter(kinds: [1])],
            callbacks: SubscriptionCallbacks(
                onClosed: { msg in
                    closedMessage = msg
                    closedCalled.fulfill()
                }
            )
        )

        let reqSent = expectation(description: "REQ sent")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { reqSent.fulfill() }
        wait(for: [reqSent], timeout: 1.0)

        // Without signer, CLOSED auth-required should just pass through
        mockTransport.enqueue(#"["CLOSED","kf:0","auth-required: authenticate"]"#)
        wait(for: [closedCalled], timeout: 2.0)
        XCTAssertEqual(closedMessage, "auth-required: authenticate")
    }

    func testAuthFailedNotifiesPendingSubs() {
        connection.connect()

        let closedCalled = expectation(description: "onClosed called after auth failure")

        let _ = try? connection.subscribe(
            filters: [NostrFilter(kinds: [1])],
            callbacks: SubscriptionCallbacks(
                onClosed: { msg in
                    if msg.contains("authentication failed") {
                        closedCalled.fulfill()
                    }
                }
            )
        )

        let reqSent = expectation(description: "REQ sent")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { reqSent.fulfill() }
        wait(for: [reqSent], timeout: 1.0)

        // Close with auth-required
        mockTransport.enqueue(#"["CLOSED","kf:0","auth-required: need auth"]"#)

        // AUTH challenge
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.mockTransport.enqueue(##"["AUTH","challenge-authfail"]"##)
        }

        // Auth rejected
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            self.mockTransport.enqueue(#"["OK","auth-evt-1",false,"restricted: denied"]"#)
        }

        wait(for: [closedCalled], timeout: 3.0)
        // Subscription should NOT be in active set
        XCTAssertFalse(connection.activeSubscriptionIds.contains("kf:0"))
    }

    // MARK: - Auth State Reset

    func testDisconnectResetsAuthState() {
        connection.connect()

        let authenticating = expectation(description: "authenticating")
        connection.onAuthStateChange = { state in
            if state == .authenticating {
                authenticating.fulfill()
            }
        }

        mockTransport.enqueue(#"["AUTH","challenge-reset"]"#)
        wait(for: [authenticating], timeout: 3.0)

        connection.disconnect()
        XCTAssertEqual(connection.authState, .notRequired)
    }

    // MARK: - OK Routing

    func testOKForAuthEventNotPassedToPublishContinuation() async throws {
        connection.connect()

        let authenticated = expectation(description: "authenticated")
        connection.onAuthStateChange = { state in
            if state == .authenticated {
                authenticated.fulfill()
            }
        }

        // Trigger auth
        mockTransport.enqueue(#"["AUTH","challenge-ok"]"#)

        // Wait for auth to be in authenticating state
        let authWait = expectation(description: "wait for auth")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { authWait.fulfill() }
        await fulfillment(of: [authWait], timeout: 1.0)

        // Now publish an event
        let event = RelayEvent(
            id: "pub-during-auth", pubkey: "pk", created_at: 100,
            kind: 1, tags: [], content: "test", sig: "sig"
        )

        // Send OK for auth event (should NOT go to publish)
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.mockTransport.enqueue(#"["OK","auth-evt-1",true,""]"#)
            // Then send OK for the published event
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.mockTransport.enqueue(#"["OK","pub-during-auth",true,""]"#)
        }

        await fulfillment(of: [authenticated], timeout: 3.0)

        // The publish should get its own OK
        let result = try await connection.publish(event: event)
        XCTAssertEqual(result.eventId, "pub-during-auth")
        XCTAssertTrue(result.accepted)
    }
}
