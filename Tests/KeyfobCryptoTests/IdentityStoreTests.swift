//
//  IdentityStoreTests.swift
//
//
//  Created for Keyfob – kf-3kr
//

import XCTest
@testable import KeyfobCrypto
import NostrSDK

// MARK: - Identity Model Tests

final class IdentityModelTests: XCTestCase {

    func testIdentityInit() {
        let id = UUID()
        let identity = Identity(
            id: id,
            pubkeyHex: "aaaa",
            label: "Test",
            createdAt: Date(timeIntervalSince1970: 1000),
            source: .generated,
            isActive: true
        )
        XCTAssertEqual(identity.id, id)
        XCTAssertEqual(identity.pubkeyHex, "aaaa")
        XCTAssertEqual(identity.label, "Test")
        XCTAssertEqual(identity.createdAt, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(identity.source, .generated)
        XCTAssertTrue(identity.isActive)
    }

    func testIdentityDefaults() {
        let identity = Identity(pubkeyHex: "bbbb", source: .imported)
        XCTAssertNil(identity.label)
        XCTAssertFalse(identity.isActive)
        XCTAssertEqual(identity.source, .imported)
    }

    func testIdentityEquatable() {
        let id = UUID()
        let a = Identity(id: id, pubkeyHex: "aa", source: .generated, isActive: false)
        let b = Identity(id: id, pubkeyHex: "aa", source: .generated, isActive: true)
        // isActive is excluded from CodingKeys but included in Equatable synthesis
        // because it's a stored property. This is intentional — two identities with
        // different active states are not equal.
        XCTAssertNotEqual(a, b)
    }

    func testIdentityCodingExcludesIsActive() throws {
        let identity = Identity(
            pubkeyHex: "cccc",
            label: "Encoded",
            source: .generated,
            isActive: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(identity)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // isActive should NOT be in the encoded JSON.
        XCTAssertNil(json?["isActive"])

        // Decode it back — isActive should default to false.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Identity.self, from: data)
        XCTAssertFalse(decoded.isActive)
        XCTAssertEqual(decoded.pubkeyHex, "cccc")
        XCTAssertEqual(decoded.label, "Encoded")
        XCTAssertEqual(decoded.source, .generated)
    }

    func testIdentitySourceRawValues() {
        XCTAssertEqual(IdentitySource.generated.rawValue, "generated")
        XCTAssertEqual(IdentitySource.imported.rawValue, "imported")
        XCTAssertEqual(IdentitySource.mnemonic.rawValue, "mnemonic")
        XCTAssertEqual(IdentitySource.nip49.rawValue, "nip49")
    }
}

// MARK: - IdentityStoreError Tests

final class IdentityStoreErrorTests: XCTestCase {

    func testErrorEquatable() {
        let id = UUID()
        XCTAssertEqual(
            IdentityStoreError.identityNotFound(id),
            IdentityStoreError.identityNotFound(id)
        )
        XCTAssertEqual(
            IdentityStoreError.duplicatePublicKey("abc"),
            IdentityStoreError.duplicatePublicKey("abc")
        )
        XCTAssertNotEqual(
            IdentityStoreError.duplicatePublicKey("abc"),
            IdentityStoreError.duplicatePublicKey("def")
        )
        XCTAssertEqual(
            IdentityStoreError.keychainError(-25300),
            IdentityStoreError.keychainError(-25300)
        )
        XCTAssertEqual(
            IdentityStoreError.appGroupUnavailable,
            IdentityStoreError.appGroupUnavailable
        )
        XCTAssertEqual(
            IdentityStoreError.invalidPrivateKey,
            IdentityStoreError.invalidPrivateKey
        )
        XCTAssertEqual(
            IdentityStoreError.unsupportedSourceForCreate(.mnemonic),
            IdentityStoreError.unsupportedSourceForCreate(.mnemonic)
        )
    }
}

// MARK: - KeychainConfig Tests

final class KeychainConfigTests: XCTestCase {

    func testServiceName() {
        XCTAssertEqual(KeychainConfig.service, "keyfob")
    }

    func testKeychainAccountFormat() {
        let id = UUID()
        let account = KeychainConfig.keychainAccount(for: id)
        XCTAssertEqual(account, "identity.\(id.uuidString)")
        XCTAssertTrue(account.hasPrefix("identity."))
    }

    func testLegacyKeyAccount() {
        XCTAssertEqual(KeychainConfig.legacyKeyAccount, "default.nsec")
    }

    func testDarwinNotificationName() {
        XCTAssertEqual(
            KeychainConfig.activeIdentityChangedNotification,
            "com.keyfob.identity.didChange"
        )
    }

    func testKeychainAccountUniqueness() {
        let id1 = UUID()
        let id2 = UUID()
        XCTAssertNotEqual(
            KeychainConfig.keychainAccount(for: id1),
            KeychainConfig.keychainAccount(for: id2)
        )
    }

    func testKeychainAccountDoesNotCollideWithLegacy() {
        let id = UUID()
        let account = KeychainConfig.keychainAccount(for: id)
        XCTAssertNotEqual(account, KeychainConfig.legacyKeyAccount)
        XCTAssertFalse(account.contains("default"))
    }
}

// MARK: - Metadata File Tests

final class MetadataFileTests: XCTestCase {

    func testMetadataFileRoundTrip() throws {
        let id1 = UUID()
        let id2 = UUID()
        let now = Date()

        let file = IdentityMetadataFile(
            schemaVersion: 1,
            activeIdentityID: id1,
            identities: [
                StoredIdentityRecord(id: id1, pubkeyHex: "aabb", label: "Main", createdAt: now, source: .generated),
                StoredIdentityRecord(id: id2, pubkeyHex: "ccdd", label: nil, createdAt: now, source: .imported)
            ]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(IdentityMetadataFile.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.activeIdentityID, id1)
        XCTAssertEqual(decoded.identities.count, 2)
        XCTAssertEqual(decoded.identities[0].pubkeyHex, "aabb")
        XCTAssertEqual(decoded.identities[0].label, "Main")
        XCTAssertEqual(decoded.identities[0].source, .generated)
        XCTAssertEqual(decoded.identities[1].pubkeyHex, "ccdd")
        XCTAssertNil(decoded.identities[1].label)
        XCTAssertEqual(decoded.identities[1].source, .imported)
    }

    func testEmptyMetadataFile() throws {
        let file = IdentityMetadataFile(identities: [])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(IdentityMetadataFile.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertNil(decoded.activeIdentityID)
        XCTAssertTrue(decoded.identities.isEmpty)
    }
}

// MARK: - KeychainIdentityStore Integration Tests
// These tests use a temp directory as the container to avoid needing real app group entitlements.
// They exercise metadata file operations but Keychain operations will fail in non-entitled test runners,
// so Keychain-dependent tests are gated.

final class KeychainIdentityStoreMetadataTests: XCTestCase {

    var tempDir: URL!
    var store: KeychainIdentityStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IdentityStoreTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try? KeychainIdentityStore(containerURL: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testStoreInitCreatesMetadataFile() {
        let metadataPath = tempDir
            .appendingPathComponent("IdentityStore")
            .appendingPathComponent("identities.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataPath.path))
    }

    func testStoreInitCreatesDirectoryStructure() {
        let storeDir = tempDir.appendingPathComponent("IdentityStore")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeDir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testEmptyStoreListReturnsEmpty() throws {
        let identities = try store.listIdentities()
        XCTAssertTrue(identities.isEmpty)
    }

    func testEmptyStoreActiveIdentityReturnsNil() throws {
        let active = try store.activeIdentity()
        XCTAssertNil(active)
    }

    func testSetActiveIdentityThrowsForUnknownID() {
        let unknownID = UUID()
        XCTAssertThrowsError(try store.setActiveIdentity(unknownID)) { error in
            guard case IdentityStoreError.identityNotFound(let id) = error else {
                XCTFail("Expected identityNotFound, got \(error)")
                return
            }
            XCTAssertEqual(id, unknownID)
        }
    }

    func testSetActiveIdentityNilSucceedsOnEmptyStore() throws {
        // Clearing active on an empty store should be fine.
        XCTAssertNoThrow(try store.setActiveIdentity(nil))
    }

    func testDeleteIdentityThrowsForUnknownID() {
        let unknownID = UUID()
        XCTAssertThrowsError(try store.deleteIdentity(unknownID)) { error in
            guard case IdentityStoreError.identityNotFound(let id) = error else {
                XCTFail("Expected identityNotFound, got \(error)")
                return
            }
            XCTAssertEqual(id, unknownID)
        }
    }

    func testImportIdentityWithInvalidHexThrows() {
        XCTAssertThrowsError(try store.importIdentity(
            privateKeyHex: "not-valid-hex",
            source: .imported,
            label: nil,
            makeActive: true
        )) { error in
            XCTAssertEqual(error as? IdentityStoreError, .invalidPrivateKey)
        }
    }

    func testImportIdentityWithUnsupportedSourceThrows() {
        XCTAssertThrowsError(try store.importIdentity(
            privateKeyHex: "aabb",
            source: .mnemonic,
            label: nil,
            makeActive: true
        )) { error in
            XCTAssertEqual(error as? IdentityStoreError, .unsupportedSourceForCreate(.mnemonic))
        }
    }

    func testImportIdentityWithNIP49Source_invalidKey_throws() {
        // NIP-49 source is now allowed (kf-9h2), but invalid hex still fails
        XCTAssertThrowsError(try store.importIdentity(
            privateKeyHex: "aabb",
            source: .nip49,
            label: nil,
            makeActive: true
        )) { error in
            XCTAssertEqual(error as? IdentityStoreError, .invalidPrivateKey)
        }
    }

    func testMetadataFileIsValidJSONAfterInit() throws {
        let metadataURL = tempDir
            .appendingPathComponent("IdentityStore")
            .appendingPathComponent("identities.json")
        let data = try Data(contentsOf: metadataURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json)
        XCTAssertEqual(json?["schemaVersion"] as? Int, 1)
        XCTAssertNotNil(json?["identities"])
    }

    func testMultipleStoreInstancesSameContainer() throws {
        // Two store instances pointing at the same container should work.
        let store2 = try KeychainIdentityStore(containerURL: tempDir)
        let list1 = try store.listIdentities()
        let list2 = try store2.listIdentities()
        XCTAssertEqual(list1.count, list2.count)
    }

    func testMetadataCorruptionDetected() throws {
        // Write invalid JSON to the metadata file.
        let metadataURL = tempDir
            .appendingPathComponent("IdentityStore")
            .appendingPathComponent("identities.json")
        try "{ invalid json".data(using: .utf8)!.write(to: metadataURL)

        XCTAssertThrowsError(try store.listIdentities()) { error in
            guard case IdentityStoreError.metadataCorrupt = error else {
                XCTFail("Expected metadataCorrupt, got \(error)")
                return
            }
        }
    }
}

// MARK: - Keychain Integration Tests (require Keychain access)
// These tests exercise actual Keychain storage and will only pass when run
// in an environment with Keychain access (e.g., Xcode test runner with entitlements).

final class KeychainIdentityStoreKeychainTests: XCTestCase {

    var tempDir: URL!
    var store: KeychainIdentityStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IdentityStoreKeychainTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try? KeychainIdentityStore(containerURL: tempDir)
    }

    override func tearDown() {
        // Clean up any Keychain entries we created.
        if let identities = try? store?.listIdentities() {
            for identity in identities {
                try? store?.deleteIdentity(identity.id)
            }
        }
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// Test that createIdentity works end-to-end when Keychain access is available.
    /// This test is expected to fail in environments without Keychain entitlements
    /// (e.g., `swift test` on CI). It passes in Xcode with proper entitlements.
    func testCreateIdentityEndToEnd() throws {
        // This will fail with keychainError if Keychain access isn't available.
        // That's expected in `swift test` — the metadata tests above cover the logic.
        do {
            let identity = try store.createIdentity(label: "Test Key", makeActive: true)
            XCTAssertEqual(identity.label, "Test Key")
            XCTAssertTrue(identity.isActive)
            XCTAssertEqual(identity.source, .generated)
            XCTAssertFalse(identity.pubkeyHex.isEmpty)
            XCTAssertEqual(identity.pubkeyHex.count, 64, "pubkey should be 64 hex chars")

            // Should appear in list.
            let list = try store.listIdentities()
            XCTAssertEqual(list.count, 1)
            XCTAssertEqual(list[0].id, identity.id)
            XCTAssertTrue(list[0].isActive)

            // Should be the active identity.
            let active = try store.activeIdentity()
            XCTAssertEqual(active?.id, identity.id)

            // Should be able to load the SDK keypair.
            let keypair = try store.loadSDKKeypair(for: identity.id)
            XCTAssertEqual(keypair.publicKey.hex, identity.pubkeyHex)

            // Delete it.
            try store.deleteIdentity(identity.id)
            let listAfter = try store.listIdentities()
            XCTAssertTrue(listAfter.isEmpty)
            let activeAfter = try store.activeIdentity()
            XCTAssertNil(activeAfter)

        } catch let error as IdentityStoreError {
            if case .keychainError = error {
                // Expected in environments without Keychain entitlements.
                NSLog("[IdentityStoreTests] Skipping Keychain test: \(error)")
            } else {
                throw error
            }
        }
    }

    /// Test import + duplicate detection.
    func testImportAndDuplicateDetection() throws {
        guard let testKeypair = NostrSDK.Keypair() else {
            XCTFail("Could not generate test keypair")
            return
        }

        do {
            let identity = try store.importIdentity(
                privateKeyHex: testKeypair.privateKey.hex,
                source: .imported,
                label: "Imported",
                makeActive: true
            )
            XCTAssertEqual(identity.pubkeyHex, testKeypair.publicKey.hex)
            XCTAssertEqual(identity.source, .imported)

            // Importing the same key again should fail.
            XCTAssertThrowsError(try store.importIdentity(
                privateKeyHex: testKeypair.privateKey.hex,
                source: .imported,
                label: "Dup",
                makeActive: false
            )) { error in
                guard case IdentityStoreError.duplicatePublicKey(let pk) = error else {
                    XCTFail("Expected duplicatePublicKey, got \(error)")
                    return
                }
                XCTAssertEqual(pk, testKeypair.publicKey.hex)
            }

            // Clean up.
            try store.deleteIdentity(identity.id)

        } catch let error as IdentityStoreError {
            if case .keychainError = error {
                NSLog("[IdentityStoreTests] Skipping Keychain test: \(error)")
            } else {
                throw error
            }
        }
    }

    /// Test multi-identity management.
    func testMultipleIdentities() throws {
        do {
            let id1 = try store.createIdentity(label: "Key 1", makeActive: true)
            let id2 = try store.createIdentity(label: "Key 2", makeActive: false)

            var list = try store.listIdentities()
            XCTAssertEqual(list.count, 2)
            // First created should still be active.
            XCTAssertEqual(try store.activeIdentity()?.id, id1.id)

            // Switch active.
            try store.setActiveIdentity(id2.id)
            XCTAssertEqual(try store.activeIdentity()?.id, id2.id)

            // Verify isActive flags in list.
            list = try store.listIdentities()
            let activeFlags = list.map { $0.isActive }
            XCTAssertEqual(activeFlags.filter { $0 }.count, 1)
            XCTAssertTrue(list.first(where: { $0.id == id2.id })!.isActive)

            // Delete active identity — active should be cleared.
            try store.deleteIdentity(id2.id)
            XCTAssertNil(try store.activeIdentity())
            XCTAssertEqual(try store.listIdentities().count, 1)

            // Clean up.
            try store.deleteIdentity(id1.id)

        } catch let error as IdentityStoreError {
            if case .keychainError = error {
                NSLog("[IdentityStoreTests] Skipping Keychain test: \(error)")
            } else {
                throw error
            }
        }
    }

    /// Test loadSDKKeypair for nonexistent identity.
    func testLoadSDKKeypairForNonexistentIdentity() {
        let fakeID = UUID()
        XCTAssertThrowsError(try store.loadSDKKeypair(for: fakeID)) { error in
            guard case IdentityStoreError.identityNotFound(let id) = error else {
                XCTFail("Expected identityNotFound, got \(error)")
                return
            }
            XCTAssertEqual(id, fakeID)
        }
    }
}
