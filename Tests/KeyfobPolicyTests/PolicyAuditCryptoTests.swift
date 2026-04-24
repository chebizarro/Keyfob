//
//  PolicyAuditCryptoTests.swift
//
//
//  Created for Keyfob – kf-3vo
//

import XCTest
@testable import KeyfobPolicy

// MARK: - AuditEntry Crypto Fields Tests

final class AuditEntryCryptoFieldsTests: XCTestCase {

    func testNewFieldsDefaultToNil() {
        let entry = AuditEntry(origin: "x", action: .approved)
        XCTAssertNil(entry.operationType)
        XCTAssertNil(entry.counterpartyPubkey)
        XCTAssertNil(entry.identityUsed)
    }

    func testNewFieldsPopulated() {
        let entry = AuditEntry(
            origin: "com.test",
            action: .approved,
            eventKind: nil,
            detail: "encrypt ok",
            durationMs: 42,
            operationType: "nip44Encrypt",
            counterpartyPubkey: "abc123",
            identityUsed: "def456"
        )
        XCTAssertEqual(entry.operationType, "nip44Encrypt")
        XCTAssertEqual(entry.counterpartyPubkey, "abc123")
        XCTAssertEqual(entry.identityUsed, "def456")
        XCTAssertEqual(entry.durationMs, 42)
    }

    func testCodableRoundTrip_withNewFields() throws {
        let entry = AuditEntry(
            origin: "com.test",
            action: .ruleAutoApproved,
            operationType: "nip04Decrypt",
            counterpartyPubkey: "peer123",
            identityUsed: "me456"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AuditEntry.self, from: data)

        XCTAssertEqual(decoded.operationType, "nip04Decrypt")
        XCTAssertEqual(decoded.counterpartyPubkey, "peer123")
        XCTAssertEqual(decoded.identityUsed, "me456")
        XCTAssertEqual(decoded.action, .ruleAutoApproved)
    }

