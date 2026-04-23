import XCTest
@testable import KeyfobPolicy

final class AuditLogTests: XCTestCase {

    private var tempDir: URL!
    private var log: AuditLog!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyfob-audit-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        log = AuditLog(containerURL: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Basic Append / Read

    func testAppendAndRead() {
        let entry = AuditEntry(origin: "example.com", action: .approved, detail: "mode=session")
        log.log(entry)

        let entries = log.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].origin, "example.com")
        XCTAssertEqual(entries[0].action, .approved)
        XCTAssertEqual(entries[0].detail, "mode=session")
    }

    func testMultipleAppends() {
        log.log(AuditEntry(origin: "a.com", action: .approved))
        log.log(AuditEntry(origin: "b.com", action: .denied))
        log.log(AuditEntry(origin: "c.com", action: .rateLimited))

        let entries = log.entries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].origin, "a.com")
        XCTAssertEqual(entries[1].origin, "b.com")
        XCTAssertEqual(entries[2].origin, "c.com")
    }

    func testEntryCount() {
        XCTAssertEqual(log.entryCount, 0)
        log.log(AuditEntry(origin: "a.com", action: .approved))
        log.log(AuditEntry(origin: "b.com", action: .denied))
        XCTAssertEqual(log.entryCount, 2)
    }

    // MARK: - Limit

    func testEntriesLimit() {
        for i in 0..<20 {
            log.log(AuditEntry(origin: "origin-\(i).com", action: .approved))
        }
        let limited = log.entries(limit: 5)
        XCTAssertEqual(limited.count, 5)
        // Should return the 5 most recent (indices 15-19)
        XCTAssertEqual(limited[0].origin, "origin-15.com")
        XCTAssertEqual(limited[4].origin, "origin-19.com")
    }

    func testEntriesLimitLargerThanCount() {
        log.log(AuditEntry(origin: "only.com", action: .approved))
        let entries = log.entries(limit: 100)
        XCTAssertEqual(entries.count, 1)
    }

    // MARK: - Clear

    func testClear() {
        log.log(AuditEntry(origin: "a.com", action: .approved))
        log.log(AuditEntry(origin: "b.com", action: .denied))
        XCTAssertEqual(log.entryCount, 2)

        log.clear()
        XCTAssertEqual(log.entryCount, 0)
        XCTAssertTrue(log.entries().isEmpty)
    }

    func testClearThenAppend() {
        log.log(AuditEntry(origin: "before.com", action: .approved))
        log.clear()
        log.log(AuditEntry(origin: "after.com", action: .denied))

        let entries = log.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].origin, "after.com")
    }

    // MARK: - Filtering

    func testFilterByOrigin() {
        log.log(AuditEntry(origin: "a.com", action: .approved))
        log.log(AuditEntry(origin: "b.com", action: .denied))
        log.log(AuditEntry(origin: "a.com", action: .rateLimited))

        let aEntries = log.entries(forOrigin: "a.com")
        XCTAssertEqual(aEntries.count, 2)
        XCTAssertTrue(aEntries.allSatisfy { $0.origin == "a.com" })

        let bEntries = log.entries(forOrigin: "b.com")
        XCTAssertEqual(bEntries.count, 1)
    }

    func testFilterByAction() {
        log.log(AuditEntry(origin: "a.com", action: .approved))
        log.log(AuditEntry(origin: "b.com", action: .denied))
        log.log(AuditEntry(origin: "c.com", action: .approved))

        let approved = log.entries(withAction: .approved)
        XCTAssertEqual(approved.count, 2)
        XCTAssertTrue(approved.allSatisfy { $0.action == .approved })
    }

    func testFilterByOriginWithLimit() {
        for i in 0..<10 {
            log.log(AuditEntry(origin: "target.com", action: .approved, detail: "entry-\(i)"))
        }
        log.log(AuditEntry(origin: "other.com", action: .denied))

        let limited = log.entries(forOrigin: "target.com", limit: 3)
        XCTAssertEqual(limited.count, 3)
        // Should be the 3 most recent target.com entries
        XCTAssertEqual(limited[0].detail, "entry-7")
        XCTAssertEqual(limited[2].detail, "entry-9")
    }

    // MARK: - Entry Fields

    func testAllActionTypes() {
        let actions: [AuditEntry.Action] = [.approved, .denied, .sessionAutoApproved, .rateLimited, .noProvider]
        for action in actions {
            log.log(AuditEntry(origin: "test.com", action: action))
        }
        let entries = log.entries()
        XCTAssertEqual(entries.count, 5)
        XCTAssertEqual(entries.map(\.action), actions)
    }

    func testEventKindField() {
        log.log(AuditEntry(origin: "test.com", action: .approved, eventKind: 1, detail: "text note"))
        log.log(AuditEntry(origin: "test.com", action: .approved, eventKind: nil))

        let entries = log.entries()
        XCTAssertEqual(entries[0].eventKind, 1)
        XCTAssertNil(entries[1].eventKind)
    }

    func testTimestampPreservation() {
        let fixedDate = Date(timeIntervalSince1970: 1700000000)
        log.log(AuditEntry(timestamp: fixedDate, origin: "test.com", action: .approved))

        let entries = log.entries()
        XCTAssertEqual(entries.count, 1)
        // ISO-8601 round-trip may lose sub-second precision, check within 1 second
        XCTAssertEqual(entries[0].timestamp.timeIntervalSince1970, fixedDate.timeIntervalSince1970, accuracy: 1.0)
    }

    // MARK: - Persistence

    func testPersistenceAcrossInstances() {
        log.log(AuditEntry(origin: "persist.com", action: .approved))
        log.log(AuditEntry(origin: "persist.com", action: .denied))

        // Create a new AuditLog pointing at the same directory
        let log2 = AuditLog(containerURL: tempDir)
        let entries = log2.entries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].origin, "persist.com")
    }

    // MARK: - Auto-Trim

    func testAutoTrimAtCapacity() {
        // Use a small maxEntries for testing
        let smallLog = AuditLog(containerURL: tempDir, filename: "small_audit.jsonl", maxEntries: 20)

        // Write 25 entries to exceed capacity
        for i in 0..<25 {
            smallLog.log(AuditEntry(origin: "origin-\(i).com", action: .approved))
        }

        // Should have been trimmed (keeps maxEntries/2 = 10 most recent)
        let count = smallLog.entryCount
        XCTAssertLessThanOrEqual(count, 20, "Log should auto-trim when exceeding maxEntries")
        // The most recent entry should always survive
        let entries = smallLog.entries(limit: 1)
        XCTAssertEqual(entries[0].origin, "origin-24.com")
    }

    // MARK: - Empty / Edge Cases

    func testEmptyLogReturnsEmptyArray() {
        XCTAssertTrue(log.entries().isEmpty)
        XCTAssertEqual(log.entryCount, 0)
    }

    func testClearOnEmptyLogNoError() {
        // Should not throw or crash
        log.clear()
        XCTAssertEqual(log.entryCount, 0)
    }

    func testNilContainerURLDoesNotCrash() {
        // nil containerURL falls back to tmp — should work without crashing
        let nilLog = AuditLog(containerURL: nil)
        nilLog.log(AuditEntry(origin: "test.com", action: .approved))
        XCTAssertGreaterThanOrEqual(nilLog.entryCount, 0)
    }

    // MARK: - Concurrent Access

    func testConcurrentWritesDoNotCrash() {
        let group = DispatchGroup()
        let iterations = 100

        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                self.log.log(AuditEntry(origin: "concurrent-\(i).com", action: .approved))
            }
        }

        let result = group.wait(timeout: .now() + 10)
        XCTAssertEqual(result, .success, "Concurrent writes timed out")
        XCTAssertEqual(log.entryCount, iterations)
    }

    func testConcurrentReadsAndWritesDoNotCrash() {
        let group = DispatchGroup()

        // Write some initial data
        for i in 0..<10 {
            log.log(AuditEntry(origin: "seed-\(i).com", action: .approved))
        }

        // Concurrent reads and writes
        for i in 0..<50 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                if i % 2 == 0 {
                    self.log.log(AuditEntry(origin: "write-\(i).com", action: .denied))
                } else {
                    _ = self.log.entries(limit: 5)
                }
            }
        }

        let result = group.wait(timeout: .now() + 10)
        XCTAssertEqual(result, .success, "Concurrent reads/writes timed out")
    }

    // MARK: - Action Codable Round-Trip

    func testActionRawValues() {
        XCTAssertEqual(AuditEntry.Action.approved.rawValue, "approved")
        XCTAssertEqual(AuditEntry.Action.denied.rawValue, "denied")
        XCTAssertEqual(AuditEntry.Action.sessionAutoApproved.rawValue, "sessionAutoApproved")
        XCTAssertEqual(AuditEntry.Action.rateLimited.rawValue, "rateLimited")
        XCTAssertEqual(AuditEntry.Action.noProvider.rawValue, "noProvider")
    }
}

