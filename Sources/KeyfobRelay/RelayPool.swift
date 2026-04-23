// ──────────────────────────────────────────────────────────────────
// RelayPool.swift — Multi-relay connection pool with role-based routing
// ──────────────────────────────────────────────────────────────────

import Foundation

// MARK: - Relay Pool

/// Manages multiple relay connections with read/write role-based routing.
///
/// - Subscribes on all read-capable relays simultaneously.
/// - Publishes to write-capable relays with failover.
/// - Each connection independently manages lifecycle, reconnect, and AUTH.
/// - Circuit breaker deprioritizes consistently unavailable relays.
public final class RelayPool: @unchecked Sendable {

    // MARK: - Types

    /// Status of a single relay in the pool.
    public struct RelayStatus: Sendable {
        public let url: URL
        public let role: RelayRole
        public let connectionState: RelayConnectionState
        public let circuitOpen: Bool
    }

    /// Result of a publish attempt across multiple write relays.
    public enum PoolPublishResult: Sendable, Equatable {
        /// At least one relay accepted the event.
        case accepted(relayCount: Int)
        /// All write relays rejected or timed out.
        case allFailed
        /// No write relays configured or available.
        case noWriteRelays
    }

    /// A pool-level subscription handle.
    public struct PoolSubscriptionHandle: Sendable {
        public let id: String
        internal let subHandles: [String: SubscriptionHandle] // relay URL → handle
    }

    // MARK: - Circuit Breaker

    private struct CircuitState {
        var consecutiveFailures: Int = 0
        var openUntil: Date?
        var isOpen: Bool { openUntil.map { Date() < $0 } ?? false }

        mutating func recordFailure(backoff: TimeInterval) {
            consecutiveFailures += 1
            let duration = min(backoff * pow(2.0, Double(consecutiveFailures - 1)), 300)
            openUntil = Date().addingTimeInterval(duration)
        }

        mutating func recordSuccess() {
            consecutiveFailures = 0
            openUntil = nil
        }
    }

    // MARK: - Properties

    private let lock = NSLock()
    private var connections: [URL: RelayConnection] = [:]
    private var config: RelayPoolConfig
    private var circuitStates: [URL: CircuitState] = [:]
    private let transportFactory: ((URL) -> WebSocketTransport)?
    private var poolSubscriptions: [String: [String: SubscriptionHandle]] = [:]
    private var nextPoolSubIndex: Int = 0

    /// Base backoff for circuit breaker. Default: 30 seconds.
    public var circuitBreakerBackoff: TimeInterval = 30.0

    /// Number of consecutive failures to trip the circuit breaker. Default: 3.
    public var circuitBreakerThreshold: Int = 3

    /// Auth signer applied to all connections.
    public var authSigner: RelayAuthSigner? {
        didSet {
            lock.lock()
            let conns = Array(connections.values)
            lock.unlock()
            for conn in conns { conn.authSigner = authSigner }
        }
    }

    // MARK: - Init

    /// Create a relay pool.
    ///
    /// - Parameters:
    ///   - config: Initial relay pool configuration.
    ///   - transportFactory: Optional transport factory for testing.
    public init(
        config: RelayPoolConfig = RelayPoolConfig(),
        transportFactory: ((URL) -> WebSocketTransport)? = nil
    ) {
        self.config = config
        self.transportFactory = transportFactory
    }

    // MARK: - Connection Management

    /// Connect to all enabled relays in the configuration.
    public func connectAll() {
        lock.lock()
        let entries = config.enabledRelays
        lock.unlock()

        for entry in entries {
            connectRelay(entry.url)
        }
    }

    /// Disconnect from all relays.
    public func disconnectAll() {
        lock.lock()
        let conns = Array(connections.values)
        poolSubscriptions.removeAll()
        lock.unlock()

        for conn in conns {
            conn.disconnect()
        }
    }

    /// Add a relay at runtime and connect to it.
    public func addRelay(url: URL, role: RelayRole = .readWrite) {
        lock.lock()
        config.addRelay(url: url, role: role)
        lock.unlock()
        connectRelay(url)
    }

    /// Remove a relay at runtime and disconnect.
    public func removeRelay(url: URL) {
        lock.lock()
        config.removeRelay(url: url)
        let conn = connections.removeValue(forKey: url)
        circuitStates.removeValue(forKey: url)
        lock.unlock()

        conn?.disconnect()
    }

    /// Get the current pool configuration.
    public var currentConfig: RelayPoolConfig {
        lock.lock()
        defer { lock.unlock() }
        return config
    }

    /// Status of all relays in the pool.
    public var relayStatuses: [RelayStatus] {
        lock.lock()
        let entries = config.relays
        let conns = connections
        let circuits = circuitStates
        lock.unlock()

        return entries.map { entry in
            RelayStatus(
                url: entry.url,
                role: entry.role,
                connectionState: conns[entry.url]?.state ?? .disconnected,
                circuitOpen: circuits[entry.url]?.isOpen ?? false
            )
        }
    }

