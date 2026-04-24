//
//  PolicyPresetTests.swift
//
//
//  Created for Keyfob – kf-w5x
//

import XCTest
@testable import KeyfobPolicy

// MARK: - PolicyPreset Model Tests

final class PolicyPresetModelTests: XCTestCase {

    func testAllCases() {
        XCTAssertEqual(PolicyPreset.allCases.count, 3)
        XCTAssertTrue(PolicyPreset.allCases.contains(.basic))
        XCTAssertTrue(PolicyPreset.allCases.contains(.standard))
        XCTAssertTrue(PolicyPreset.allCases.contains(.paranoid))
    }

    func testDisplayNames() {
        XCTAssertEqual(PolicyPreset.basic.displayName, "Basic")
        XCTAssertEqual(PolicyPreset.standard.displayName, "Standard")
        XCTAssertEqual(PolicyPreset.paranoid.displayName, "Paranoid")
    }

    func testDescriptions_notEmpty() {
        for preset in PolicyPreset.allCases {
            XCTAssertFalse(preset.description.isEmpty, "\(preset) has empty description")
        }
    }

    func testCodableRoundTrip() throws {
        for preset in PolicyPreset.allCases {
            let data = try JSONEncoder().encode(preset)
            let decoded = try JSONDecoder().decode(PolicyPreset.self, from: data)
            XCTAssertEqual(preset, decoded)
        }
    }

    func testRawValues() {
        XCTAssertEqual(PolicyPreset.basic.rawValue, "basic")
        XCTAssertEqual(PolicyPreset.standard.rawValue, "standard")
        XCTAssertEqual(PolicyPreset.paranoid.rawValue, "paranoid")
    }
}

// MARK: - Basic Preset Tests

final class BasicPresetTests: XCTestCase {

    private let clientID = "com.basic.app"
    private lazy var rules = PolicyPreset.basic.rules(forClient: clientID)

    func testBasic_generatesRules() {
        XCTAssertGreaterThan(rules.count, 0)
    }

    func testBasic_allRulesHaveCorrectClient() {
        XCTAssertTrue(rules.allSatisfy { $0.clientID == clientID })
    }

    func testBasic_allRulesArePersistent() {
        XCTAssertTrue(rules.allSatisfy { $0.scope == .persistent })
    }

    func testBasic_allRulesNonExpiring() {
        XCTAssertTrue(rules.allSatisfy { $0.expiresAt == nil })
    }

    func testBasic_autoApprovesTextNotes() {
        let result = PermissionRule.evaluate(
            rules: rules, clientID: clientID, identityID: nil,
            operationKind: "sign", eventKind: 1
        )
        XCTAssertEqual(result, .allow)
    }

    func testBasic_autoApprovesMetadata() {
        let result = PermissionRule.evaluate(
            rules: rules, clientID: clientID, identityID: nil,
            operationKind: "sign", eventKind: 0
        )
        XCTAssertEqual(result, .allow)
    }

    func testBasic_autoApprovesContacts() {
        let result = PermissionRule.evaluate(
            rules: rules, clientID: clientID, identityID: nil,
            operationKind: "sign", eventKind: 3
        )
        XCTAssertEqual(result, .allow)
    }

    func testBasic_autoApprovesRepost() {
        let result = PermissionRule.evaluate(
            rules: rules, clientID: clientID, identityID: nil,
            operationKind: "sign", eventKind: 6
        )
        XCTAssertEqual(result, .allow)
    }

    func testBasic_autoApprovesReaction() {
        let result = PermissionRule.evaluate(
            rules: rules, clientID: clientID, identityID: nil,
            operationKind: "sign", eventKind: 7
        )
        XCTAssertEqual(result, .allow)
    }

    func testBasic_promptsForDM() {
        let result = PermissionRule.evaluate(
            rules: rules, clientID: clientID, identityID: nil,
            operationKind: "sign", eventKind: 4
        )
        XCTAssertEqual(result, .prompt)
    }

    func testBasic_unknownKind_noRule() {
        // Unknown kinds have no specific rule — falls through (nil)
        let result = PermissionRule.evaluate(
            rules: rules, clientID: clientID, identityID: nil,
            operationKind: "sign", eventKind: 30023
        )
        XCTAssertNil(result, "Unknown kinds should have no matching rule")
    }

    func testBasic_autoApprovesNip44Encrypt() {
        let result = PermissionRule.evaluate(
            rules: rules, clientID: clientID, identityID: nil,
            operationKind: "nip44Encrypt", eventKind: nil
        )
        XCTAssertEqual(result, .allow)
    }

