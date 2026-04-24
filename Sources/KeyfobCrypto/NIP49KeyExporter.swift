//
//  NIP49KeyExporter.swift
//
//
//  Created for Keyfob – kf-3so
//
//  NIP-49 ncryptsec bech32 encoding/decoding layer.
//  Wraps NIP49Encryption (scrypt + XChaCha20-Poly1305) with bech32 framing.
//
//  Wire format (91 bytes, bech32-encoded with "ncryptsec" HRP):
//    version (1 byte, must be 0x02)
//    log_n   (1 byte, scrypt cost parameter)
//    salt    (16 bytes)
//    nonce   (24 bytes)
//    key_security (1 byte)
//    encrypted_key (48 bytes = 32-byte key + 16-byte Poly1305 tag)
//

import Foundation
import NostrSDK

// MARK: - NIP49KeyExporterError

/// Errors from ncryptsec encoding/decoding.
public enum NIP49KeyExporterError: Error, Equatable {
    /// The bech32 string does not use the "ncryptsec" HRP.
    case invalidHRP(String)
    /// The decoded payload is not the expected 91 bytes.
    case invalidPayloadLength(Int)
    /// The version byte is not 0x02.
    case unsupportedVersion(UInt8)
    /// The password is empty.
    case emptyPassword
    /// Bech32 encoding failed.
    case encodingFailed(String)
    /// Bech32 decoding failed.
    case decodingFailed(String)
    /// The decrypted key is not a valid Nostr private key.
    case invalidPrivateKey
    /// The identity was not found in the store.
    case identityNotFound
    /// The identity store returned no private key bytes.
    case noPrivateKeyData
}

// MARK: - NCryptsec

/// Encodes and decodes NIP-49 ncryptsec strings.
///
/// An ncryptsec string is a bech32-encoded, password-encrypted Nostr private key
/// following the NIP-49 specification. It allows users to back up and transfer
/// private keys securely using a memorable password.
///
/// ## Usage
///
/// ```swift
/// // Encrypt a private key to ncryptsec
/// let ncryptsec = try NCryptsec.encode(
///     privateKeyHex: "deadbeef...",
///     password: "correct horse battery staple"
/// )
/// // → "ncryptsec1qgg9..."
///
/// // Decrypt from ncryptsec
/// let privateKey = try NCryptsec.decode(ncryptsec, password: "correct horse battery staple")
/// ```
public enum NCryptsec {

    /// The bech32 human-readable part for NIP-49 encrypted keys.
    public static let hrp = "ncryptsec"

    /// Expected version byte in the NIP-49 payload.
    public static let expectedVersion: UInt8 = 0x02

    // MARK: - Encode

    /// Encrypt a private key and encode as an ncryptsec bech32 string.
    ///
    /// - Parameters:
    ///   - privateKeyHex: The 32-byte private key as a 64-character hex string.
    ///   - password: The encryption password. Must not be empty.
    ///   - logN: The scrypt cost parameter (default: 16 for interactive use).
    ///   - keySecurity: How the key was obtained (default: `.unknown`).
    /// - Returns: The bech32-encoded ncryptsec string.
    /// - Throws: ``NIP49KeyExporterError`` or ``NIP49EncryptionError``.
    public static func encode(
        privateKeyHex: String,
        password: String,
        logN: UInt8 = NIP49Encryption.defaultLogN,
        keySecurity: KeySecurity = .unknown
    ) throws -> String {
        guard !password.isEmpty else {
            throw NIP49KeyExporterError.emptyPassword
        }

        guard let keyData = hexToData(privateKeyHex), keyData.count == 32 else {
            throw NIP49KeyExporterError.invalidPrivateKey
        }

        let payload = try NIP49Encryption.encrypt(
            privateKeyBytes: keyData,
            password: password,
            logN: logN,
            keySecurity: keySecurity
        )

        assert(payload.count == NIP49Encryption.payloadLength,
               "NIP-49 payload must be \(NIP49Encryption.payloadLength) bytes")

        do {
            return try Bech32Coder.encode(hrp: hrp, data: payload)
        } catch {
            throw NIP49KeyExporterError.encodingFailed(error.localizedDescription)
        }
    }

    /// Encrypt raw private key bytes and encode as an ncryptsec bech32 string.
    ///
    /// - Parameters:
    ///   - privateKeyBytes: The 32-byte private key.
    ///   - password: The encryption password. Must not be empty.
    ///   - logN: The scrypt cost parameter (default: 16 for interactive use).
    ///   - keySecurity: How the key was obtained (default: `.unknown`).
    /// - Returns: The bech32-encoded ncryptsec string.
    /// - Throws: ``NIP49KeyExporterError`` or ``NIP49EncryptionError``.
    public static func encode(
        privateKeyBytes: Data,
        password: String,
        logN: UInt8 = NIP49Encryption.defaultLogN,
        keySecurity: KeySecurity = .unknown
    ) throws -> String {
        guard !password.isEmpty else {
            throw NIP49KeyExporterError.emptyPassword
        }
        guard privateKeyBytes.count == 32 else {
            throw NIP49KeyExporterError.invalidPrivateKey
        }

        let payload = try NIP49Encryption.encrypt(
            privateKeyBytes: privateKeyBytes,
            password: password,
            logN: logN,
            keySecurity: keySecurity
        )

        do {
            return try Bech32Coder.encode(hrp: hrp, data: payload)
        } catch {
            throw NIP49KeyExporterError.encodingFailed(error.localizedDescription)
        }
    }

    // MARK: - Decode

