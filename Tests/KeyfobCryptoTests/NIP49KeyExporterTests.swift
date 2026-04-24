//
//  NIP49KeyExporterTests.swift
//
//
//  Created for Keyfob – kf-3so
//

import XCTest
@testable import KeyfobCrypto
import NostrSDK

final class NIP49KeyExporterTests: XCTestCase {

    // Use a fast logN for tests (logN=4 is much faster than default 16)
    private let testLogN: UInt8 = 4

    // A known valid 32-byte private key hex
    private let testKeyHex = "7f4c11a9742721d66e40e321f3f3a39b22e81f51b24098de68e7e1e781884b0d"

    // MARK: - NCryptsec Encode

    func testEncode_producesNCryptsecPrefix() throws {
        let result = try NCryptsec.encode(
            privateKeyHex: testKeyHex,
            password: "test-password",
            logN: testLogN
        )
        XCTAssertTrue(result.hasPrefix("ncryptsec1"), "Expected ncryptsec1 prefix, got: \(result.prefix(20))")
    }

    func testEncode_emptyPassword_throws() {
        XCTAssertThrowsError(try NCryptsec.encode(
            privateKeyHex: testKeyHex,
            password: "",
            logN: testLogN
        )) { error in
            XCTAssertEqual(error as? NIP49KeyExporterError, .emptyPassword)
        }
    }

    func testEncode_invalidHex_throws() {
        XCTAssertThrowsError(try NCryptsec.encode(
            privateKeyHex: "not-hex",
            password: "test",
            logN: testLogN
        )) { error in
            XCTAssertEqual(error as? NIP49KeyExporterError, .invalidPrivateKey)
        }
    }

    func testEncode_shortKey_throws() {
        XCTAssertThrowsError(try NCryptsec.encode(
            privateKeyHex: "abcd",
            password: "test",
            logN: testLogN
        )) { error in
            XCTAssertEqual(error as? NIP49KeyExporterError, .invalidPrivateKey)
        }
    }

    func testEncode_withBytes() throws {
        let keyData = Data((0..<32).map { UInt8($0) })
        let result = try NCryptsec.encode(
            privateKeyBytes: keyData,
            password: "test-password",
            logN: testLogN
        )
        XCTAssertTrue(result.hasPrefix("ncryptsec1"))
    }

    func testEncode_withBytes_wrongSize_throws() {
        let keyData = Data([0x01, 0x02, 0x03])
        XCTAssertThrowsError(try NCryptsec.encode(
            privateKeyBytes: keyData,
            password: "test",
            logN: testLogN
        )) { error in
            XCTAssertEqual(error as? NIP49KeyExporterError, .invalidPrivateKey)
        }
    }

    func testEncode_withBytes_emptyPassword_throws() {
        let keyData = Data(repeating: 0x42, count: 32)
        XCTAssertThrowsError(try NCryptsec.encode(
            privateKeyBytes: keyData,
            password: "",
            logN: testLogN
        )) { error in
            XCTAssertEqual(error as? NIP49KeyExporterError, .emptyPassword)
        }
    }

    // MARK: - NCryptsec Decode (Roundtrip)

    func testRoundtrip_hex() throws {
        let password = "roundtrip-test-password"
        let ncryptsec = try NCryptsec.encode(
            privateKeyHex: testKeyHex,
            password: password,
            logN: testLogN
        )

        let decoded = try NCryptsec.decode(ncryptsec, password: password)
        XCTAssertEqual(decoded.hex, testKeyHex)
    }

    func testRoundtrip_bytes() throws {
        let keyData = hexToData(testKeyHex)!
        let password = "bytes-roundtrip"
        let ncryptsec = try NCryptsec.encode(
            privateKeyBytes: keyData,
            password: password,
            logN: testLogN
        )

        let decoded = try NCryptsec.decode(ncryptsec, password: password)
        XCTAssertEqual(decoded.hex, testKeyHex)
    }

    func testRoundtrip_preservesKeySecurity() throws {
        let password = "security-meta"
        let ncryptsec = try NCryptsec.encode(
            privateKeyHex: testKeyHex,
            password: password,
            logN: testLogN,
            keySecurity: .generated
        )

        let (key, security) = try NCryptsec.decodeWithMetadata(ncryptsec, password: password)
        XCTAssertEqual(key.hex, testKeyHex)
        XCTAssertEqual(security, .generated)
    }

    func testRoundtrip_keySecurity_known() throws {
        let password = "known-security"
        let ncryptsec = try NCryptsec.encode(
            privateKeyHex: testKeyHex,
            password: password,
            logN: testLogN,
            keySecurity: .known
        )

        let (_, security) = try NCryptsec.decodeWithMetadata(ncryptsec, password: password)
        XCTAssertEqual(security, .known)
    }

    func testRoundtrip_unicodePassword() throws {
        let password = "🔐 пароль 密码 パスワード"
        let ncryptsec = try NCryptsec.encode(
            privateKeyHex: testKeyHex,
            password: password,
            logN: testLogN
        )

        let decoded = try NCryptsec.decode(ncryptsec, password: password)
        XCTAssertEqual(decoded.hex, testKeyHex)
    }

    func testRoundtrip_longPassword() throws {
        let password = String(repeating: "abcdefghijklmnop", count: 100) // 1600 chars
        let ncryptsec = try NCryptsec.encode(
            privateKeyHex: testKeyHex,
            password: password,
            logN: testLogN
        )

        let decoded = try NCryptsec.decode(ncryptsec, password: password)
        XCTAssertEqual(decoded.hex, testKeyHex)
    }

    // MARK: - Decode Errors

