//
//  Bech32CoderTests.swift
//
//
//  Created for Keyfob – kf-3so
//

import XCTest
@testable import KeyfobCrypto

final class Bech32CoderTests: XCTestCase {

    // MARK: - Encoding Basic

    func testEncode_simpleData() throws {
        let data = Data([0x00, 0x01, 0x02, 0x03])
        let encoded = try Bech32Coder.encode(hrp: "test", data: data)
        XCTAssertTrue(encoded.hasPrefix("test1"))
        XCTAssertFalse(encoded.isEmpty)
    }

    func testEncode_emptyData() throws {
        let encoded = try Bech32Coder.encode(hrp: "test", data: Data())
        XCTAssertTrue(encoded.hasPrefix("test1"))
        // Should have HRP + separator + checksum only
    }

    func testEncode_emptyHRP_throws() {
        XCTAssertThrowsError(try Bech32Coder.encode(hrp: "", data: Data([0x01]))) { error in
            XCTAssertEqual(error as? Bech32CoderError, .emptyHRP)
        }
    }

    func testEncode_lowercasesHRP() throws {
        let data = Data([0xAB, 0xCD])
        let encoded = try Bech32Coder.encode(hrp: "TEST", data: data)
        XCTAssertTrue(encoded.hasPrefix("test1"))
    }

    // MARK: - Roundtrip

    func testRoundtrip_smallData() throws {
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let encoded = try Bech32Coder.encode(hrp: "abc", data: data)
        let (hrp, decoded) = try Bech32Coder.decode(encoded)
        XCTAssertEqual(hrp, "abc")
        XCTAssertEqual(decoded, data)
    }

    func testRoundtrip_32Bytes() throws {
        let data = Data((0..<32).map { UInt8($0) })
        let encoded = try Bech32Coder.encode(hrp: "npub", data: data)
        let (hrp, decoded) = try Bech32Coder.decode(encoded)
        XCTAssertEqual(hrp, "npub")
        XCTAssertEqual(decoded, data)
    }

    func testRoundtrip_91Bytes_ncryptsec() throws {
        // NIP-49 payload is 91 bytes
        let data = Data((0..<91).map { UInt8($0 % 256) })
        let encoded = try Bech32Coder.encode(hrp: "ncryptsec", data: data)
        XCTAssertTrue(encoded.hasPrefix("ncryptsec1"))
        let (hrp, decoded) = try Bech32Coder.decode(encoded)
        XCTAssertEqual(hrp, "ncryptsec")
        XCTAssertEqual(decoded, data)
    }

    func testRoundtrip_emptyData() throws {
        let encoded = try Bech32Coder.encode(hrp: "empty", data: Data())
        let (hrp, decoded) = try Bech32Coder.decode(encoded)
        XCTAssertEqual(hrp, "empty")
        XCTAssertEqual(decoded, Data())
    }

    func testRoundtrip_allZeros() throws {
        let data = Data(repeating: 0x00, count: 32)
        let encoded = try Bech32Coder.encode(hrp: "zeros", data: data)
        let (hrp, decoded) = try Bech32Coder.decode(encoded)
        XCTAssertEqual(hrp, "zeros")
        XCTAssertEqual(decoded, data)
    }

    func testRoundtrip_allOnes() throws {
        let data = Data(repeating: 0xFF, count: 32)
        let encoded = try Bech32Coder.encode(hrp: "ones", data: data)
        let (hrp, decoded) = try Bech32Coder.decode(encoded)
        XCTAssertEqual(hrp, "ones")
        XCTAssertEqual(decoded, data)
    }

    func testRoundtrip_longHRP() throws {
        let data = Data([0x42])
        let encoded = try Bech32Coder.encode(hrp: "averylonghumanreadablepart", data: data)
        let (hrp, decoded) = try Bech32Coder.decode(encoded)
        XCTAssertEqual(hrp, "averylonghumanreadablepart")
        XCTAssertEqual(decoded, data)
    }

    // MARK: - Decode with expected HRP

    func testDecode_withExpectedHRP() throws {
        let data = Data([0x01, 0x02, 0x03])
        let encoded = try Bech32Coder.encode(hrp: "ncryptsec", data: data)
        let decoded = try Bech32Coder.decode(encoded, expectedHRP: "ncryptsec")
        XCTAssertEqual(decoded, data)
    }

