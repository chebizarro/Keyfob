// ──────────────────────────────────────────────────────────────────
// RelayFrame.swift — Nostr relay protocol frame types
// ──────────────────────────────────────────────────────────────────

import Foundation

// MARK: - Relay Event (self-contained for zero-dep module)

/// A signed Nostr event as delivered by a relay.
/// Compatible with KeyfobCore.NostrEvent but independently decodable.
public struct RelayEvent: Codable, Equatable, Sendable {
    public let id: String
    public let pubkey: String
    public let created_at: Int
    public let kind: Int
    public let tags: [[String]]
    public let content: String
    public let sig: String

    public init(id: String, pubkey: String, created_at: Int, kind: Int,
                tags: [[String]], content: String, sig: String) {
        self.id = id
        self.pubkey = pubkey
        self.created_at = created_at
        self.kind = kind
        self.tags = tags
        self.content = content
        self.sig = sig
    }
}

// MARK: - Server → Client Frames

/// A frame received from a Nostr relay.
public enum ServerFrame: Equatable, Sendable {
    /// `["EVENT", <subscription_id>, <event>]`
    case event(subscriptionId: String, event: RelayEvent)
    /// `["OK", <event_id>, <accepted>, <message>]`
    case ok(eventId: String, accepted: Bool, message: String)
    /// `["EOSE", <subscription_id>]`
    case eose(subscriptionId: String)
    /// `["CLOSED", <subscription_id>, <message>]`
    case closed(subscriptionId: String, message: String)
    /// `["NOTICE", <message>]`
    case notice(message: String)
    /// `["AUTH", <challenge>]`
    case auth(challenge: String)
}

// MARK: - Client → Server Frames

/// A frame sent from the client to a Nostr relay.
public enum ClientFrame: Equatable, Sendable {
    /// `["EVENT", <event>]`
    case event(RelayEvent)
    /// `["REQ", <subscription_id>, <filter>, ...]`
    case req(subscriptionId: String, filters: [NostrFilter])
    /// `["CLOSE", <subscription_id>]`
    case close(subscriptionId: String)
    /// `["AUTH", <event>]`
    case auth(RelayEvent)
}

// MARK: - Parsing

extension ServerFrame {
    /// Parse a raw JSON string from the relay into a `ServerFrame`.
    public static func parse(_ text: String) throws -> ServerFrame {
        guard let data = text.data(using: .utf8) else {
            throw RelayFrameError.invalidJSON
        }
        guard let array = try JSONSerialization.jsonObject(with: data) as? [Any],
              let label = array.first as? String else {
            throw RelayFrameError.invalidStructure
        }
        switch label {
        case "EVENT":
            guard array.count >= 3,
                  let subId = array[1] as? String else {
                throw RelayFrameError.invalidStructure
            }
            let eventData = try JSONSerialization.data(withJSONObject: array[2])
            let event = try JSONDecoder().decode(RelayEvent.self, from: eventData)
            return .event(subscriptionId: subId, event: event)

        case "OK":
            guard array.count >= 4,
                  let eventId = array[1] as? String,
                  let accepted = array[2] as? Bool else {
                throw RelayFrameError.invalidStructure
            }
            let message = (array[3] as? String) ?? ""
            return .ok(eventId: eventId, accepted: accepted, message: message)

        case "EOSE":
            guard array.count >= 2, let subId = array[1] as? String else {
                throw RelayFrameError.invalidStructure
            }
            return .eose(subscriptionId: subId)

        case "CLOSED":
            guard array.count >= 3,
                  let subId = array[1] as? String,
                  let message = array[2] as? String else {
                throw RelayFrameError.invalidStructure
            }
            return .closed(subscriptionId: subId, message: message)

        case "NOTICE":
            guard array.count >= 2, let message = array[1] as? String else {
                throw RelayFrameError.invalidStructure
            }
            return .notice(message: message)

        case "AUTH":
            guard array.count >= 2, let challenge = array[1] as? String else {
                throw RelayFrameError.invalidStructure
            }
            return .auth(challenge: challenge)

        default:
            throw RelayFrameError.unknownFrame(label)
        }
    }
}

// MARK: - Serialization

extension ClientFrame {
    /// Serialize this client frame to a JSON string for sending to a relay.
    public func serialize() throws -> String {
        let array: [Any]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        switch self {
        case .event(let event):
            let eventData = try encoder.encode(event)
            let eventObj = try JSONSerialization.jsonObject(with: eventData)
            array = ["EVENT", eventObj]

        case .req(let subId, let filters):
            var arr: [Any] = ["REQ", subId]
            for filter in filters {
                let filterData = try encoder.encode(filter)
                let filterObj = try JSONSerialization.jsonObject(with: filterData)
                arr.append(filterObj)
            }
            array = arr

        case .close(let subId):
            array = ["CLOSE", subId]

        case .auth(let event):
            let eventData = try encoder.encode(event)
            let eventObj = try JSONSerialization.jsonObject(with: eventData)
            array = ["AUTH", eventObj]
        }

        let data = try JSONSerialization.data(withJSONObject: array)
        guard let json = String(data: data, encoding: .utf8) else {
            throw RelayFrameError.serializationFailed
        }
        return json
    }
}

// MARK: - Errors

public enum RelayFrameError: Error, Equatable {
    case invalidJSON
    case invalidStructure
    case unknownFrame(String)
    case serializationFailed
}
