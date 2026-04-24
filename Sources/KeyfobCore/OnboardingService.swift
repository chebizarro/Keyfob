//
//  OnboardingService.swift
//
//
//  Created for Keyfob – kf-9h2
//
//  First-run onboarding logic: create new key, import from nsec/hex/ncryptsec.
//  UI-agnostic service layer that coordinates IdentityStore, KeyImport, and NCryptsec.
//

import Foundation
import KeyfobCrypto
import NostrSDK

// MARK: - OnboardingResult

/// The result of a successful onboarding operation (create or import).
///
/// Contains all the information the UI needs to display confirmation and
/// offer key backup, without requiring the UI to import KeyfobCrypto.
public struct OnboardingResult: Sendable, Equatable {
    /// The UUID of the newly created identity.
    public let identityID: UUID

    /// 64-character hex public key.
    public let pubkeyHex: String

    /// Full bech32 npub string for display (e.g. `npub1abc...`).
    public let npubDisplay: String

    /// Truncated npub for compact display (e.g. `npub1abcdefgh...wxyz`).
    public let npubTruncated: String

    /// The nsec string for backup — only populated in the create flow.
    /// `nil` for import flows (the user already has their key).
    public let nsecForBackup: String?

    /// How the key was provisioned.
    public let source: String

    /// Optional label assigned to the identity.
    public let label: String?

    public init(
        identityID: UUID,
        pubkeyHex: String,
        npubDisplay: String,
        npubTruncated: String,
        nsecForBackup: String? = nil,
        source: String,
        label: String? = nil
    ) {
        self.identityID = identityID
        self.pubkeyHex = pubkeyHex
        self.npubDisplay = npubDisplay
        self.npubTruncated = npubTruncated
        self.nsecForBackup = nsecForBackup
        self.source = source
        self.label = label
    }
}

// MARK: - InputFormat

/// The detected format of a key input string.
public enum InputFormat: Equatable, Sendable {
    /// Bech32-encoded private key (nsec1...).
    case nsec
    /// Bech32-encoded public key (npub1...) — not importable as identity.
    case npub
    /// 64-character hex string.
    case hex
    /// NIP-49 encrypted key (ncryptsec1...) — requires password.
    case ncryptsec
    /// Unrecognized format.
    case unknown
}

// MARK: - OnboardingError

/// Errors from the onboarding flow.
public enum OnboardingError: Error, Equatable {
    /// Key generation failed internally.
    case keyCreationFailed(String)
    /// Key import failed (invalid format, bad nsec, etc.).
    case importFailed(String)
    /// ncryptsec decryption failed (wrong password, corrupt data, etc.).
    case ncryptsecDecryptionFailed(String)
    /// The input is an npub (public key only), not a private key.
    case publicKeyNotImportable
    /// The input format could not be determined.
    case unrecognizedFormat
    /// The identity store is not available.
    case storeUnavailable(String)
}

// MARK: - OnboardingService

/// Coordinates first-run key creation and import flows.
///
/// This service is the single entry point for onboarding logic. It handles:
/// 1. **Create new key** — generates a Keypair, stores it, returns npub + nsec for backup
/// 2. **Import from nsec/hex** — parses the input, stores it
/// 3. **Import from ncryptsec** — decrypts with password, stores it
///
/// The service is UI-agnostic and returns ``OnboardingResult`` structs that
/// contain all the display-ready strings the UI needs.
///
/// ## Usage
///
/// ```swift
/// let service = OnboardingService(identityStore: store)
///
/// // Create new key
/// let result = try service.createNewIdentity(label: "Main")
/// print(result.npubDisplay)     // npub1abc...
/// print(result.nsecForBackup!)  // nsec1xyz... (show in backup sheet)
///
/// // Import existing key
/// let result = try service.importKey("nsec1...", label: "Imported")
///
/// // Import ncryptsec (password required)
/// let result = try service.importNCryptsec("ncryptsec1...", password: "hunter2")
/// ```
public final class OnboardingService: @unchecked Sendable {

    private let identityStore: IdentityStore

    /// Create an onboarding service backed by the given identity store.
    ///
    /// - Parameter identityStore: The store to create/import identities into.
    public init(identityStore: IdentityStore) {
        self.identityStore = identityStore
    }

    // MARK: - Create New Key

    /// Generate a new keypair and store it as an identity.
    ///
    /// The result includes the nsec string for the backup prompt. This is the
    /// only time the private key is exposed — after this, it lives only in the Keychain.
    ///
    /// - Parameter label: Optional display label for the identity.
    /// - Returns: An ``OnboardingResult`` with npub display info and nsec for backup.
    /// - Throws: ``OnboardingError`` on failure.
    public func createNewIdentity(label: String? = nil) throws -> OnboardingResult {
        let identity: Identity
        do {
            identity = try identityStore.createIdentity(label: label, makeActive: true)
        } catch {
            throw OnboardingError.keyCreationFailed(error.localizedDescription)
        }

        // Load keypair to get the nsec for the backup prompt
        let nsec: String?
        do {
            let keypair = try identityStore.loadSDKKeypair(for: identity.id)
            nsec = keypair.privateKey.nsec
        } catch {
            // Key was created successfully but we can't retrieve nsec for backup.
            // Still return a result — the key is stored and usable.
            nsec = nil
        }

        return makeResult(identity: identity, nsecForBackup: nsec)
    }

