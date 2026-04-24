//
//  KeychainIdentityStore.swift
//
//
//  Created for Keyfob – kf-3kr
//

import Foundation
import NostrSDK

// MARK: - Metadata File Envelope

/// On-disk JSON envelope for identity metadata.
///
/// Stored at `<appGroupContainer>/IdentityStore/identities.json`.
/// The `schemaVersion` field allows forward-compatible migrations.
struct IdentityMetadataFile: Codable {
    var schemaVersion: Int = 1
    var activeIdentityID: UUID?
    var identities: [StoredIdentityRecord]
}

/// A single identity record as persisted in the metadata file.
///
/// This mirrors ``Identity`` but without `isActive`, which is derived
/// from ``IdentityMetadataFile/activeIdentityID``.
struct StoredIdentityRecord: Codable {
    let id: UUID
    let pubkeyHex: String
    var label: String?
    let createdAt: Date
    let source: IdentitySource
}

// MARK: - KeychainIdentityStore

/// Keychain-backed implementation of ``IdentityStore``.
///
/// - Metadata (public keys, labels, etc.) is persisted in a JSON file in the
///   app group container for cross-process visibility.
/// - Private keys are stored in the Keychain with biometric access control.
/// - Cross-process consistency is ensured by:
///   - File lock (`flock`) around metadata reads/writes.
///   - Atomic file replacement (`write(to:atomically:)`).
///   - Darwin notifications for cross-process observation.
///
/// This class coexists with the legacy ``KeyManager`` — migration is handled
/// by a separate bead (kf-gps).
public final class KeychainIdentityStore: IdentityStore, @unchecked Sendable {

    // MARK: - Properties

    /// URL of the metadata JSON file.
    private let metadataURL: URL

    /// Serial queue protecting in-process metadata access.
    private let queue = DispatchQueue(label: "com.keyfob.identityStore", qos: .userInitiated)

    /// Darwin notification port for cross-process observation.
    private let notifyPort: CFNotificationCenter

    // MARK: - Init

