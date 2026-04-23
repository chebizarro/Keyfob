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

    public func cancel() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

// MARK: - Relay Connection

/// A connection to a single Nostr relay.
///
/// Manages WebSocket lifecycle, subscription routing, and publish/OK tracking.
/// Use `WebSocketTransport` protocol for testability — inject a mock in tests.
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
        let callbacks: SubscriptionCallbacks
    }

    private var subscriptions: [String: ActiveSubscription] = [:]
    private var nextSubIndex: Int = 0

    // MARK: - Pending OK

    private var pendingOK: [String: CheckedContinuation<OKResult, Error>] = [:]

    // MARK: - Transport

    private var transport: WebSocketTransport?
    private let transportFactory: (URL) -> WebSocketTransport
    private var receiveTask: Task<Void, Never>?

    /// Callback for unhandled server frames (AUTH, NOTICE).
    public var onAuthChallenge: (@Sendable (String) -> Void)?
    public var onNotice: (@Sendable (String) -> Void)?

    // MARK: - Init

    /// Create a relay connection.
    ///
    /// - Parameters:
    ///   - url: The relay WebSocket URL (e.g., `wss://relay.example.com`).
    ///   - transportFactory: Inject a custom transport factory for testing.
    ///     Defaults to `URLSessionTransport`.
    public init(url: URL, transportFactory: ((URL) -> WebSocketTransport)? = nil) {
        self.url = url
        self.transportFactory = transportFactory ?? { url in
            let t = URLSessionTransport(url: url)
            t.connect()
            return t
        }
    }

    // MARK: - Connect / Disconnect

    /// Connect to the relay. No-op if already connected or connecting.
    public func connect() {
        lock.lock()
        guard _state == .disconnected else {
            lock.unlock()
            return
        }
        _state = .connecting
        let observers = _stateObservers
        lock.unlock()
        for o in observers { o(.connecting) }

        let ws = transportFactory(url)
        lock.lock()
        transport = ws
        _state = .connected
        let obs2 = _stateObservers
        lock.unlock()
        for o in obs2 { o(.connected) }

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    /// Disconnect from the relay. Sends CLOSE for all active subscriptions.
    public func disconnect() {
        lock.lock()
        guard _state == .connected || _state == .connecting else {
            lock.unlock()
            return
        }
        _state = .closing
        let subs = Array(subscriptions.keys)
        let ws = transport
        let pending = pendingOK
        pendingOK.removeAll()
        subscriptions.removeAll()
        let obs = _stateObservers
        lock.unlock()

        for o in obs { o(.closing) }

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
        subscriptions[subId] = ActiveSubscription(callbacks: callbacks)
        lock.unlock()

        let frame = ClientFrame.req(subscriptionId: subId, filters: filters)
        let json = try frame.serialize()
        Task { try? await ws.send(json) }

        return SubscriptionHandle(id: subId)
    }

    /// Close an active subscription.
    public func closeSubscription(_ handle: SubscriptionHandle) throws {
        lock.lock()
        guard subscriptions.removeValue(forKey: handle.id) != nil else {
            lock.unlock()
            return // already closed, no-op
        }
        let ws = transport
        lock.unlock()

        let frame = ClientFrame.close(subscriptionId: handle.id)
        let json = try frame.serialize()
        Task { try? await ws?.send(json) }
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
                    setState(.disconnected)
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
            let sub = subscriptions[subId]
            lock.unlock()
            sub?.callbacks.onEvent(event)

        case .ok(let eventId, let accepted, let message):
            lock.lock()
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
            let sub = subscriptions.removeValue(forKey: subId)
            lock.unlock()
            sub?.callbacks.onClosed(message)

        case .notice(let message):
            onNotice?(message)

        case .auth(let challenge):
            onAuthChallenge?(challenge)
        }
    }
}

// MARK: - Errors

public enum RelayConnectionError: Error, Equatable {
    case notConnected
    case disconnected
    case invalidData
}