    /// Get the connection for a specific relay URL (for testing/advanced use).
    public func connection(for url: URL) -> RelayConnection? {
        lock.lock()
        defer { lock.unlock() }
        return connections[url]
    }

    // MARK: - Subscribe (Read Relays)

    /// Subscribe on all read-capable relays simultaneously.
    ///
    /// Events from multiple relays should be deduplicated by the caller
    /// using `EventDeduplicator`.
    ///
    /// - Parameters:
    ///   - filters: Nostr subscription filters.
    ///   - callbacks: Callbacks for events, EOSE, and CLOSED.
    /// - Returns: A pool subscription handle for closing.
    public func subscribe(
        filters: [NostrFilter],
        callbacks: SubscriptionCallbacks
    ) -> PoolSubscriptionHandle {
        lock.lock()
        let readEntries = config.readRelays
        let conns = connections
        nextPoolSubIndex += 1
        let poolSubId = "pool-\(nextPoolSubIndex)"
        lock.unlock()

        var subHandles: [String: SubscriptionHandle] = [:]

        for entry in readEntries {
            guard let conn = conns[entry.url], conn.state == .connected else { continue }

            if let handle = try? conn.subscribe(filters: filters, callbacks: callbacks) {
                subHandles[entry.url.absoluteString] = handle
            }
        }

        lock.lock()
        poolSubscriptions[poolSubId] = subHandles
        lock.unlock()

        return PoolSubscriptionHandle(id: poolSubId, subHandles: subHandles)
    }

    /// Close a pool subscription on all relays.
    public func closeSubscription(_ handle: PoolSubscriptionHandle) {
        lock.lock()
        poolSubscriptions.removeValue(forKey: handle.id)
        let conns = connections
        lock.unlock()

        for (urlStr, subHandle) in handle.subHandles {
            guard let url = URL(string: urlStr),
                  let conn = conns[url] else { continue }
            try? conn.closeSubscription(subHandle)
        }
    }

    // MARK: - Publish (Write Relays)

    /// Publish an event to all available write relays concurrently.
    ///
    /// Tries all non-circuit-broken write relays in parallel. Returns
    /// `.accepted` if at least one relay accepts.
    ///
    /// - Parameter event: The signed event to publish.
    /// - Returns: The aggregate publish result.
    public func publish(event: RelayEvent) async -> PoolPublishResult {
        lock.lock()
        let writeEntries = config.writeRelays
        let conns = connections
        let circuits = circuitStates
        lock.unlock()

        // Filter to available write relays (connected, circuit closed)
        let available = writeEntries.filter { entry in
            guard let conn = conns[entry.url], conn.state == .connected else { return false }
            return !(circuits[entry.url]?.isOpen ?? false)
        }

        if available.isEmpty {
            return writeEntries.isEmpty ? .noWriteRelays : .allFailed
        }

        // Publish to all write relays concurrently
        let acceptedCount = await withTaskGroup(of: Bool.self) { group in
            for entry in available {
                guard let conn = conns[entry.url] else { continue }
                let url = entry.url
                group.addTask {
                    do {
                        let result = try await conn.publish(event: event)
                        if result.accepted {
                            self.recordSuccess(for: url)
                            return true
                        } else {
                            self.recordFailure(for: url)
                            return false
                        }
                    } catch {
                        self.recordFailure(for: url)
                        return false
                    }
                }
            }

            var count = 0
            for await accepted in group {
                if accepted { count += 1 }
            }
            return count
        }

        return acceptedCount > 0
            ? .accepted(relayCount: acceptedCount)
            : .allFailed
    }

    // MARK: - Circuit Breaker

    private func recordSuccess(for url: URL) {
        lock.lock()
        circuitStates[url]?.recordSuccess()
        lock.unlock()
    }

    private func recordFailure(for url: URL) {
        lock.lock()
        if circuitStates[url] == nil {
            circuitStates[url] = CircuitState()
        }
        if (circuitStates[url]?.consecutiveFailures ?? 0) + 1 >= circuitBreakerThreshold {
            circuitStates[url]?.recordFailure(backoff: circuitBreakerBackoff)
        } else {
            circuitStates[url]?.consecutiveFailures += 1
        }
        lock.unlock()
    }

    /// Check if a relay's circuit breaker is open.
    public func isCircuitOpen(for url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return circuitStates[url]?.isOpen ?? false
    }

    /// Reset the circuit breaker for a specific relay.
    public func resetCircuit(for url: URL) {
        lock.lock()
        circuitStates.removeValue(forKey: url)
        lock.unlock()
    }

    // MARK: - Internals

    private func connectRelay(_ url: URL) {
        lock.lock()
        guard connections[url] == nil else {
            lock.unlock()
            return
        }

        let conn: RelayConnection
        if let factory = transportFactory {
            conn = RelayConnection(
                url: url,
                transportFactory: factory
            )
        } else {
            conn = RelayConnection(url: url)
        }

        if let signer = authSigner {
            conn.authSigner = signer
        }
        connections[url] = conn
        lock.unlock()

        conn.connect()
    }
}