    /// Decode an ncryptsec string and decrypt the private key.
    ///
    /// - Parameters:
    ///   - ncryptsec: The bech32-encoded ncryptsec string.
    ///   - password: The decryption password.
    /// - Returns: The decrypted ``NostrSDK/PrivateKey``.
    /// - Throws: ``NIP49KeyExporterError`` or ``NIP49EncryptionError``.
    public static func decode(_ ncryptsec: String, password: String) throws -> NostrSDK.PrivateKey {
        guard !password.isEmpty else {
            throw NIP49KeyExporterError.emptyPassword
        }

        let payload = try decodePayload(ncryptsec)
        let (keyData, _) = try NIP49Encryption.decrypt(payload: payload, password: password)

        guard let privateKey = NostrSDK.PrivateKey(hex: keyData.map { String(format: "%02x", $0) }.joined()) else {
            throw NIP49KeyExporterError.invalidPrivateKey
        }

        return privateKey
    }

    /// Decode an ncryptsec string, decrypt, and return both key and security metadata.
    ///
    /// - Parameters:
    ///   - ncryptsec: The bech32-encoded ncryptsec string.
    ///   - password: The decryption password.
    /// - Returns: Tuple of (privateKey, keySecurity).
    /// - Throws: ``NIP49KeyExporterError`` or ``NIP49EncryptionError``.
    public static func decodeWithMetadata(
        _ ncryptsec: String,
        password: String
    ) throws -> (privateKey: NostrSDK.PrivateKey, keySecurity: KeySecurity) {
        guard !password.isEmpty else {
            throw NIP49KeyExporterError.emptyPassword
        }

        let payload = try decodePayload(ncryptsec)
        let (keyData, keySecurity) = try NIP49Encryption.decrypt(payload: payload, password: password)

        let hex = keyData.map { String(format: "%02x", $0) }.joined()
        guard let privateKey = NostrSDK.PrivateKey(hex: hex) else {
            throw NIP49KeyExporterError.invalidPrivateKey
        }

        return (privateKey, keySecurity)
    }

    // MARK: - Payload Validation

    /// Decode bech32 and validate the NIP-49 payload structure without decrypting.
    ///
    /// Useful for UI validation (e.g. checking if a pasted string is a valid ncryptsec
    /// before prompting for a password).
    ///
    /// - Parameter ncryptsec: The bech32-encoded ncryptsec string.
    /// - Returns: `true` if the string is a structurally valid ncryptsec.
    public static func isValid(_ ncryptsec: String) -> Bool {
        do {
            _ = try decodePayload(ncryptsec)
            return true
        } catch {
            return false
        }
    }

    /// Extract metadata from an ncryptsec string without decrypting.
    ///
    /// - Parameter ncryptsec: The bech32-encoded ncryptsec string.
    /// - Returns: A tuple with `logN` and `keySecurity`.
    /// - Throws: ``NIP49KeyExporterError`` on invalid format.
    public static func inspectMetadata(_ ncryptsec: String) throws -> (logN: UInt8, keySecurity: KeySecurity) {
        let payload = try decodePayload(ncryptsec)
        let logN = payload[1]
        let keySecurityByte = payload[42]
        let keySecurity = KeySecurity(rawValue: keySecurityByte) ?? .unknown
        return (logN, keySecurity)
    }

    // MARK: - Internal

    /// Decode and validate the bech32 payload (HRP, length, version).
    private static func decodePayload(_ ncryptsec: String) throws -> Data {
        let (decodedHRP, payload): (String, Data)
        do {
            (decodedHRP, payload) = try Bech32Coder.decode(ncryptsec)
        } catch {
            throw NIP49KeyExporterError.decodingFailed(error.localizedDescription)
        }

        guard decodedHRP == hrp else {
            throw NIP49KeyExporterError.invalidHRP(decodedHRP)
        }

        guard payload.count == NIP49Encryption.payloadLength else {
            throw NIP49KeyExporterError.invalidPayloadLength(payload.count)
        }

        let version = payload[0]
        guard version == expectedVersion else {
            throw NIP49KeyExporterError.unsupportedVersion(version)
        }

        return payload
    }

    /// Convert a hex string to Data.
    private static func hexToData(_ hex: String) -> Data? {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var data = Data(capacity: chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[i...i+1]), radix: 16) else {
                return nil
            }
            data.append(byte)
        }
        return data
    }
}

// MARK: - KeyExporter Protocol

/// Protocol for exporting and importing Nostr private keys as ncryptsec strings.
///
/// Implementations bridge the identity store (which holds keys) with the
/// NIP-49 ncryptsec format (which encrypts keys for backup/transfer).
public protocol KeyExporter: Sendable {
    /// Export an identity's private key as a password-encrypted ncryptsec string.
    ///
    /// - Parameters:
    ///   - identityID: The UUID of the identity to export.
    ///   - password: The encryption password.
    /// - Returns: The bech32-encoded ncryptsec string.
    /// - Throws: On identity not found, store errors, or encryption errors.
    func exportNCryptsec(identityID: UUID, password: String) throws -> String

    /// Import a private key from an ncryptsec string and create an identity.
    ///
    /// - Parameters:
    ///   - ncryptsec: The bech32-encoded ncryptsec string.
    ///   - password: The decryption password.
    /// - Returns: The decrypted ``NostrSDK/PrivateKey``.
    /// - Throws: On decoding, decryption, or key validation errors.
    func importNCryptsec(_ ncryptsec: String, password: String) throws -> NostrSDK.PrivateKey
}
