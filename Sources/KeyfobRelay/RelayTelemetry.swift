// ──────────────────────────────────────────────────────────────────
// RelayTelemetry.swift — Relay lifecycle telemetry events
// ──────────────────────────────────────────────────────────────────
//
// Structured telemetry events for relay connection state, subscription
// lifecycle, NIP-42 AUTH outcomes, and publish results. Wire these to
// your preferred logging backend (os_log, AuditLog, analytics, etc.)
// via RelayConnection.telemetry callback.
//
// All events include the relay URL for multi-relay correlation.
// ──────────────────────────────────────────────────────────────────

import Foundation

// MARK: - Telemetry Event

/// A structured relay lifecycle event for observability.
public enum RelayTelemetryEvent: Sendable, CustomStringConvertible {

    // ── Connection ──────────────────────────────────────────────

    /// WebSocket connection established.
    case connected(relay: URL)

    /// WebSocket disconnected.
    case disconnected(relay: URL, reason: String)

    /// Reconnect attempt starting after backoff.
    case reconnectAttempt(relay: URL, attempt: Int, delayMs: Int)

    /// Reconnect succeeded — connection restored.
    case reconnectSuccess(relay: URL, attempt: Int)

    /// Reconnect policy exhausted — gave up.
    case reconnectGaveUp(relay: URL, attempts: Int)

    // ── Subscription ────────────────────────────────────────────

    /// REQ sent to relay for a new subscription.
    case subscriptionOpened(relay: URL, subscriptionId: String, filterCount: Int)

    /// EOSE received — end of stored events for subscription.
    case eoseReceived(relay: URL, subscriptionId: String)

    /// CLOSED received — relay closed subscription.
    case subscriptionClosed(relay: URL, subscriptionId: String, reason: String)

    /// Subscription restored after reconnect.
    case subscriptionRestored(relay: URL, subscriptionId: String)

    // ── Auth (NIP-42) ───────────────────────────────────────────

    /// AUTH challenge received from relay.
    case authChallengeReceived(relay: URL)

    /// AUTH response event sent to relay.
    case authResponseSent(relay: URL)

    /// AUTH succeeded (OK true for auth event).
    case authSucceeded(relay: URL)

    /// AUTH failed (OK false for auth event).
    case authFailed(relay: URL, message: String)

    // ── Publish ─────────────────────────────────────────────────

    /// EVENT frame sent to relay (publish).
    case eventPublished(relay: URL, eventId: String, kind: Int)

    /// Relay accepted published event (OK true).
    case publishAccepted(relay: URL, eventId: String)

    /// Relay rejected published event (OK false).
    case publishRejected(relay: URL, eventId: String, reason: String)

    // MARK: - Description

    public var description: String {
        switch self {
        case .connected(let relay):
            return "[Relay] connected: \(relay.absoluteString)"
        case .disconnected(let relay, let reason):
            return "[Relay] disconnected: \(relay.absoluteString) reason=\(reason)"
        case .reconnectAttempt(let relay, let attempt, let delayMs):
            return "[Relay] reconnect attempt=\(attempt) delay=\(delayMs)ms: \(relay.absoluteString)"
        case .reconnectSuccess(let relay, let attempt):
            return "[Relay] reconnect succeeded after attempt=\(attempt): \(relay.absoluteString)"
        case .reconnectGaveUp(let relay, let attempts):
            return "[Relay] reconnect gave up after \(attempts) attempts: \(relay.absoluteString)"
        case .subscriptionOpened(let relay, let subId, let count):
            return "[Relay] REQ subId=\(subId) filters=\(count): \(relay.absoluteString)"
        case .eoseReceived(let relay, let subId):
            return "[Relay] EOSE subId=\(subId): \(relay.absoluteString)"
        case .subscriptionClosed(let relay, let subId, let reason):
            return "[Relay] CLOSED subId=\(subId) reason=\(reason): \(relay.absoluteString)"
        case .subscriptionRestored(let relay, let subId):
            return "[Relay] subscription restored subId=\(subId): \(relay.absoluteString)"
        case .authChallengeReceived(let relay):
            return "[Relay] AUTH challenge received: \(relay.absoluteString)"
        case .authResponseSent(let relay):
            return "[Relay] AUTH response sent: \(relay.absoluteString)"
        case .authSucceeded(let relay):
            return "[Relay] AUTH succeeded: \(relay.absoluteString)"
        case .authFailed(let relay, let message):
            return "[Relay] AUTH failed: \(relay.absoluteString) message=\(message)"
        case .eventPublished(let relay, let eventId, let kind):
            return "[Relay] EVENT published id=\(eventId) kind=\(kind): \(relay.absoluteString)"
        case .publishAccepted(let relay, let eventId):
            return "[Relay] OK accepted id=\(eventId): \(relay.absoluteString)"
        case .publishRejected(let relay, let eventId, let reason):
            return "[Relay] OK rejected id=\(eventId) reason=\(reason): \(relay.absoluteString)"
        }
    }
}
