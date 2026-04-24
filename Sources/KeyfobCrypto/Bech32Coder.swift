//
//  Bech32Coder.swift
//
//
//  Created for Keyfob – kf-3so
//
//  Minimal BIP-173 bech32 encoder/decoder for custom HRPs (e.g. "ncryptsec").
//  NostrSDK's Bech32 class is internal, so we need our own implementation.
//
//  Reference: https://github.com/bitcoin/bips/blob/master/bip-0173.mediawiki
//

import Foundation

// MARK: - Bech32CoderError

/// Errors from bech32 encoding/decoding operations.
public enum Bech32CoderError: Error, Equatable {
    /// The input string is empty or not valid UTF-8.
    case invalidInput
    /// Mixed case characters detected (bech32 requires uniform case).
    case mixedCase
    /// A character in the data part is not in the bech32 alphabet.
    case invalidCharacter
    /// No separator ('1') found in the string.
    case noSeparator
    /// The human-readable part is empty.
    case emptyHRP
    /// The data part is too short to contain a valid checksum.
    case dataTooShort
    /// The checksum does not match.
    case checksumMismatch
    /// The HRP does not match the expected value.
    case hrpMismatch(expected: String, got: String)
    /// Base-5 to base-8 conversion failed (invalid padding).
    case invalidPadding
}

// MARK: - Bech32Coder

/// A minimal bech32 encoder/decoder supporting arbitrary HRPs.
///
/// This is a self-contained implementation based on BIP-173. It does not
/// depend on NostrSDK's internal `Bech32` class.
///
/// ## Usage
///
/// ```swift
/// // Encode arbitrary data with a custom HRP
/// let encoded = try Bech32Coder.encode(hrp: "ncryptsec", data: payload)
///
/// // Decode and validate HRP
/// let (hrp, data) = try Bech32Coder.decode(encoded)
/// ```
public enum Bech32Coder {

    // MARK: - Constants

    /// The bech32 character set for encoding (maps 5-bit values to characters).
    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")

    /// Reverse lookup: ASCII value → 5-bit value (-1 = invalid).
    private static let charsetReverse: [Int8] = {
        var table = [Int8](repeating: -1, count: 128)
        for (i, c) in charset.enumerated() {
            table[Int(c.asciiValue!)] = Int8(i)
        }
        return table
    }()

    /// Generator polynomial coefficients for bech32 checksum.
    private static let generator: [UInt32] = [
        0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3
    ]

    // MARK: - Public API

    /// Encode data as a bech32 string with the given HRP.
    ///
    /// - Parameters:
    ///   - hrp: Human-readable part (e.g. "ncryptsec"). Will be lowercased.
    ///   - data: Raw bytes to encode.
    /// - Returns: The bech32-encoded string.
    public static func encode(hrp: String, data: Data) throws -> String {
        let hrp = hrp.lowercased()
        guard !hrp.isEmpty else { throw Bech32CoderError.emptyHRP }

        let base5 = convertBits(from: 8, to: 5, data: data, pad: true)
        let checksum = createChecksum(hrp: hrp, values: base5)

        var result = hrp + "1"
        for v in base5 + checksum {
            result.append(charset[Int(v)])
        }
        return result
    }

    /// Decode a bech32 string, returning the HRP and raw data bytes.
    ///
    /// - Parameter str: The bech32-encoded string.
    /// - Returns: A tuple of `(hrp, data)` where data is the decoded raw bytes.
    /// - Throws: ``Bech32CoderError`` on invalid input.
    public static func decode(_ str: String) throws -> (hrp: String, data: Data) {
        guard !str.isEmpty else { throw Bech32CoderError.invalidInput }

        // Check for mixed case
        let hasLower = str.contains(where: { $0.isLowercase })
        let hasUpper = str.contains(where: { $0.isUppercase })
        if hasLower && hasUpper {
            throw Bech32CoderError.mixedCase
        }

        let lowered = str.lowercased()

        // Find the last '1' separator
        guard let separatorIndex = lowered.lastIndex(of: "1") else {
            throw Bech32CoderError.noSeparator
        }

        let hrp = String(lowered[lowered.startIndex..<separatorIndex])
        guard !hrp.isEmpty else { throw Bech32CoderError.emptyHRP }

        let dataPartStart = lowered.index(after: separatorIndex)
        let dataPart = String(lowered[dataPartStart...])

        // Data part must have at least 6 characters for the checksum
        guard dataPart.count >= 6 else { throw Bech32CoderError.dataTooShort }

        // Decode data part from charset
        var base5Values = [UInt8]()
        base5Values.reserveCapacity(dataPart.count)
        for c in dataPart {
            guard let ascii = c.asciiValue, ascii < 128 else {
                throw Bech32CoderError.invalidCharacter
            }
            let value = charsetReverse[Int(ascii)]
            guard value >= 0 else {
                throw Bech32CoderError.invalidCharacter
            }
            base5Values.append(UInt8(value))
        }

        // Verify checksum
        guard verifyChecksum(hrp: hrp, values: Data(base5Values)) else {
            throw Bech32CoderError.checksumMismatch
        }

        // Strip the 6-byte checksum
        let payload5 = Array(base5Values.dropLast(6))

        // Convert from base-5 to base-8
        guard let decoded = convertBits(from: 5, to: 8, data: Data(payload5)) else {
            throw Bech32CoderError.invalidPadding
        }

        return (hrp, decoded)
    }

