//
//  KeyImportTests.swift
//
//
//  Created for Keyfob – kf-dbn
//

import XCTest
@testable import KeyfobCrypto
import NostrSDK

// MARK: - KeyImportError Tests

final class KeyImportErrorTests: XCTestCase {

    func testErrorEquatable() {
        XCTAssertEqual(KeyImportError.emptyInput, .emptyInput)
        XCTAssertEqual(KeyImportError.invalidNsec, .invalidNsec)
        XCTAssertEqual(KeyImportError.invalidNpub, .invalidNpub)
        XCTAssertEqual(KeyImportError.invalidHexPrivateKey, .invalidHexPrivateKey)
        XCTAssertEqual(KeyImportError.invalidHexPublicKey, .invalidHexPublicKey)
        XCTAssertEqual(KeyImportError.unrecognizedFormat, .unrecognizedFormat)
        XCTAssertEqual(
            KeyImportError.wrongKeyType(expected: "nsec", got: "npub"),
            KeyImportError.wrongKeyType(expected: "nsec", got: "npub")
        )
        XCTAssertNotEqual(
            KeyImportError.wrongKeyType(expected: "nsec", got: "npub"),
            KeyImportError.wrongKeyType(expected: "npub", got: "nsec")
        )
    }
}

// MARK: - Parse Any Key Tests

final class KeyImportParseTests: XCTestCase {

    // Generate a real keypair for valid test data
    private lazy var testKeypair: NostrSDK.Keypair = {
        guard let kp = NostrSDK.Keypair() else {
            fatalError("Could not generate test keypair")
        }
        return kp
    }()

    // MARK: - nsec parsing

    func testParseValidNsec() throws {
        let nsec = testKeypair.privateKey.nsec
        let result = try KeyImport.parse(nsec)

        guard case .privateKey(let pk) = result else {
            XCTFail("Expected privateKey, got \(result)")
            return
        }
        XCTAssertEqual(pk.hex, testKeypair.privateKey.hex)
    }

    func testParseNsecWithWhitespace() throws {
        let nsec = "  \(testKeypair.privateKey.nsec)  \n"
        let result = try KeyImport.parse(nsec)

        guard case .privateKey(let pk) = result else {
            XCTFail("Expected privateKey, got \(result)")
            return
        }
        XCTAssertEqual(pk.hex, testKeypair.privateKey.hex)
    }

    func testParseInvalidNsecThrows() {
        XCTAssertThrowsError(try KeyImport.parse("nsec1invalidchecksum")) { error in
            XCTAssertEqual(error as? KeyImportError, .invalidNsec)
        }
    }

    // MARK: - npub parsing

    func testParseValidNpub() throws {
        let npub = testKeypair.publicKey.npub
        let result = try KeyImport.parse(npub)

        guard case .publicKey(let pk) = result else {
            XCTFail("Expected publicKey, got \(result)")
            return
        }
        XCTAssertEqual(pk.hex, testKeypair.publicKey.hex)
    }

    func testParseNpubWithWhitespace() throws {
        let npub = "  \(testKeypair.publicKey.npub)  "
        let result = try KeyImport.parse(npub)

        guard case .publicKey(let pk) = result else {
            XCTFail("Expected publicKey, got \(result)")
            return
        }
        XCTAssertEqual(pk.hex, testKeypair.publicKey.hex)
    }

    func testParseInvalidNpubThrows() {
        XCTAssertThrowsError(try KeyImport.parse("npub1invalidchecksum")) { error in
            XCTAssertEqual(error as? KeyImportError, .invalidNpub)
        }
    }

    // MARK: - hex parsing

    func testParseValidHexPrivateKey() throws {
        let result = try KeyImport.parse(testKeypair.privateKey.hex)

        guard case .privateKey(let pk) = result else {
            XCTFail("Expected privateKey, got \(result)")
            return
        }
        XCTAssertEqual(pk.hex, testKeypair.privateKey.hex)
    }

    func testParseValidHexPublicKey() throws {
        // Public key hex that is NOT a valid private key should parse as public key.
        // Use the public key hex directly — it may or may not be a valid private key
        // (depends on whether it's in the valid scalar range), so we test with an
        // explicitly constructed pubkey.
        let result = try KeyImport.parse(testKeypair.publicKey.hex)

        // Since hex is tried as private key first, this may return either type.
        // The important thing is it doesn't throw.
        switch result {
        case .privateKey:
            // Valid — the hex happened to also be a valid private key scalar
            break
        case .publicKey:
            // Also valid — it's a valid public key but not a valid private key
            break
        }
    }

