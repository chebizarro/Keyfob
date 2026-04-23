// ──────────────────────────────────────────────────────────────────
// SubscriptionManager.swift — EOSE-aware subscription management
// ──────────────────────────────────────────────────────────────────

import Foundation

// MARK: - Subscription Phase

/// Phase of a managed subscription relative to the EOSE boundary.
public enum SubscriptionPhase: Sendable, Equatable {
    /// Receiving stored/historical events from the relay (before EOSE).
    case catchingUp
    /// EOSE received; now receiving realtime events.
    case live
    /// Subscription was closed by the relay or client.
    case closed
}

// MARK: - EOSE Behavior

/// How a subscription should behave when EOSE is received.
public enum EOSEBehavior: Sendable, Equatable {
    /// After EOSE, transition to live mode and keep listening for new events.
    case transitionToLive
    /// After EOSE, automatically close the subscription (one-shot backfill).
    case closeAfterEOSE
}

// MARK: - Closed Reason

/// Parsed reason for a relay-initiated subscription closure (NIP-01).
public enum ClosedReason: Sendable, Equatable {
    /// Relay requires authentication (NIP-42).
    case authRequired(String)
    /// Relay rate-limited the subscription.
    case rateLimited(String)
    /// Relay reported an error.
    case error(String)
    /// Relay blocked the subscription.
    case blocked(String)
    /// Any other reason.
    case other(String)

    /// Parse a CLOSED message into a typed reason.
    public static func parse(_ message: String) -> ClosedReason {
        if message.hasPrefix("auth-required:") { return .authRequired(message) }
        if message.hasPrefix("rate-limited:") { return .rateLimited(message) }
        if message.hasPrefix("error:") { return .error(message) }
        if message.hasPrefix("blocked:") { return .blocked(message) }
        return .other(message)
    }

    /// The raw message string regardless of variant.
    public var message: String {
        switch self {
        case .authRequired(let m), .rateLimited(let m),
             .error(let m), .blocked(let m), .other(let m):
            return m
        }
    }
}

// MARK: - Managed Event

/// An event delivered with context about its EOSE phase.
public struct ManagedEvent: Sendable {
    /// The raw relay event.
    public let event: RelayEvent
    /// `true` if received before EOSE (historical/stored event).
    public let isHistorical: Bool

    public init(event: RelayEvent, isHistorical: Bool) {
        self.event = event
        self.isHistorical = isHistorical
    }
}

// MARK: - Managed Subscription Callbacks

/// Callbacks for a managed subscription with EOSE awareness.
public struct ManagedSubscriptionCallbacks: Sendable {
    /// Called for each event, annotated with historical/realtime context.
    public var onEvent: @Sendable (ManagedEvent) -> Void
    /// Called when EOSE is received (end of stored events).
    public var onEOSE: @Sendable () -> Void
    /// Called when the subscription phase changes.
    public var onPhaseChange: @Sendable (SubscriptionPhase) -> Void
    /// Called when the relay closes the subscription with a reason.
    public var onClosed: @Sendable (ClosedReason) -> Void

    public init(
        onEvent: @escaping @Sendable (ManagedEvent) -> Void = { _ in },
        onEOSE: @escaping @Sendable () -> Void = {},
        onPhaseChange: @escaping @Sendable (SubscriptionPhase) -> Void = { _ in },
        onClosed: @escaping @Sendable (ClosedReason) -> Void = { _ in }
    ) {
        self.onEvent = onEvent
        self.onEOSE = onEOSE
        self.onPhaseChange = onPhaseChange
        self.onClosed = onClosed
    }
}

// MARK: - Managed Subscription Handle

/// An opaque handle for a managed subscription.
public struct ManagedSubscriptionHandle: Sendable, Equatable {
    /// The underlying subscription ID.
    public let id: String
    public init(id: String) { self.id = id }
}

// MARK: - Reference Box (for capturing ID in callbacks)

/// Thread-safe box for sharing a subscription ID between the
/// subscribe call site and the callbacks.
private final class SubIdBox: @unchecked Sendable {
    var id: String = ""
}

// MARK: - Subscription Manager

/// EOSE-aware subscription manager layered on top of `RelayConnection`.
///
/// Tracks the catch-up → live phase boundary per subscription, annotates
/// events as historical or realtime, supports one-shot backfill, and
/// parses relay CLOSED reasons.
///
/// On reconnect, phases reset to `.catchingUp` — the relay will re-send
/// stored events and a new EOSE before delivering live events.
public final class SubscriptionManager: @unchecked Sendable {

    private let connection: RelayConnection
    private let lock = NSLock()

