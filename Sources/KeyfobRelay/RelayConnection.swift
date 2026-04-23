// ──────────────────────────────────────────────────────────────────
// RelayConnection.swift — WebSocket-based Nostr relay client
// ──────────────────────────────────────────────────────────────────

import Foundation

// MARK: - Connection State

/// Observable state of a relay connection.
public enum RelayConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case closing
}

// MARK: - OK Result

/// Result of publishing an event to a relay.
public struct OKResult: Sendable, Equatable {
    public let eventId: String
    public let accepted: Bool
    public let message: String

    public init(eventId: String, accepted: Bool, message: String) {
        self.eventId = eventId
        self.accepted = accepted
        self.message = message
    }
}

// MARK: - Subscription Handle

/// An opaque handle representing an active subscription.
public struct SubscriptionHandle: Sendable, Equatable {
    public let id: String
    public init(id: String) { self.id = id }
}

// MARK: - Subscription Callbacks

/// Callbacks invoked as a subscription receives frames from the relay.
public struct SubscriptionCallbacks: Sendable {
    public var onEvent: @Sendable (RelayEvent) -> Void
    public var onEOSE: @Sendable () -> Void
    public var onClosed: @Sendable (String) -> Void

    public init(
        onEvent: @escaping @Sendable (RelayEvent) -> Void = { _ in },
        onEOSE: @escaping @Sendable () -> Void = {},
        onClosed: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.onEvent = onEvent
        self.onEOSE = onEOSE
        self.onClosed = onClosed
    }
}

// MARK: - WebSocket Transport (protocol for testability)

/// Abstraction over a WebSocket connection for testability.
/// In production, backed by `URLSessionWebSocketTask`.
public protocol WebSocketTransport: Sendable {
    func send(_ text: String) async throws
    func receive() async throws -> String
    func sendPing() async throws
    func cancel()
}

// MARK: - URLSession Transport

/// Production WebSocket transport using `URLSessionWebSocketTask`.
public final class URLSessionTransport: WebSocketTransport, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    public init(url: URL, session: URLSession = .shared) {
        self.task = session.webSocketTask(with: url)
    }

    public func connect() {
        task.resume()
    }

    public func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    public func receive() async throws -> String {
        let message = try await task.receive()
        switch message {
        case .string(let text):
            return text
        case .data(let data):
            guard let text = String(data: data, encoding: .utf8) else {
                throw RelayConnectionError.invalidData
            }
            return text
        @unknown default:
            throw RelayConnectionError.invalidData
        }
    }

    public func sendPing() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
    }

    public func cancel() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

// MARK: - Relay Connection

/// A connection to a single Nostr relay.
///
/// Manages WebSocket lifecycle, subscription routing, publish/OK tracking,
/// automatic reconnect with exponential backoff, and WebSocket ping/pong
/// liveness detection. Use `WebSocketTransport` protocol for testability.
public final class RelayConnection: @unchecked Sendable {

    /// The relay URL this connection targets.
    public let url: URL

    // MARK: - State

    private let lock = NSLock()
    private var _state: RelayConnectionState = .disconnected
    private var _stateObservers: [(RelayConnectionState) -> Void] = []

    public var state: RelayConnectionState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    private func setState(_ newState: RelayConnectionState) {
        lock.lock()
        _state = newState
        let observers = _stateObservers
        lock.unlock()
        for observer in observers { observer(newState) }
    }

    /// Register an observer for state changes. Called on arbitrary queue.
    public func observeState(_ handler: @escaping (RelayConnectionState) -> Void) {
        lock.lock()
        _stateObservers.append(handler)
        lock.unlock()
    }

    // MARK: - Subscriptions

    private struct ActiveSubscription {
        let filters: [NostrFilter]
        let callbacks: SubscriptionCallbacks
        var lastEventAt: Int?
    }

    private var subscriptions: [String: ActiveSubscription] = [:]
    private var nextSubIndex: Int = 0

    // MARK: - Pending OK

    private var pendingOK: [String: CheckedContinuation<OKResult, Error>] = [:]

    // MARK: - Transport

    private var transport: WebSocketTransport?
    private let transportFactory: (URL) -> WebSocketTransport
    private var receiveTask: Task<Void, Never>?