    func testCodableBackwardCompat_missingNewFields() throws {
        // Simulate a legacy entry without the new fields
        let json = """
        {"timestamp":"2026-01-01T00:00:00Z","origin":"old","action":"approved"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(AuditEntry.self, from: Data(json.utf8))

        XCTAssertEqual(entry.origin, "old")
        XCTAssertEqual(entry.action, .approved)
        XCTAssertNil(entry.operationType)
        XCTAssertNil(entry.counterpartyPubkey)
        XCTAssertNil(entry.identityUsed)
    }

    func testNewActions_codable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        for action in [AuditEntry.Action.ruleAutoApproved, .ruleAutoDenied] {
            let entry = AuditEntry(origin: "x", action: action)
            let data = try encoder.encode(entry)
            let decoded = try decoder.decode(AuditEntry.self, from: data)
            XCTAssertEqual(decoded.action, action)
        }
    }
}

// MARK: - AuditLog Crypto Filter Tests

final class AuditLogCryptoFilterTests: XCTestCase {

    private var tempDir: URL!
    private var log: AuditLog!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyfobAuditTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        log = AuditLog(containerURL: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testFilterByOperationType() {
        log.log(AuditEntry(origin: "a", action: .approved, operationType: "sign"))
        log.log(AuditEntry(origin: "b", action: .approved, operationType: "nip44Encrypt"))
        log.log(AuditEntry(origin: "c", action: .approved, operationType: "nip44Decrypt"))
        log.log(AuditEntry(origin: "d", action: .approved, operationType: "nip44Encrypt"))

        let nip44Encrypts = log.entries(forOperationType: "nip44Encrypt")
        XCTAssertEqual(nip44Encrypts.count, 2)
        XCTAssertTrue(nip44Encrypts.allSatisfy { $0.operationType == "nip44Encrypt" })

        let signs = log.entries(forOperationType: "sign")
        XCTAssertEqual(signs.count, 1)
    }

    func testFilterByCounterparty() {
        log.log(AuditEntry(origin: "a", action: .approved, counterpartyPubkey: "peer1"))
        log.log(AuditEntry(origin: "b", action: .approved, counterpartyPubkey: "peer2"))
        log.log(AuditEntry(origin: "c", action: .approved, counterpartyPubkey: "peer1"))

        let peer1 = log.entries(forCounterparty: "peer1")
        XCTAssertEqual(peer1.count, 2)
    }

    func testFilterByOperationType_limit() {
        for i in 0..<20 {
            log.log(AuditEntry(
                origin: "client\(i)",
                action: .approved,
                operationType: "nip44Encrypt"
            ))
        }
        let limited = log.entries(forOperationType: "nip44Encrypt", limit: 5)
        XCTAssertEqual(limited.count, 5)
    }

    func testNewFieldsPersistThroughLog() {
        log.log(AuditEntry(
            origin: "com.test",
            action: .ruleAutoApproved,
            operationType: "nip04Encrypt",
            counterpartyPubkey: "peer",
            identityUsed: "me"
        ))

        let entries = log.entries(limit: 1)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].operationType, "nip04Encrypt")
        XCTAssertEqual(entries[0].counterpartyPubkey, "peer")
        XCTAssertEqual(entries[0].identityUsed, "me")
        XCTAssertEqual(entries[0].action, .ruleAutoApproved)
    }
}

// MARK: - PolicyEngine Crypto Operation Tests

final class PolicyEngineCryptoOperationTests: XCTestCase {

    private var tempDir: URL!
    private var ruleStore: FilePermissionRuleStore!
    private var engine: PolicyEngine!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyfobPolicyCrypto-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ruleStore = try! FilePermissionRuleStore(containerURL: tempDir)
        engine = PolicyEngine(auditLog: AuditLog(containerURL: tempDir))
        engine.ruleStore = ruleStore
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    class MockConsent: PolicyEngine.ConsentProvider {
        var approveAll = true
        var callCount = 0
        var lastEventPreview: String?
        func requestConsent(origin: String, eventPreview: String, mode: PolicyEngine.ConsentMode) throws {
            callCount += 1
            lastEventPreview = eventPreview
            if !approveAll { throw NSError(domain: "Mock", code: 1) }
        }
    }

    // MARK: - evaluatePermission with crypto context

    func testEvaluatePermission_nip44Encrypt_allow() throws {
        try ruleStore.addRule(PermissionRule(
            clientID: "com.app",
            operationKind: "nip44Encrypt",
            decision: .allow,
            scope: .persistent
        ))

        let result = try engine.evaluatePermission(
            clientID: "com.app",
            operationKind: "nip44Encrypt",
            counterpartyPubkey: "peer123",
            identityPubkey: "me456"
        )
        XCTAssertEqual(result, .allow)

        // Verify audit entry has crypto context
        let entries = engine.auditLog.entries(limit: 10)
        let ruleEntry = entries.first(where: { $0.action == .ruleAutoApproved })
        XCTAssertNotNil(ruleEntry)
        XCTAssertEqual(ruleEntry?.operationType, "nip44Encrypt")
        XCTAssertEqual(ruleEntry?.counterpartyPubkey, "peer123")
        XCTAssertEqual(ruleEntry?.identityUsed, "me456")
    }

    func testEvaluatePermission_nip44Decrypt_deny() throws {
        try ruleStore.addRule(PermissionRule(
            clientID: "com.blocked",
            operationKind: "nip44Decrypt",
            decision: .deny,
            scope: .persistent
        ))

        let result = try engine.evaluatePermission(
            clientID: "com.blocked",
            operationKind: "nip44Decrypt",
            counterpartyPubkey: "peer",
            identityPubkey: "me"
        )
        XCTAssertEqual(result, .deny)

        let entries = engine.auditLog.entries(limit: 10)
        let denyEntry = entries.first(where: { $0.action == .ruleAutoDenied })
        XCTAssertNotNil(denyEntry)
        XCTAssertEqual(denyEntry?.operationType, "nip44Decrypt")
    }

    func testEvaluatePermission_nip04_operations() throws {
        try ruleStore.addRule(PermissionRule(
            clientID: "com.legacy",
            operationKind: "nip04Encrypt",
            decision: .deny,
            scope: .persistent
        ))
        try ruleStore.addRule(PermissionRule(
            clientID: "com.legacy",
            operationKind: "nip04Decrypt",
            decision: .allow,
            scope: .persistent
        ))

        XCTAssertEqual(
            try engine.evaluatePermission(clientID: "com.legacy", operationKind: "nip04Encrypt"),
            .deny
        )
        XCTAssertEqual(
            try engine.evaluatePermission(clientID: "com.legacy", operationKind: "nip04Decrypt"),
            .allow
        )
    }

    func testEvaluatePermission_allowSignButPromptEncrypt() throws {
        try ruleStore.addRule(PermissionRule(
            clientID: "com.mixed",
            operationKind: "sign",
            decision: .allow,
            scope: .persistent
        ))
        // No rule for encrypt — should return nil (prompt)

        XCTAssertEqual(
            try engine.evaluatePermission(clientID: "com.mixed", operationKind: "sign"),
            .allow
        )
        XCTAssertNil(
            try engine.evaluatePermission(clientID: "com.mixed", operationKind: "nip44Encrypt")
        )
    }

    // MARK: - preflightOperation

    func testPreflightOperation_ruleAllows_noConsentNeeded() throws {
        let mock = MockConsent()
        engine.consentProvider = mock

        try ruleStore.addRule(PermissionRule(
            clientID: "com.auto",
            operationKind: "nip44Encrypt",
            decision: .allow,
            scope: .persistent
        ))

        XCTAssertNoThrow(try engine.preflightOperation(
            clientID: "com.auto",
            operationKind: "nip44Encrypt",
            counterpartyPubkey: "peer",
            identityPubkey: "me"
        ))

        XCTAssertEqual(mock.callCount, 0, "Consent should not be prompted when rule allows")
    }

    func testPreflightOperation_ruleDenies_throws() throws {
        let mock = MockConsent()
        engine.consentProvider = mock

        try ruleStore.addRule(PermissionRule(
            clientID: "com.blocked",
            operationKind: "nip44Decrypt",
            decision: .deny,
            scope: .persistent
        ))

        XCTAssertThrowsError(try engine.preflightOperation(
            clientID: "com.blocked",
            operationKind: "nip44Decrypt"
        )) { error in
            guard let policyError = error as? PolicyOperationError else {
                XCTFail("Expected PolicyOperationError, got \(error)")
                return
            }
            XCTAssertEqual(policyError, .deniedByRule(clientID: "com.blocked", operationKind: "nip44Decrypt"))
        }
        XCTAssertEqual(mock.callCount, 0, "Consent should not be prompted when rule denies")
    }

    func testPreflightOperation_noRule_fallsToConsent() throws {
        let mock = MockConsent()
        engine.consentProvider = mock

        XCTAssertNoThrow(try engine.preflightOperation(
            clientID: "com.new",
            operationKind: "nip44Encrypt",
            eventPreview: "{}",
            mode: .perRequest
        ))
        XCTAssertEqual(mock.callCount, 1, "Should fall through to consent when no rule")
    }

    func testPreflightOperation_noRule_consentDenied_throws() throws {
        let mock = MockConsent()
        mock.approveAll = false
        engine.consentProvider = mock

        XCTAssertThrowsError(try engine.preflightOperation(
            clientID: "com.denied",
            operationKind: "nip04Encrypt"
        ))
        XCTAssertEqual(mock.callCount, 1)
    }

    func testPreflightOperation_rateLimitApplies() throws {
        let mock = MockConsent()
        engine.consentProvider = mock

        // Exhaust rate limit (shared across all op types)
        var rateLimited = false
        for _ in 0..<15 {
            do {
                try engine.preflightOperation(
                    clientID: "com.flood.\(UUID().uuidString)",
                    operationKind: "nip44Encrypt"
                )
            } catch {
                rateLimited = true
                break
            }
        }
        // Note: rate limiting is per-origin, so with unique origins each time,
        // it won't trigger. Let's test with same origin:
        rateLimited = false
        let sameOrigin = "com.flood.same"
        for _ in 0..<15 {
            do {
                try engine.preflightOperation(
                    clientID: sameOrigin,
                    operationKind: "nip44Encrypt"
                )
            } catch {
                rateLimited = true
                break
            }
        }
        XCTAssertTrue(rateLimited, "Rate limit should trigger for repeated same-origin requests")
    }

    // MARK: - recordOperationSuccess/Failure

    func testRecordOperationSuccess() {
        engine.recordOperationSuccess(
            clientID: "com.test",
            operationKind: "nip44Encrypt",
            counterpartyPubkey: "peer",
            identityPubkey: "me",
            durationMs: 15
        )

        let entries = engine.auditLog.entries(limit: 1)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].action, .approved)
        XCTAssertEqual(entries[0].operationType, "nip44Encrypt")
        XCTAssertEqual(entries[0].counterpartyPubkey, "peer")
        XCTAssertEqual(entries[0].identityUsed, "me")
        XCTAssertEqual(entries[0].durationMs, 15)
    }

    func testRecordOperationFailure() {
        let error = NSError(domain: "Test", code: 42, userInfo: [NSLocalizedDescriptionKey: "test error"])
        engine.recordOperationFailure(
            clientID: "com.fail",
            operationKind: "nip04Decrypt",
            counterpartyPubkey: "peer",
            identityPubkey: "me",
            error: error,
            durationMs: 5
        )

        let entries = engine.auditLog.entries(limit: 1)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].action, .denied)
        XCTAssertEqual(entries[0].operationType, "nip04Decrypt")
        XCTAssertEqual(entries[0].counterpartyPubkey, "peer")
        XCTAssertEqual(entries[0].durationMs, 5)
        XCTAssertTrue(entries[0].detail?.contains("test error") ?? false)
    }

    // MARK: - Per-operation-type rules

    func testPerOperationTypeRules_signAllowedEncryptDenied() throws {
        try ruleStore.addRule(PermissionRule(
            clientID: "com.selective",
            operationKind: "sign",
            decision: .allow,
            scope: .persistent
        ))
        try ruleStore.addRule(PermissionRule(
            clientID: "com.selective",
            operationKind: "nip04Encrypt",
            decision: .deny,
            scope: .persistent
        ))

        // Sign should be auto-approved
        let mock = MockConsent()
        engine.consentProvider = mock

        XCTAssertNoThrow(try engine.preflightOperation(
            clientID: "com.selective",
            operationKind: "sign"
        ))
        XCTAssertEqual(mock.callCount, 0)

        // NIP-04 encrypt should be auto-denied
        XCTAssertThrowsError(try engine.preflightOperation(
            clientID: "com.selective",
            operationKind: "nip04Encrypt"
        ))
        XCTAssertEqual(mock.callCount, 0)

        // NIP-44 encrypt (no rule) should prompt
        XCTAssertNoThrow(try engine.preflightOperation(
            clientID: "com.selective",
            operationKind: "nip44Encrypt"
        ))
        XCTAssertEqual(mock.callCount, 1)
    }

    // MARK: - PolicyOperationError

    func testPolicyOperationError_equatable() {
        XCTAssertEqual(
            PolicyOperationError.deniedByRule(clientID: "a", operationKind: "sign"),
            PolicyOperationError.deniedByRule(clientID: "a", operationKind: "sign")
        )
        XCTAssertNotEqual(
            PolicyOperationError.deniedByRule(clientID: "a", operationKind: "sign"),
            PolicyOperationError.deniedByRule(clientID: "b", operationKind: "sign")
        )
    }
}