// MARK: - PolicyEngine Integration Tests

final class PolicyEngineAuditIntegrationTests: XCTestCase {

    private var tempDir: URL!
    private var auditLog: AuditLog!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyfob-policy-audit-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        auditLog = AuditLog(containerURL: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    class MockConsent: PolicyEngine.ConsentProvider {
        var approveAll = true
        var callCount = 0
        func requestConsent(origin: String, eventPreview: String, mode: PolicyEngine.ConsentMode) throws {
            callCount += 1
            if !approveAll {
                throw NSError(domain: "MockConsent", code: 1, userInfo: [NSLocalizedDescriptionKey: "Denied by mock"])
            }
        }
    }

    func testConsentApprovalIsLogged() throws {
        let engine = PolicyEngine.shared
        let mock = MockConsent()
        mock.approveAll = true
        engine.consentProvider = mock
        defer { engine.consentProvider = nil }

        let origin = "audit.approve.\(UUID().uuidString)"
        try engine.requestConsent(origin: origin, eventPreview: "{}", mode: .perRequest)

        // Check the shared audit log recorded the approval
        let entries = engine.auditLog.entries(forOrigin: origin)
        XCTAssertFalse(entries.isEmpty, "Approval should be logged")
        XCTAssertEqual(entries.last?.action, .approved)
        XCTAssertTrue(entries.last?.detail?.contains("perRequest") == true)
    }

    func testConsentDenialIsLogged() throws {
        let engine = PolicyEngine.shared
        let mock = MockConsent()
        mock.approveAll = false
        engine.consentProvider = mock
        defer { engine.consentProvider = nil }

        let origin = "audit.deny.\(UUID().uuidString)"
        XCTAssertThrowsError(try engine.requestConsent(origin: origin, eventPreview: "{}", mode: .perRequest))

        let entries = engine.auditLog.entries(forOrigin: origin)
        XCTAssertFalse(entries.isEmpty, "Denial should be logged")
        XCTAssertEqual(entries.last?.action, .denied)
    }

    func testNoProviderIsLogged() throws {
        let engine = PolicyEngine.shared
        let saved = engine.consentProvider
        engine.consentProvider = nil
        defer { engine.consentProvider = saved }

        let origin = "audit.noprovider.\(UUID().uuidString)"
        XCTAssertThrowsError(try engine.requestConsent(origin: origin, eventPreview: "{}", mode: .perRequest))

        let entries = engine.auditLog.entries(forOrigin: origin)
        XCTAssertFalse(entries.isEmpty, "No-provider error should be logged")
        XCTAssertEqual(entries.last?.action, .noProvider)
    }

    func testSessionAutoApprovalIsLogged() throws {
        let engine = PolicyEngine.shared
        let mock = MockConsent()
        engine.consentProvider = mock
        defer { engine.consentProvider = nil }

        let origin = "audit.session.\(UUID().uuidString)"
        // Allow origin with session mode
        engine.allow(origin: origin, duration: 60, defaultMode: .session)

        // Session mode request should auto-approve and log
        try engine.requestConsent(origin: origin, eventPreview: "{}", mode: .session)

        let entries = engine.auditLog.entries(forOrigin: origin)
        XCTAssertTrue(entries.contains(where: { $0.action == .sessionAutoApproved }), "Session auto-approval should be logged")
    }

    func testRateLimitIsLogged() throws {
        let engine = PolicyEngine.shared

        let origin = "audit.ratelimit.\(UUID().uuidString)"
        var rateLimited = false
        // Exceed rate limit
        for _ in 0..<15 {
            do { try engine.preflight(origin: origin) } catch {
                rateLimited = true
                break
            }
        }
        XCTAssertTrue(rateLimited, "Should have hit rate limit")

        let entries = engine.auditLog.entries(forOrigin: origin)
        XCTAssertTrue(entries.contains(where: { $0.action == .rateLimited }), "Rate limit should be logged")
    }
}

// MARK: - Duration Telemetry Tests

final class AuditEntryDurationTests: XCTestCase {