    // MARK: - Reconnect

    /// The reconnect policy governing backoff behavior.
    /// Modify before `connect()` or at any time; changes take effect on next reconnect.
    public var reconnectPolicy: ReconnectPolicy
    private var _explicitDisconnect = false
    private var reconnectTask: Task<Void, Never>?
    private var _connectedSince: Date?

    // MARK: - Ping/Pong

    /// Interval between WebSocket pings in seconds. Default: 30s.
    public var pingInterval: TimeInterval = 30.0

    /// Seconds to wait for pong response before treating connection as dead. Default: 10s.
    public var pongTimeout: TimeInterval = 10.0

    private var pingTask: Task<Void, Never>?

    // MARK: - Auth (NIP-42)

    /// Optional signer for automatic NIP-42 AUTH handling.
    /// When set, AUTH challenges are automatically signed and sent.
    /// When nil, AUTH challenges are passed to `onAuthChallenge` callback.
    public var authSigner: RelayAuthSigner?

    private var _authState: AuthState = .notRequired
    private var _authEventId: String?
    private var _pendingAuthSubs: [String: ActiveSubscription] = [:]

    /// Current NIP-42 auth state.
    public var authState: AuthState {
        lock.lock()
        defer { lock.unlock() }
        return _authState
    }

    /// Callback for auth state transitions.
    public var onAuthStateChange: (@Sendable (AuthState) -> Void)?

    // MARK: - Callbacks

    /// Callback for relay AUTH challenges (NIP-42).
    /// Only called when `authSigner` is nil.
    public var onAuthChallenge: (@Sendable (String) -> Void)?

    /// Callback for relay NOTICE messages.
    public var onNotice: (@Sendable (String) -> Void)?

    // MARK: - Init

    /// Create a relay connection.
    ///
    /// - Parameters:
    ///   - url: The relay WebSocket URL (e.g., `wss://relay.example.com`).
    ///   - reconnectPolicy: Backoff policy for automatic reconnect. Default: `.default`.
    ///   - transportFactory: Inject a custom transport factory for testing.
    ///     Defaults to `URLSessionTransport`.
    public init(
        url: URL,
        reconnectPolicy: ReconnectPolicy = .default,
        transportFactory: ((URL) -> WebSocketTransport)? = nil
    ) {
        self.url = url
        self.reconnectPolicy = reconnectPolicy
        self.transportFactory = transportFactory ?? { url in
            let t = URLSessionTransport(url: url)
            t.connect()
            return t
        }
    }

    // MARK: - Connect / Disconnect

    /// Connect to the relay. No-op if already connected, connecting, or reconnecting.
    public func connect() {
        lock.lock()
        guard _state == .disconnected else {
            lock.unlock()
            return
        }
        _explicitDisconnect = false
        reconnectPolicy.reset()
        _state = .connecting
        let observers = _stateObservers
        lock.unlock()
        for o in observers { o(.connecting) }

        let ws = transportFactory(url)
        lock.lock()
        transport = ws
        _state = .connected
        _connectedSince = Date()
        let obs2 = _stateObservers
        lock.unlock()
        for o in obs2 { o(.connected) }

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        startPingLoop()
    }

    /// Disconnect from the relay. Cancels any pending reconnect.
    /// Sends CLOSE for all active subscriptions.
    public func disconnect() {
        lock.lock()
        guard _state == .connected || _state == .connecting || _state == .reconnecting else {
            lock.unlock()
            return
        }
        _explicitDisconnect = true
        _state = .closing
        _authState = .notRequired
        _authEventId = nil
        _pendingAuthSubs.removeAll()
        let subs = Array(subscriptions.keys)
        let ws = transport
        let pending = pendingOK
        pendingOK.removeAll()
        subscriptions.removeAll()
        let obs = _stateObservers
        lock.unlock()

        for o in obs { o(.closing) }

        // Cancel background tasks
        reconnectTask?.cancel()
        reconnectTask = nil
        pingTask?.cancel()
        pingTask = nil

        // Cancel pending OK continuations
        for (_, continuation) in pending {
            continuation.resume(throwing: RelayConnectionError.disconnected)
        }

        // Best-effort CLOSE for active subscriptions
        for subId in subs {
            let frame = ClientFrame.close(subscriptionId: subId)
            if let json = try? frame.serialize() {
                Task { try? await ws?.send(json) }
            }
        }

        receiveTask?.cancel()
        receiveTask = nil
        ws?.cancel()

        lock.lock()
        transport = nil
        _state = .disconnected
        _connectedSince = nil
        let obs2 = _stateObservers
        lock.unlock()
        for o in obs2 { o(.disconnected) }
    }

