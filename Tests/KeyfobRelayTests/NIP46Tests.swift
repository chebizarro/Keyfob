// ──────────────────────────────────────────────────────────────────
// NIP46Tests.swift — Tests for NIP-46 remote signer protocol
// ──────────────────────────────────────────────────────────────────

import XCTest
@testable import KeyfobRelay

// MARK: - Mock NIP-46 Delegate

final class MockNIP46Delegate: NIP46Delegate, @unchecked Sendable {
    private let lock = NSLock()

    /// Decrypted content to return (maps encrypted→decrypted).
    var decryptMap: [String: String] = [:]
    /// Whether decrypt should throw.
    var decryptShouldFail = false

    /// Encrypted content to return (maps plain→encrypted).
    var encryptMap: [String: String] = [:]

    /// The signer's pubkey.
    var pubkey = "signer-pubkey-hex"

    /// Whether signEvent should throw.
    var signShouldFail = false
    /// The signed event JSON to return.
    var signedResult = #"{"id":"signed-id","sig":"signed-sig"}"#

    /// Track calls for verification.
    var signEventCalls: [(eventJSON: String, requesterPubkey: String)] = []

    /// Response event ID counter.
    var responseEventCounter = 0

    func decrypt(content: String, fromPubkey: String) async throws -> String {
        if decryptShouldFail { throw NIP46Error.decryptionFailed("mock decrypt failure") }
        return decryptMap[content] ?? content // passthrough if not mapped
    }

    func encrypt(content: String, forPubkey: String) async throws -> String {
        return encryptMap[content] ?? "encrypted:\(content)"
    }

    func getPublicKey() async -> String {
        return pubkey
    }

    func signEvent(eventJSON: String, requesterPubkey: String) async throws -> String {
        lock.lock()
        signEventCalls.append((eventJSON, requesterPubkey))
        lock.unlock()
        if signShouldFail { throw NIP46Error.signingFailed("mock sign failure") }
        return signedResult
    }

    func buildResponseEvent(content: String, recipientPubkey: String) async throws -> RelayEvent {
        lock.lock()
        responseEventCounter += 1
        let id = "resp-\(responseEventCounter)"
        lock.unlock()
        return RelayEvent(
            id: id,
            pubkey: pubkey,
            created_at: Int(Date().timeIntervalSince1970),
            kind: 24133,
            tags: [["p", recipientPubkey]],
            content: content,
            sig: "resp-sig-\(id)"
        )
    }
}

// MARK: - NIP-46 Message Tests

final class NIP46MessageTests: XCTestCase {

    // MARK: - Request Parsing

    func testParseSignEventRequest() throws {
        let json = #"{"id":"req-1","method":"sign_event","params":["{\"kind\":1}"]}"#
        let req = try NIP46Request.parse(json)
        XCTAssertEqual(req.id, "req-1")
        XCTAssertEqual(req.method, .sign_event)
        XCTAssertEqual(req.params, [#"{"kind":1}"#])
    }

    func testParsePingRequest() throws {
        let json = #"{"id":"req-2","method":"ping","params":[]}"#
        let req = try NIP46Request.parse(json)
        XCTAssertEqual(req.method, .ping)
        XCTAssertTrue(req.params.isEmpty)
    }

    func testParseGetPublicKeyRequest() throws {
        let json = #"{"id":"req-3","method":"get_public_key"}"#
        let req = try NIP46Request.parse(json)
        XCTAssertEqual(req.method, .get_public_key)
    }

    func testParseConnectRequest() throws {
        let json = #"{"id":"req-4","method":"connect","params":["my-secret-token"]}"#
        let req = try NIP46Request.parse(json)
        XCTAssertEqual(req.method, .connect)
        XCTAssertEqual(req.params, ["my-secret-token"])
    }

    func testParseInvalidJSON() {
        XCTAssertThrowsError(try NIP46Request.parse("not json")) { error in
            XCTAssertEqual(error as? NIP46Error, .invalidJSON)
        }
    }

    func testParseMissingId() {
        let json = #"{"method":"ping"}"#
        XCTAssertThrowsError(try NIP46Request.parse(json)) { error in
            XCTAssertEqual(error as? NIP46Error, .missingField("id"))
        }
    }

    func testParseMissingMethod() {
        let json = #"{"id":"req-5"}"#
        XCTAssertThrowsError(try NIP46Request.parse(json)) { error in
            XCTAssertEqual(error as? NIP46Error, .missingField("method"))
        }
    }

    func testParseUnsupportedMethod() {
        let json = #"{"id":"req-6","method":"unknown_method"}"#
        XCTAssertThrowsError(try NIP46Request.parse(json)) { error in
            XCTAssertEqual(error as? NIP46Error, .unsupportedMethod("unknown_method"))
        }
    }

    // MARK: - Response Serialization

    func testSuccessResponse() throws {
        let resp = NIP46Response.success(id: "req-1", result: "pong")
        let json = try resp.toJSON()
        let data = json.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["id"] as? String, "req-1")
        XCTAssertEqual(obj["result"] as? String, "pong")
        XCTAssertNil(obj["error"])
    }

    func testErrorResponse() throws {
        let resp = NIP46Response.failure(id: "req-2", error: "auth failed")
        let json = try resp.toJSON()
        let data = json.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["id"] as? String, "req-2")
        XCTAssertEqual(obj["error"] as? String, "auth failed")
        XCTAssertNil(obj["result"])
    }