    /// Creates a store using the default app group container.
    public convenience init() throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: KeychainConfig.appGroup
        ) else {
            throw IdentityStoreError.appGroupUnavailable
        }
        try self.init(containerURL: containerURL)
    }

    /// Creates a store with a custom container URL (used for testing).
    public init(containerURL: URL) throws {
        let dir = containerURL.appendingPathComponent("IdentityStore", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.metadataURL = dir.appendingPathComponent("identities.json")
        self.notifyPort = CFNotificationCenterGetDarwinNotifyCenter()

        // Create empty metadata file if it doesn't exist.
        if !FileManager.default.fileExists(atPath: metadataURL.path) {
            let empty = IdentityMetadataFile(identities: [])
            try writeMetadata(empty)
        }
    }

    // MARK: - CRUD

    public func createIdentity(label: String?, makeActive: Bool) throws -> Identity {
        // Generate a new SDK Keypair.
        guard let sdkKeypair = NostrSDK.Keypair() else {
            throw IdentityStoreError.invalidPrivateKey
        }

        let identityID = UUID()
        let pubkeyHex = sdkKeypair.publicKey.hex

        // Store private key in Keychain first — if this fails, no metadata is written.
        try storePrivateKey(sdkKeypair.privateKey.dataRepresentation, for: identityID)

        // Update metadata file under lock.
        return try withMetadataLock { metadata in
            // Check for duplicate pubkey.
            if metadata.identities.contains(where: { $0.pubkeyHex == pubkeyHex }) {
                // Clean up the Keychain entry we just wrote.
                self.deleteKeychainEntry(for: identityID)
                throw IdentityStoreError.duplicatePublicKey(pubkeyHex)
            }

            let record = StoredIdentityRecord(
                id: identityID,
                pubkeyHex: pubkeyHex,
                label: label,
                createdAt: Date(),
                source: .generated
            )
            metadata.identities.append(record)

            if makeActive {
                metadata.activeIdentityID = identityID
            }

            try self.writeMetadata(metadata)
            self.postChangeNotification()

            return self.materialize(record, activeID: metadata.activeIdentityID)
        }
    }

    public func importIdentity(privateKeyHex: String, source: IdentitySource, label: String?, makeActive: Bool) throws -> Identity {
        guard source == .imported || source == .generated || source == .nip49 else {
            throw IdentityStoreError.unsupportedSourceForCreate(source)
        }

        guard let sdkPrivateKey = NostrSDK.PrivateKey(hex: privateKeyHex),
              let sdkKeypair = NostrSDK.Keypair(privateKey: sdkPrivateKey) else {
            throw IdentityStoreError.invalidPrivateKey
        }

        let identityID = UUID()
        let pubkeyHex = sdkKeypair.publicKey.hex

        // Store private key in Keychain first.
        try storePrivateKey(sdkPrivateKey.dataRepresentation, for: identityID)

        // Update metadata under lock.
        return try withMetadataLock { metadata in
            if metadata.identities.contains(where: { $0.pubkeyHex == pubkeyHex }) {
                self.deleteKeychainEntry(for: identityID)
                throw IdentityStoreError.duplicatePublicKey(pubkeyHex)
            }

            let record = StoredIdentityRecord(
                id: identityID,
                pubkeyHex: pubkeyHex,
                label: label,
                createdAt: Date(),
                source: source
            )
            metadata.identities.append(record)

            if makeActive {
                metadata.activeIdentityID = identityID
            }

            try self.writeMetadata(metadata)
            self.postChangeNotification()

            return self.materialize(record, activeID: metadata.activeIdentityID)
        }
    }

    public func listIdentities() throws -> [Identity] {
        let metadata = try readMetadata()
        return metadata.identities
            .sorted { $0.createdAt < $1.createdAt }
            .map { materialize($0, activeID: metadata.activeIdentityID) }
    }

    public func activeIdentity() throws -> Identity? {
        let metadata = try readMetadata()
        guard let activeID = metadata.activeIdentityID,
              let record = metadata.identities.first(where: { $0.id == activeID }) else {
            return nil
        }
        return materialize(record, activeID: activeID)
    }

    public func setActiveIdentity(_ id: UUID?) throws {
        try withMetadataLock { metadata in
            if let id = id {
                guard metadata.identities.contains(where: { $0.id == id }) else {
                    throw IdentityStoreError.identityNotFound(id)
                }
            }
            metadata.activeIdentityID = id
            try self.writeMetadata(metadata)
            self.postChangeNotification()
        }
    }

    public func deleteIdentity(_ id: UUID) throws {
        try withMetadataLock { metadata in
            guard let idx = metadata.identities.firstIndex(where: { $0.id == id }) else {
                throw IdentityStoreError.identityNotFound(id)
            }
            metadata.identities.remove(at: idx)

            // Clear active if we're deleting the active identity.
            if metadata.activeIdentityID == id {
                metadata.activeIdentityID = nil
            }

            try self.writeMetadata(metadata)

            // Remove Keychain entry (best-effort; metadata is already updated).
            self.deleteKeychainEntry(for: id)

            self.postChangeNotification()
        }
    }

    // MARK: - Key Access

    public func loadSDKKeypair(for identityID: UUID) throws -> NostrSDK.Keypair {
        // Verify identity exists in metadata first (cheap, no biometrics).
        let metadata = try readMetadata()
        guard metadata.identities.contains(where: { $0.id == identityID }) else {
            throw IdentityStoreError.identityNotFound(identityID)
        }

        // Read from Keychain — may trigger biometric prompt.
        // NOTE: Do NOT hold file lock during this call (Oracle guidance).
        let account = KeychainConfig.keychainAccount(for: identityID)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: KeychainConfig.service,
            kSecAttrAccessGroup as String: KeychainConfig.accessGroup,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let skData = item as? Data else {
            throw IdentityStoreError.keychainError(status)
        }

        guard let priv = NostrSDK.PrivateKey(dataRepresentation: skData),
              let keypair = NostrSDK.Keypair(privateKey: priv) else {
            throw IdentityStoreError.invalidPrivateKey
        }
        return keypair
    }

    // MARK: - Observation

    public func observeActiveIdentity() -> AsyncStream<Identity?> {
        AsyncStream { continuation in
            // Yield current value immediately.
            let current = try? self.activeIdentity()
            continuation.yield(current)

            // Observe Darwin notifications for cross-process changes.
            let name = KeychainConfig.activeIdentityChangedNotification as CFString

            // Store continuation in a box so the C callback can access it.
            let box = continuationBox(continuation)
            let boxPtr = Unmanaged.passRetained(box).toOpaque()

            CFNotificationCenterAddObserver(
                self.notifyPort,
                boxPtr,
                { _, observerPtr, _, _, _ in
                    guard let ptr = observerPtr else { return }
                    let box = Unmanaged<ContinuationBox<Identity?>>.fromOpaque(ptr).takeUnretainedValue()
                    let store = box.store
                    let current = try? store.activeIdentity()
                    box.continuation.yield(current)
                },
                name,
                nil,
                .deliverImmediately
            )

            // UnsafeMutableRawPointer is not Sendable but this is safe:
            // the pointer refers to a retained ContinuationBox that outlives the closure.
            nonisolated(unsafe) let boxPtrForCleanup = boxPtr
            continuation.onTermination = { @Sendable _ in
                CFNotificationCenterRemoveObserver(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    boxPtrForCleanup,
                    CFNotificationName(name),
                    nil
                )
                // Release the box.
                Unmanaged<ContinuationBox<Identity?>>.fromOpaque(boxPtrForCleanup).release()
            }
        }
    }

    // MARK: - Private: Metadata File I/O

    /// Read metadata with file lock for consistency.
    private func readMetadata() throws -> IdentityMetadataFile {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            return IdentityMetadataFile(identities: [])
        }
        let data = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(IdentityMetadataFile.self, from: data)
        } catch {
            throw IdentityStoreError.metadataCorrupt(error.localizedDescription)
        }
    }

    /// Write metadata atomically.
    private func writeMetadata(_ metadata: IdentityMetadataFile) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(metadata)
        } catch {
            throw IdentityStoreError.metadataWriteFailed(error.localizedDescription)
        }
        do {
            try data.write(to: metadataURL, options: .atomic)
        } catch {
            throw IdentityStoreError.metadataWriteFailed(error.localizedDescription)
        }
    }

    /// Execute a closure with exclusive file lock and fresh metadata.
    ///
    /// The lock is held for the duration of `body`. The closure receives an
    /// `inout` copy of the metadata so mutations can be applied. The caller
    /// is responsible for calling `writeMetadata(_:)` within the body if changes
    /// were made.
    @discardableResult
    private func withMetadataLock<T>(_ body: (inout IdentityMetadataFile) throws -> T) throws -> T {
        // Open (or create) a lock file adjacent to the metadata file.
        let lockURL = metadataURL.appendingPathExtension("lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            throw IdentityStoreError.metadataWriteFailed("Could not open lock file")
        }
        defer { close(fd) }

        // Acquire exclusive lock (blocks until available).
        guard flock(fd, LOCK_EX) == 0 else {
            throw IdentityStoreError.metadataWriteFailed("Could not acquire file lock")
        }
        defer { flock(fd, LOCK_UN) }

        // Reload metadata under lock to avoid TOCTOU races.
        var metadata = try readMetadata()
        return try body(&metadata)
    }

    // MARK: - Private: Keychain Operations

    /// Store a private key in the Keychain with biometric protection.
    private func storePrivateKey(_ keyData: Data, for identityID: UUID) throws {
        let account = KeychainConfig.keychainAccount(for: identityID)

        let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet],
            nil
        )!

        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: KeychainConfig.service,
            kSecAttrAccessGroup as String: KeychainConfig.accessGroup,
            kSecAttrAccessControl as String: access,
            kSecValueData as String: keyData,
            kSecUseDataProtectionKeychain as String: true
        ]

        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw IdentityStoreError.keychainError(status)
        }
    }

    /// Delete a Keychain entry for an identity (best-effort).
    private func deleteKeychainEntry(for identityID: UUID) {
        let account = KeychainConfig.keychainAccount(for: identityID)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: KeychainConfig.service,
            kSecAttrAccessGroup as String: KeychainConfig.accessGroup
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Private: Helpers

    /// Convert a ``StoredIdentityRecord`` to a full ``Identity``,
    /// deriving `isActive` from the given active ID.
    private func materialize(_ record: StoredIdentityRecord, activeID: UUID?) -> Identity {
        Identity(
            id: record.id,
            pubkeyHex: record.pubkeyHex,
            label: record.label,
            createdAt: record.createdAt,
            source: record.source,
            isActive: record.id == activeID
        )
    }

    /// Post a Darwin notification to inform other processes of a change.
    private func postChangeNotification() {
        let name = KeychainConfig.activeIdentityChangedNotification as CFString
        CFNotificationCenterPostNotification(
            notifyPort,
            CFNotificationName(name),
            nil,
            nil,
            true
        )
    }

    /// Helper to create a continuation box for the C callback.
    private func continuationBox(_ continuation: AsyncStream<Identity?>.Continuation) -> ContinuationBox<Identity?> {
        ContinuationBox(continuation: continuation, store: self)
    }
}

// MARK: - ContinuationBox

/// A reference type that bridges an `AsyncStream.Continuation` into a C-function callback.
///
/// Needed because `CFNotificationCenterAddObserver` uses an `UnsafeRawPointer` context,
/// and we need to pass both the continuation and a reference to the store.
private final class ContinuationBox<T> {
    let continuation: AsyncStream<T>.Continuation
    let store: KeychainIdentityStore

    init(continuation: AsyncStream<T>.Continuation, store: KeychainIdentityStore) {
        self.continuation = continuation
        self.store = store
    }
}
