//
//  LegacyKeyMigrationTests.swift
//
//
//  Created for Keyfob – kf-gps
//

import XCTest
@testable import KeyfobCrypto
import NostrSDK

// MARK: - Migration State Tests (no Keychain needed)

final class LegacyKeyMigrationStateTests: XCTestCase {

    var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "LegacyKeyMigrationTests-\(UUID().uuidString)")!
    }

    override func tearDown() {
        if let suiteName = defaults.volatileDomainNames.first {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    func testMigrationNotCompleteByDefault() {
        XCTAssertFalse(LegacyKeyMigration.isMigrationComplete(defaults: defaults))
    }

    func testMigratedIdentityIDNilByDefault() {
        XCTAssertNil(LegacyKeyMigration.migratedIdentityID(defaults: defaults))
    }

    func testResetMigrationState() {
        defaults.set(true, forKey: "com.keyfob.legacyKeyMigration.complete")
        defaults.set(UUID().uuidString, forKey: "com.keyfob.legacyKeyMigration.identityID")

        LegacyKeyMigration.resetMigrationState(defaults: defaults)

        XCTAssertFalse(LegacyKeyMigration.isMigrationComplete(defaults: defaults))
        XCTAssertNil(LegacyKeyMigration.migratedIdentityID(defaults: defaults))
    }

    func testMigrateWithNoLegacyKeyMarksComplete() throws {
        // Create a store with a temp directory.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MigrationTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try KeychainIdentityStore(containerURL: tempDir)

        // No legacy key exists, so migration should complete with nil result.
        let result = try LegacyKeyMigration.migrateIfNeeded(to: store, defaults: defaults)
        XCTAssertNil(result)
        XCTAssertTrue(LegacyKeyMigration.isMigrationComplete(defaults: defaults))
    }

    func testMigrateIsIdempotent() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MigrationTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try KeychainIdentityStore(containerURL: tempDir)

        // First call — marks complete
        _ = try LegacyKeyMigration.migrateIfNeeded(to: store, defaults: defaults)
        XCTAssertTrue(LegacyKeyMigration.isMigrationComplete(defaults: defaults))

        // Second call — returns nil immediately (already complete)
        let result = try LegacyKeyMigration.migrateIfNeeded(to: store, defaults: defaults)
        XCTAssertNil(result)
    }
}

// MARK: - Migration Integration Tests (require Keychain access)

final class LegacyKeyMigrationKeychainTests: XCTestCase {