    // MARK: - Import from String

    /// Import a private key from an nsec or hex string.
    ///
    /// Auto-detects the format. Returns an error for npub (public-key-only)
    /// or ncryptsec (which requires a password via ``importNCryptsec(_:password:label:)``).
    ///
    /// - Parameters:
    ///   - input: The key string (nsec1... or 64-char hex).
    ///   - label: Optional display label.
    /// - Returns: An ``OnboardingResult`` with the imported identity info.
    /// - Throws: ``OnboardingError`` on invalid input or store failure.
    public func importKey(_ input: String, label: String? = nil) throws -> OnboardingResult {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let format = detectInputFormat(trimmed)

        switch format {
        case .npub:
            throw OnboardingError.publicKeyNotImportable
        case .ncryptsec:
            throw OnboardingError.importFailed("ncryptsec requires a password. Use importNCryptsec(_:password:label:) instead.")
        case .unknown:
            throw OnboardingError.unrecognizedFormat
        case .nsec, .hex:
            break
        }

        let privateKeyHex: String
        do {
            let parsed = try KeyImport.parsePrivateKey(trimmed)
            privateKeyHex = parsed.hex
        } catch {
            throw OnboardingError.importFailed(error.localizedDescription)
        }

        let identity: Identity
        do {
            identity = try identityStore.importIdentity(
                privateKeyHex: privateKeyHex,
                source: .imported,
                label: label,
                makeActive: true
            )
        } catch {
            throw OnboardingError.importFailed(error.localizedDescription)
        }

        return makeResult(identity: identity)
    }

    // MARK: - Import from NCryptsec

    /// Decrypt an ncryptsec string and import the private key.
    ///
    /// - Parameters:
    ///   - ncryptsec: The bech32-encoded ncryptsec string.
    ///   - password: The decryption password.
    ///   - label: Optional display label.
    /// - Returns: An ``OnboardingResult`` with the imported identity info.
    /// - Throws: ``OnboardingError`` on decryption or store failure.
    public func importNCryptsec(_ ncryptsec: String, password: String, label: String? = nil) throws -> OnboardingResult {
        let decodedKey: NostrSDK.PrivateKey
        do {
            decodedKey = try NCryptsec.decode(ncryptsec, password: password)
        } catch {
            throw OnboardingError.ncryptsecDecryptionFailed(error.localizedDescription)
        }

        let identity: Identity
        do {
            identity = try identityStore.importIdentity(
                privateKeyHex: decodedKey.hex,
                source: .nip49,
                label: label,
                makeActive: true
            )
        } catch {
            throw OnboardingError.importFailed(error.localizedDescription)
        }

        return makeResult(identity: identity)
    }

    // MARK: - Format Detection

    /// Detect the format of a key input string.
    ///
    /// Useful for UI validation — e.g. showing a password field when ncryptsec
    /// is detected, or showing an error for npub input.
    ///
    /// - Parameter input: The raw input string.
    /// - Returns: The detected ``InputFormat``.
    public func detectInputFormat(_ input: String) -> InputFormat {
        Self.detectFormat(input)
    }

    /// Static format detection (no instance required).
    public static func detectFormat(_ input: String) -> InputFormat {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return .unknown }

        if trimmed.hasPrefix("ncryptsec1") {
            return .ncryptsec
        }
        if trimmed.hasPrefix("nsec1") {
            return .nsec
        }
        if trimmed.hasPrefix("npub1") {
            return .npub
        }
        if trimmed.count == 64 && trimmed.allSatisfy({ $0.isHexDigit }) {
            return .hex
        }
        return .unknown
    }

    // MARK: - Helpers

    /// Check whether the identity store has any identities.
    ///
    /// Used to determine whether to show onboarding or the main app.
    ///
    /// - Returns: `true` if the store has at least one identity.
    public func hasExistingIdentity() throws -> Bool {
        let identities = try identityStore.listIdentities()
        return !identities.isEmpty
    }

    /// Build an OnboardingResult from an Identity.
    private func makeResult(identity: Identity, nsecForBackup: String? = nil) -> OnboardingResult {
        let npub = NpubDisplay.npub(from: identity.pubkeyHex) ?? identity.pubkeyHex
        let npubTrunc = NpubDisplay.truncated(identity.pubkeyHex)

        return OnboardingResult(
            identityID: identity.id,
            pubkeyHex: identity.pubkeyHex,
            npubDisplay: npub,
            npubTruncated: npubTrunc,
            nsecForBackup: nsecForBackup,
            source: identity.source.rawValue,
            label: identity.label
        )
    }
}


