//
//  KeyImport.swift
//
//
//  Created for Keyfob – kf-dbn
//

import Foundation
import NostrSDK

// MARK: - KeyImportError

/// Errors from key import parsing and validation.
public enum KeyImportError: Error, Equatable {
    /// The input string is empty.
    case emptyInput
    /// The input looks like an nsec but could not be decoded.
    case invalidNsec
    /// The input looks like an npub but could not be decoded.
    case invalidNpub
    /// The input looks like hex but is not a valid private key.
    case invalidHexPrivateKey
    /// The input looks like hex but is not a valid public key.
    case invalidHexPublicKey
    /// The input does not match any recognized format.
    case unrecognizedFormat
    /// The input has a recognized bech32 prefix but the wrong one for the expected type.
    case wrongKeyType(expected: String, got: String)
}

// MARK: - KeyImportResult

/// The result of parsing a key import string.
public enum KeyImportResult: Equatable {
    /// A valid private key was parsed (can derive the full keypair).
    case privateKey(NostrSDK.PrivateKey)
    /// A valid public key was parsed (watch-only / contact reference).
    case publicKey(NostrSDK.PublicKey)

    public static func == (lhs: KeyImportResult, rhs: KeyImportResult) -> Bool {
        switch (lhs, rhs) {
        case (.privateKey(let a), .privateKey(let b)):
            return a.hex == b.hex
        case (.publicKey(let a), .publicKey(let b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - KeyImport

/// Parses and validates Nostr key strings in multiple formats.
///
/// Supports:
/// - **nsec**: Bech32-encoded private key (e.g. `nsec1abc...`)
/// - **npub**: Bech32-encoded public key (e.g. `npub1xyz...`)
/// - **hex**: 64-character lowercase hex string (private or public key)
///
/// The parser auto-detects the format from the input prefix and length.
///
/// ## Usage
///
/// ```swift
/// // Import a private key from any format
/// let privateKey = try KeyImport.parsePrivateKey("nsec1...")
///
/// // Import any key (private or public)
/// switch try KeyImport.parse("npub1...") {
/// case .privateKey(let pk): // full keypair available
/// case .publicKey(let pk):  // watch-only
/// }
/// ```
public enum KeyImport {

    // MARK: - Parse Any Key

    /// Parse a key string in any supported format.
    ///
    /// Auto-detects the format:
    /// - Strings starting with `nsec1` → private key (bech32)
    /// - Strings starting with `npub1` → public key (bech32)
    /// - 64-character hex strings → tried as private key first, then public key
    ///
    /// - Parameter input: The key string to parse (whitespace is trimmed).
    /// - Returns: A ``KeyImportResult`` indicating the key type and value.
    /// - Throws: ``KeyImportError`` with a specific reason on failure.
    public static func parse(_ input: String) throws -> KeyImportResult {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KeyImportError.emptyInput
        }

        let lowered = trimmed.lowercased()

        // Bech32 nsec
        if lowered.hasPrefix("nsec1") {
            guard let pk = NostrSDK.PrivateKey(nsec: lowered) else {
                throw KeyImportError.invalidNsec
            }
            return .privateKey(pk)
        }

        // Bech32 npub
        if lowered.hasPrefix("npub1") {
            guard let pk = NostrSDK.PublicKey(npub: lowered) else {
                throw KeyImportError.invalidNpub
            }
            return .publicKey(pk)
        }

        // Reject other bech32 prefixes with a helpful error
        if lowered.hasPrefix("nprofile1") || lowered.hasPrefix("nevent1") || lowered.hasPrefix("naddr1") || lowered.hasPrefix("note1") {
            throw KeyImportError.unrecognizedFormat
        }

        // 64-char hex → try as private key
        if lowered.count == 64 && lowered.allSatisfy({ $0.isHexDigit }) {
            if let pk = NostrSDK.PrivateKey(hex: lowered) {
                return .privateKey(pk)
            }
            // If it's valid hex but not a valid private key, try as public key
            if let pk = NostrSDK.PublicKey(hex: lowered) {
                return .publicKey(pk)
            }
            throw KeyImportError.invalidHexPrivateKey
        }

        throw KeyImportError.unrecognizedFormat
    }

    // MARK: - Parse Private Key Only

    /// Parse a private key string (nsec or hex).
    ///
    /// Rejects npub input with a clear error. Use this when you specifically
    /// need a private key (e.g. for identity import).
    ///
    /// - Parameter input: The key string to parse.
    /// - Returns: The parsed ``NostrSDK/PrivateKey``.
    /// - Throws: ``KeyImportError`` on failure.
    public static func parsePrivateKey(_ input: String) throws -> NostrSDK.PrivateKey {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KeyImportError.emptyInput
        }

        let lowered = trimmed.lowercased()

        // Reject npub with a helpful error
        if lowered.hasPrefix("npub1") {
            throw KeyImportError.wrongKeyType(expected: "nsec", got: "npub")
        }

        // nsec
        if lowered.hasPrefix("nsec1") {
            guard let pk = NostrSDK.PrivateKey(nsec: lowered) else {
                throw KeyImportError.invalidNsec
            }
            return pk
        }

        // 64-char hex
        if lowered.count == 64 && lowered.allSatisfy({ $0.isHexDigit }) {
            guard let pk = NostrSDK.PrivateKey(hex: lowered) else {
                throw KeyImportError.invalidHexPrivateKey
            }
            return pk
        }

        throw KeyImportError.unrecognizedFormat
    }

    // MARK: - Parse Public Key Only

    /// Parse a public key string (npub or hex).
    ///
    /// Rejects nsec input with a clear error. Use this when you specifically
    /// need a public key (e.g. for contact lookup or verification).
    ///
    /// - Parameter input: The key string to parse.
    /// - Returns: The parsed ``NostrSDK/PublicKey``.
    /// - Throws: ``KeyImportError`` on failure.
    public static func parsePublicKey(_ input: String) throws -> NostrSDK.PublicKey {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KeyImportError.emptyInput
        }

        let lowered = trimmed.lowercased()

        // Reject nsec with a helpful error
        if lowered.hasPrefix("nsec1") {
            throw KeyImportError.wrongKeyType(expected: "npub", got: "nsec")
        }

        // npub
        if lowered.hasPrefix("npub1") {
            guard let pk = NostrSDK.PublicKey(npub: lowered) else {
                throw KeyImportError.invalidNpub
            }
            return pk
        }

        // 64-char hex
        if lowered.count == 64 && lowered.allSatisfy({ $0.isHexDigit }) {
            guard let pk = NostrSDK.PublicKey(hex: lowered) else {
                throw KeyImportError.invalidHexPublicKey
            }
            return pk
        }

        throw KeyImportError.unrecognizedFormat
    }
}