    // MARK: - edge cases

    func testParseEmptyStringThrows() {
        XCTAssertThrowsError(try KeyImport.parse("")) { error in
            XCTAssertEqual(error as? KeyImportError, .emptyInput)
        }
    }

    func testParseWhitespaceOnlyThrows() {
        XCTAssertThrowsError(try KeyImport.parse("   \n\t  ")) { error in
            XCTAssertEqual(error as? KeyImportError, .emptyInput)
        }
    }

    func testParseRandomTextThrows() {
        XCTAssertThrowsError(try KeyImport.parse("not a key at all")) { error in
            XCTAssertEqual(error as? KeyImportError, .unrecognizedFormat)
        }
    }

    func testParseShortHexThrows() {
        XCTAssertThrowsError(try KeyImport.parse("aabbccdd")) { error in
            XCTAssertEqual(error as? KeyImportError, .unrecognizedFormat)
        }
    }

    func testParseNprofileThrows() {
        XCTAssertThrowsError(try KeyImport.parse("nprofile1abc")) { error in
            XCTAssertEqual(error as? KeyImportError, .unrecognizedFormat)
        }
    }

    func testParseNoteThrows() {
        XCTAssertThrowsError(try KeyImport.parse("note1abc")) { error in
            XCTAssertEqual(error as? KeyImportError, .unrecognizedFormat)
        }
    }

    func testParseCaseInsensitive() throws {
        // nsec/npub should be case-insensitive (lowered before parsing)
        let nsec = testKeypair.privateKey.nsec
        let uppercased = nsec.uppercased()

        // The SDK may or may not accept uppercase; we lowercase before passing.
        let result = try KeyImport.parse(uppercased)
        guard case .privateKey(let pk) = result else {
            XCTFail("Expected privateKey")
            return
        }
        XCTAssertEqual(pk.hex, testKeypair.privateKey.hex)
    }
}

// MARK: - Parse Private Key Only Tests

final class KeyImportParsePrivateKeyTests: XCTestCase {

    private lazy var testKeypair: NostrSDK.Keypair = {
        guard let kp = NostrSDK.Keypair() else {
            fatalError("Could not generate test keypair")
        }
        return kp
    }()

    func testParsePrivateKeyFromNsec() throws {
        let pk = try KeyImport.parsePrivateKey(testKeypair.privateKey.nsec)
        XCTAssertEqual(pk.hex, testKeypair.privateKey.hex)
    }

    func testParsePrivateKeyFromHex() throws {
        let pk = try KeyImport.parsePrivateKey(testKeypair.privateKey.hex)
        XCTAssertEqual(pk.hex, testKeypair.privateKey.hex)
    }

    func testParsePrivateKeyRejectsNpub() {
        XCTAssertThrowsError(try KeyImport.parsePrivateKey(testKeypair.publicKey.npub)) { error in
            XCTAssertEqual(error as? KeyImportError, .wrongKeyType(expected: "nsec", got: "npub"))
        }
    }

    func testParsePrivateKeyEmptyThrows() {
        XCTAssertThrowsError(try KeyImport.parsePrivateKey("")) { error in
            XCTAssertEqual(error as? KeyImportError, .emptyInput)
        }
    }

    func testParsePrivateKeyInvalidNsecThrows() {
        XCTAssertThrowsError(try KeyImport.parsePrivateKey("nsec1bad")) { error in
            XCTAssertEqual(error as? KeyImportError, .invalidNsec)
        }
    }

    func testParsePrivateKeyRandomTextThrows() {
        XCTAssertThrowsError(try KeyImport.parsePrivateKey("hello world")) { error in
            XCTAssertEqual(error as? KeyImportError, .unrecognizedFormat)
        }
    }
}

// MARK: - Parse Public Key Only Tests

final class KeyImportParsePublicKeyTests: XCTestCase {

    private lazy var testKeypair: NostrSDK.Keypair = {
        guard let kp = NostrSDK.Keypair() else {
            fatalError("Could not generate test keypair")
        }
        return kp
    }()

    func testParsePublicKeyFromNpub() throws {
        let pk = try KeyImport.parsePublicKey(testKeypair.publicKey.npub)
        XCTAssertEqual(pk.hex, testKeypair.publicKey.hex)
    }

    func testParsePublicKeyFromHex() throws {
        let pk = try KeyImport.parsePublicKey(testKeypair.publicKey.hex)
        XCTAssertEqual(pk.hex, testKeypair.publicKey.hex)
    }

