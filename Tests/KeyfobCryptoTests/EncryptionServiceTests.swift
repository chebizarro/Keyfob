//
//  EncryptionServiceTests.swift
//
//
//  Created for Keyfob – kf-0qn
//

import XCTest
@testable import KeyfobCrypto
import NostrSDK

// MARK: - EncryptionServiceError Tests

final class EncryptionServiceErrorTests: XCTestCase {

    func testErrorEquatable() {
        XCTAssertEqual(
            EncryptionServiceError.invalidPeerPublicKey("short"),
            EncryptionServiceError.invalidPeerPublicKey("short")
        )
        XCTAssertNotEqual(
            EncryptionServiceError.invalidPeerPublicKey("aa"),
            EncryptionServiceError.invalidPeerPublicKey("bb")
        )
        XCTAssertEqual(
            EncryptionServiceError.invalidPrivateKey,
            EncryptionServiceError.invalidPrivateKey
        )
        XCTAssertEqual(
            EncryptionServiceError.nip44EncryptionFailed("err"),
            EncryptionServiceError.nip44EncryptionFailed("err")
        )
        XCTAssertEqual(
            EncryptionServiceError.nip44DecryptionFailed("err"),
            EncryptionServiceError.nip44DecryptionFailed("err")
        )
        XCTAssertEqual(
            EncryptionServiceError.nip04EncryptionFailed("err"),
            EncryptionServiceError.nip04EncryptionFailed("err")
        )
        XCTAssertEqual(
            EncryptionServiceError.nip04DecryptionFailed("err"),
            EncryptionServiceError.nip04DecryptionFailed("err")
        )
    }

    func testDifferentErrorCasesNotEqual() {
        XCTAssertNotEqual(
            EncryptionServiceError.nip44EncryptionFailed("x"),
            EncryptionServiceError.nip44DecryptionFailed("x")
        )
        XCTAssertNotEqual(
            EncryptionServiceError.nip04EncryptionFailed("x"),
            EncryptionServiceError.nip04DecryptionFailed("x")
        )
    }
}

// MARK: - Pubkey Validation Tests

final class EncryptionServiceValidationTests: XCTestCase {

    let service = EncryptionService()

    private func makeKeypair() -> NostrSDK.Keypair {
        guard let kp = NostrSDK.Keypair() else {
            fatalError("Could not generate test keypair")
        }
        return kp
    }

    func testRejectsShortPubkeyHex() {
        let kp = makeKeypair()
        XCTAssertThrowsError(
            try service.nip44Encrypt(plaintext: "hi", peerPubkeyHex: "aabb", using: kp)
        ) { error in
            guard case EncryptionServiceError.invalidPeerPublicKey(let pk) = error else {
                XCTFail("Expected invalidPeerPublicKey, got \(error)")
                return
            }
            XCTAssertEqual(pk, "aabb")
        }
    }

    func testRejectsNonHexCharacters() {
        let kp = makeKeypair()
        let invalidHex = String(repeating: "g", count: 64)
        XCTAssertThrowsError(
            try service.nip44Encrypt(plaintext: "hi", peerPubkeyHex: invalidHex, using: kp)
        ) { error in
            guard case EncryptionServiceError.invalidPeerPublicKey = error else {
                XCTFail("Expected invalidPeerPublicKey, got \(error)")
                return
            }
        }
    }

    func testRejectsUppercaseHex() {
        let kp = makeKeypair()
        // Valid 64-char hex but uppercase
        let upper = kp.publicKey.hex.uppercased()
        XCTAssertThrowsError(
            try service.nip44Encrypt(plaintext: "hi", peerPubkeyHex: upper, using: kp)
        ) { error in
            guard case EncryptionServiceError.invalidPeerPublicKey = error else {
                XCTFail("Expected invalidPeerPublicKey, got \(error)")
                return
            }
        }
    }