    func testDecode_withWrongHRP_throws() throws {
        let data = Data([0x01, 0x02, 0x03])
        let encoded = try Bech32Coder.encode(hrp: "ncryptsec", data: data)
        XCTAssertThrowsError(try Bech32Coder.decode(encoded, expectedHRP: "nsec")) { error in
            guard case Bech32CoderError.hrpMismatch(expected: "nsec", got: "ncryptsec") = error else {
                XCTFail("Expected hrpMismatch, got \(error)")
                return
            }
        }
    }

    // MARK: - Decoding Errors

    func testDecode_emptyString_throws() {
        XCTAssertThrowsError(try Bech32Coder.decode("")) { error in
            XCTAssertEqual(error as? Bech32CoderError, .invalidInput)
        }
    }

    func testDecode_noSeparator_throws() {
        XCTAssertThrowsError(try Bech32Coder.decode("noseparatorhere")) { error in
            XCTAssertEqual(error as? Bech32CoderError, .noSeparator)
        }
    }

    func testDecode_emptyHRP_throws() {
        // String starts with "1" → empty HRP
        XCTAssertThrowsError(try Bech32Coder.decode("1qqqqqq")) { error in
            XCTAssertEqual(error as? Bech32CoderError, .emptyHRP)
        }
    }

    func testDecode_tooShortData_throws() {
        // HRP + separator + less than 6 chars
        XCTAssertThrowsError(try Bech32Coder.decode("test1abc")) { error in
            XCTAssertEqual(error as? Bech32CoderError, .dataTooShort)
        }
    }

    func testDecode_invalidCharacter_throws() {
        // 'b' is valid, but '!' is not in bech32 charset
        XCTAssertThrowsError(try Bech32Coder.decode("test1!qqqqqq")) { error in
            XCTAssertEqual(error as? Bech32CoderError, .invalidCharacter)
        }
    }

    func testDecode_mixedCase_throws() {
        XCTAssertThrowsError(try Bech32Coder.decode("Test1qqqqqq")) { error in
            XCTAssertEqual(error as? Bech32CoderError, .mixedCase)
        }
    }

    func testDecode_corruptedChecksum_throws() throws {
        var encoded = try Bech32Coder.encode(hrp: "test", data: Data([0x01]))
        // Corrupt the last character
        let chars = Array(encoded)
        let lastChar = chars[chars.count - 1]
        let replacement: Character = lastChar == "q" ? "p" : "q"
        encoded = String(chars.dropLast()) + String(replacement)

        XCTAssertThrowsError(try Bech32Coder.decode(encoded)) { error in
            XCTAssertEqual(error as? Bech32CoderError, .checksumMismatch)
        }
    }

    // MARK: - Case Insensitivity

    func testDecode_uppercaseInput() throws {
        let data = Data([0x01, 0x02])
        let encoded = try Bech32Coder.encode(hrp: "test", data: data)
        let uppercased = encoded.uppercased()
        let (hrp, decoded) = try Bech32Coder.decode(uppercased)
        XCTAssertEqual(hrp, "test")
        XCTAssertEqual(decoded, data)
    }

    // MARK: - BIP-173 Test Vectors

    func testRoundtrip_variousSizes() throws {
        // Test various payload sizes to exercise padding edge cases
        for size in [1, 2, 3, 4, 5, 8, 16, 20, 32, 33, 64, 91, 100] {
            let data = Data((0..<size).map { UInt8($0 % 256) })
            let encoded = try Bech32Coder.encode(hrp: "test", data: data)
            let (_, decoded) = try Bech32Coder.decode(encoded)
            XCTAssertEqual(decoded, data, "Roundtrip failed for size \(size)")
        }
    }

    // MARK: - Determinism

    func testEncode_deterministic() throws {
        let data = Data([0xCA, 0xFE, 0xBA, 0xBE])
        let e1 = try Bech32Coder.encode(hrp: "det", data: data)
        let e2 = try Bech32Coder.encode(hrp: "det", data: data)
        XCTAssertEqual(e1, e2, "Bech32 encoding should be deterministic")
    }
}
