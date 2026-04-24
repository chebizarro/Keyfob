//
//  PermissionRuleTests.swift
//
//
//  Created for Keyfob – kf-sxf
//

import XCTest
@testable import KeyfobPolicy

// MARK: - PermissionRule Model Tests

final class PermissionRuleModelTests: XCTestCase {

    // MARK: - Init & Properties

    func testInit_defaults() {
        let rule = PermissionRule(
            clientID: "com.test",
            operationKind: "sign",
            decision: .allow,
            scope: .persistent
        )
        XCTAssertEqual(rule.clientID, "com.test")
        XCTAssertNil(rule.identityID)
        XCTAssertEqual(rule.operationKind, "sign")
        XCTAssertNil(rule.eventKind)
        XCTAssertEqual(rule.decision, .allow)
        XCTAssertEqual(rule.scope, .persistent)
        XCTAssertNil(rule.expiresAt)
        XCTAssertFalse(rule.isExpired)
    }

    func testInit_allParameters() {
        let id = UUID()
        let identityID = UUID()
        let now = Date()
        let expiry = now.addingTimeInterval(3600)

        let rule = PermissionRule(
            id: id,
            clientID: "com.example",
            identityID: identityID,
            operationKind: "nip44Encrypt",
            eventKind: 1,
            decision: .deny,
            scope: .session,
            expiresAt: expiry,
            createdAt: now
        )

        XCTAssertEqual(rule.id, id)
        XCTAssertEqual(rule.identityID, identityID)
        XCTAssertEqual(rule.operationKind, "nip44Encrypt")
        XCTAssertEqual(rule.eventKind, 1)
        XCTAssertEqual(rule.decision, .deny)
        XCTAssertEqual(rule.scope, .session)
        XCTAssertEqual(rule.expiresAt, expiry)
    }

    func testIsExpired_futureDate() {
        let rule = PermissionRule(
            clientID: "x",
            operationKind: "sign",
            decision: .allow,
            scope: .session,
            expiresAt: Date().addingTimeInterval(3600)
        )
        XCTAssertFalse(rule.isExpired)
    }

    func testIsExpired_pastDate() {
        let rule = PermissionRule(
            clientID: "x",
            operationKind: "sign",
            decision: .allow,
            scope: .session,
            expiresAt: Date().addingTimeInterval(-1)
        )
        XCTAssertTrue(rule.isExpired)
    }

    func testIsExpired_nilDate() {
        let rule = PermissionRule(
            clientID: "x",
            operationKind: "sign",
            decision: .allow,
            scope: .persistent,
            expiresAt: nil
        )
        XCTAssertFalse(rule.isExpired)
    }

    // MARK: - Specificity

    func testSpecificity_wildcardBoth() {
        let rule = PermissionRule(
            clientID: "x", identityID: nil, operationKind: "sign",
            eventKind: nil, decision: .allow, scope: .persistent
        )
        XCTAssertEqual(rule.specificity, 1)
    }

    func testSpecificity_exactEventKind() {
        let rule = PermissionRule(
            clientID: "x", identityID: nil, operationKind: "sign",
            eventKind: 1, decision: .allow, scope: .persistent
        )
        XCTAssertEqual(rule.specificity, 2)
    }

    func testSpecificity_exactIdentity() {
        let rule = PermissionRule(
            clientID: "x", identityID: UUID(), operationKind: "sign",
            eventKind: nil, decision: .allow, scope: .persistent
        )
        XCTAssertEqual(rule.specificity, 3)
    }

    func testSpecificity_exactBoth() {
        let rule = PermissionRule(
            clientID: "x", identityID: UUID(), operationKind: "sign",
            eventKind: 1, decision: .allow, scope: .persistent
        )
        XCTAssertEqual(rule.specificity, 4)
    }

    // MARK: - Codable