    // MARK: - Request Session

    func testRequestSessionStateTransitions() {
        let session = NIP46RequestSession(
            request: NIP46Request(id: "sess-1", method: .ping),
            requesterPubkey: "pk",
            eventId: "evt-1"
        )

        XCTAssertEqual(session.state, .receivedRequest)

        var states: [NIP46RequestState] = []
        let lock = NSLock()
        session.onStateChange = { state in
            lock.lock()
            states.append(state)
            lock.unlock()
        }

        session.transition(to: .publishing)
        session.transition(to: .completed)

        lock.lock()
        XCTAssertEqual(states, [.publishing, .completed])
        lock.unlock()
    }

    func testRequestSessionTimeout() {
        let session = NIP46RequestSession(
            request: NIP46Request(id: "sess-2", method: .sign_event),
            requesterPubkey: "pk",
            eventId: "evt-2",
            receivedAt: Date().addingTimeInterval(-400) // 400s ago
        )

        XCTAssertTrue(session.hasTimedOut(timeout: 300)) // 5 min timeout
        XCTAssertFalse(session.hasTimedOut(timeout: 600)) // 10 min timeout
    }
}

// MARK: - NIP-46 Handler Tests

final class NIP46HandlerTests: XCTestCase {

    private var relay: MockRelay!
    private var mockDelegate: MockNIP46Delegate!
    private var handler: NIP46Handler!

    override func setUp() {
        super.setUp()
        relay = MockRelay()
        relay.connect()
        mockDelegate = MockNIP46Delegate()
        handler = NIP46Handler(
            connection: relay.connection,
            delegate: mockDelegate,
            signerPubkey: "signer-pubkey-hex"
        )
    }

    override func tearDown() {
        handler.stop()
        relay.disconnect()
        relay = nil
        mockDelegate = nil
        handler = nil
        super.tearDown()
    }

    /// Helper: make a kind 24133 request event with decryptable content.
    private func injectNIP46Request(
        eventId: String = "nip46-evt-1",
        fromPubkey: String = "requester-pk",
        requestJSON: String
    ) {
        // Map the "encrypted" content to the decrypted request JSON
        let encrypted = "enc:\(requestJSON)"
        mockDelegate.decryptMap[encrypted] = requestJSON

        // First subscription on a fresh RelayConnection is always "kf:0".
        // The subscription is registered synchronously in subscribe(),
        // only the REQ frame send is async — so the ID is deterministic.
        let subId = "kf:0"

        relay.injectEvent(
            subscriptionId: subId,
            event: RelayEvent(
                id: eventId,
                pubkey: fromPubkey,
                created_at: Int(Date().timeIntervalSince1970),
                kind: 24133,
                tags: [["p", "signer-pubkey-hex"]],
                content: encrypted,
                sig: "sig-\(eventId)"
            )
        )
    }

    // MARK: - Ping

    func testPingRequest() async throws {
        try handler.start()

        let responsePublished = expectation(description: "response published")

        // Watch for response event being published
        handler.onRequestStateChange = { session, state in
            if state == .completed { responsePublished.fulfill() }
        }

        // Wait for subscription to be established
        try? await Task.sleep(nanoseconds: 50_000_000)

        injectNIP46Request(
            requestJSON: #"{"id":"ping-1","method":"ping","params":[]}"#
        )

        // Inject OK for the response event (guard against tearDown racing)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let relay = self?.relay else { return }
            relay.injectOK(eventId: "resp-1", accepted: true)
        }

