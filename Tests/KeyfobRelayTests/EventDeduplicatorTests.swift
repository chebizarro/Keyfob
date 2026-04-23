// ──────────────────────────────────────────────────────────────────
// EventDeduplicatorTests.swift — Tests for event-ID deduplication
// ──────────────────────────────────────────────────────────────────

import XCTest
@testable import KeyfobRelay

final class EventDeduplicatorTests: XCTestCase {

    // MARK: - Basic Dedup

    func testNewEventReturnsNew() {
        let dedup = EventDeduplicator()
        XCTAssertEqual(dedup.check("event-1"), .new)
    }

    func testSecondCheckReturnsDuplicate() {
        let dedup = EventDeduplicator()
        XCTAssertEqual(dedup.check("event-1"), .new)
        dedup.markCompleted("event-1")
        XCTAssertEqual(dedup.check("event-1"), .duplicate)
    }

    func testInFlightCheckReturnsInFlight() {
        let dedup = EventDeduplicator()
        XCTAssertEqual(dedup.check("event-1"), .new)
        // Not yet marked completed → still processing
        XCTAssertEqual(dedup.check("event-1"), .inFlight)
    }

    func testMarkCompletedTransitionsState() {
        let dedup = EventDeduplicator()
        _ = dedup.check("event-1")
        XCTAssertEqual(dedup.state(of: "event-1"), .processing)

        dedup.markCompleted("event-1")
        XCTAssertEqual(dedup.state(of: "event-1"), .completed)
    }

    func testMarkCompletedReturnsFalseForUnknown() {
        let dedup = EventDeduplicator()
        XCTAssertFalse(dedup.markCompleted("nonexistent"))
    }

    // MARK: - Multi-Relay Dedup

    func testMultiRelayFirstArrivalWins() {
        let dedup = EventDeduplicator()

        // Same event from 3 relays
        let result1 = dedup.check("shared-event")
        let result2 = dedup.check("shared-event")
        let result3 = dedup.check("shared-event")

        XCTAssertEqual(result1, .new)
        XCTAssertEqual(result2, .inFlight)
        XCTAssertEqual(result3, .inFlight)
    }

    func testMultiRelayAfterCompletion() {
        let dedup = EventDeduplicator()

        XCTAssertEqual(dedup.check("shared-event"), .new)
        dedup.markCompleted("shared-event")

        // Late arrival from second relay
        XCTAssertEqual(dedup.check("shared-event"), .duplicate)
    }

    // MARK: - Different Events

    func testDifferentEventsAreIndependent() {
        let dedup = EventDeduplicator()
        XCTAssertEqual(dedup.check("event-a"), .new)
        XCTAssertEqual(dedup.check("event-b"), .new)
        XCTAssertEqual(dedup.check("event-c"), .new)
        XCTAssertEqual(dedup.count, 3)
    }

    // MARK: - TTL Expiry

    func testExpiredEntryTreatedAsNew() {
        let dedup = EventDeduplicator(ttl: 0.0) // Immediate expiry

        XCTAssertEqual(dedup.check("event-1"), .new)
        dedup.markCompleted("event-1")

        // TTL=0 means entry expired immediately
        XCTAssertEqual(dedup.check("event-1"), .new)
    }

    func testStateReturnsNilForExpired() {
        let dedup = EventDeduplicator(ttl: 0.0)

        _ = dedup.check("event-1")
        XCTAssertNil(dedup.state(of: "event-1"))
    }

    func testNonExpiredEntryRetained() {
        let dedup = EventDeduplicator(ttl: 3600)

        _ = dedup.check("event-1")
        dedup.markCompleted("event-1")
        XCTAssertEqual(dedup.state(of: "event-1"), .completed)
    }

    // MARK: - LRU Eviction

    func testEvictsOldestWhenFull() {
        let dedup = EventDeduplicator(maxSize: 3)

        _ = dedup.check("event-1")
        _ = dedup.check("event-2")
        _ = dedup.check("event-3")
        XCTAssertEqual(dedup.count, 3)

        // Adding 4th should evict event-1
        _ = dedup.check("event-4")
        XCTAssertEqual(dedup.count, 3)
        XCTAssertNil(dedup.state(of: "event-1"))
        XCTAssertNotNil(dedup.state(of: "event-2"))
        XCTAssertNotNil(dedup.state(of: "event-3"))
        XCTAssertNotNil(dedup.state(of: "event-4"))
    }

    func testLRUTouchPreservesRecentlyAccessed() {
        let dedup = EventDeduplicator(maxSize: 3)

        _ = dedup.check("event-1")
        _ = dedup.check("event-2")
        _ = dedup.check("event-3")

        // Touch event-1 by re-checking (returns .inFlight, updates LRU)
        _ = dedup.check("event-1")

        // Now event-2 is the oldest untouched
        _ = dedup.check("event-4")
        XCTAssertNil(dedup.state(of: "event-2")) // Evicted
        XCTAssertNotNil(dedup.state(of: "event-1")) // Kept (recently touched)
    }