    func testCodableRoundTrip() throws {
        let rule = PermissionRule(
            clientID: "com.test",
            identityID: UUID(),
            operationKind: "nip04Decrypt",
            eventKind: 4,
            decision: .prompt,
            scope: .session,
            expiresAt: Date(timeIntervalSince1970: 5000),
            createdAt: Date(timeIntervalSince1970: 1000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(rule)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(PermissionRule.self, from: data)

        XCTAssertEqual(rule, decoded)
    }

    func testDecisionAllCases() {
        XCTAssertEqual(PermissionRule.Decision.allCases.count, 3)
        XCTAssertTrue(PermissionRule.Decision.allCases.contains(.allow))
        XCTAssertTrue(PermissionRule.Decision.allCases.contains(.prompt))
        XCTAssertTrue(PermissionRule.Decision.allCases.contains(.deny))
    }

    func testScopeAllCases() {
        XCTAssertEqual(PermissionRule.Scope.allCases.count, 2)
        XCTAssertTrue(PermissionRule.Scope.allCases.contains(.session))
        XCTAssertTrue(PermissionRule.Scope.allCases.contains(.persistent))
    }
}

// MARK: - Rule Evaluation Tests

final class PermissionRuleEvaluationTests: XCTestCase {

    private let identity1 = UUID()
    private let identity2 = UUID()

    private func makeRule(
        clientID: String = "com.test",
        identityID: UUID? = nil,
        operationKind: String = "sign",
        eventKind: Int? = nil,
        decision: PermissionRule.Decision = .allow,
        expiresAt: Date? = nil
    ) -> PermissionRule {
        PermissionRule(
            clientID: clientID,
            identityID: identityID,
            operationKind: operationKind,
            eventKind: eventKind,
            decision: decision,
            scope: .persistent,
            expiresAt: expiresAt
        )
    }

    func testEvaluate_noRules_returnsNil() {
        let result = PermissionRule.evaluate(
            rules: [], clientID: "x", identityID: nil,
            operationKind: "sign", eventKind: nil
        )
        XCTAssertNil(result)
    }

    func testEvaluate_noMatchingClient_returnsNil() {
        let rules = [makeRule(clientID: "com.other")]
        let result = PermissionRule.evaluate(
            rules: rules, clientID: "com.test", identityID: nil,
            operationKind: "sign", eventKind: nil
        )
        XCTAssertNil(result)
    }

    func testEvaluate_noMatchingOp_returnsNil() {
        let rules = [makeRule(operationKind: "nip44Encrypt")]
        let result = PermissionRule.evaluate(
            rules: rules, clientID: "com.test", identityID: nil,
            operationKind: "sign", eventKind: nil
        )
        XCTAssertNil(result)
    }

    func testEvaluate_exactMatch() {
        let rules = [makeRule(identityID: identity1, eventKind: 1, decision: .deny)]
        let result = PermissionRule.evaluate(
            rules: rules, clientID: "com.test", identityID: identity1,
            operationKind: "sign", eventKind: 1
        )
        XCTAssertEqual(result, .deny)
    }

    func testEvaluate_wildcardEventKind() {
        let rules = [makeRule(identityID: identity1, decision: .allow)]
        let result = PermissionRule.evaluate(
            rules: rules, clientID: "com.test", identityID: identity1,
            operationKind: "sign", eventKind: 7
        )
        XCTAssertEqual(result, .allow)
    }

    func testEvaluate_wildcardIdentity() {
        let rules = [makeRule(eventKind: 1, decision: .prompt)]
        let result = PermissionRule.evaluate(
            rules: rules, clientID: "com.test", identityID: identity1,
            operationKind: "sign", eventKind: 1
        )
        XCTAssertEqual(result, .prompt)
    }

    func testEvaluate_doubleWildcard() {
        let rules = [makeRule(decision: .allow)]
        let result = PermissionRule.evaluate(
            rules: rules, clientID: "com.test", identityID: identity1,
            operationKind: "sign", eventKind: 42
        )
        XCTAssertEqual(result, .allow)
    }

    func testEvaluate_moreSpecificWins() {
        let rules = [
            makeRule(decision: .allow),                              // specificity 1
            makeRule(identityID: identity1, decision: .deny),        // specificity 3
        ]
        let result = PermissionRule.evaluate(
            rules: rules, clientID: "com.test", identityID: identity1,
            operationKind: "sign", eventKind: nil
        )
        XCTAssertEqual(result, .deny, "More specific identity rule should win")
    }

    func testEvaluate_exactKindBeatsWildcard() {
        let rules = [
            makeRule(identityID: identity1, decision: .allow),                      // specificity 3
            makeRule(identityID: identity1, eventKind: 1, decision: .deny),         // specificity 4
        ]
        let result = PermissionRule.evaluate(
            rules: rules, clientID: "com.test", identityID: identity1,
            operationKind: "sign", eventKind: 1
        )
        XCTAssertEqual(result, .deny, "Exact event kind match should win")
    }

    func testEvaluate_expiredRulesSkipped() {
        let rules = [
            makeRule(decision: .allow, expiresAt: Date().addingTimeInterval(-100)),
        ]
        let result = PermissionRule.evaluate(
            rules: rules, clientID: "com.test", identityID: nil,
            operationKind: "sign", eventKind: nil
        )
        XCTAssertNil(result, "Expired rule should be skipped")
    }

    func testEvaluate_nonExpiredRuleWins() {
        let rules = [
            makeRule(decision: .allow, expiresAt: Date().addingTimeInterval(-100)),
            makeRule(decision: .deny, expiresAt: Date().addingTimeInterval(3600)),
        ]
        let result = PermissionRule.evaluate(
            rules: rules, clientID: "com.test", identityID: nil,
            operationKind: "sign", eventKind: nil
        )
        XCTAssertEqual(result, .deny)
    }

    func testEvaluate_identityMismatch_skips() {
        let rules = [makeRule(identityID: identity1, decision: .allow)]
        let result = PermissionRule.evaluate(
            rules: rules, clientID: "com.test", identityID: identity2,
            operationKind: "sign", eventKind: nil
        )
        XCTAssertNil(result, "Rule for different identity should not match")
    }

    func testEvaluate_eventKindMismatch_skips() {
        let rules = [makeRule(eventKind: 1, decision: .allow)]
        let result = PermissionRule.evaluate(
            rules: rules, clientID: "com.test", identityID: nil,
            operationKind: "sign", eventKind: 7
        )
        XCTAssertNil(result, "Rule for different event kind should not match")
    }

    func testEvaluate_multipleOperationKinds() {
        let rules = [
            makeRule(operationKind: "sign", decision: .allow),
            makeRule(operationKind: "nip44Encrypt", decision: .deny),
        ]
        XCTAssertEqual(
            PermissionRule.evaluate(
                rules: rules, clientID: "com.test", identityID: nil,
                operationKind: "sign", eventKind: nil
            ),
            .allow
        )
        XCTAssertEqual(
            PermissionRule.evaluate(
                rules: rules, clientID: "com.test", identityID: nil,
                operationKind: "nip44Encrypt", eventKind: nil
            ),
            .deny
        )
    }
}

// MARK: - PermissionRuleStore Error Tests

final class PermissionRuleStoreErrorTests: XCTestCase {

    func testRuleNotFound_equatable() {
        let id = UUID()
        XCTAssertEqual(
            PermissionRuleStoreError.ruleNotFound(id),
            PermissionRuleStoreError.ruleNotFound(id)
        )
    }

    func testStorageUnavailable_equatable() {
        XCTAssertEqual(
            PermissionRuleStoreError.storageUnavailable("a"),
            PermissionRuleStoreError.storageUnavailable("a")
        )
    }

    func testDataCorrupt_equatable() {
        XCTAssertEqual(
            PermissionRuleStoreError.dataCorrupt("bad"),
            PermissionRuleStoreError.dataCorrupt("bad")
        )
    }
}

// MARK: - FilePermissionRuleStore Tests

final class FilePermissionRuleStoreTests: XCTestCase {

    private var tempDir: URL!
    private var store: FilePermissionRuleStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyfobRuleTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try! FilePermissionRuleStore(containerURL: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeRule(
        clientID: String = "com.test",
        identityID: UUID? = nil,
        operationKind: String = "sign",
        eventKind: Int? = nil,
        decision: PermissionRule.Decision = .allow,
        scope: PermissionRule.Scope = .persistent,
        expiresAt: Date? = nil
    ) -> PermissionRule {
        PermissionRule(
            clientID: clientID,
            identityID: identityID,
            operationKind: operationKind,
            eventKind: eventKind,
            decision: decision,
            scope: scope,
            expiresAt: expiresAt
        )
    }

    // MARK: - addRule

    func testAddRule() throws {
        let rule = makeRule()
        try store.addRule(rule)

        let all = try store.allRules()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, rule.id)
    }

    func testAddMultipleRules() throws {
        try store.addRule(makeRule(clientID: "a"))
        try store.addRule(makeRule(clientID: "b"))
        try store.addRule(makeRule(clientID: "c"))

        let all = try store.allRules()
        XCTAssertEqual(all.count, 3)
    }

    // MARK: - removeRule

    func testRemoveRule() throws {
        let rule = makeRule()
        try store.addRule(rule)
        try store.removeRule(id: rule.id)

        let all = try store.allRules()
        XCTAssertEqual(all.count, 0)
    }

    func testRemoveRule_notFound_throws() {
        let id = UUID()
        XCTAssertThrowsError(try store.removeRule(id: id)) { error in
            guard let storeError = error as? PermissionRuleStoreError else {
                XCTFail("Expected PermissionRuleStoreError")
                return
            }
            XCTAssertEqual(storeError, .ruleNotFound(id))
        }
    }

    func testRemoveRule_onlyTargeted() throws {
        let keep = makeRule(clientID: "keep")
        let remove = makeRule(clientID: "remove")
        try store.addRule(keep)
        try store.addRule(remove)

        try store.removeRule(id: remove.id)

        let all = try store.allRules()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.clientID, "keep")
    }

    // MARK: - removeRules(forClient:)

    func testRemoveRulesForClient() throws {
        try store.addRule(makeRule(clientID: "com.remove", operationKind: "sign"))
        try store.addRule(makeRule(clientID: "com.remove", operationKind: "nip44Encrypt"))
        try store.addRule(makeRule(clientID: "com.keep"))

        try store.removeRules(forClient: "com.remove")

        let all = try store.allRules()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.clientID, "com.keep")
    }