    // MARK: - Subscribe

    /// Open a subscription with the given filters.
    ///
    /// - Parameters:
    ///   - filters: One or more `NostrFilter` objects.
    ///   - callbacks: Handlers for EVENT, EOSE, and CLOSED frames on this subscription.
    /// - Returns: A `SubscriptionHandle` that can be used to close the subscription.
    public func subscribe(filters: [NostrFilter], callbacks: SubscriptionCallbacks) throws -> SubscriptionHandle {
        lock.lock()
        guard _state == .connected, let ws = transport else {
            lock.unlock()
            throw RelayConnectionError.notConnected
        }
        let subId = "kf:\(nextSubIndex)"
        nextSubIndex += 1
        subscriptions[subId] = ActiveSubscription(filters: filters, callbacks: callbacks)
        lock.unlock()

        let frame = ClientFrame.req(subscriptionId: subId, filters: filters)
        let json = try frame.serialize()
        Task { try? await ws.send(json) }

        return SubscriptionHandle(id: subId)
    }

    /// Close an active subscription. The subscription will NOT be restored on reconnect.
    public func closeSubscription(_ handle: SubscriptionHandle) throws {
        lock.lock()
        guard subscriptions.removeValue(forKey: handle.id) != nil else {
            lock.unlock()
            return // already closed, no-op
        }
        let ws = transport
        lock.unlock()

        if let ws = ws {
            let frame = ClientFrame.close(subscriptionId: handle.id)
            let json = try frame.serialize()
            Task { try? await ws.send(json) }
        }
    }

    // MARK: - Publish