    func testMaxSizeOneWorks() {
        let dedup = EventDeduplicator(maxSize: 1)

        _ = dedup.check("event-1")
        XCTAssertEqual(dedup.count, 1)

        _ = dedup.check("event-2")
        XCTAssertEqual(dedup.count, 1)
        XCTAssertNil(dedup.state(of: "event-1"))
        XCTAssertNotNil(dedup.state(of: "event-2"))
    }

    // MARK: - Remove

    func testRemoveReturnsTrue() {
        let dedup = EventDeduplicator()
        _ = dedup.check("event-1")
        XCTAssertTrue(dedup.remove("event-1"))
        XCTAssertEqual(dedup.count, 0)
    }

    func testRemoveReturnsFalseForUnknown() {
        let dedup = EventDeduplicator()
        XCTAssertFalse(dedup.remove("nonexistent"))
    }

    func testRemoveAllowsReprocessing() {
        let dedup = EventDeduplicator()
        _ = dedup.check("event-1")
        dedup.markCompleted("event-1")
        XCTAssertEqual(dedup.check("event-1"), .duplicate)

        dedup.remove("event-1")
        XCTAssertEqual(dedup.check("event-1"), .new) // Can be reprocessed
    }

    // MARK: - Clear

    func testClearRemovesAll() {
        let dedup = EventDeduplicator()
        _ = dedup.check("event-1")
        _ = dedup.check("event-2")
        _ = dedup.check("event-3")
        XCTAssertEqual(dedup.count, 3)

        dedup.clear()
        XCTAssertEqual(dedup.count, 0)
    }

    // MARK: - Processing Count

    func testProcessingCount() {
        let dedup = EventDeduplicator()

        _ = dedup.check("event-1")
        _ = dedup.check("event-2")
        _ = dedup.check("event-3")
        XCTAssertEqual(dedup.processingCount, 3)

        dedup.markCompleted("event-1")
        XCTAssertEqual(dedup.processingCount, 2)

        dedup.markCompleted("event-2")
        dedup.markCompleted("event-3")
        XCTAssertEqual(dedup.processingCount, 0)
    }

    // MARK: - Thread Safety

    func testConcurrentAccessDoesNotCrash() {
        let dedup = EventDeduplicator(maxSize: 100)
        let group = DispatchGroup()

        // Spawn 50 concurrent writes
        for i in 0..<50 {
            group.enter()
            DispatchQueue.global().async {
                let result = dedup.check("concurrent-\(i)")
                XCTAssertEqual(result, .new)
                dedup.markCompleted("concurrent-\(i)")
                group.leave()
            }
        }

        // Spawn 50 concurrent reads
        for i in 0..<50 {
            group.enter()
            DispatchQueue.global().async {
                _ = dedup.state(of: "concurrent-\(i)")
                _ = dedup.count
                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + 5.0)
        XCTAssertEqual(result, .success)
        XCTAssertEqual(dedup.count, 50)
    }

    func testConcurrentDuplicatesOnlyOneNew() {
        let dedup = EventDeduplicator()
        let group = DispatchGroup()
        let lock = NSLock()
        var newCount = 0

        // 20 concurrent checks for the same event ID
        for _ in 0..<20 {
            group.enter()
            DispatchQueue.global().async {
                let result = dedup.check("same-event")
                if result == .new {
                    lock.lock()
                    newCount += 1
                    lock.unlock()
                }
                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + 5.0)
        XCTAssertEqual(result, .success)
        XCTAssertEqual(newCount, 1) // Exactly one thread wins
    }

    // MARK: - Reconnect Scenario

    func testReconnectRedeliveryDeduped() {
        let dedup = EventDeduplicator()

        // Process events from initial connection
        XCTAssertEqual(dedup.check("event-a"), .new)
        dedup.markCompleted("event-a")
        XCTAssertEqual(dedup.check("event-b"), .new)
        dedup.markCompleted("event-b")
        XCTAssertEqual(dedup.check("event-c"), .new)
        dedup.markCompleted("event-c")

        // Simulate reconnect — relay sends same events again via since filter
        XCTAssertEqual(dedup.check("event-a"), .duplicate)
        XCTAssertEqual(dedup.check("event-b"), .duplicate)
        XCTAssertEqual(dedup.check("event-c"), .duplicate)

        // New event after reconnect still works
        XCTAssertEqual(dedup.check("event-d"), .new)
    }

    // MARK: - Coalescing Scenario

    func testCoalescingWhileProcessing() {
        let dedup = EventDeduplicator()

        // First arrival starts processing (consent pending)
        XCTAssertEqual(dedup.check("pending-event"), .new)

        // Second arrival while consent still pending
        XCTAssertEqual(dedup.check("pending-event"), .inFlight)
        // Third arrival from yet another relay
        XCTAssertEqual(dedup.check("pending-event"), .inFlight)

        // Consent granted, processing completes
        dedup.markCompleted("pending-event")

        // Any future duplicates
        XCTAssertEqual(dedup.check("pending-event"), .duplicate)
    }
}