    func testRejectsEmptyString() {
        let kp = makeKeypair()
        XCTAssertThrowsError(
            try service.nip44Encrypt(plaintext: "hi", peerPubkeyHex: "", using: kp)
        ) { error in
            guard case EncryptionServiceError.invalidPeerPublicKey = error else {
                XCTFail("Expected invalidPeerPublicKey, got \(error)")
                return
            }
        }
    }

    func testRejectsTooLongHex() {
        let kp = makeKeypair()
        let tooLong = String(repeating: "a", count: 66)
        XCTAssertThrowsError(
            try service.nip44Encrypt(plaintext: "hi", peerPubkeyHex: tooLong, using: kp)
        ) { error in
            guard case EncryptionServiceError.invalidPeerPublicKey = error else {
                XCTFail("Expected invalidPeerPublicKey, got \(error)")
                return
            }
        }
    }
}

// MARK: - NIP-44 Round-Trip Tests

final class EncryptionServiceNIP44Tests: XCTestCase {

    let service = EncryptionService()

    private func makeKeypair() -> NostrSDK.Keypair {
        guard let kp = NostrSDK.Keypair() else {
            fatalError("Could not generate test keypair")
        }
        return kp
    }

    func testNIP44EncryptDecryptRoundTrip() throws {
        let alice = makeKeypair()
        let bob = makeKeypair()

        let plaintext = "Hello, Bob! This is a secret message."

        // Alice encrypts for Bob
        let ciphertext = try service.nip44Encrypt(
            plaintext: plaintext,
            peerPubkeyHex: bob.publicKey.hex,
            using: alice
        )

        // Ciphertext should be non-empty and different from plaintext
        XCTAssertFalse(ciphertext.isEmpty)
        XCTAssertNotEqual(ciphertext, plaintext)

        // Bob decrypts from Alice
        let decrypted = try service.nip44Decrypt(
            payload: ciphertext,
            peerPubkeyHex: alice.publicKey.hex,
            using: bob
        )

        XCTAssertEqual(decrypted, plaintext)
    }

    func testNIP44EncryptIsNonDeterministic() throws {
        let alice = makeKeypair()
        let bob = makeKeypair()
        let plaintext = "Same message encrypted twice"

        let ct1 = try service.nip44Encrypt(plaintext: plaintext, peerPubkeyHex: bob.publicKey.hex, using: alice)
        let ct2 = try service.nip44Encrypt(plaintext: plaintext, peerPubkeyHex: bob.publicKey.hex, using: alice)

        // Each encryption uses a random nonce, so outputs should differ
        XCTAssertNotEqual(ct1, ct2)

        // Both should decrypt to same plaintext
        let d1 = try service.nip44Decrypt(payload: ct1, peerPubkeyHex: alice.publicKey.hex, using: bob)
        let d2 = try service.nip44Decrypt(payload: ct2, peerPubkeyHex: alice.publicKey.hex, using: bob)
        XCTAssertEqual(d1, plaintext)
        XCTAssertEqual(d2, plaintext)
    }

    func testNIP44SymmetricKeyAgreement() throws {
        // Either party can decrypt what the other encrypted
        let alice = makeKeypair()
        let bob = makeKeypair()
        let plaintext = "Symmetric key agreement test"

        // Alice encrypts
        let ciphertext = try service.nip44Encrypt(plaintext: plaintext, peerPubkeyHex: bob.publicKey.hex, using: alice)

        // Alice can also decrypt her own message (she knows bob's pubkey + her own privkey)
        let decryptedByAlice = try service.nip44Decrypt(payload: ciphertext, peerPubkeyHex: bob.publicKey.hex, using: alice)
        XCTAssertEqual(decryptedByAlice, plaintext)

        // Bob decrypts (he knows alice's pubkey + his own privkey)
        let decryptedByBob = try service.nip44Decrypt(payload: ciphertext, peerPubkeyHex: alice.publicKey.hex, using: bob)
        XCTAssertEqual(decryptedByBob, plaintext)
    }