    func testRemoveRulesForClient_nonexistent_noOp() throws {
        try store.addRule(makeRule(clientID: "com.keep"))
        try store.removeRules(forClient: "com.ghost")

        let all = try store.allRules()
        XCTAssertEqual(all.count, 1)
    }

    // MARK: - rules(forClient:)

    func testRulesForClient() throws {
        try store.addRule(makeRule(clientID: "com.a", operationKind: "sign"))
        try store.addRule(makeRule(clientID: "com.a", operationKind: "nip44Encrypt"))
        try store.addRule(makeRule(clientID: "com.b"))

        let rulesA = try store.rules(forClient: "com.a")
        XCTAssertEqual(rulesA.count, 2)

        let rulesB = try store.rules(forClient: "com.b")
        XCTAssertEqual(rulesB.count, 1)
    }

    func testRulesForClient_empty() throws {
        let rules = try store.rules(forClient: "com.missing")
        XCTAssertEqual(rules.count, 0)
    }

    // MARK: - pruneExpired

    func testPruneExpired_removesExpired() throws {
        try store.addRule(makeRule(clientID: "expired", expiresAt: Date().addingTimeInterval(-100)))
        try store.addRule(makeRule(clientID: "valid", expiresAt: Date().addingTimeInterval(3600)))
        try store.addRule(makeRule(clientID: "noExpiry"))

        let removed = try store.pruneExpired()
        XCTAssertEqual(removed, 1)

        let all = try store.allRules()
        XCTAssertEqual(all.count, 2)
        XCTAssertFalse(all.contains(where: { $0.clientID == "expired" }))
    }