    /// Decode a bech32 string, validating that the HRP matches the expected value.
    ///
    /// - Parameters:
    ///   - str: The bech32-encoded string.
    ///   - expectedHRP: The expected human-readable part.
    /// - Returns: The decoded raw data bytes.
    /// - Throws: ``Bech32CoderError`` on invalid input or HRP mismatch.
    public static func decode(_ str: String, expectedHRP: String) throws -> Data {
        let (hrp, data) = try decode(str)
        guard hrp == expectedHRP.lowercased() else {
            throw Bech32CoderError.hrpMismatch(expected: expectedHRP.lowercased(), got: hrp)
        }
        return data
    }

    // MARK: - Checksum

    /// Polymod function for bech32 checksum calculation.
    private static func polymod(_ values: [UInt8]) -> UInt32 {
        var chk: UInt32 = 1
        for v in values {
            let top = chk >> 25
            chk = (chk & 0x1ffffff) << 5 ^ UInt32(v)
            for i in 0..<5 {
                if (top >> i) & 1 == 1 {
                    chk ^= generator[i]
                }
            }
        }
        return chk
    }

    /// Expand the HRP for use in checksum computation.
    private static func expandHRP(_ hrp: String) -> [UInt8] {
        var result = [UInt8]()
        result.reserveCapacity(hrp.count * 2 + 1)
        for c in hrp.utf8 {
            result.append(c >> 5)
        }
        result.append(0)
        for c in hrp.utf8 {
            result.append(c & 0x1f)
        }
        return result
    }

    /// Verify the bech32 checksum.
    private static func verifyChecksum(hrp: String, values: Data) -> Bool {
        let expanded = expandHRP(hrp)
        return polymod(expanded + Array(values)) == 1
    }

    /// Create a 6-byte bech32 checksum.
    private static func createChecksum(hrp: String, values: [UInt8]) -> [UInt8] {
        let data = expandHRP(hrp) + values + [0, 0, 0, 0, 0, 0]
        let mod = polymod(data) ^ 1
        var result = [UInt8](repeating: 0, count: 6)
        for i in 0..<6 {
            result[i] = UInt8((mod >> (5 * (5 - i))) & 31)
        }
        return result
    }

    // MARK: - Bit Conversion

    /// Convert data between bit groups (e.g. 8-bit to 5-bit with padding).
    /// Used for encoding: base-8 → base-5.
    private static func convertBits(from: Int, to: Int, data: Data, pad: Bool) -> [UInt8] {
        var acc: UInt32 = 0
        var bits = 0
        var result = [UInt8]()
        let maxV: UInt32 = (1 << to) - 1

        for value in data {
            acc = (acc << from) | UInt32(value)
            bits += from
            while bits >= to {
                bits -= to
                result.append(UInt8((acc >> bits) & maxV))
            }
        }

        if pad {
            if bits > 0 {
                result.append(UInt8((acc << (to - bits)) & maxV))
            }
        }

        return result
    }

    /// Convert data between bit groups without padding (strict mode).
    /// Used for decoding: base-5 → base-8. Returns nil on invalid padding.
    private static func convertBits(from: Int, to: Int, data: Data) -> Data? {
        var acc: UInt32 = 0
        var bits = 0
        var result = [UInt8]()
        let maxV: UInt32 = (1 << to) - 1

        for value in data {
            acc = (acc << from) | UInt32(value)
            bits += from
            while bits >= to {
                bits -= to
                result.append(UInt8((acc >> bits) & maxV))
            }
        }

        // Verify padding bits are zero
        if bits >= from {
            return nil
        }
        if ((acc << (to - bits)) & maxV) != 0 {
            return nil
        }

        return Data(result)
    }
}
