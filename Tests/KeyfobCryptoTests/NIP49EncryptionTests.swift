//
//  NIP49EncryptionTests.swift
//
//
//  Created for Keyfob – kf-q3r
//

import XCTest
@testable import KeyfobCrypto

// MARK: - HChaCha20 Tests

final class HChaCha20Tests: XCTestCase {

    /// Test vector from RFC 7539 / draft-irtf-cfrg-xchacha
    /// Key: 000102...1f, Nonce: 000000090000004a0000000031415927
    /// Expected subkey: 82413b4227b27bfed30e42508a877d73a0f9e4d58a74a853c12ec41326d3ecdc
    func testHChaCha20_rfcVector() {
        let key = Data((0..<32).map { UInt8($0) })
        let nonce = Data([
            0x00, 0x00, 0x00, 0x09,
            0x00, 0x00, 0x00, 0x4a,
            0x00, 0x00, 0x00, 0x00,
            0x31, 0x41, 0x59, 0x27
        ])

        let subkey = NIP49Encryption.hchacha20(key: key, nonce: nonce)
        XCTAssertEqual(subkey.count, 32)

        let expected = Data([
            0x82, 0x41, 0x3b, 0x42, 0x27, 0xb2, 0x7b, 0xfe,
            0xd3, 0x0e, 0x42, 0x50, 0x8a, 0x87, 0x7d, 0x73,
            0xa0, 0xf9, 0xe4, 0xd5, 0x8a, 0x74, 0xa8, 0x53,
            0xc1, 0x2e, 0xc4, 0x13, 0x26, 0xd3, 0xec, 0xdc
        ])
        XCTAssertEqual(subkey, expected)
    }

    func testHChaCha20_outputLength() {
        let key = Data(repeating: 0xAB, count: 32)
        let nonce = Data(repeating: 0xCD, count: 16)
        let subkey = NIP49Encryption.hchacha20(key: key, nonce: nonce)
        XCTAssertEqual(subkey.count, 32)
    }

    func testHChaCha20_differentInputsProduceDifferentOutputs() {
        let key1 = Data(repeating: 0x01, count: 32)
        let key2 = Data(repeating: 0x02, count: 32)
        let nonce = Data(repeating: 0x00, count: 16)

        let sub1 = NIP49Encryption.hchacha20(key: key1, nonce: nonce)
        let sub2 = NIP49Encryption.hchacha20(key: key2, nonce: nonce)
        XCTAssertNotEqual(sub1, sub2)
    }
}

// MARK: - XChaCha20-Poly1305 Tests

final class XChaCha20Poly1305Tests: XCTestCase {

    func testRoundTrip() throws {
        let key = Data(repeating: 0x42, count: 32)
        let nonce = Data(repeating: 0x13, count: 24)
        let plaintext = Data("Hello, XChaCha20-Poly1305!".utf8)
        let aad = Data([0x01])

        let ciphertext = try NIP49Encryption.xchacha20Poly1305Encrypt(
            key: key, nonce: nonce, plaintext: plaintext, aad: aad
        )

        // Ciphertext should be plaintext + 16 bytes tag
        XCTAssertEqual(ciphertext.count, plaintext.count + 16)

        let decrypted = try NIP49Encryption.xchacha20Poly1305Decrypt(
            key: key, nonce: nonce, ciphertext: ciphertext, aad: aad
        )
        XCTAssertEqual(decrypted, plaintext)
    }

    func testWrongKey_fails() throws {
        let key = Data(repeating: 0x42, count: 32)
        let wrongKey = Data(repeating: 0x43, count: 32)
        let nonce = Data(repeating: 0x00, count: 24)
        let plaintext = Data("secret".utf8)
        let aad = Data([0x00])

        let ciphertext = try NIP49Encryption.xchacha20Poly1305Encrypt(
            key: key, nonce: nonce, plaintext: plaintext, aad: aad
        )

        XCTAssertThrowsError(try NIP49Encryption.xchacha20Poly1305Decrypt(
            key: wrongKey, nonce: nonce, ciphertext: ciphertext, aad: aad
        ))
    }

    func testWrongAAD_fails() throws {
        let key = Data(repeating: 0x42, count: 32)
        let nonce = Data(repeating: 0x00, count: 24)
        let plaintext = Data("secret".utf8)
        let aad = Data([0x01])

        let ciphertext = try NIP49Encryption.xchacha20Poly1305Encrypt(
            key: key, nonce: nonce, plaintext: plaintext, aad: aad
        )

        XCTAssertThrowsError(try NIP49Encryption.xchacha20Poly1305Decrypt(
            key: key, nonce: nonce, ciphertext: ciphertext, aad: Data([0x02])
        ))
    }