    func testPruneExpired_noneExpired() throws {
        try store.addRule(makeRule(clientID: "a"))
        try store.addRule(makeRule(clientID: "b"))

        let removed = try store.pruneExpired()
        XCTAssertEqual(removed, 0)
    }

    // MARK: - evaluate

    func testEvaluate_matchesRule() throws {
        try store.addRule(makeRule(decision: .allow))
        let result = try store.evaluate(
            clientID: "com.test", identityID: nil,
            operationKind: "sign", eventKind: nil
        )
        XCTAssertEqual(result, .allow)
    }

    func testEvaluate_noMatch_returnsNil() throws {
        try store.addRule(makeRule(clientID: "com.other", decision: .allow))
        let result = try store.evaluate(
            clientID: "com.test", identityID: nil,
            operationKind: "sign", eventKind: nil
        )
        XCTAssertNil(result)
    }

    func testEvaluate_respectsSpecificity() throws {
        let identity = UUID()
        try store.addRule(makeRule(decision: .allow))                                // specificity 1
        try store.addRule(makeRule(identityID: identity, decision: .deny))            // specificity 3

        let result = try store.evaluate(
            clientID: "com.test", identityID: identity,
            operationKind: "sign", eventKind: nil
        )
        XCTAssertEqual(result, .deny)
    }