    private var tempDir: URL!
    private var log: AuditLog!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyfob-duration-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        log = AuditLog(containerURL: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testDurationMsRecordedOnEntry() {
        let entry = AuditEntry(
            origin: "example.com",
            action: .approved,
            eventKind: 1,
            detail: "sign completed",
            durationMs: 42
        )
        log.log(entry)

        let entries = log.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].durationMs, 42)
        XCTAssertEqual(entries[0].action, .approved)
        XCTAssertEqual(entries[0].eventKind, 1)
    }

    func testDurationMsNilByDefault() {
        let entry = AuditEntry(origin: "example.com", action: .approved)
        log.log(entry)

        let entries = log.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].durationMs)
    }

    func testDurationMsRoundTripsViaJSONL() {
        // Write entry with duration, read it back — field must survive encode/decode
        let entry = AuditEntry(
            origin: "latency.test",
            action: .denied,
            detail: "user denied",
            durationMs: 1500
        )
        log.log(entry)

        // Read from a fresh AuditLog pointing to the same file
        let log2 = AuditLog(containerURL: tempDir)
        let entries = log2.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].durationMs, 1500)
        XCTAssertEqual(entries[0].action, .denied)
    }

    func testBackwardCompatibility_NilDurationDecodesFromOldFormat() {
        // Simulate an old-format entry without durationMs field
        let oldJSON = """
        {"timestamp":"2026-01-01T00:00:00Z","origin":"old.com","action":"approved"}
        """
        let fileURL = tempDir.appendingPathComponent("audit_log.jsonl")
        try! (oldJSON + "\n").data(using: .utf8)!.write(to: fileURL, options: .atomic)

        let log2 = AuditLog(containerURL: tempDir)
        let entries = log2.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].origin, "old.com")
        XCTAssertNil(entries[0].durationMs, "Old entries without durationMs should decode as nil")
    }

    func testDurationMsOnDeniedEntry() {
        let entry = AuditEntry(
            origin: "denied.com",
            action: .denied,
            detail: "sign failed: timeout",
            durationMs: 120000
        )
        log.log(entry)

        let entries = log.entries(withAction: .denied)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].durationMs, 120000)
    }

    func testMixedEntriesWithAndWithoutDuration() {
        log.log(AuditEntry(origin: "a.com", action: .approved, durationMs: 50))
        log.log(AuditEntry(origin: "b.com", action: .sessionAutoApproved))
        log.log(AuditEntry(origin: "c.com", action: .denied, durationMs: 3000))
        log.log(AuditEntry(origin: "d.com", action: .rateLimited))

        let entries = log.entries()
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries[0].durationMs, 50)
        XCTAssertNil(entries[1].durationMs)
        XCTAssertEqual(entries[2].durationMs, 3000)
        XCTAssertNil(entries[3].durationMs)
    }
}