    func testTruncatedCiphertext_fails() {
        let key = Data(repeating: 0x42, count: 32)
        let nonce = Data(repeating: 0x00, count: 24)

        XCTAssertThrowsError(try NIP49Encryption.xchacha20Poly1305Decrypt(
            key: key, nonce: nonce, ciphertext: Data([0x01, 0x02, 0x03]), aad: Data()
        ))
    }
}

// MARK: - scrypt Key Derivation Tests

final class ScryptDerivationTests: XCTestCase {

    func testDeriveKey_produces32Bytes() throws {
        // Use low logN for test speed
        let key = try NIP49Encryption.deriveKey(
            password: "testpassword",
            salt: Data(repeating: 0xAA, count: 16),
            logN: 2 // Very low for speed
        )
        XCTAssertEqual(key.count, 32)
    }

    func testDeriveKey_deterministic() throws {
        let salt = Data(repeating: 0xBB, count: 16)
        let key1 = try NIP49Encryption.deriveKey(password: "same", salt: salt, logN: 2)
        let key2 = try NIP49Encryption.deriveKey(password: "same", salt: salt, logN: 2)
        XCTAssertEqual(key1, key2)
    }

    func testDeriveKey_differentPasswordsDifferentKeys() throws {
        let salt = Data(repeating: 0xCC, count: 16)
        let key1 = try NIP49Encryption.deriveKey(password: "pass1", salt: salt, logN: 2)
        let key2 = try NIP49Encryption.deriveKey(password: "pass2", salt: salt, logN: 2)
        XCTAssertNotEqual(key1, key2)
    }

    func testDeriveKey_differentSaltsDifferentKeys() throws {
        let salt1 = Data(repeating: 0x01, count: 16)
        let salt2 = Data(repeating: 0x02, count: 16)
        let key1 = try NIP49Encryption.deriveKey(password: "same", salt: salt1, logN: 2)
        let key2 = try NIP49Encryption.deriveKey(password: "same", salt: salt2, logN: 2)
        XCTAssertNotEqual(key1, key2)
    }
}

// MARK: - NIP-49 Full Encrypt/Decrypt Tests

final class NIP49FullTests: XCTestCase {

    private let testPrivateKey = Data(repeating: 0x42, count: 32)
    private let testPassword = "correct horse battery staple"

    // Use low logN for test speed (production uses 16).
    private func encrypt(
        key: Data? = nil,
        password: String? = nil,
        logN: UInt8 = 2,
        keySecurity: KeySecurity = .unknown
    ) throws -> Data {
        try NIP49Encryption.encrypt(
            privateKeyBytes: key ?? testPrivateKey,
            password: password ?? testPassword,
            logN: logN,
            keySecurity: keySecurity
        )
    }

    func testEncrypt_producesCorrectLength() throws {
        let payload = try encrypt()
        XCTAssertEqual(payload.count, NIP49Encryption.payloadLength)
        XCTAssertEqual(payload.count, 91)
    }

    func testEncrypt_versionByte() throws {
        let payload = try encrypt()
        XCTAssertEqual(payload[0], 0x02)
    }

    func testEncrypt_logNByte() throws {
        let payload = try encrypt(logN: 5)
        XCTAssertEqual(payload[1], 5)
    }

    func testEncrypt_keySecurityByte() throws {
        let payload0 = try encrypt(keySecurity: .unknown)
        XCTAssertEqual(payload0[42], 0x00)

        let payload1 = try encrypt(keySecurity: .known)
        XCTAssertEqual(payload1[42], 0x01)

        let payload2 = try encrypt(keySecurity: .generated)
        XCTAssertEqual(payload2[42], 0x02)
    }

    func testEncrypt_nonDeterministic() throws {
        let a = try encrypt()
        let b = try encrypt()
        // Different random salt + nonce → different payloads
        XCTAssertNotEqual(a, b)
    }

    func testDecrypt_roundTrip() throws {
        let payload = try encrypt()
        let (decrypted, security) = try NIP49Encryption.decrypt(
            payload: payload, password: testPassword
        )
        XCTAssertEqual(decrypted, testPrivateKey)
        XCTAssertEqual(security, .unknown)
    }

    func testDecrypt_roundTrip_knownSecurity() throws {
        let payload = try encrypt(keySecurity: .known)
        let (decrypted, security) = try NIP49Encryption.decrypt(
            payload: payload, password: testPassword
        )
        XCTAssertEqual(decrypted, testPrivateKey)
        XCTAssertEqual(security, .known)
    }

    func testDecrypt_roundTrip_generatedSecurity() throws {
        let payload = try encrypt(keySecurity: .generated)
        let (_, security) = try NIP49Encryption.decrypt(
            payload: payload, password: testPassword
        )
        XCTAssertEqual(security, .generated)
    }

    func testDecrypt_wrongPassword_fails() throws {
        let payload = try encrypt()
        XCTAssertThrowsError(try NIP49Encryption.decrypt(
            payload: payload, password: "wrong password"
        )) { error in
            XCTAssertEqual(error as? NIP49EncryptionError, .decryptionFailed)
        }
    }

