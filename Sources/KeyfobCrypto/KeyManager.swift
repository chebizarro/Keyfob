import Foundation
import LocalAuthentication
import CryptoKit
import NostrSDK

/// Namespace for random byte generation via CryptoKit.
private enum CryptoKitRNG {
    static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let result = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(result == errSecSuccess, "Failed to generate random bytes")
        return Data(bytes)
    }
}

public enum KeyfobCryptoError: Error {
    case keyNotFound
    case exportPasswordRequired
    case keychainError(OSStatus)
    case biometricFailed
    case encryptionFailed
    case importFormatInvalid
}

/// A Keyfob identity's public half. Private keys remain in the Keychain.
///
/// The ``pubkeyHex`` field is the canonical storage representation (`Codable`/`Equatable`).
/// SDK-typed accessors (``publicKey``, ``npub``) are derived on demand from the hex,
/// providing bech32 encoding, data representation, and other NIP-19 functionality
/// without requiring a separate bech32 implementation.
public struct Keypair: Codable, Equatable, Sendable {
    /// The secp256k1 public key as a 64-character lowercase hex string (x-only, no prefix).
    public let pubkeyHex: String

    /// SDK `PublicKey` instance providing `.npub`, `.dataRepresentation`, and NIP-19 support.
    /// Returns `nil` only if ``pubkeyHex`` is not a valid 32-byte hex value (e.g., in test stubs).
    public var publicKey: NostrSDK.PublicKey? {
        NostrSDK.PublicKey(hex: pubkeyHex)
    }

    /// Bech32-encoded npub string for user-facing display (e.g., `npub1abc...`).
    /// Returns `nil` only if ``pubkeyHex`` is not a valid 32-byte hex value.
    public var npub: String? {
        publicKey?.npub
    }

    /// Initialize with a raw hex public key string.
    public init(pubkeyHex: String) {
        self.pubkeyHex = pubkeyHex
    }

    /// Initialize from an SDK ``NostrSDK/PublicKey``.
    public init(publicKey: NostrSDK.PublicKey) {
        self.pubkeyHex = publicKey.hex
    }

    /// Initialize from an SDK ``NostrSDK/Keypair``, retaining only the public half.
    /// The private key is intentionally discarded — it should remain in the Keychain.
    public init(keypair: NostrSDK.Keypair) {
        self.pubkeyHex = keypair.publicKey.hex
    }
}

public final class KeyManager {
    public static let shared = KeyManager()
    private init() {}

    // MARK: - Configuration
    // These must be overridden via build configuration for production.
    // See Docs/SECURITY.md for required setup.
    static let accessGroup: String = {
        if let override = Bundle.main.infoDictionary?["KEYFOB_KEYCHAIN_ACCESS_GROUP"] as? String, !override.isEmpty {
            return override
        }
        return "TEAMID.com.example.keyfob.shared"
    }()
    private let keyAccount = "default.nsec"