    func testBasic_autoApprovesNip44Decrypt() {
        let result = PermissionRule.evaluate(
            rules: rules, clientID: clientID, identityID: nil,
            operationKind: "nip44Decrypt", eventKind: nil
        )
        XCTAssertEqual(result, .allow)
    }

    func testBasic_promptsForNip04Encrypt() {
        let result = PermissionRule.evaluate(
            rules: rules, clientID: clientID, identityID: nil,
            operationKind: "nip04Encrypt", eventKind: nil
        )
        XCTAssertEqual(result, .prompt)
    }

    func testBasic_promptsForNip04Decrypt() {
        let result = PermissionRule.evaluate(
            rules: rules, clientID: clientID, identityID: nil,
            operationKind: "nip04Decrypt", eventKind: nil
        )
        XCTAssertEqual(result, .prompt)
    }

    func testBasic_withIdentityID() {
        let identity = UUID()
        let scopedRules = PolicyPreset.basic.rules(forClient: clientID, identityID: identity)
        XCTAssertTrue(scopedRules.allSatisfy { $0.identityID == identity })

        // Still works for that identity
        let result = PermissionRule.evaluate(
            rules: scopedRules, clientID: clientID, identityID: identity,
            operationKind: "sign", eventKind: 1
        )
        XCTAssertEqual(result, .allow)

        // Doesn't match a different identity
        let otherResult = PermissionRule.evaluate(
            rules: scopedRules, clientID: clientID, identityID: UUID(),
            operationKind: "sign", eventKind: 1
        )
        XCTAssertNil(otherResult)
    }
}

// MARK: - Standard Preset Tests

final class StandardPresetTests: XCTestCase {

    private let clientID = "com.standard.app"
    private lazy var rules = PolicyPreset.standard.rules(forClient: clientID)

    func testStandard_generatesRules() {
        XCTAssertGreaterThan(rules.count, 0)
    }

    func testStandard_promptsForAllSigning() {
        // Wildcard sign rule means all event kinds get .prompt
        for kind in [0, 1, 3, 4, 6, 7, 42, 1000, 30023] {
            let result = PermissionRule.evaluate(
                rules: rules, clientID: clientID, identityID: nil,
                operationKind: "sign", eventKind: kind
            )
            XCTAssertEqual(result, .prompt, "Standard should prompt for sign kind \(kind)")
        }
    }

    func testStandard_autoApprovesNip44() {
        XCTAssertEqual(
            PermissionRule.evaluate(
                rules: rules, clientID: clientID, identityID: nil,
                operationKind: "nip44Encrypt", eventKind: nil
            ),
            .allow
        )
        XCTAssertEqual(
            PermissionRule.evaluate(
                rules: rules, clientID: clientID, identityID: nil,
                operationKind: "nip44Decrypt", eventKind: nil
            ),
            .allow
        )
    }

    func testStandard_promptsForNip04() {
        XCTAssertEqual(
            PermissionRule.evaluate(
                rules: rules, clientID: clientID, identityID: nil,
                operationKind: "nip04Encrypt", eventKind: nil
            ),
            .prompt
        )
        XCTAssertEqual(
            PermissionRule.evaluate(
                rules: rules, clientID: clientID, identityID: nil,
                operationKind: "nip04Decrypt", eventKind: nil
            ),
            .prompt
        )
    }
}

// MARK: - Paranoid Preset Tests

final class ParanoidPresetTests: XCTestCase {

    private let clientID = "com.paranoid.app"
    private lazy var rules = PolicyPreset.paranoid.rules(forClient: clientID)

    func testParanoid_generatesRules() {
        XCTAssertEqual(rules.count, 5, "One rule per operation kind")
    }

    func testParanoid_promptsForAllOperations() {
        let ops = ["sign", "nip44Encrypt", "nip44Decrypt", "nip04Encrypt", "nip04Decrypt"]
        for op in ops {
            let result = PermissionRule.evaluate(
                rules: rules, clientID: clientID, identityID: nil,
                operationKind: op, eventKind: nil
            )
            XCTAssertEqual(result, .prompt, "Paranoid should prompt for \(op)")
        }
    }

    func testParanoid_promptsForSpecificEventKinds() {
        // Even specific event kinds should get .prompt
        for kind in [0, 1, 3, 4, 7, 42] {
            let result = PermissionRule.evaluate(
                rules: rules, clientID: clientID, identityID: nil,
                operationKind: "sign", eventKind: kind
            )
            XCTAssertEqual(result, .prompt, "Paranoid should prompt for sign kind \(kind)")
        }
    }
}

// MARK: - PolicyPreset Apply Tests