    var tempDir: URL!
    var store: KeychainIdentityStore!
    var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MigrationKeychainTest-\(UUID().uuidString)")
        store = try? KeychainIdentityStore(containerURL: tempDir)
        defaults = UserDefaults(suiteName: "MigrationKeychainTests-\(UUID().uuidString)")!
    }

    override func tearDown() {
        // Clean up any identities we created.
        if let identities = try? store?.listIdentities() {
            for identity in identities {
                try? store?.deleteIdentity(identity.id)
            }
        }
        // Clean up any legacy key we created.
        LegacyKeyMigration.deleteLegacyKey()
        LegacyKeyMigration.resetMigrationState(defaults: defaults)
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// Helper: write a legacy key directly to the Keychain.
    private func writeLegacyKey(_ keyData: Data) -> Bool {
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConfig.legacyKeyAccount,
            kSecAttrService as String: KeychainConfig.service,
            kSecAttrAccessGroup as String: KeychainConfig.accessGroup,
            kSecValueData as String: keyData,
            kSecUseDataProtectionKeychain as String: true
        ]
        // Delete any existing entry first.
        LegacyKeyMigration.deleteLegacyKey()
        let status = SecItemAdd(attrs as CFDictionary, nil)
        return status == errSecSuccess
    }

    func testHasLegacyKeyDetectsExistingKey() {
        guard let kp = NostrSDK.Keypair() else {
            XCTFail("Could not generate keypair")
            return
        }

        guard writeLegacyKey(kp.privateKey.dataRepresentation) else {
            NSLog("[MigrationTests] Skipping: Keychain write failed (no entitlements)")
            return
        }

        XCTAssertTrue(LegacyKeyMigration.hasLegacyKey())

        // Clean up.
        LegacyKeyMigration.deleteLegacyKey()
        XCTAssertFalse(LegacyKeyMigration.hasLegacyKey())
    }

    func testFullMigrationEndToEnd() throws {
        guard let kp = NostrSDK.Keypair() else {
            XCTFail("Could not generate keypair")
            return
        }

        guard writeLegacyKey(kp.privateKey.dataRepresentation) else {
            NSLog("[MigrationTests] Skipping: Keychain write failed (no entitlements)")
            return
        }

        do {
            // Run migration.
            let migrated = try LegacyKeyMigration.migrateIfNeeded(
                to: store,
                removeLegacyEntry: false,
                defaults: defaults
            )

            // Should return the migrated identity.
            XCTAssertNotNil(migrated)
            XCTAssertEqual(migrated?.pubkeyHex, kp.publicKey.hex)
            XCTAssertEqual(migrated?.label, "Default")
            XCTAssertEqual(migrated?.source, .generated)
            XCTAssertTrue(migrated!.isActive)

            // Should be in the store.
            let identities = try store.listIdentities()
            XCTAssertEqual(identities.count, 1)
            XCTAssertEqual(identities[0].pubkeyHex, kp.publicKey.hex)

            // Should be the active identity.
            let active = try store.activeIdentity()
            XCTAssertEqual(active?.id, migrated?.id)

            // Migration state should be recorded.
            XCTAssertTrue(LegacyKeyMigration.isMigrationComplete(defaults: defaults))
            XCTAssertEqual(LegacyKeyMigration.migratedIdentityID(defaults: defaults), migrated?.id)

            // Legacy key should still exist (removeLegacyEntry: false).
            XCTAssertTrue(LegacyKeyMigration.hasLegacyKey())

            // Should be able to load the SDK keypair from the new identity.
            let loadedKeypair = try store.loadSDKKeypair(for: migrated!.id)
            XCTAssertEqual(loadedKeypair.publicKey.hex, kp.publicKey.hex)

        } catch let error as IdentityStoreError {
            if case .keychainError = error {
                NSLog("[MigrationTests] Skipping Keychain test: \(error)")
            } else {
                throw error
            }
        }
    }

    func testMigrationWithRemoveLegacyEntry() throws {
        guard let kp = NostrSDK.Keypair() else {
            XCTFail("Could not generate keypair")
            return
        }

        guard writeLegacyKey(kp.privateKey.dataRepresentation) else {
            NSLog("[MigrationTests] Skipping: Keychain write failed (no entitlements)")
            return
        }

        do {
            let migrated = try LegacyKeyMigration.migrateIfNeeded(
                to: store,
                removeLegacyEntry: true,
                defaults: defaults
            )

            XCTAssertNotNil(migrated)

            // Legacy key should be removed.
            XCTAssertFalse(LegacyKeyMigration.hasLegacyKey())

        } catch let error as IdentityStoreError {
            if case .keychainError = error {
                NSLog("[MigrationTests] Skipping Keychain test: \(error)")
            } else {
                throw error
            }
        }
    }

    func testMigrationSkipsIfPubkeyAlreadyInStore() throws {
        guard let kp = NostrSDK.Keypair() else {
            XCTFail("Could not generate keypair")
            return
        }

        do {
            // Pre-import the key into the store.
            let preImported = try store.importIdentity(
                privateKeyHex: kp.privateKey.hex,
                source: .imported,
                label: "Already Here",
                makeActive: false
            )

            // Now write the same key as a legacy entry.
            guard writeLegacyKey(kp.privateKey.dataRepresentation) else {
                NSLog("[MigrationTests] Skipping: Keychain write failed (no entitlements)")
                // Clean up the pre-imported identity.
                try? store.deleteIdentity(preImported.id)
                return
            }

            // Migration should detect the duplicate and reuse the existing identity.
            let migrated = try LegacyKeyMigration.migrateIfNeeded(
                to: store,
                defaults: defaults
            )

            // Should return the existing identity, not create a new one.
            XCTAssertNotNil(migrated)
            XCTAssertEqual(migrated?.id, preImported.id)

            // Should have made it active.
            let active = try store.activeIdentity()
            XCTAssertEqual(active?.id, preImported.id)

            // Still only one identity in the store.
            XCTAssertEqual(try store.listIdentities().count, 1)

        } catch let error as IdentityStoreError {
            if case .keychainError = error {
                NSLog("[MigrationTests] Skipping Keychain test: \(error)")
            } else {
                throw error
            }
        }
    }

    func testReadLegacyKeyReturnsNilWhenNoKey() {
        // Ensure no legacy key exists.
        LegacyKeyMigration.deleteLegacyKey()
        XCTAssertNil(LegacyKeyMigration.readLegacyKey())
    }

    func testDeleteLegacyKeyIsIdempotent() {
        // Delete when nothing exists — should succeed.
        XCTAssertTrue(LegacyKeyMigration.deleteLegacyKey())
        // Delete again — still fine.
        XCTAssertTrue(LegacyKeyMigration.deleteLegacyKey())
    }
}