    private struct ManagedSub {
        let rawHandle: SubscriptionHandle
        let callbacks: ManagedSubscriptionCallbacks
        let eoseBehavior: EOSEBehavior
        var phase: SubscriptionPhase
    }

    private var managedSubs: [String: ManagedSub] = [:]

    // MARK: - Init

    /// Create a subscription manager for the given connection.
    ///
    /// The manager observes connection state to reset subscription
    /// phases on reconnect.
    public init(connection: RelayConnection) {
        self.connection = connection
        connection.observeState { [weak self] state in
            if state == .reconnecting {
                self?.resetPhasesForReconnect()
            }
        }
    }

    // MARK: - Subscribe

    /// Open an EOSE-aware subscription.
    ///
    /// - Parameters:
    ///   - filters: NIP-01 subscription filters.
    ///   - eoseBehavior: Whether to stay live or auto-close after EOSE.
    ///   - callbacks: Event and phase callbacks with EOSE context.
    /// - Returns: A handle to close the subscription.
    public func subscribe(
        filters: [NostrFilter],
        eoseBehavior: EOSEBehavior = .transitionToLive,
        callbacks: ManagedSubscriptionCallbacks
    ) throws -> ManagedSubscriptionHandle {

        let idBox = SubIdBox()

        let rawHandle = try connection.subscribe(
            filters: filters,
            callbacks: SubscriptionCallbacks(
                onEvent: { [weak self, idBox] event in
                    self?.handleEvent(subId: idBox.id, event: event)
                },
                onEOSE: { [weak self, idBox] in
                    self?.handleEOSE(subId: idBox.id)
                },
                onClosed: { [weak self, idBox] message in
                    self?.handleClosed(subId: idBox.id, message: message)
                }
            )
        )

        idBox.id = rawHandle.id

        let managed = ManagedSub(
            rawHandle: rawHandle,
            callbacks: callbacks,
            eoseBehavior: eoseBehavior,
            phase: .catchingUp
        )

        lock.lock()
        managedSubs[rawHandle.id] = managed
        lock.unlock()

        callbacks.onPhaseChange(.catchingUp)

        return ManagedSubscriptionHandle(id: rawHandle.id)
    }

    /// Close a managed subscription.
    public func close(_ handle: ManagedSubscriptionHandle) throws {
        lock.lock()
        guard let sub = managedSubs.removeValue(forKey: handle.id) else {
            lock.unlock()
            return
        }
        lock.unlock()
        try connection.closeSubscription(sub.rawHandle)
    }

    // MARK: - Phase Query

    /// Returns the current phase of a managed subscription.
    public func phase(for handle: ManagedSubscriptionHandle) -> SubscriptionPhase? {
        lock.lock()
        defer { lock.unlock() }
        return managedSubs[handle.id]?.phase
    }

    /// Returns the number of active managed subscriptions.
    public var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return managedSubs.count
    }

    // MARK: - Internal Handlers

    private func handleEvent(subId: String, event: RelayEvent) {
        lock.lock()
        guard let sub = managedSubs[subId] else {
            lock.unlock()
            return
        }
        let isHistorical = sub.phase == .catchingUp
        lock.unlock()

        let managed = ManagedEvent(event: event, isHistorical: isHistorical)
        sub.callbacks.onEvent(managed)
    }

    private func handleEOSE(subId: String) {
        lock.lock()
        guard var sub = managedSubs[subId] else {
            lock.unlock()
            return
        }
        sub.phase = .live
        managedSubs[subId] = sub
        let eoseBehavior = sub.eoseBehavior
        lock.unlock()

        sub.callbacks.onEOSE()
        sub.callbacks.onPhaseChange(.live)

        if eoseBehavior == .closeAfterEOSE {
            lock.lock()
            managedSubs.removeValue(forKey: subId)
            lock.unlock()
            try? connection.closeSubscription(sub.rawHandle)
            sub.callbacks.onPhaseChange(.closed)
        }
    }

    private func handleClosed(subId: String, message: String) {
        lock.lock()
        guard let sub = managedSubs.removeValue(forKey: subId) else {
            lock.unlock()
            return
        }
        lock.unlock()

        let reason = ClosedReason.parse(message)
        sub.callbacks.onClosed(reason)
        sub.callbacks.onPhaseChange(.closed)
    }

    // MARK: - Reconnect

    /// Reset all subscription phases to `.catchingUp` on reconnect.
    /// The relay will re-send stored events and EOSE.
    private func resetPhasesForReconnect() {
        lock.lock()
        for (id, var sub) in managedSubs {
            sub.phase = .catchingUp
            managedSubs[id] = sub
        }
        lock.unlock()
    }
}