final class PolicyPresetApplyTests: XCTestCase {

    private var tempDir: URL!
    private var store: FilePermissionRuleStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyfobPresetTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try! FilePermissionRuleStore(containerURL: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testApply_addsRulesToStore() throws {
        try PolicyPreset.basic.apply(to: store, forClient: "com.test")

        let rules = try store.rules(forClient: "com.test")
        XCTAssertGreaterThan(rules.count, 0)
    }

    func testApply_replacesExistingRules() throws {
        // Apply basic first
        try PolicyPreset.basic.apply(to: store, forClient: "com.test")
        let basicCount = try store.rules(forClient: "com.test").count

        // Apply paranoid — should replace
        try PolicyPreset.paranoid.apply(to: store, forClient: "com.test")
        let paranoidRules = try store.rules(forClient: "com.test")

        XCTAssertEqual(paranoidRules.count, 5)
        XCTAssertNotEqual(basicCount, paranoidRules.count)
        XCTAssertTrue(paranoidRules.allSatisfy { $0.decision == .prompt })
    }

    func testApply_doesNotAffectOtherClients() throws {
        // Add a rule for another client
        try store.addRule(PermissionRule(
            clientID: "com.other",
            operationKind: "sign",
            decision: .deny,
            scope: .persistent
        ))

        // Apply preset to different client
        try PolicyPreset.standard.apply(to: store, forClient: "com.test")

        // Other client's rules should be untouched
        let otherRules = try store.rules(forClient: "com.other")
        XCTAssertEqual(otherRules.count, 1)
        XCTAssertEqual(otherRules.first?.decision, .deny)
    }

    func testApply_withIdentityScope() throws {
        let identity = UUID()
        try PolicyPreset.basic.apply(to: store, forClient: "com.test", identityID: identity)

        let rules = try store.rules(forClient: "com.test")
        XCTAssertTrue(rules.allSatisfy { $0.identityID == identity })
    }

    func testApply_thenEvaluate_basic() throws {
        try PolicyPreset.basic.apply(to: store, forClient: "com.test")

        // Text note should auto-approve
        XCTAssertEqual(
            try store.evaluate(clientID: "com.test", identityID: nil, operationKind: "sign", eventKind: 1),
            .allow
        )

        // DM should prompt
        XCTAssertEqual(
            try store.evaluate(clientID: "com.test", identityID: nil, operationKind: "sign", eventKind: 4),
            .prompt
        )

        // NIP-44 encrypt should auto-approve
        XCTAssertEqual(
            try store.evaluate(clientID: "com.test", identityID: nil, operationKind: "nip44Encrypt", eventKind: nil),
            .allow
        )
    }

    func testApply_thenEvaluate_standard() throws {
        try PolicyPreset.standard.apply(to: store, forClient: "com.test")

        // All signing should prompt
        XCTAssertEqual(
            try store.evaluate(clientID: "com.test", identityID: nil, operationKind: "sign", eventKind: 1),
            .prompt
        )

        // NIP-44 should auto-approve
        XCTAssertEqual(
            try store.evaluate(clientID: "com.test", identityID: nil, operationKind: "nip44Decrypt", eventKind: nil),
            .allow
        )
    }

    func testApply_thenEvaluate_paranoid() throws {
        try PolicyPreset.paranoid.apply(to: store, forClient: "com.test")

        // Everything should prompt
        let ops = ["sign", "nip44Encrypt", "nip44Decrypt", "nip04Encrypt", "nip04Decrypt"]
        for op in ops {
            XCTAssertEqual(
                try store.evaluate(clientID: "com.test", identityID: nil, operationKind: op, eventKind: nil),
                .prompt,
                "Paranoid: \(op) should prompt"
            )
        }
    }

    func testSwitchingPresets_cleanlyReplaces() throws {
        // Start with basic (auto-approve text notes)
        try PolicyPreset.basic.apply(to: store, forClient: "com.test")
        XCTAssertEqual(
            try store.evaluate(clientID: "com.test", identityID: nil, operationKind: "sign", eventKind: 1),
            .allow
        )

        // Switch to paranoid (prompt everything)
        try PolicyPreset.paranoid.apply(to: store, forClient: "com.test")
        XCTAssertEqual(
            try store.evaluate(clientID: "com.test", identityID: nil, operationKind: "sign", eventKind: 1),
            .prompt
        )

        // Switch back to basic
        try PolicyPreset.basic.apply(to: store, forClient: "com.test")
        XCTAssertEqual(
            try store.evaluate(clientID: "com.test", identityID: nil, operationKind: "sign", eventKind: 1),
            .allow
        )
    }
}
