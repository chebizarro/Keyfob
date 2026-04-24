//
//  OnboardingServiceTests.swift
//
//
//  Created for Keyfob – kf-9h2
//

import XCTest
@testable import KeyfobCore
@testable import KeyfobCrypto
import NostrSDK

// MARK: - Mock Identity Store

/// In-memory IdentityStore for testing without Keychain access.
final class MockIdentityStore: IdentityStore, @unchecked Sendable {

    private var identities: [UUID: (identity: Identity, keypair: NostrSDK.Keypair)] = [:]
    private var activeID: UUID?

    var createCallCount = 0
    var importCallCount = 0
    var shouldFailCreate = false
    var shouldFailImport = false

    func createIdentity(label: String?, makeActive: Bool) throws -> Identity {
        createCallCount += 1
        if shouldFailCreate {
            throw IdentityStoreError.invalidPrivateKey
        }

        guard let keypair = NostrSDK.Keypair() else {
            throw IdentityStoreError.invalidPrivateKey
        }

        let id = UUID()
        let identity = Identity(
            id: id,
            pubkeyHex: keypair.publicKey.hex,
            label: label,
            createdAt: Date(),
            source: .generated,
            isActive: makeActive
        )
        identities[id] = (identity, keypair)
        if makeActive { activeID = id }
        return identity
    }

    func importIdentity(privateKeyHex: String, source: IdentitySource, label: String?, makeActive: Bool) throws -> Identity {
        importCallCount += 1
        if shouldFailImport {
            throw IdentityStoreError.invalidPrivateKey
        }

        guard let pk = NostrSDK.PrivateKey(hex: privateKeyHex),
              let keypair = NostrSDK.Keypair(privateKey: pk) else {
            throw IdentityStoreError.invalidPrivateKey
        }

        // Check duplicate
        if identities.values.contains(where: { $0.identity.pubkeyHex == keypair.publicKey.hex }) {
            throw IdentityStoreError.duplicatePublicKey(keypair.publicKey.hex)
        }

        let id = UUID()
        let identity = Identity(
            id: id,
            pubkeyHex: keypair.publicKey.hex,
            label: label,
            createdAt: Date(),
            source: source,
            isActive: makeActive
        )
        identities[id] = (identity, keypair)
        if makeActive { activeID = id }
        return identity
    }

    func listIdentities() throws -> [Identity] {
        identities.values.map { $0.identity }.sorted { $0.createdAt < $1.createdAt }
    }

    func activeIdentity() throws -> Identity? {
        guard let activeID else { return nil }
        return identities[activeID]?.identity
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
        activeID = id
    }

    func deleteIdentity(_ id: UUID) throws {
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
        AsyncStream { continuation in
            continuation.yield(try? activeIdentity())
            continuation.finish()
        }
    }
}

// MARK: - OnboardingService Tests

final class OnboardingServiceTests: XCTestCase {

    private var store: MockIdentityStore!
    private var service: OnboardingService!

    // A known valid test private key
    private let testKeyHex = "7f4c11a9742721d66e40e321f3f3a39b22e81f51b24098de68e7e1e781884b0d"

    override func setUp() {
        super.setUp()
        store = MockIdentityStore()
        service = OnboardingService(identityStore: store)
    }

    override func tearDown() {
        store = nil
        service = nil
        super.tearDown()
    }

    // MARK: - Create New Identity

    func testCreateNewIdentity_success() throws {
        let result = try service.createNewIdentity()

        XCTAssertFalse(result.pubkeyHex.isEmpty)
        XCTAssertFalse(result.npubDisplay.isEmpty)
        XCTAssertTrue(result.npubDisplay.hasPrefix("npub1"))
        XCTAssertFalse(result.npubTruncated.isEmpty)
        XCTAssertNotNil(result.nsecForBackup, "Create flow should include nsec for backup")
        XCTAssertTrue(result.nsecForBackup?.hasPrefix("nsec1") ?? false)
        XCTAssertEqual(result.source, "generated")
        XCTAssertEqual(store.createCallCount, 1)
    }

    func testCreateNewIdentity_withLabel() throws {
        let result = try service.createNewIdentity(label: "Main")

        XCTAssertEqual(result.label, "Main")
    }

    func testCreateNewIdentity_storeFailure() {
        store.shouldFailCreate = true

        XCTAssertThrowsError(try service.createNewIdentity()) { error in
            guard case OnboardingError.keyCreationFailed = error else {
                XCTFail("Expected keyCreationFailed, got \(error)")
                return
            }
        }
    }