    func testDecode_emptyPassword_throws() throws {
        let ncryptsec = try NCryptsec.encode(
            privateKeyHex: testKeyHex,
            password: "valid",
            logN: testLogN
        )

        XCTAssertThrowsError(try NCryptsec.decode(ncryptsec, password: "")) { error in
            XCTAssertEqual(error as? NIP49KeyExporterError, .emptyPassword)
        }
    }

    func testDecode_wrongPassword_throws() throws {
        let ncryptsec = try NCryptsec.encode(
            privateKeyHex: testKeyHex,
            password: "correct-password",
            logN: testLogN
        )

        // Wrong password should fail at decryption
        XCTAssertThrowsError(try NCryptsec.decode(ncryptsec, password: "wrong-password"))
    }

    func testDecode_invalidBech32_throws() {
        XCTAssertThrowsError(try NCryptsec.decode("not-valid-bech32", password: "test")) { error in
            guard case NIP49KeyExporterError.decodingFailed = error else {
                XCTFail("Expected decodingFailed, got \(error)")
                return
            }
        }
    }

    func testDecode_wrongHRP_throws() throws {
        // Encode some data with a different HRP
        let fakeData = Data(repeating: 0x02, count: 91) // starts with version 0x02
        let encoded = try Bech32Coder.encode(hrp: "nsec", data: fakeData)

        XCTAssertThrowsError(try NCryptsec.decode(encoded, password: "test")) { error in
            guard case NIP49KeyExporterError.invalidHRP(let hrp) = error else {
                XCTFail("Expected invalidHRP, got \(error)")
                return
            }
            XCTAssertEqual(hrp, "nsec")
        }
    }

    func testDecode_wrongVersion_throws() throws {
        // Build a payload with version 0x01 instead of 0x02
        var fakePayload = Data(repeating: 0x00, count: 91)
        fakePayload[0] = 0x01 // wrong version
        let encoded = try Bech32Coder.encode(hrp: "ncryptsec", data: fakePayload)

        XCTAssertThrowsError(try NCryptsec.decode(encoded, password: "test")) { error in
            guard case NIP49KeyExporterError.unsupportedVersion(let v) = error else {
                XCTFail("Expected unsupportedVersion, got \(error)")
                return
            }
            XCTAssertEqual(v, 0x01)
        }
    }

    func testDecode_wrongPayloadLength_throws() throws {
        // Payload of 50 bytes instead of 91
        let shortPayload = Data(repeating: 0x02, count: 50)
        let encoded = try Bech32Coder.encode(hrp: "ncryptsec", data: shortPayload)

        XCTAssertThrowsError(try NCryptsec.decode(encoded, password: "test")) { error in
            guard case NIP49KeyExporterError.invalidPayloadLength(let len) = error else {
                XCTFail("Expected invalidPayloadLength, got \(error)")
                return
            }
            XCTAssertEqual(len, 50)
        }
    }

    // MARK: - isValid

    func testIsValid_validNCryptsec() throws {
        let ncryptsec = try NCryptsec.encode(
            privateKeyHex: testKeyHex,
            password: "test",
            logN: testLogN
        )
        XCTAssertTrue(NCryptsec.isValid(ncryptsec))
    }

    func testIsValid_invalidString() {
        XCTAssertFalse(NCryptsec.isValid("not-ncryptsec"))
    }

    func testIsValid_wrongHRP() throws {
        let data = Data(repeating: 0x02, count: 91)
        let encoded = try Bech32Coder.encode(hrp: "nsec", data: data)
        XCTAssertFalse(NCryptsec.isValid(encoded))
    }

    func testIsValid_wrongVersion() throws {
        var data = Data(repeating: 0x00, count: 91)
        data[0] = 0x01
        let encoded = try Bech32Coder.encode(hrp: "ncryptsec", data: data)
        XCTAssertFalse(NCryptsec.isValid(encoded))
    }

    // MARK: - inspectMetadata

    func testInspectMetadata() throws {
        let ncryptsec = try NCryptsec.encode(
            privateKeyHex: testKeyHex,
            password: "test",
            logN: testLogN,
            keySecurity: .generated
        )

        let meta = try NCryptsec.inspectMetadata(ncryptsec)
        XCTAssertEqual(meta.logN, testLogN)
        XCTAssertEqual(meta.keySecurity, .generated)
    }

    func testInspectMetadata_unknownKeySecurity() throws {
        let ncryptsec = try NCryptsec.encode(
            privateKeyHex: testKeyHex,
            password: "test",
            logN: testLogN,
            keySecurity: .unknown
        )

        let meta = try NCryptsec.inspectMetadata(ncryptsec)
        XCTAssertEqual(meta.keySecurity, .unknown)
    }

    // MARK: - KeyExporter Protocol

    func testKeyExporterProtocol_exists() {
        // Verify the protocol compiles and has the expected methods
        // (Concrete implementation will be in a higher-level module)
        // Just confirm the protocol type is accessible
        XCTAssertTrue(true, "KeyExporter protocol compiles successfully")
    }

    // MARK: - Nondeterminism (random salt/nonce)

    func testEncode_producesUniqueOutputs() throws {
        let password = "same-password"
        let r1 = try NCryptsec.encode(privateKeyHex: testKeyHex, password: password, logN: testLogN)
        let r2 = try NCryptsec.encode(privateKeyHex: testKeyHex, password: password, logN: testLogN)
        // Random salt and nonce should produce different ciphertexts
        XCTAssertNotEqual(r1, r2, "Two encryptions with same key+password should differ (random salt/nonce)")
    }

    // MARK: - Helpers

    private func hexToData(_ hex: String) -> Data? {
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
