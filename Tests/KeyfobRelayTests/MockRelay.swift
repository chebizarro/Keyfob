// ──────────────────────────────────────────────────────────────────
// MockRelay.swift — High-level mock relay fixture for NIP-46 testing
// ──────────────────────────────────────────────────────────────────
//
// Provides a structured mock relay that wraps MockWebSocketTransport
// with helper methods for injecting relay frames (EVENT, OK, EOSE,
// CLOSED, AUTH, NOTICE) in a type-safe way. Eliminates raw JSON
// string construction in tests.
//
// Anti-patterns this fixture prevents:
// - Thread.sleep / Task.sleep for relay response timing
// - XCTestExpectation timeout as sole assertion mechanism
// - Missing OK/EOSE/CLOSED frames in mock sequences
//
// ──────────────────────────────────────────────────────────────────

import XCTest
@testable import KeyfobRelay

// MARK: - Mock Relay

/// A high-level mock relay that wraps MockWebSocketTransport.
///
/// Provides type-safe frame injection and assertion helpers
/// for event-driven relay protocol tests.
final class MockRelay: @unchecked Sendable {

    /// The underlying mock transport.
    let transport: MockWebSocketTransport

    /// The connection using this mock relay.
    let connection: RelayConnection

    /// Create a mock relay with a fresh connection.
    ///
    /// - Parameters:
    ///   - url: Relay URL (default: wss://mock.relay)
    ///   - reconnectPolicy: Reconnect policy (default: disabled for tests)
    init(
        url: URL = URL(string: "wss://mock.relay")!,
        reconnectPolicy: ReconnectPolicy = .disabled
    ) {
        let mock = MockWebSocketTransport()
        self.transport = mock
        self.connection = RelayConnection(
            url: url,
            reconnectPolicy: reconnectPolicy,
            transportFactory: { _ in mock }
        )
    }

    /// Connect the mock relay.
    func connect() {
        connection.connect()
    }

    /// Disconnect the mock relay.
    func disconnect() {
        connection.disconnect()
    }

    // MARK: - Frame Injection

    /// Inject an EVENT frame for a subscription.
    ///
    /// - Parameters:
    ///   - subscriptionId: The subscription ID to target.
    ///   - event: The relay event to deliver.
    func injectEvent(subscriptionId: String, event: RelayEvent) {
        let tags = event.tags.map { tag in
            "[" + tag.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        }.joined(separator: ",")

        let json = """
        ["EVENT","\(subscriptionId)",{"id":"\(event.id)","pubkey":"\(event.pubkey)",\
        "created_at":\(event.created_at),"kind":\(event.kind),\
        "tags":[\(tags)],"content":"\(event.content)","sig":"\(event.sig)"}]
        """
        transport.enqueue(json)
    }

    /// Inject an EOSE frame for a subscription.
    func injectEOSE(subscriptionId: String) {
        transport.enqueue(#"["EOSE","\#(subscriptionId)"]"#)
    }

    /// Inject an OK frame (accept or reject).
    ///
    /// - Parameters:
    ///   - eventId: The event ID being acknowledged.
    ///   - accepted: Whether the relay accepted the event.
    ///   - message: Rejection reason or empty string.
    func injectOK(eventId: String, accepted: Bool, message: String = "") {
        transport.enqueue("""
        ["OK","\(eventId)",\(accepted),"\(message)"]
        """)
    }

    /// Inject a CLOSED frame for a subscription.
    func injectClosed(subscriptionId: String, message: String) {
        transport.enqueue("""
        ["CLOSED","\(subscriptionId)","\(message)"]
        """)
    }

    /// Inject an AUTH challenge.
    func injectAuthChallenge(_ challenge: String) {
        transport.enqueue(#"["AUTH","\#(challenge)"]"#)
    }

    /// Inject a NOTICE frame.
    func injectNotice(_ message: String) {
        transport.enqueue(#"["NOTICE","\#(message)"]"#)
    }

    /// Simulate a connection drop (triggers reconnect if enabled).
    func injectDisconnect() {
        transport.enqueueDisconnect()
    }

    // MARK: - Sent Frame Inspection

    /// All messages sent by the client through this relay.
    var sentMessages: [String] { transport.sentMessages }

    /// Parse sent messages as ClientFrame objects.
    var sentFrames: [ClientFrame] {
        sentMessages.compactMap { text in
            // Parse JSON array to extract frame type
            guard let data = text.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let type = arr.first as? String else { return nil }

            switch type {
            case "EVENT":
                guard arr.count >= 2,
                      let eventData = try? JSONSerialization.data(withJSONObject: arr[1]),
                      let event = try? JSONDecoder().decode(RelayEvent.self, from: eventData)
                else { return nil }
                return .event(event)
            case "REQ":
                // REQ has subId + filters
                guard arr.count >= 3, let subId = arr[1] as? String else { return nil }
                return .req(subscriptionId: subId, filters: []) // Filters omitted for simplicity
            case "CLOSE":
                guard arr.count >= 2, let subId = arr[1] as? String else { return nil }
                return .close(subscriptionId: subId)
            case "AUTH":
                guard arr.count >= 2,
                      let eventData = try? JSONSerialization.data(withJSONObject: arr[1]),
                      let event = try? JSONDecoder().decode(RelayEvent.self, from: eventData)
                else { return nil }
                return .auth(event)
            default:
                return nil
            }
        }
    }

    /// Count of REQ frames sent.
    var reqCount: Int {
        sentFrames.filter {
            if case .req = $0 { return true }
            return false
        }.count
    }

    /// Count of EVENT frames sent (published events).
    var eventCount: Int {
        sentFrames.filter {
            if case .event = $0 { return true }
            return false
        }.count
    }

    /// Count of AUTH frames sent.
    var authCount: Int {
        sentFrames.filter {
            if case .auth = $0 { return true }
            return false
        }.count
    }

    // MARK: - Event Factory

    /// Create a sample relay event for testing.
    static func makeEvent(
        id: String = "evt-\(UUID().uuidString.prefix(8))",
        pubkey: String = "test-pubkey",
        kind: Int = 1,
        content: String = "test content",
        tags: [[String]] = [],
        createdAt: Int = Int(Date().timeIntervalSince1970)
    ) -> RelayEvent {
        RelayEvent(
            id: id,
            pubkey: pubkey,
            created_at: createdAt,
            kind: kind,
            tags: tags,
            content: content,
            sig: "test-sig-\(id)"
        )
    }

    /// Create a NIP-46 kind 24133 event for testing.
    static func makeNIP46Event(
        id: String = "nip46-\(UUID().uuidString.prefix(8))",
        fromPubkey: String = "requester-pubkey",
        toPubkey: String = "signer-pubkey",
        content: String = "encrypted-content"
    ) -> RelayEvent {
        makeEvent(
            id: id,
            pubkey: fromPubkey,
            kind: 24133,
            content: content,
            tags: [["p", toPubkey]]
        )
    }
}