    func testCreateNewIdentity_setsActive() throws {
        _ = try service.createNewIdentity()

        let active = try store.activeIdentity()
        XCTAssertNotNil(active)
    }

    // MARK: - Import Key (nsec)

    func testImportKey_nsec() throws {
        // Generate a valid nsec for testing
        guard let testKeypair = NostrSDK.Keypair() else {
            XCTFail("Failed to generate test keypair")
            return
        }
        let nsec = testKeypair.privateKey.nsec

        let result = try service.importKey(nsec)

        XCTAssertEqual(result.pubkeyHex, testKeypair.publicKey.hex)
        XCTAssertNil(result.nsecForBackup, "Import flow should not return nsec for backup")
        XCTAssertEqual(result.source, "imported")
        XCTAssertEqual(store.importCallCount, 1)
    }

    // MARK: - Import Key (hex)

    func testImportKey_hex() throws {
        let result = try service.importKey(testKeyHex)

        XCTAssertFalse(result.pubkeyHex.isEmpty)
        XCTAssertNil(result.nsecForBackup)
        XCTAssertEqual(result.source, "imported")
    }

    func testImportKey_hex_withLabel() throws {
        let result = try service.importKey(testKeyHex, label: "Imported")

        XCTAssertEqual(result.label, "Imported")
    }

    // MARK: - Import Key (error cases)

    func testImportKey_npub_throws() {
        guard let keypair = NostrSDK.Keypair() else {
            XCTFail("Failed to generate test keypair")
            return
        }
        let npub = keypair.publicKey.npub

        XCTAssertThrowsError(try service.importKey(npub)) { error in
            XCTAssertEqual(error as? OnboardingError, .publicKeyNotImportable)
        }
    }

    func testImportKey_ncryptsec_requiresPassword() throws {
        // Create a valid ncryptsec
        let ncryptsec = try NCryptsec.encode(privateKeyHex: testKeyHex, password: "test", logN: 4)

        XCTAssertThrowsError(try service.importKey(ncryptsec)) { error in
            guard case OnboardingError.importFailed = error else {
                XCTFail("Expected importFailed, got \(error)")
                return
            }
        }
    }

    func testImportKey_emptyInput_throws() {
        XCTAssertThrowsError(try service.importKey("")) { error in
            XCTAssertEqual(error as? OnboardingError, .unrecognizedFormat)
        }
    }

    func testImportKey_garbage_throws() {
        XCTAssertThrowsError(try service.importKey("not-a-key")) { error in
            XCTAssertEqual(error as? OnboardingError, .unrecognizedFormat)
        }
    }

    func testImportKey_invalidNsec_throws() {
        XCTAssertThrowsError(try service.importKey("nsec1invalidkey")) { error in
            guard case OnboardingError.importFailed = error else {
                XCTFail("Expected importFailed, got \(error)")
                return
            }
        }
    }