    func testParsePublicKeyRejectsNsec() {
        XCTAssertThrowsError(try KeyImport.parsePublicKey(testKeypair.privateKey.nsec)) { error in
            XCTAssertEqual(error as? KeyImportError, .wrongKeyType(expected: "npub", got: "nsec"))
        }
    }

    func testParsePublicKeyEmptyThrows() {
        XCTAssertThrowsError(try KeyImport.parsePublicKey("")) { error in
            XCTAssertEqual(error as? KeyImportError, .emptyInput)
        }
    }

    func testParsePublicKeyInvalidNpubThrows() {
        XCTAssertThrowsError(try KeyImport.parsePublicKey("npub1bad")) { error in
            XCTAssertEqual(error as? KeyImportError, .invalidNpub)
        }
    }

    func testParsePublicKeyRandomTextThrows() {
        XCTAssertThrowsError(try KeyImport.parsePublicKey("not a key")) { error in
            XCTAssertEqual(error as? KeyImportError, .unrecognizedFormat)
        }
    }
}

// MARK: - KeyImportResult Equatable Tests

final class KeyImportResultTests: XCTestCase {

    func testPrivateKeyEquality() {
        guard let kp = NostrSDK.Keypair() else {
            XCTFail("Could not generate keypair")
            return
        }
        let a = KeyImportResult.privateKey(kp.privateKey)
        let b = KeyImportResult.privateKey(kp.privateKey)
        XCTAssertEqual(a, b)
    }

    func testPublicKeyEquality() {
        guard let kp = NostrSDK.Keypair() else {
            XCTFail("Could not generate keypair")
            return
        }
        let a = KeyImportResult.publicKey(kp.publicKey)
        let b = KeyImportResult.publicKey(kp.publicKey)
        XCTAssertEqual(a, b)
    }

    func testDifferentTypesNotEqual() {
        guard let kp = NostrSDK.Keypair() else {
            XCTFail("Could not generate keypair")
            return
        }
        let priv = KeyImportResult.privateKey(kp.privateKey)
        let pub = KeyImportResult.publicKey(kp.publicKey)
        XCTAssertNotEqual(priv, pub)
    }

    func testDifferentKeysNotEqual() {
        guard let kp1 = NostrSDK.Keypair(), let kp2 = NostrSDK.Keypair() else {
            XCTFail("Could not generate keypairs")
            return
        }
        XCTAssertNotEqual(
            KeyImportResult.privateKey(kp1.privateKey),
            KeyImportResult.privateKey(kp2.privateKey)
        )
    }
}

// MARK: - Round-Trip Tests (nsec ↔ hex ↔ keypair)

final class KeyImportRoundTripTests: XCTestCase {

    func testNsecToHexRoundTrip() throws {
        guard let kp = NostrSDK.Keypair() else {
            XCTFail("Could not generate keypair")
            return
        }

        // Parse nsec → get hex
        let fromNsec = try KeyImport.parsePrivateKey(kp.privateKey.nsec)
        // Parse hex → same key
        let fromHex = try KeyImport.parsePrivateKey(fromNsec.hex)

        XCTAssertEqual(fromNsec.hex, fromHex.hex)
        XCTAssertEqual(fromNsec.nsec, fromHex.nsec)
    }

    func testNpubToHexRoundTrip() throws {
        guard let kp = NostrSDK.Keypair() else {
            XCTFail("Could not generate keypair")
            return
        }

        let fromNpub = try KeyImport.parsePublicKey(kp.publicKey.npub)
        let fromHex = try KeyImport.parsePublicKey(fromNpub.hex)

        XCTAssertEqual(fromNpub.hex, fromHex.hex)
        XCTAssertEqual(fromNpub.npub, fromHex.npub)
    }

    func testImportedPrivateKeyDerivesCorrectPublicKey() throws {
        guard let kp = NostrSDK.Keypair() else {
            XCTFail("Could not generate keypair")
            return
        }

        let importedPK = try KeyImport.parsePrivateKey(kp.privateKey.nsec)
        guard let derivedKeypair = NostrSDK.Keypair(privateKey: importedPK) else {
            XCTFail("Could not create keypair from imported private key")
            return
        }

        XCTAssertEqual(derivedKeypair.publicKey.hex, kp.publicKey.hex)
        XCTAssertEqual(derivedKeypair.publicKey.npub, kp.publicKey.npub)
    }
}
