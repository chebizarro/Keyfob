//
//  KeyManagementServiceTests.swift
//
//
//  Created for Keyfob – kf-tiu
//

import XCTest
@testable import KeyfobCore
@testable import KeyfobCrypto
import NostrSDK

// MARK: - Mock Store for Key Management

private final class KMMockStore: IdentityStore, @unchecked Sendable {
    private var identities: [UUID: (identity: Identity, keypair: NostrSDK.Keypair)] = [:]
    private var activeID: UUID?

    func createIdentity(label: String?, makeActive: Bool) throws -> Identity {
        guard let keypair = NostrSDK.Keypair() else {
            throw IdentityStoreError.invalidPrivateKey
        }
        let id = UUID()
        let identity = Identity(
            id: id, pubkeyHex: keypair.publicKey.hex, label: label,
            createdAt: Date(), source: .generated, isActive: makeActive
        )
        identities[id] = (identity, keypair)
        if makeActive { activeID = id }
        return identity
    }

    func importIdentity(privateKeyHex: String, source: IdentitySource, label: String?, makeActive: Bool) throws -> Identity {
        guard let pk = NostrSDK.PrivateKey(hex: privateKeyHex),
              let keypair = NostrSDK.Keypair(privateKey: pk) else {
            throw IdentityStoreError.invalidPrivateKey
        }
        let id = UUID()
        let identity = Identity(
            id: id, pubkeyHex: keypair.publicKey.hex, label: label,
            createdAt: Date(), source: source, isActive: makeActive
        )
        identities[id] = (identity, keypair)
        if makeActive { activeID = id }
        return identity
    }