    func testImportKey_storeFailure_throws() {
        store.shouldFailImport = true

        XCTAssertThrowsError(try service.importKey(testKeyHex)) { error in
            guard case OnboardingError.importFailed = error else {
                XCTFail("Expected importFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - Import NCryptsec

    func testImportNCryptsec_success() throws {
        let password = "test-password"
        let ncryptsec = try NCryptsec.encode(privateKeyHex: testKeyHex, password: password, logN: 4)

        let result = try service.importNCryptsec(ncryptsec, password: password)

        // Verify the imported key matches
        guard let expectedPK = NostrSDK.PrivateKey(hex: testKeyHex),
              let expectedKP = NostrSDK.Keypair(privateKey: expectedPK) else {
            XCTFail("Failed to create expected keypair")
            return
        }
        XCTAssertEqual(result.pubkeyHex, expectedKP.publicKey.hex)
        XCTAssertEqual(result.source, "nip49")
        XCTAssertNil(result.nsecForBackup)
    }

    func testImportNCryptsec_withLabel() throws {
        let password = "test"
        let ncryptsec = try NCryptsec.encode(privateKeyHex: testKeyHex, password: password, logN: 4)

        let result = try service.importNCryptsec(ncryptsec, password: password, label: "NIP-49")

        XCTAssertEqual(result.label, "NIP-49")
    }

    func testImportNCryptsec_wrongPassword_throws() throws {
        let ncryptsec = try NCryptsec.encode(privateKeyHex: testKeyHex, password: "correct", logN: 4)

        XCTAssertThrowsError(try service.importNCryptsec(ncryptsec, password: "wrong")) { error in
            guard case OnboardingError.ncryptsecDecryptionFailed = error else {
                XCTFail("Expected ncryptsecDecryptionFailed, got \(error)")
                return
            }
        }
    }

    func testImportNCryptsec_invalidString_throws() {
        XCTAssertThrowsError(try service.importNCryptsec("not-ncryptsec", password: "test")) { error in
            guard case OnboardingError.ncryptsecDecryptionFailed = error else {
                XCTFail("Expected ncryptsecDecryptionFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - Format Detection

    func testDetectFormat_nsec() {
        XCTAssertEqual(service.detectInputFormat("nsec1abc123"), .nsec)
    }

    func testDetectFormat_npub() {
        XCTAssertEqual(service.detectInputFormat("npub1abc123"), .npub)
    }

    func testDetectFormat_ncryptsec() {
        XCTAssertEqual(service.detectInputFormat("ncryptsec1abc123"), .ncryptsec)
    }

    func testDetectFormat_hex() {
        let hex = String(repeating: "a", count: 64)
        XCTAssertEqual(service.detectInputFormat(hex), .hex)
    }

    func testDetectFormat_unknown() {
        XCTAssertEqual(service.detectInputFormat("random text"), .unknown)
    }

    func testDetectFormat_empty() {
        XCTAssertEqual(service.detectInputFormat(""), .unknown)
    }

    func testDetectFormat_whitespace() {
        XCTAssertEqual(service.detectInputFormat("  nsec1abc123  "), .nsec)
    }

    func testDetectFormat_uppercase() {
        XCTAssertEqual(service.detectInputFormat("NSEC1ABC123"), .nsec)
    }

    func testDetectFormat_static() {
        XCTAssertEqual(OnboardingService.detectFormat("npub1xyz"), .npub)
    }

    // MARK: - Has Existing Identity

    func testHasExistingIdentity_empty() throws {
        XCTAssertFalse(try service.hasExistingIdentity())
    }

    func testHasExistingIdentity_afterCreate() throws {
        _ = try service.createNewIdentity()
        XCTAssertTrue(try service.hasExistingIdentity())
    }

    // MARK: - Multiple Operations

    func testCreateThenImport_bothStored() throws {
        let r1 = try service.createNewIdentity(label: "First")
        let r2 = try service.importKey(testKeyHex, label: "Second")

        let identities = try store.listIdentities()
        XCTAssertEqual(identities.count, 2)

        // Second import should be active
        let active = try store.activeIdentity()
        XCTAssertEqual(active?.id, r2.identityID)

        XCTAssertNotEqual(r1.identityID, r2.identityID)
    }

    func testImportDuplicate_throws() throws {
        _ = try service.importKey(testKeyHex)

        XCTAssertThrowsError(try service.importKey(testKeyHex)) { error in
            guard case OnboardingError.importFailed = error else {
                XCTFail("Expected importFailed for duplicate, got \(error)")
                return
            }
        }
    }
}

// MARK: - OnboardingResult Tests

final class OnboardingResultTests: XCTestCase {

    func testEquatable() {
        let r1 = OnboardingResult(
            identityID: UUID(),
            pubkeyHex: "abc",
            npubDisplay: "npub1abc",
            npubTruncated: "npub1a…c",
            source: "generated"
        )
        let r2 = r1
        XCTAssertEqual(r1, r2)
    }

    func testEquatable_different() {
        let r1 = OnboardingResult(
            identityID: UUID(),
            pubkeyHex: "abc",
            npubDisplay: "npub1abc",
            npubTruncated: "npub1a…c",
            source: "generated"
        )
        let r2 = OnboardingResult(
            identityID: UUID(),
            pubkeyHex: "def",
            npubDisplay: "npub1def",
            npubTruncated: "npub1d…f",
            source: "imported"
        )
        XCTAssertNotEqual(r1, r2)
    }
}

// MARK: - InputFormat Tests

final class InputFormatTests: XCTestCase {

    func testAllCasesEquatable() {
        XCTAssertEqual(InputFormat.nsec, InputFormat.nsec)
        XCTAssertEqual(InputFormat.npub, InputFormat.npub)
        XCTAssertEqual(InputFormat.hex, InputFormat.hex)
        XCTAssertEqual(InputFormat.ncryptsec, InputFormat.ncryptsec)
        XCTAssertEqual(InputFormat.unknown, InputFormat.unknown)
        XCTAssertNotEqual(InputFormat.nsec, InputFormat.npub)
    }
}
