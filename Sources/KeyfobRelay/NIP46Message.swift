// ──────────────────────────────────────────────────────────────────
// NIP46Message.swift — NIP-46 JSON-RPC message model
// ──────────────────────────────────────────────────────────────────

import Foundation

// MARK: - NIP-46 Methods

/// Supported NIP-46 JSON-RPC methods.
public enum NIP46Method: String, Codable, Sendable, Equatable {
    /// Sign a Nostr event.
    case sign_event
    /// Get the signer's public key.
    case get_public_key
    /// Ping the signer (liveness check).
    case ping
    /// Connect/authenticate a remote app.
    case connect
}

// MARK: - NIP-46 Request

/// A parsed NIP-46 JSON-RPC request (decrypted from kind 24133 content).
public struct NIP46Request: Sendable, Equatable {
    /// JSON-RPC correlation ID.
    public let id: String
    /// The requested method.
    public let method: NIP46Method
    /// Method parameters (varies by method).
    public let params: [String]

    public init(id: String, method: NIP46Method, params: [String] = []) {
        self.id = id
        self.method = method
        self.params = params
    }

    /// Parse a NIP-46 request from a decrypted JSON string.
    public static func parse(_ json: String) throws -> NIP46Request {
        guard let data = json.data(using: .utf8) else {
            throw NIP46Error.invalidJSON
        }
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw NIP46Error.invalidJSON
        }
        guard let obj = raw as? [String: Any] else {
            throw NIP46Error.invalidJSON
        }
        guard let id = obj["id"] as? String else {
            throw NIP46Error.missingField("id")
        }
        guard let methodStr = obj["method"] as? String else {
            throw NIP46Error.missingField("method")
        }
        guard let method = NIP46Method(rawValue: methodStr) else {
            throw NIP46Error.unsupportedMethod(methodStr)
        }
        let params = (obj["params"] as? [String]) ?? []
        return NIP46Request(id: id, method: method, params: params)
    }
}

// MARK: - NIP-46 Response

/// A NIP-46 JSON-RPC response (to be encrypted and published as kind 24133).
public struct NIP46Response: Sendable, Equatable {
    /// JSON-RPC correlation ID (must match the request).
    public let id: String
    /// Result on success (JSON string or value).
    public let result: String?
    /// Error message on failure.
    public let error: String?

    /// Create a success response.
    public static func success(id: String, result: String) -> NIP46Response {
        NIP46Response(id: id, result: result, error: nil)
    }

    /// Create an error response.
    public static func failure(id: String, error: String) -> NIP46Response {
        NIP46Response(id: id, result: nil, error: error)
    }

    /// Serialize to a JSON string for encryption.
    public func toJSON() throws -> String {
        var dict: [String: Any] = ["id": id]
        if let result = result { dict["result"] = result }
        if let error = error { dict["error"] = error }
        let data = try JSONSerialization.data(withJSONObject: dict, options: .sortedKeys)
        guard let json = String(data: data, encoding: .utf8) else {
            throw NIP46Error.serializationFailed
        }
        return json
    }
}

// MARK: - NIP-46 Errors

/// Errors from NIP-46 message handling.
public enum NIP46Error: Error, Equatable {
    case invalidJSON
    case missingField(String)
    case unsupportedMethod(String)
    case serializationFailed
    case decryptionFailed(String)
    case encryptionFailed(String)
    case signingFailed(String)
    case requestTimeout
    case notConnected
}

// MARK: - Request Session State

/// Per-request processing state for the NIP-46 state machine.
public enum NIP46RequestState: Sendable, Equatable {
    /// Request received, awaiting processing.
    case receivedRequest
    /// Awaiting user consent (for sign_event).
    case awaitingConsent
    /// Consent granted, signing in progress.
    case signing
    /// Signed, publishing response to relay.
    case publishing
    /// Response published successfully.
    case completed
    /// Processing failed.
    case errored(String)
    /// Request timed out (e.g., consent never granted).
    case timedOut
}

// MARK: - Request Session

/// Tracks the state of an in-flight NIP-46 request.
public final class NIP46RequestSession: @unchecked Sendable {

    /// The original request.
    public let request: NIP46Request
    /// Pubkey of the requesting app.
    public let requesterPubkey: String
    /// The relay event ID that carried this request.
    public let eventId: String
    /// When the request was received.
    public let receivedAt: Date

    private let lock = NSLock()
    private var _state: NIP46RequestState = .receivedRequest

    /// Current processing state.
    public var state: NIP46RequestState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    /// State change callback.
    public var onStateChange: (@Sendable (NIP46RequestState) -> Void)?

    public init(
        request: NIP46Request,
        requesterPubkey: String,
        eventId: String,
        receivedAt: Date = Date()
    ) {
        self.request = request
        self.requesterPubkey = requesterPubkey
        self.eventId = eventId
        self.receivedAt = receivedAt
    }

    /// Transition to a new state.
    public func transition(to newState: NIP46RequestState) {
        lock.lock()
        _state = newState
        let callback = onStateChange
        lock.unlock()
        callback?(newState)
    }

    /// Whether this request has timed out.
    public func hasTimedOut(timeout: TimeInterval) -> Bool {
        Date().timeIntervalSince(receivedAt) >= timeout
    }
}
