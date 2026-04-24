//
//  IdentityGateTests.swift
//
//
//  Created for Keyfob – kf-28e
//

import XCTest
@testable import KeyfobCore
@testable import KeyfobCrypto
import NostrSDK

// MARK: - Mock Identity Store for Gate Tests

/// Minimal mock that returns a configurable active identity.
private final class GateMockStore: IdentityStore, @unchecked Sendable {
    var activeIdentityResult: Identity?
    var identitiesList: [Identity] = []
    var shouldThrow = false

    func createIdentity(label: String?, makeActive: Bool) throws -> Identity {
        fatalError("Not needed for gate tests")
    }

    func importIdentity(privateKeyHex: String, source: IdentitySource, label: String?, makeActive: Bool) throws -> Identity {
        fatalError("Not needed for gate tests")
    }

    func listIdentities() throws -> [Identity] {
        if shouldThrow { throw IdentityStoreError.appGroupUnavailable }
        return identitiesList
    }

    func activeIdentity() throws -> Identity? {
        if shouldThrow { throw IdentityStoreError.appGroupUnavailable }
        return activeIdentityResult
    }

    func setActiveIdentity(_ id: UUID?) throws {}
    func deleteIdentity(_ id: UUID) throws {}

    func loadSDKKeypair(for identityID: UUID) throws -> NostrSDK.Keypair {
        fatalError("Not needed for gate tests")
    }

    func observeActiveIdentity() -> AsyncStream<Identity?> {
        AsyncStream { $0.finish() }
    }
}

// MARK: - IdentityGateError Tests

final class IdentityGateErrorTests: XCTestCase {

    func testErrorEquatable() {
        XCTAssertEqual(IdentityGateError.noActiveIdentity, IdentityGateError.noActiveIdentity)
    }

    func testErrorDescription() {
        let error = IdentityGateError.noActiveIdentity
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("No active identity"))
    }

    func testLocalizedError() {
        let error: Error = IdentityGateError.noActiveIdentity
        XCTAssertTrue(error.localizedDescription.contains("No active identity"))
    }
}

// MARK: - IdentityGate (Store-based) Tests

final class IdentityGateStoreTests: XCTestCase {

    private var store: GateMockStore!

    override func setUp() {
        super.setUp()
        store = GateMockStore()
    }

    override func tearDown() {
        IdentityGate.resetSharedStore()
        store = nil
        super.tearDown()
    }

    func testRequireActiveIdentity_withActiveIdentity_succeeds() throws {
        store.activeIdentityResult = Identity(
            pubkeyHex: String(repeating: "a", count: 64),
            source: .generated,
            isActive: true
        )

        XCTAssertNoThrow(try IdentityGate.requireActiveIdentity(store: store))
    }

    func testRequireActiveIdentity_noActiveIdentity_throws() {
        store.activeIdentityResult = nil

        XCTAssertThrowsError(try IdentityGate.requireActiveIdentity(store: store)) { error in
            XCTAssertEqual(error as? IdentityGateError, .noActiveIdentity)
        }
    }

    func testRequireActiveIdentity_storeThrows_propagates() {
        store.shouldThrow = true

        XCTAssertThrowsError(try IdentityGate.requireActiveIdentity(store: store))
    }

    func testHasActiveIdentity_true() {
        store.activeIdentityResult = Identity(
            pubkeyHex: String(repeating: "b", count: 64),
            source: .imported,
            isActive: true
        )

        XCTAssertTrue(IdentityGate.hasActiveIdentity(store: store))
    }

    func testHasActiveIdentity_false() {
        store.activeIdentityResult = nil
        XCTAssertFalse(IdentityGate.hasActiveIdentity(store: store))
    }

    func testHasActiveIdentity_storeError_returnsFalse() {
        store.shouldThrow = true
        XCTAssertFalse(IdentityGate.hasActiveIdentity(store: store))
    }
}

// MARK: - Shared Store Tests

final class IdentityGateSharedStoreTests: XCTestCase {

    private var store: GateMockStore!

    override func setUp() {
        super.setUp()
        store = GateMockStore()
        IdentityGate.resetSharedStore()
    }

    override func tearDown() {
        IdentityGate.resetSharedStore()
        store = nil
        super.tearDown()
    }

    func testConfigureSharedStore() {
        XCTAssertNil(IdentityGate.sharedStore)
        IdentityGate.configureSharedStore(store)
        XCTAssertNotNil(IdentityGate.sharedStore)
    }

    func testRequireActiveIdentity_usesSharedStore() {
        store.activeIdentityResult = Identity(
            pubkeyHex: String(repeating: "c", count: 64),
            source: .generated,
            isActive: true
        )
        IdentityGate.configureSharedStore(store)

        XCTAssertNoThrow(try IdentityGate.requireActiveIdentity())
    }

    func testRequireActiveIdentity_sharedStore_noIdentity_throws() {
        store.activeIdentityResult = nil
        IdentityGate.configureSharedStore(store)

        XCTAssertThrowsError(try IdentityGate.requireActiveIdentity()) { error in
            XCTAssertEqual(error as? IdentityGateError, .noActiveIdentity)
        }
    }

    func testHasActiveIdentity_usesSharedStore() {
        store.activeIdentityResult = Identity(
            pubkeyHex: String(repeating: "d", count: 64),
            source: .generated,
            isActive: true
        )
        IdentityGate.configureSharedStore(store)

        XCTAssertTrue(IdentityGate.hasActiveIdentity())
    }

    func testHasActiveIdentity_noSharedStore_noIdentity() {
        // No shared store configured, legacy fallback will likely fail
        // in test environment (no keychain)
        XCTAssertFalse(IdentityGate.hasActiveIdentity())
    }

    func testResetSharedStore() {
        IdentityGate.configureSharedStore(store)
        XCTAssertNotNil(IdentityGate.sharedStore)
        IdentityGate.resetSharedStore()
        XCTAssertNil(IdentityGate.sharedStore)
    }
}

// MARK: - RequireLegacyKeypair Tests

final class IdentityGateLegacyTests: XCTestCase {

    override func setUp() {
        super.setUp()
        IdentityGate.resetSharedStore()
    }

    override func tearDown() {
        IdentityGate.resetSharedStore()
        super.tearDown()
    }

    func testRequireLegacyKeypair_noStore_noKeychain_throws() {
        // No shared store, no keychain key → should throw noActiveIdentity
        XCTAssertThrowsError(try IdentityGate.requireLegacyKeypair()) { error in
            XCTAssertEqual(error as? IdentityGateError, .noActiveIdentity)
        }
    }

    func testRequireLegacyKeypair_withSharedStore_hasIdentities_succeeds() {
        let mockStore = GateMockStore()
        mockStore.identitiesList = [
            Identity(
                pubkeyHex: String(repeating: "e", count: 64),
                source: .generated,
                isActive: true
            )
        ]
        IdentityGate.configureSharedStore(mockStore)

        XCTAssertNoThrow(try IdentityGate.requireLegacyKeypair())
    }

    func testRequireLegacyKeypair_withSharedStore_empty_throws() {
        let mockStore = GateMockStore()
        mockStore.identitiesList = []
        IdentityGate.configureSharedStore(mockStore)

        XCTAssertThrowsError(try IdentityGate.requireLegacyKeypair()) { error in
            XCTAssertEqual(error as? IdentityGateError, .noActiveIdentity)
        }
    }
}
