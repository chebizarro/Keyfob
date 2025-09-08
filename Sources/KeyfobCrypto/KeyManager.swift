import Foundation
import LocalAuthentication
import NostrSDK

public enum KeyfobCryptoError: Error {
    case keyNotFound
    case exportPasswordRequired
    case keychainError(OSStatus)
    case biometricFailed
}

public struct Keypair: Codable, Equatable {
    public let pubkeyHex: String
    public let privkeyRef: Data // Keychain reference
}

public final class KeyManager {
    public static let shared = KeyManager()
    private init() {}

    private let accessGroup = "TODO_TEAMID.com.yourorg.keyfob.shared"
    private let keyAccount = "default.nsec"

    // Generate and persist a secp256k1 key using Keychain with biometry access control.
    public func generateIfNeeded(useICloud: Bool) throws -> Keypair {
        if let existing = try? loadKeypair() { return existing }
        guard let kp = NostrSDK.Keypair() else { throw KeyfobCryptoError.keychainError(errSecItemNotFound) }
        let sk = kp.privateKey.dataRepresentation
        let pk = kp.publicKey.hex

        let access = SecAccessControlCreateWithFlags(nil,
                                                     kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                     [.privateKeyUsage, .biometryCurrentSet],
                                                     nil)!

        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keyAccount,
            kSecAttrService as String: "keyfob",
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrAccessControl as String: access,
            kSecValueData as String: sk,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: useICloud
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyfobCryptoError.keychainError(status) }
        return Keypair(pubkeyHex: pk, privkeyRef: Data())
    }

    public func loadKeypair() throws -> Keypair {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keyAccount,
            kSecAttrService as String: "keyfob",
            kSecAttrAccessGroup as String: accessGroup,
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
        guard let priv = NostrSDK.PrivateKey(dataRepresentation: sk), let kp = NostrSDK.Keypair(privateKey: priv) else {
            throw KeyfobCryptoError.keyNotFound
        }
        return Keypair(pubkeyHex: kp.publicKey.hex, privkeyRef: Data())
    }

    public func exportEncrypted(password: String) throws -> Data {
        guard !password.isEmpty else { throw KeyfobCryptoError.exportPasswordRequired }
        let sk = try readPrivateKeyWithBiometrics()
        // Simple password-based encryption placeholder (replace with strong KDF + AEAD)
        let pub = try loadKeypair().pubkeyHex
        let payload = ["pubkey": pub, "sk": sk.base64EncodedString()]
        let json = try JSONSerialization.data(withJSONObject: payload)
        // TODO: Replace with Argon2id + ChaCha20-Poly1305
        return json
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
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let sk = item as? Data else { throw KeyfobCryptoError.keychainError(status) }
        return sk
    }
}
