// ──────────────────────────────────────────────────────────────────
// EventDeduplicator.swift — Event-ID deduplication with LRU + TTL
// ────────────────────────────────────────────────────��─────────────

import Foundation

// MARK: - Event Deduplicator

/// Thread-safe event deduplicator that drops duplicate Nostr events
/// by event ID using an LRU cache with TTL expiry.
///
/// Handles three dedup scenarios:
/// 1. **Multi-relay**: Same event arriving from N relays → first-arrival wins.
/// 2. **Reconnect**: Events re-delivered via `since` filter after reconnect.
/// 3. **Coalescing**: Duplicate arrives while original is still processing.
///
/// The cache tracks both "seen" (processing complete) and "processing"
/// (in-flight) states, allowing callers to distinguish between a finished
/// duplicate and one that's still being handled.
public final class EventDeduplicator: @unchecked Sendable {

    // MARK: - Types

    /// The state of a tracked event ID.
    public enum EventState: Sendable, Equatable {
        /// Event is currently being processed (e.g., consent pending).
        case processing
        /// Event processing completed (response published or dropped).
        case completed
    }

    /// Result of checking an event for deduplication.
    public enum CheckResult: Sendable, Equatable {
        /// Event has not been seen before — caller should process it.
        case new
        /// Event is currently being processed — caller should coalesce/drop.
        case inFlight
        /// Event was already fully processed — caller should drop.
        case duplicate
    }

    // MARK: - Cache Entry

    private struct CacheEntry {
        var state: EventState
        let insertedAt: Date
        var lastAccessedAt: Date

        var isProcessing: Bool { state == .processing }
    }

    // MARK: - Properties

    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]

    /// Insertion-order tracking for LRU eviction.
    /// Most recently used at the end.
    private var accessOrder: [String] = []

    /// Maximum number of cached event IDs. Default: 10,000.
    public let maxSize: Int

    /// Time-to-live for cache entries. Default: 1 hour.
    public let ttl: TimeInterval

    // MARK: - Init

    /// Create a new deduplicator.
    ///
    /// - Parameters:
    ///   - maxSize: Maximum cache capacity (LRU eviction). Default: 10,000.
    ///   - ttl: Time-to-live for entries. Default: 3,600s (1 hour).
    public init(maxSize: Int = 10_000, ttl: TimeInterval = 3600) {
        self.maxSize = max(1, maxSize)
        self.ttl = ttl
    }

    // MARK: - Core API

    /// Check and atomically register an event ID.
    ///
    /// If the event is new, it is registered as `.processing`.
    /// Returns the check result indicating how the caller should handle it.
    ///
    /// - Parameter eventId: The 64-character hex event ID.
    /// - Returns: `.new` if first time seen, `.inFlight` if being processed,
    ///            `.duplicate` if already completed.
    public func check(_ eventId: String) -> CheckResult {
        let now = Date()

        lock.lock()
        defer { lock.unlock() }

        // Expire stale entry
        if let entry = cache[eventId] {
            if now.timeIntervalSince(entry.insertedAt) >= ttl {
                removeEntry(eventId)
            } else {
                // Still valid — touch for LRU
                cache[eventId]?.lastAccessedAt = now
                touchAccessOrder(eventId)
                return entry.isProcessing ? .inFlight : .duplicate
            }
        }

        // New event — register as processing
        evictIfNeeded()
        cache[eventId] = CacheEntry(
            state: .processing,
            insertedAt: now,
            lastAccessedAt: now
        )
        accessOrder.append(eventId)
        return .new
    }

    /// Check if an event has been seen without registering it.
    ///
    /// - Parameter eventId: The event ID to query.
    /// - Returns: The current state, or `nil` if not tracked.
    public func state(of eventId: String) -> EventState? {
        let now = Date()

        lock.lock()
        defer { lock.unlock() }

        guard let entry = cache[eventId] else { return nil }
        if now.timeIntervalSince(entry.insertedAt) >= ttl {
            removeEntry(eventId)
            return nil
        }
        return entry.state
    }

    /// Mark an in-flight event as completed.
    ///
    /// Call this after successfully publishing a response or deciding
    /// to drop the event, so future duplicates get `.duplicate` instead
    /// of `.inFlight`.
    ///
    /// - Parameter eventId: The event ID to mark completed.
    /// - Returns: `true` if the state was updated, `false` if not found.
    @discardableResult
    public func markCompleted(_ eventId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard cache[eventId] != nil else { return false }
        cache[eventId]?.state = .completed
        return true
    }

    /// Remove a specific event ID from the cache.
    ///
    /// Useful if processing failed and you want to allow a retry.
    ///
    /// - Parameter eventId: The event ID to remove.
    /// - Returns: `true` if the entry existed and was removed.
    @discardableResult
    public func remove(_ eventId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard cache[eventId] != nil else { return false }
        removeEntry(eventId)
        return true
    }

    // MARK: - Cache Info

    /// Current number of entries in the cache.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    /// Remove all entries.
    public func clear() {
        lock.lock()
        cache.removeAll()
        accessOrder.removeAll()
        lock.unlock()
    }

    /// Number of events currently in the `.processing` state.
    public var processingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.values.filter { $0.isProcessing }.count
    }

    // MARK: - Internals

    private func removeEntry(_ eventId: String) {
        cache.removeValue(forKey: eventId)
        if let idx = accessOrder.firstIndex(of: eventId) {
            accessOrder.remove(at: idx)
        }
    }

    private func touchAccessOrder(_ eventId: String) {
        if let idx = accessOrder.firstIndex(of: eventId) {
            accessOrder.remove(at: idx)
        }
        accessOrder.append(eventId)
    }

    private func evictIfNeeded() {
        while cache.count >= maxSize, let oldest = accessOrder.first {
            removeEntry(oldest)
        }
    }
}