    func testNIP44EmptyPlaintext() {
        let alice = makeKeypair()
        let bob = makeKeypair()

        // NIP-44 spec requires plaintext length 1-65535, so empty should fail
        XCTAssertThrowsError(
            try service.nip44Encrypt(plaintext: "", peerPubkeyHex: bob.publicKey.hex, using: alice)
        ) { error in
            guard case EncryptionServiceError.nip44EncryptionFailed = error else {
                XCTFail("Expected nip44EncryptionFailed, got \(error)")
                return
            }
        }
    }

    func testNIP44UnicodeContent() throws {
        let alice = makeKeypair()
        let bob = makeKeypair()
        let plaintext = "🤙 Nostr is freedom! こんにちは 🌐"

        let ciphertext = try service.nip44Encrypt(plaintext: plaintext, peerPubkeyHex: bob.publicKey.hex, using: alice)
        let decrypted = try service.nip44Decrypt(payload: ciphertext, peerPubkeyHex: alice.publicKey.hex, using: bob)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testNIP44LongMessage() throws {
        let alice = makeKeypair()
        let bob = makeKeypair()
        // 1000 characters
        let plaintext = String(repeating: "abcdefghij", count: 100)

        let ciphertext = try service.nip44Encrypt(plaintext: plaintext, peerPubkeyHex: bob.publicKey.hex, using: alice)
        let decrypted = try service.nip44Decrypt(payload: ciphertext, peerPubkeyHex: alice.publicKey.hex, using: bob)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testNIP44DecryptWithWrongKeyFails() throws {
        let alice = makeKeypair()
        let bob = makeKeypair()
        let charlie = makeKeypair()

        let ciphertext = try service.nip44Encrypt(plaintext: "secret", peerPubkeyHex: bob.publicKey.hex, using: alice)

        // Charlie can't decrypt — wrong key pair
        XCTAssertThrowsError(
            try service.nip44Decrypt(payload: ciphertext, peerPubkeyHex: alice.publicKey.hex, using: charlie)
        ) { error in
            guard case EncryptionServiceError.nip44DecryptionFailed = error else {
                XCTFail("Expected nip44DecryptionFailed, got \(error)")
                return
            }
        }
    }

    func testNIP44DecryptTamperedPayloadFails() throws {
        let alice = makeKeypair()
        let bob = makeKeypair()

        let ciphertext = try service.nip44Encrypt(plaintext: "test", peerPubkeyHex: bob.publicKey.hex, using: alice)

        // Tamper with the ciphertext
        var tampered = ciphertext
        if let range = tampered.index(tampered.startIndex, offsetBy: 10, limitedBy: tampered.endIndex).map({ tampered.startIndex..<$0 }) {
            tampered = String(tampered[range]) + "AAAA" + String(tampered.dropFirst(14))
        }

        XCTAssertThrowsError(
            try service.nip44Decrypt(payload: tampered, peerPubkeyHex: alice.publicKey.hex, using: bob)
        )
    }
}

// MARK: - NIP-04 (Legacy) Round-Trip Tests

@available(*, deprecated)
final class EncryptionServiceNIP04Tests: XCTestCase {

    let service = EncryptionService()

    private func makeKeypair() -> NostrSDK.Keypair {
        guard let kp = NostrSDK.Keypair() else {
            fatalError("Could not generate test keypair")
        }
        return kp
    }

    func testNIP04EncryptDecryptRoundTrip() throws {
        let alice = makeKeypair()
        let bob = makeKeypair()
        let content = "Hello via NIP-04!"

        let encrypted = try service.nip04Encrypt(
            content: content,
            peerPubkeyHex: bob.publicKey.hex,
            using: alice
        )

        // NIP-04 format: base64?iv=base64
        XCTAssertTrue(encrypted.contains("?iv="), "NIP-04 ciphertext should contain ?iv= separator")

        let decrypted = try service.nip04Decrypt(
            encryptedContent: encrypted,
            peerPubkeyHex: alice.publicKey.hex,
            using: bob
        )

        XCTAssertEqual(decrypted, content)
    }

    func testNIP04SymmetricKeyAgreement() throws {
        let alice = makeKeypair()
        let bob = makeKeypair()
        let content = "NIP-04 symmetric test"

        let encrypted = try service.nip04Encrypt(content: content, peerPubkeyHex: bob.publicKey.hex, using: alice)

        // Alice can decrypt her own message
        let byAlice = try service.nip04Decrypt(encryptedContent: encrypted, peerPubkeyHex: bob.publicKey.hex, using: alice)
        XCTAssertEqual(byAlice, content)

        // Bob can decrypt
        let byBob = try service.nip04Decrypt(encryptedContent: encrypted, peerPubkeyHex: alice.publicKey.hex, using: bob)
        XCTAssertEqual(byBob, content)
    }

    func testNIP04RejectsInvalidPubkey() {
        let kp = makeKeypair()
        XCTAssertThrowsError(
            try service.nip04Encrypt(content: "hi", peerPubkeyHex: "short", using: kp)
        ) { error in
            guard case EncryptionServiceError.invalidPeerPublicKey = error else {
                XCTFail("Expected invalidPeerPublicKey, got \(error)")
                return
            }
        }
    }

    func testNIP04DecryptWithWrongKeyFails() throws {
        let alice = makeKeypair()
        let bob = makeKeypair()
        let charlie = makeKeypair()

        let encrypted = try service.nip04Encrypt(content: "secret", peerPubkeyHex: bob.publicKey.hex, using: alice)

        // Charlie can't decrypt
        XCTAssertThrowsError(
            try service.nip04Decrypt(encryptedContent: encrypted, peerPubkeyHex: alice.publicKey.hex, using: charlie)
        ) { error in
            guard case EncryptionServiceError.nip04DecryptionFailed = error else {
                XCTFail("Expected nip04DecryptionFailed, got \(error)")
                return
            }
        }
    }

    func testNIP04UnicodeContent() throws {
        let alice = makeKeypair()
        let bob = makeKeypair()
        let content = "🔑 Legacy encryption with unicode! 日本語テスト"

        let encrypted = try service.nip04Encrypt(content: content, peerPubkeyHex: bob.publicKey.hex, using: alice)
        let decrypted = try service.nip04Decrypt(encryptedContent: encrypted, peerPubkeyHex: alice.publicKey.hex, using: bob)
        XCTAssertEqual(decrypted, content)
    }
}

// MARK: - Cross-Protocol Tests

final class EncryptionServiceCrossProtocolTests: XCTestCase {

    let service = EncryptionService()

    private func makeKeypair() -> NostrSDK.Keypair {
        guard let kp = NostrSDK.Keypair() else {
            fatalError("Could not generate test keypair")
        }
        return kp
    }

    func testNIP44CiphertextCannotBeDecryptedByNIP04() throws {
        let alice = makeKeypair()
        let bob = makeKeypair()

        let nip44ct = try service.nip44Encrypt(plaintext: "test", peerPubkeyHex: bob.publicKey.hex, using: alice)

        // NIP-44 ciphertext should not be parseable as NIP-04
        XCTAssertThrowsError(
            try service.nip04Decrypt(encryptedContent: nip44ct, peerPubkeyHex: alice.publicKey.hex, using: bob)
        )
    }

    @available(*, deprecated)
    func testNIP04CiphertextCannotBeDecryptedByNIP44() throws {
        let alice = makeKeypair()
        let bob = makeKeypair()

        let nip04ct = try service.nip04Encrypt(content: "test", peerPubkeyHex: bob.publicKey.hex, using: alice)

        // NIP-04 ciphertext should not be parseable as NIP-44
        XCTAssertThrowsError(
            try service.nip44Decrypt(payload: nip04ct, peerPubkeyHex: alice.publicKey.hex, using: bob)
        )
    }
}