    /// Publish an event to the relay and await the OK response.
    ///
    /// - Parameter event: A signed `RelayEvent` to publish.
    /// - Returns: The `OKResult` from the relay.
    /// - Throws: If not connected, serialization fails, or the connection drops.
    public func publish(event: RelayEvent) async throws -> OKResult {
        lock.lock()
        guard _state == .connected, let ws = transport else {
            lock.unlock()
            throw RelayConnectionError.notConnected
        }
        lock.unlock()

        let frame = ClientFrame.event(event)
        let json = try frame.serialize()

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pendingOK[event.id] = continuation
            lock.unlock()

            Task {
                do {
                    try await ws.send(json)
                } catch {
                    self.lock.lock()
                    let cont = self.pendingOK.removeValue(forKey: event.id)
                    self.lock.unlock()
                    cont?.resume(throwing: error)
                }
            }
        }
    }

    /// Send a raw client frame (used for AUTH responses).
    public func send(_ frame: ClientFrame) throws {
        lock.lock()
        guard let ws = transport else {
            lock.unlock()
            throw RelayConnectionError.notConnected
        }
        lock.unlock()

        let json = try frame.serialize()
        Task { try? await ws.send(json) }
    }

    // MARK: - Active Subscription Info

    /// Returns the IDs of currently active subscriptions.
    public var activeSubscriptionIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(subscriptions.keys)
    }

    // MARK: - Receive Loop

    private func receiveLoop() async {
        while !Task.isCancelled {
            lock.lock()
            let ws = transport
            lock.unlock()

            guard let ws = ws else { break }

            let text: String
            do {
                text = try await ws.receive()
            } catch {
                // Connection dropped
                if !Task.isCancelled {
                    handleConnectionLoss()
                }
                break
            }

            do {
                let frame = try ServerFrame.parse(text)
                handleFrame(frame)
            } catch {
                // Unparseable frame — ignore per Nostr convention
            }
        }
    }

    private func handleFrame(_ frame: ServerFrame) {
        switch frame {
        case .event(let subId, let event):
            lock.lock()
            // Track the latest event timestamp for subscription restoration
            if var sub = subscriptions[subId] {
                if sub.lastEventAt == nil || event.created_at > (sub.lastEventAt ?? 0) {
                    sub.lastEventAt = event.created_at
                    subscriptions[subId] = sub
                }
                lock.unlock()
                sub.callbacks.onEvent(event)
            } else {
                lock.unlock()
            }

        case .ok(let eventId, let accepted, let message):
            lock.lock()
            // Check if this OK is for our auth event
            if let authId = _authEventId, eventId == authId {
                _authEventId = nil
                if accepted {
                    _authState = .authenticated
                    let pendingSubs = _pendingAuthSubs
                    _pendingAuthSubs.removeAll()
                    lock.unlock()
                    onAuthStateChange?(.authenticated)
                    retryPendingAuthSubs(pendingSubs)
                } else {
                    let failState = AuthState.failed(message)
                    _authState = failState
                    let pendingSubs = _pendingAuthSubs
                    _pendingAuthSubs.removeAll()
                    lock.unlock()
                    onAuthStateChange?(failState)
                    // Notify pending auth subs that auth failed
                    for (_, sub) in pendingSubs {
                        sub.callbacks.onClosed("auth-required: authentication failed")
                    }
                }
                return
            }
            let continuation = pendingOK.removeValue(forKey: eventId)
            lock.unlock()
            continuation?.resume(returning: OKResult(eventId: eventId, accepted: accepted, message: message))

        case .eose(let subId):
            lock.lock()
            let sub = subscriptions[subId]
            lock.unlock()
            sub?.callbacks.onEOSE()

        case .closed(let subId, let message):
            lock.lock()
            // If closed with auth-required and we have a signer, queue for retry
            if message.hasPrefix("auth-required:") && authSigner != nil {
                if let sub = subscriptions.removeValue(forKey: subId) {
                    _pendingAuthSubs[subId] = sub
                }
                lock.unlock()
                // Don't call onClosed — subscription will be retried after auth
            } else {
                let sub = subscriptions.removeValue(forKey: subId)
                lock.unlock()
                sub?.callbacks.onClosed(message)
            }

        case .notice(let message):
            onNotice?(message)

        case .auth(let challenge):
            if let signer = authSigner {
                handleAuthChallenge(challenge: challenge, signer: signer)
            } else {
                onAuthChallenge?(challenge)
            }
        }
    }

    // MARK: - Auth Challenge Handling

    /// Handle an AUTH challenge from the relay by signing and sending a kind 22242 event.
    private func handleAuthChallenge(challenge: String, signer: RelayAuthSigner) {
        lock.lock()
        _authState = .challenged(challenge)
        lock.unlock()
        onAuthStateChange?(.challenged(challenge))

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let event = try await signer.signAuthEvent(challenge: challenge, relayURL: self.url)
                // Validate that it's kind 22242
                guard event.kind == 22242 else {
                    self.lock.lock()
                    let failState = AuthState.failed("signer returned wrong kind: \(event.kind)")
                    self._authState = failState
                    self.lock.unlock()
                    self.onAuthStateChange?(failState)
                    return
                }

                self.lock.lock()
                self._authState = .authenticating
                self._authEventId = event.id
                self.lock.unlock()
                self.onAuthStateChange?(.authenticating)

                try self.send(.auth(event))
            } catch {
                self.lock.lock()
                let failState = AuthState.failed("signing failed: \(error.localizedDescription)")
                self._authState = failState
                self.lock.unlock()
                self.onAuthStateChange?(failState)
            }
        }
    }

    /// Re-send REQ for subscriptions that were CLOSED with "auth-required:" after auth success.
    private func retryPendingAuthSubs(_ pendingSubs: [String: ActiveSubscription]) {
        lock.lock()
        let ws = transport
        for (subId, sub) in pendingSubs {
            subscriptions[subId] = sub
        }
        lock.unlock()

        for (subId, sub) in pendingSubs {
            let frame = ClientFrame.req(subscriptionId: subId, filters: sub.filters)
            if let json = try? frame.serialize() {
                Task { try? await ws?.send(json) }
            }
        }
    }

    // MARK: - Connection Loss & Reconnect

    /// Called when the receive loop detects a connection drop.
    private func handleConnectionLoss() {
        lock.lock()
        guard !_explicitDisconnect else {
            lock.unlock()
            return
        }

        // Check if connection was stable long enough to reset backoff
        if let since = _connectedSince, reconnectPolicy.isStable(connectedSince: since) {
            reconnectPolicy.reset()
        }

        let ws = transport
        let pending = pendingOK
        pendingOK.removeAll()
        // Keep subscriptions — they'll be restored on reconnect
        lock.unlock()

        // Cancel current transport and ping
        pingTask?.cancel()
        pingTask = nil
        ws?.cancel()

        // Cancel pending OK continuations (publish results are lost on disconnect)
        for (_, continuation) in pending {
            continuation.resume(throwing: RelayConnectionError.disconnected)
        }

        guard reconnectPolicy.isEnabled else {
            setState(.disconnected)
            return
        }

        setState(.reconnecting)

        lock.lock()
        transport = nil
        _connectedSince = nil
        _authState = .notRequired
        _authEventId = nil
        _pendingAuthSubs.removeAll()
        lock.unlock()

        reconnectTask = Task { [weak self] in
            await self?.reconnectLoop()
        }
    }

    /// Reconnect loop: wait for backoff, create transport, restore subscriptions.
    private func reconnectLoop() async {
        while !Task.isCancelled {
            lock.lock()
            let delay = reconnectPolicy.nextDelay()
            lock.unlock()

            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                break // Cancelled (explicit disconnect)
            }

            guard !Task.isCancelled else { break }

            // Attempt to create a new transport
            let ws = transportFactory(url)

            lock.lock()
            guard !_explicitDisconnect else {
                lock.unlock()
                ws.cancel()
                break
            }
            transport = ws
            _state = .connected
            _connectedSince = Date()
            let observers = _stateObservers
            lock.unlock()

            for o in observers { o(.connected) }

            // Restore active subscriptions with updated `since` timestamps
            restoreSubscriptions()

            // Start receive and ping loops
            receiveTask = Task { [weak self] in
                await self?.receiveLoop()
            }
            startPingLoop()

            break // Reconnected; receive loop takes over
        }
    }

    /// Re-send REQ for all active subscriptions after reconnect.
    /// Updates `since` parameter to avoid duplicate events.
    private func restoreSubscriptions() {
        lock.lock()
        let subs = subscriptions
        let ws = transport
        lock.unlock()

        for (subId, sub) in subs {
            var filters = sub.filters
            if let lastAt = sub.lastEventAt {
                filters = filters.map { filter in
                    var f = filter
                    f.since = max(f.since ?? 0, lastAt)
                    return f
                }
            }
            let frame = ClientFrame.req(subscriptionId: subId, filters: filters)
            if let json = try? frame.serialize() {
                Task { try? await ws?.send(json) }
            }
        }
    }

    // MARK: - Ping / Pong Liveness

    private func startPingLoop() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            await self?.pingLoop()
        }
    }

    private func pingLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: UInt64(pingInterval * 1_000_000_000))
            } catch {
                break // Cancelled
            }

            guard !Task.isCancelled else { break }

            let pongOk = await pingOnce()
            if !pongOk && !Task.isCancelled {
                // Ping timeout — treat as connection loss
                lock.lock()
                let explicit = _explicitDisconnect
                lock.unlock()
                if !explicit {
                    receiveTask?.cancel()
                    receiveTask = nil
                    handleConnectionLoss()
                }
                break
            }
        }
    }

    /// Send a single ping and wait for pong with timeout.
    /// Returns `true` if pong received within `pongTimeout`, `false` otherwise.
    private func pingOnce() async -> Bool {
        lock.lock()
        let ws = transport
        lock.unlock()

        guard let ws = ws else { return false }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await ws.sendPing()
                    return true
                } catch {
                    return false
                }
            }
            group.addTask { [pongTimeout] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(pongTimeout * 1_000_000_000))
                    return false // Timed out
                } catch {
                    return false // Cancelled
                }
            }
            // First result wins
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}

// MARK: - Errors

public enum RelayConnectionError: Error, Equatable {
    case notConnected
    case disconnected
    case invalidData
}