        await fulfillment(of: [responsePublished], timeout: 2.0)
        XCTAssertTrue(handler.activeSessions.isEmpty)
    }

    // MARK: - Get Public Key

    func testGetPublicKeyRequest() async throws {
        try handler.start()

        let completed = expectation(description: "completed")
        handler.onRequestStateChange = { _, state in
            if state == .completed { completed.fulfill() }
        }

        try? await Task.sleep(nanoseconds: 50_000_000)

        injectNIP46Request(
            eventId: "gpk-evt",
            requestJSON: #"{"id":"gpk-1","method":"get_public_key","params":[]}"#
        )

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let relay = self?.relay else { return }
            relay.injectOK(eventId: "resp-1", accepted: true)
        }

        await fulfillment(of: [completed], timeout: 2.0)
    }

    // MARK: - Connect

    func testConnectWithValidSecret() async throws {
        handler.requiredSecret = "my-secret"
        try handler.start()

        let completed = expectation(description: "completed")
        handler.onRequestStateChange = { _, state in
            if state == .completed { completed.fulfill() }
        }

        try? await Task.sleep(nanoseconds: 50_000_000)

        injectNIP46Request(
            eventId: "conn-evt",
            requestJSON: #"{"id":"conn-1","method":"connect","params":["my-secret"]}"#
        )

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let relay = self?.relay else { return }
            relay.injectOK(eventId: "resp-1", accepted: true)
        }

        await fulfillment(of: [completed], timeout: 2.0)
        XCTAssertEqual(handler.connectedApps.count, 1)
        XCTAssertEqual(handler.connectedApps.first?.pubkey, "requester-pk")
    }

    func testConnectWithInvalidSecret() async throws {
        handler.requiredSecret = "correct-secret"
        try handler.start()

        let errored = expectation(description: "errored")
        handler.onRequestStateChange = { _, state in
            if case .errored = state { errored.fulfill() }
        }

        try? await Task.sleep(nanoseconds: 50_000_000)

        injectNIP46Request(
            eventId: "conn-bad",
            requestJSON: #"{"id":"conn-2","method":"connect","params":["wrong-secret"]}"#
        )

        // Error path: state fires before publish, OK still needed to unblock publish
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let relay = self?.relay else { return }
            relay.injectOK(eventId: "resp-1", accepted: true)
        }

        await fulfillment(of: [errored], timeout: 2.0)
        XCTAssertTrue(handler.connectedApps.isEmpty)
    }

    // MARK: - Sign Event

    func testSignEventRequest() async throws {
        try handler.start()

        let completed = expectation(description: "completed")
        handler.onRequestStateChange = { _, state in
            if state == .completed { completed.fulfill() }
        }

        try? await Task.sleep(nanoseconds: 50_000_000)

        injectNIP46Request(
            eventId: "sign-evt",
            requestJSON: #"{"id":"sign-1","method":"sign_event","params":["{\"kind\":1,\"content\":\"hello\"}"]}"#
        )

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let relay = self?.relay else { return }
            relay.injectOK(eventId: "resp-1", accepted: true)
        }

        await fulfillment(of: [completed], timeout: 2.0)

        // Verify delegate was called
        XCTAssertEqual(mockDelegate.signEventCalls.count, 1)
        XCTAssertEqual(mockDelegate.signEventCalls.first?.requesterPubkey, "requester-pk")
    }

    func testSignEventFailure() async throws {
        mockDelegate.signShouldFail = true
        try handler.start()

        let errored = expectation(description: "errored")
        handler.onRequestStateChange = { _, state in
            if case .errored = state { errored.fulfill() }
        }

        try? await Task.sleep(nanoseconds: 50_000_000)

        injectNIP46Request(
            eventId: "sign-fail",
            requestJSON: #"{"id":"sign-2","method":"sign_event","params":["{\"kind\":1}"]}"#
        )

        // Error path: state fires before publish, OK still needed to unblock publish
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let relay = self?.relay else { return }
            relay.injectOK(eventId: "resp-1", accepted: true)
        }

        await fulfillment(of: [errored], timeout: 2.0)
    }

    // MARK: - Deduplication

    func testDuplicateEventsDropped() async throws {
        try handler.start()

        let completed = expectation(description: "completed")
        handler.onRequestStateChange = { _, state in
            if state == .completed { completed.fulfill() }
        }

        try? await Task.sleep(nanoseconds: 50_000_000)

        // Send same event twice (same event ID)
        injectNIP46Request(
            eventId: "dup-evt",
            requestJSON: #"{"id":"dup-1","method":"ping","params":[]}"#
        )
        injectNIP46Request(
            eventId: "dup-evt", // Same event ID
            requestJSON: #"{"id":"dup-1","method":"ping","params":[]}"#
        )

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let relay = self?.relay else { return }
            relay.injectOK(eventId: "resp-1", accepted: true)
        }

        await fulfillment(of: [completed], timeout: 2.0)
        // Only one response should be published (delegate counter = 1)
        XCTAssertEqual(mockDelegate.responseEventCounter, 1)
    }

    // MARK: - Decrypt Failure

    func testDecryptFailureSilentlyDrops() async throws {
        mockDelegate.decryptShouldFail = true
        try handler.start()

        try? await Task.sleep(nanoseconds: 50_000_000)

        injectNIP46Request(
            eventId: "decrypt-fail",
            requestJSON: #"{"id":"df-1","method":"ping","params":[]}"#
        )

        // Wait a bit — nothing should happen
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(handler.activeSessions.isEmpty)
        XCTAssertEqual(mockDelegate.responseEventCounter, 0)
    }
}