    // MARK: - Persistence

    func testPersistence_survivesFreshLoad() throws {
        let rule = makeRule(clientID: "persistent", decision: .deny)
        try store.addRule(rule)

        let freshStore = try FilePermissionRuleStore(containerURL: tempDir)
        let all = try freshStore.allRules()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.clientID, "persistent")
        XCTAssertEqual(all.first?.decision, .deny)
    }

    func testPersistence_removeSurvives() throws {
        let rule = makeRule()
        try store.addRule(rule)
        try store.removeRule(id: rule.id)

        let freshStore = try FilePermissionRuleStore(containerURL: tempDir)
        let all = try freshStore.allRules()
        XCTAssertEqual(all.count, 0)
    }

    // MARK: - PolicyEngine Integration

    func testPolicyEngine_evaluatePermission_withStore() throws {
        let engine = PolicyEngine(auditLog: AuditLog(containerURL: tempDir))
        engine.ruleStore = store

        try store.addRule(makeRule(clientID: "com.auto", decision: .allow))

        let result = try engine.evaluatePermission(
            clientID: "com.auto",
            operationKind: "sign"
        )
        XCTAssertEqual(result, .allow)
    }

    func testPolicyEngine_evaluatePermission_noStore_returnsNil() throws {
        let engine = PolicyEngine(auditLog: AuditLog(containerURL: tempDir))
        engine.ruleStore = nil

        let result = try engine.evaluatePermission(
            clientID: "com.test",
            operationKind: "sign"
        )
        XCTAssertNil(result)
    }

    func testPolicyEngine_evaluatePermission_deny() throws {
        let engine = PolicyEngine(auditLog: AuditLog(containerURL: tempDir))
        engine.ruleStore = store

        try store.addRule(makeRule(clientID: "com.blocked", decision: .deny))

        let result = try engine.evaluatePermission(
            clientID: "com.blocked",
            operationKind: "sign"
        )
        XCTAssertEqual(result, .deny)
    }

    func testPolicyEngine_evaluatePermission_prompt_returnsNil() throws {
        let engine = PolicyEngine(auditLog: AuditLog(containerURL: tempDir))
        engine.ruleStore = store

        try store.addRule(makeRule(clientID: "com.ask", decision: .prompt))

        let result = try engine.evaluatePermission(
            clientID: "com.ask",
            operationKind: "sign"
        )
        XCTAssertNil(result, ".prompt should fall through as nil")
    }

    func testPolicyEngine_evaluatePermission_noMatch_returnsNil() throws {
        let engine = PolicyEngine(auditLog: AuditLog(containerURL: tempDir))
        engine.ruleStore = store

        let result = try engine.evaluatePermission(
            clientID: "com.unknown",
            operationKind: "sign"
        )
        XCTAssertNil(result)
    }
}