    // Generate and persist a secp256k1 key using Keychain with biometry access control.
    public func generateIfNeeded(useICloud: Bool) throws -> Keypair {
        if let existing = try? loadKeypair() { return existing }
        guard let sdkKeypair = NostrSDK.Keypair() else { throw KeyfobCryptoError.keychainError(errSecItemNotFound) }
        let sk = sdkKeypair.privateKey.dataRepresentation

        let access = SecAccessControlCreateWithFlags(nil,
                                                     kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                     [.privateKeyUsage, .biometryCurrentSet],
                                                     nil)!

        // Note: kSecAttrAccessControl supersedes kSecAttrAccessible (Apple docs).
        // Do not set both. Synchronizable is only safe without biometry-gated access control.
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keyAccount,
            kSecAttrService as String: "keyfob",
            kSecAttrAccessGroup as String: Self.accessGroup,
            kSecAttrAccessControl as String: access,
            kSecValueData as String: sk,
            kSecUseDataProtectionKeychain as String: true
        ]
        // iCloud sync is incompatible with biometryCurrentSet access control.
        // Only enable sync for non-biometric keys in the future.
        if useICloud {
            NSLog("[Keyfob][KeyManager] Warning: iCloud sync requested but incompatible with biometric access control. Ignoring.")
        }
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyfobCryptoError.keychainError(status) }
        return Keypair(keypair: sdkKeypair)
    }

    public func loadKeypair() throws -> Keypair {
        let sdkKeypair = try loadSDKKeypair()
        return Keypair(keypair: sdkKeypair)
    }

    /// Load the full SDK Keypair (private + public) from the Keychain.
    ///
    /// The returned keypair contains the private key in memory. Callers should
    /// use it transiently for signing/crypto operations and let it go out of scope.
    /// Triggers biometric authentication if required by the Keychain access control.
    public func loadSDKKeypair() throws -> NostrSDK.Keypair {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keyAccount,
            kSecAttrService as String: "keyfob",
            kSecAttrAccessGroup as String: Self.accessGroup,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let dict = item as? [String: Any], let sk = dict[kSecValueData as String] as? Data else {
            throw KeyfobCryptoError.keyNotFound
        }
        guard let priv = NostrSDK.PrivateKey(dataRepresentation: sk),
              let sdkKeypair = NostrSDK.Keypair(privateKey: priv) else {
            throw KeyfobCryptoError.keyNotFound
        }
        return sdkKeypair
    }

    /// Export the keypair encrypted with a password using AES-256-GCM with HKDF-derived key.
    /// Format: 12-byte nonce || ciphertext || 16-byte tag, with HKDF(SHA256, salt, password, info="keyfob-export").
    public func exportEncrypted(password: String) throws -> Data {
        guard !password.isEmpty else { throw KeyfobCryptoError.exportPasswordRequired }
        let sk = try readPrivateKeyWithBiometrics()
        let pub = try loadKeypair().pubkeyHex
        let payload = ["pubkey": pub, "sk": sk.base64EncodedString()]
        let json = try JSONSerialization.data(withJSONObject: payload)

        // Derive encryption key from password using HKDF
        let passwordData = Data(password.utf8)
        let salt = CryptoKitRNG.randomBytes(count: 32)
        let inputKey = SymmetricKey(data: passwordData)
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: Data("keyfob-export".utf8),
            outputByteCount: 32
        )

        // Encrypt with AES-256-GCM
        let sealedBox = try AES.GCM.seal(json, using: derivedKey)
        guard let combined = sealedBox.combined else {
            throw KeyfobCryptoError.encryptionFailed
        }

        // Output format: 32-byte salt || AES-GCM combined (nonce || ciphertext || tag)
        return salt + combined
    }

    /// Decrypt an exported keypair backup.
    public func importEncrypted(data: Data, password: String) throws -> Keypair {
        guard !password.isEmpty else { throw KeyfobCryptoError.exportPasswordRequired }
        guard data.count > 32 + 12 + 16 else { throw KeyfobCryptoError.importFormatInvalid }

        let salt = data.prefix(32)
        let sealed = data.dropFirst(32)

        let passwordData = Data(password.utf8)
        let inputKey = SymmetricKey(data: passwordData)
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: Data("keyfob-export".utf8),
            outputByteCount: 32
        )

        let sealedBox = try AES.GCM.SealedBox(combined: sealed)
        let plaintext = try AES.GCM.open(sealedBox, using: derivedKey)

        guard let dict = try? JSONSerialization.jsonObject(with: plaintext) as? [String: String],
              let pubkey = dict["pubkey"] else {
            throw KeyfobCryptoError.importFormatInvalid
        }
        return Keypair(pubkeyHex: pubkey)
    }

    // Exposed internally to module for signing
    func readPrivateKeyWithBiometrics() throws -> Data {
        let context = LAContext()
        context.localizedReason = "Approve signing"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw KeyfobCryptoError.biometricFailed
        }
        // Fetch from keychain with biometry
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keyAccount,
            kSecAttrService as String: "keyfob",
            kSecAttrAccessGroup as String: Self.accessGroup,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let sk = item as? Data else { throw KeyfobCryptoError.keychainError(status) }
        return sk
    }
}