    func listIdentities() throws -> [Identity] {
        identities.values.map { materialize($0.identity) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func activeIdentity() throws -> Identity? {
        guard let activeID else { return nil }
        guard let entry = identities[activeID] else { return nil }
        return materialize(entry.identity)
    }

    func updateLabel(for id: UUID, label: String?) throws {
        guard var entry = identities[id] else {
            throw IdentityStoreError.identityNotFound(id)
        }
        var updated = entry.identity
        updated.label = label
        entry.identity = updated
        identities[id] = entry
    }

    func setActiveIdentity(_ id: UUID?) throws {
        if let id = id, identities[id] == nil {
            throw IdentityStoreError.identityNotFound(id)
        }
        activeID = id
    }

    func deleteIdentity(_ id: UUID) throws {
        guard identities[id] != nil else {
            throw IdentityStoreError.identityNotFound(id)
        }
        identities.removeValue(forKey: id)
        if activeID == id { activeID = nil }
    }

    func loadSDKKeypair(for identityID: UUID) throws -> NostrSDK.Keypair {
        guard let entry = identities[identityID] else {
            throw IdentityStoreError.identityNotFound(identityID)
        }
        return entry.keypair
    }

    func observeActiveIdentity() -> AsyncStream<Identity?> {
        AsyncStream { $0.finish() }
    }

    private func materialize(_ identity: Identity) -> Identity {
        var i = identity
        i.isActive = (identity.id == activeID)
        return i
    }
}

// MARK: - KeyManagementService Tests

final class KeyManagementServiceTests: XCTestCase {

    private var store: KMMockStore!
    private var service: KeyManagementService!

    override func setUp() {
        super.setUp()
        store = KMMockStore()
        service = KeyManagementService(identityStore: store)
    }

    override func tearDown() {
        store = nil
        service = nil
        super.tearDown()
    }

    // MARK: - List

    func testListIdentities_empty() throws {
        let list = try service.listIdentities()
        XCTAssertTrue(list.isEmpty)
    }

    func testListIdentities_returnsViewModels() throws {
        _ = try store.createIdentity(label: "Main", makeActive: true)
        _ = try store.createIdentity(label: "Burner", makeActive: false)

        let list = try service.listIdentities()
        XCTAssertEqual(list.count, 2)
        XCTAssertTrue(list[0].npubTruncated.contains("npub1"))
        XCTAssertFalse(list[0].npubFull.isEmpty)
    }

    func testListIdentities_activeFlag() throws {
        let i1 = try store.createIdentity(label: "First", makeActive: true)
        _ = try store.createIdentity(label: "Second", makeActive: false)

        let list = try service.listIdentities()
        let active = list.first(where: { $0.id == i1.id })
        XCTAssertTrue(active?.isActive ?? false)

        let inactive = list.first(where: { $0.id != i1.id })
        XCTAssertFalse(inactive?.isActive ?? true)
    }

    func testListIdentities_viewModelFields() throws {
        let identity = try store.createIdentity(label: "Test", makeActive: true)
        let list = try service.listIdentities()
        let vm = list.first!

        XCTAssertEqual(vm.id, identity.id)
        XCTAssertEqual(vm.pubkeyHex, identity.pubkeyHex)
        XCTAssertEqual(vm.label, "Test")
        XCTAssertEqual(vm.source, "generated")
        XCTAssertEqual(vm.displayName, "Test")
    }

    func testListIdentities_displayName_fallsBackToNpub() throws {
        _ = try store.createIdentity(label: nil, makeActive: true)
        let list = try service.listIdentities()
        XCTAssertTrue(list.first!.displayName.contains("npub1"))
    }

    // MARK: - Active Identity

    func testActiveIdentity_returnsNilWhenEmpty() throws {
        let active = try service.activeIdentity()
        XCTAssertNil(active)
    }

    func testActiveIdentity_returnsViewModel() throws {
        let identity = try store.createIdentity(label: "Active", makeActive: true)
        let active = try service.activeIdentity()
        XCTAssertEqual(active?.id, identity.id)
        XCTAssertTrue(active?.isActive ?? false)
    }

    // MARK: - Set Active

    func testSetActiveIdentity() throws {
        let i1 = try store.createIdentity(label: "First", makeActive: true)
        let i2 = try store.createIdentity(label: "Second", makeActive: false)

        try service.setActiveIdentity(id: i2.id)

        let active = try service.activeIdentity()
        XCTAssertEqual(active?.id, i2.id)

        // Verify i1 is no longer active
        let list = try service.listIdentities()
        let first = list.first(where: { $0.id == i1.id })
        XCTAssertFalse(first?.isActive ?? true)
    }

    func testSetActiveIdentity_notFound_throws() {
        XCTAssertThrowsError(try service.setActiveIdentity(id: UUID())) { error in
            guard case KeyManagementError.operationFailed = error else {
                XCTFail("Expected operationFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - Rename

    func testRenameIdentity() throws {
        let identity = try store.createIdentity(label: "Old", makeActive: true)
        try service.renameIdentity(id: identity.id, newLabel: "New Name")

        let list = try service.listIdentities()
        XCTAssertEqual(list.first?.label, "New Name")
    }

    func testRenameIdentity_emptyLabel_clearsLabel() throws {
        let identity = try store.createIdentity(label: "HasLabel", makeActive: true)
        try service.renameIdentity(id: identity.id, newLabel: "")

        let list = try service.listIdentities()
        XCTAssertNil(list.first?.label)
    }

    func testRenameIdentity_whitespaceOnly_clearsLabel() throws {
        let identity = try store.createIdentity(label: "HasLabel", makeActive: true)
        try service.renameIdentity(id: identity.id, newLabel: "   ")

        let list = try service.listIdentities()
        XCTAssertNil(list.first?.label)
    }

    func testRenameIdentity_notFound_throws() {
        XCTAssertThrowsError(try service.renameIdentity(id: UUID(), newLabel: "Test")) { error in
            guard case KeyManagementError.operationFailed = error else {
                XCTFail("Expected operationFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - Delete

    func testDeleteIdentity() throws {
        _ = try store.createIdentity(label: "Keep", makeActive: true)
        let toDelete = try store.createIdentity(label: "Delete", makeActive: false)

        try service.deleteIdentity(id: toDelete.id)

        let list = try service.listIdentities()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.label, "Keep")
    }

    func testDeleteIdentity_lastIdentity_throws() throws {
        let only = try store.createIdentity(label: "Only", makeActive: true)

        XCTAssertThrowsError(try service.deleteIdentity(id: only.id)) { error in
            XCTAssertEqual(error as? KeyManagementError, .cannotDeleteLastIdentity)
        }
    }

    func testDeleteIdentity_notFound_throws() throws {
        _ = try store.createIdentity(label: "A", makeActive: true)
        _ = try store.createIdentity(label: "B", makeActive: false)

        XCTAssertThrowsError(try service.deleteIdentity(id: UUID())) { error in
            guard case KeyManagementError.operationFailed = error else {
                XCTFail("Expected operationFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - Copy Strings

    func testNpubForCopy() throws {
        let identity = try store.createIdentity(label: nil, makeActive: true)
        let npub = service.npubForCopy(pubkeyHex: identity.pubkeyHex)
        XCTAssertTrue(npub.hasPrefix("npub1"))
    }

    func testHexForCopy() throws {
        let identity = try store.createIdentity(label: nil, makeActive: true)
        let hex = service.hexForCopy(pubkeyHex: identity.pubkeyHex)
        XCTAssertEqual(hex, identity.pubkeyHex)
        XCTAssertEqual(hex.count, 64)
    }
}

// MARK: - IdentityViewModel Tests

final class IdentityViewModelTests: XCTestCase {

    func testDisplayName_withLabel() {
        let vm = IdentityViewModel(
            id: UUID(), pubkeyHex: String(repeating: "a", count: 64),
            label: "Work", npubTruncated: "npub1abc…xyz",
            npubFull: "npub1abcxyz", source: "generated",
            isActive: false, createdAt: Date()
        )
        XCTAssertEqual(vm.displayName, "Work")
    }

    func testDisplayName_withoutLabel() {
        let vm = IdentityViewModel(
            id: UUID(), pubkeyHex: String(repeating: "a", count: 64),
            label: nil, npubTruncated: "npub1abc…xyz",
            npubFull: "npub1abcxyz", source: "generated",
            isActive: false, createdAt: Date()
        )
        XCTAssertEqual(vm.displayName, "npub1abc…xyz")
    }

    func testDisplayName_emptyLabel() {
        let vm = IdentityViewModel(
            id: UUID(), pubkeyHex: String(repeating: "a", count: 64),
            label: "", npubTruncated: "npub1abc…xyz",
            npubFull: "npub1abcxyz", source: "generated",
            isActive: false, createdAt: Date()
        )
        XCTAssertEqual(vm.displayName, "npub1abc…xyz")
    }

    func testEquatable() {
        let id = UUID()
        let date = Date()
        let vm1 = IdentityViewModel(
            id: id, pubkeyHex: "abc", label: "L",
            npubTruncated: "t", npubFull: "f", source: "s",
            isActive: true, createdAt: date
        )
        let vm2 = IdentityViewModel(
            id: id, pubkeyHex: "abc", label: "L",
            npubTruncated: "t", npubFull: "f", source: "s",
            isActive: true, createdAt: date
        )
        XCTAssertEqual(vm1, vm2)
    }
}

// MARK: - KeyManagementError Tests

final class KeyManagementErrorTests: XCTestCase {

    func testCannotDeleteLastIdentity_description() {
        let error = KeyManagementError.cannotDeleteLastIdentity
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("Cannot delete"))
    }

    func testIdentityNotFound_description() {
        let id = UUID()
        let error = KeyManagementError.identityNotFound(id)
        XCTAssertTrue(error.errorDescription!.contains(id.uuidString))
    }

    func testOperationFailed_description() {
        let error = KeyManagementError.operationFailed("test error")
        XCTAssertEqual(error.errorDescription, "test error")
    }

    func testEquatable() {
        XCTAssertEqual(KeyManagementError.cannotDeleteLastIdentity, .cannotDeleteLastIdentity)
        XCTAssertNotEqual(KeyManagementError.cannotDeleteLastIdentity, .operationFailed("x"))
    }
}