    func testDecrypt_wrongVersion_fails() throws {
        var payload = try encrypt()
        payload[0] = 0x01 // Wrong version
        XCTAssertThrowsError(try NIP49Encryption.decrypt(
            payload: payload, password: testPassword
        )) { error in
            XCTAssertEqual(error as? NIP49EncryptionError, .invalidVersion(0x01))
        }
    }

    func testDecrypt_truncatedPayload_fails() {
        let shortPayload = Data(repeating: 0, count: 50)
        XCTAssertThrowsError(try NIP49Encryption.decrypt(
            payload: shortPayload, password: testPassword
        )) { error in
            XCTAssertEqual(error as? NIP49EncryptionError, .invalidPayloadLength(50))
        }
    }

    func testDecrypt_tooLongPayload_fails() {
        let longPayload = Data(repeating: 0, count: 100)
        XCTAssertThrowsError(try NIP49Encryption.decrypt(
            payload: longPayload, password: testPassword
        )) { error in
            XCTAssertEqual(error as? NIP49EncryptionError, .invalidPayloadLength(100))
        }
    }

    func testEncrypt_invalidKeyLength_fails() {
        XCTAssertThrowsError(try NIP49Encryption.encrypt(
            privateKeyBytes: Data(repeating: 0, count: 16),
            password: "pass"
        )) { error in
            XCTAssertEqual(error as? NIP49EncryptionError, .invalidPrivateKeyLength(16))
        }
    }

    func testEncrypt_emptyPassword_fails() {
        XCTAssertThrowsError(try NIP49Encryption.encrypt(
            privateKeyBytes: testPrivateKey,
            password: ""
        )) { error in
            XCTAssertEqual(error as? NIP49EncryptionError, .invalidPassword)
        }
    }

    func testDecrypt_emptyPassword_fails() throws {
        let payload = try encrypt()
        XCTAssertThrowsError(try NIP49Encryption.decrypt(
            payload: payload, password: ""
        )) { error in
            XCTAssertEqual(error as? NIP49EncryptionError, .invalidPassword)
        }
    }

    func testEncrypt_differentKeySamePassword() throws {
        let key1 = Data(repeating: 0x11, count: 32)
        let key2 = Data(repeating: 0x22, count: 32)

        let payload1 = try encrypt(key: key1)
        let payload2 = try encrypt(key: key2)

        let (d1, _) = try NIP49Encryption.decrypt(payload: payload1, password: testPassword)
        let (d2, _) = try NIP49Encryption.decrypt(payload: payload2, password: testPassword)

        XCTAssertEqual(d1, key1)
        XCTAssertEqual(d2, key2)
    }

    func testRoundTrip_unicodePassword() throws {
        let password = "pässwörd 🔑 日本語"
        let payload = try NIP49Encryption.encrypt(
            privateKeyBytes: testPrivateKey,
            password: password,
            logN: 2
        )
        let (decrypted, _) = try NIP49Encryption.decrypt(
            payload: payload, password: password
        )
        XCTAssertEqual(decrypted, testPrivateKey)
    }

    func testRoundTrip_longPassword() throws {
        let password = String(repeating: "a", count: 1000)
        let payload = try NIP49Encryption.encrypt(
            privateKeyBytes: testPrivateKey,
            password: password,
            logN: 2
        )
        let (decrypted, _) = try NIP49Encryption.decrypt(
            payload: payload, password: password
        )
        XCTAssertEqual(decrypted, testPrivateKey)
    }

    func testPayloadStructure() throws {
        let payload = try encrypt(logN: 3, keySecurity: .generated)

        // Verify structure: version(1) + logN(1) + salt(16) + nonce(24) + keySec(1) + encrypted(48)
        XCTAssertEqual(payload[0], 0x02)       // version
        XCTAssertEqual(payload[1], 3)          // logN
        XCTAssertEqual(payload[42], 0x02)      // keySecurity = .generated

        // Salt = bytes 2..17 (16 bytes)
        // Nonce = bytes 18..41 (24 bytes)
        // Encrypted = bytes 43..90 (48 bytes)
        XCTAssertEqual(payload.count, 1 + 1 + 16 + 24 + 1 + 48)
    }
}

// MARK: - KeySecurity Tests

final class KeySecurityTests: XCTestCase {

    func testRawValues() {
        XCTAssertEqual(KeySecurity.unknown.rawValue, 0x00)
        XCTAssertEqual(KeySecurity.known.rawValue, 0x01)
        XCTAssertEqual(KeySecurity.generated.rawValue, 0x02)
    }

    func testCodableRoundTrip() throws {
        for sec in [KeySecurity.unknown, .known, .generated] {
            let data = try JSONEncoder().encode(sec)
            let decoded = try JSONDecoder().decode(KeySecurity.self, from: data)
            XCTAssertEqual(sec, decoded)
        }
    }
}
