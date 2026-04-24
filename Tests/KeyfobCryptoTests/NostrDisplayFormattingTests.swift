//
//  NostrDisplayFormattingTests.swift
//
//
//  Created for Keyfob – kf-ghe
//

import XCTest
@testable import KeyfobCrypto
import NostrSDK

// MARK: - NpubDisplay Tests

final class NpubDisplayTests: XCTestCase {

    private lazy var testKeypair: NostrSDK.Keypair = {
        guard let kp = NostrSDK.Keypair() else {
            fatalError("Could not generate test keypair")
        }
        return kp
    }()

    func testTruncatedFromHex() {
        let result = NpubDisplay.truncated(testKeypair.publicKey.hex)

        // Should start with npub1
        XCTAssertTrue(result.hasPrefix("npub1"), "Truncated should start with npub1, got: \(result)")
        // Should contain ellipsis
        XCTAssertTrue(result.contains("…"), "Truncated should contain ellipsis, got: \(result)")
        // Should be shorter than the full npub
        XCTAssertTrue(result.count < testKeypair.publicKey.npub.count, "Truncated should be shorter than full npub")
    }

    func testTruncatedDefaultCounts() {
        let npub = testKeypair.publicKey.npub
        let result = NpubDisplay.truncated(npub: npub)

        // npub1 (5) + 8 chars + … + 4 chars = 18 chars
        XCTAssertEqual(result.count, 18, "Default truncation should be 18 chars, got \(result.count): \(result)")
    }

    func testTruncatedCustomCounts() {
        let npub = testKeypair.publicKey.npub
        let result = NpubDisplay.truncated(npub: npub, prefixCount: 4, suffixCount: 3)

        // npub1 (5) + 4 + … + 3 = 13 chars
        XCTAssertEqual(result.count, 13, "Custom truncation should be 13 chars, got \(result.count): \(result)")
        XCTAssertTrue(result.hasPrefix("npub1"))
    }

    func testTruncatedShortStringReturnsOriginal() {
        // If the string is short enough, return as-is
        let short = "npub1abc"
        let result = NpubDisplay.truncated(npub: short, prefixCount: 8, suffixCount: 4)
        XCTAssertEqual(result, short)
    }

    func testTruncatedFromInvalidHexFallsBackToHexTruncation() {
        let result = NpubDisplay.truncated("not-valid-hex")
        // Should return the original (too short to truncate with defaults)
        XCTAssertEqual(result, "not-valid-hex")
    }

    func testTruncatedLongInvalidHex() {
        let longHex = String(repeating: "x", count: 80)
        let result = NpubDisplay.truncated(longHex, prefixCount: 8, suffixCount: 4)
        XCTAssertTrue(result.contains("…"))
        XCTAssertTrue(result.count < longHex.count)
    }

    func testNpubFromValidHex() {
        let npub = NpubDisplay.npub(from: testKeypair.publicKey.hex)
        XCTAssertNotNil(npub)
        XCTAssertEqual(npub, testKeypair.publicKey.npub)
    }

    func testNpubFromInvalidHexReturnsNil() {
        let npub = NpubDisplay.npub(from: "invalid")
        XCTAssertNil(npub)
    }

    func testTruncatedPreservesNpubPrefix() {
        let result = NpubDisplay.truncated(testKeypair.publicKey.hex)
        XCTAssertTrue(result.hasPrefix("npub1"))
    }

    func testTruncatedEndsWithCorrectSuffix() {
        let npub = testKeypair.publicKey.npub
        let result = NpubDisplay.truncated(npub: npub, prefixCount: 8, suffixCount: 4)

        // The last 4 characters should match the full npub's last 4
        let expectedSuffix = String(npub.suffix(4))
        XCTAssertTrue(result.hasSuffix(expectedSuffix), "Expected suffix \(expectedSuffix), got ending of \(result)")
    }
}

// MARK: - Identity Display Extension Tests

final class IdentityDisplayTests: XCTestCase {

    private lazy var validPubkeyHex: String = {
        guard let kp = NostrSDK.Keypair() else {
            fatalError("Could not generate keypair")
        }
        return kp.publicKey.hex
    }()

    func testTruncatedNpub() {
        let identity = Identity(pubkeyHex: validPubkeyHex, source: .generated)
        let truncated = identity.truncatedNpub

        XCTAssertTrue(truncated.hasPrefix("npub1"))
        XCTAssertTrue(truncated.contains("…"))
    }

    func testNpub() {
        let identity = Identity(pubkeyHex: validPubkeyHex, source: .generated)
        let npub = identity.npub

        XCTAssertNotNil(npub)
        XCTAssertTrue(npub!.hasPrefix("npub1"))
    }

    func testDisplayNameUsesLabel() {
        let identity = Identity(pubkeyHex: validPubkeyHex, label: "My Key", source: .generated)
        XCTAssertEqual(identity.displayName, "My Key")
    }

    func testDisplayNameFallsBackToTruncatedNpub() {
        let identity = Identity(pubkeyHex: validPubkeyHex, source: .generated)
        XCTAssertEqual(identity.displayName, identity.truncatedNpub)
    }

    func testDisplayNameIgnoresEmptyLabel() {
        let identity = Identity(pubkeyHex: validPubkeyHex, label: "", source: .generated)
        XCTAssertEqual(identity.displayName, identity.truncatedNpub)
    }
}

// MARK: - Keypair Display Extension Tests

final class KeypairDisplayTests: XCTestCase {

    func testKeypairTruncatedNpub() {
        guard let kp = NostrSDK.Keypair() else {
            XCTFail("Could not generate keypair")
            return
        }
        let keypair = Keypair(keypair: kp)
        let truncated = keypair.truncatedNpub

        XCTAssertTrue(truncated.hasPrefix("npub1"))
        XCTAssertTrue(truncated.contains("…"))
    }
}

// MARK: - KeyClipboard Tests

final class KeyClipboardTests: XCTestCase {

    private lazy var testKeypair: NostrSDK.Keypair = {
        guard let kp = NostrSDK.Keypair() else {
            fatalError("Could not generate keypair")
        }
        return kp
    }()

    func testNpubForCopyReturnsFullNpub() {
        let result = KeyClipboard.npubForCopy(testKeypair.publicKey.hex)
        XCTAssertEqual(result, testKeypair.publicKey.npub)
        // Full npub should not be truncated
        XCTAssertFalse(result.contains("…"))
    }

    func testNpubForCopyFallsBackToHex() {
        let result = KeyClipboard.npubForCopy("invalid")
        XCTAssertEqual(result, "invalid")
    }

    func testNsecForCopy() {
        let result = KeyClipboard.nsecForCopy(testKeypair.privateKey)
        XCTAssertEqual(result, testKeypair.privateKey.nsec)
        XCTAssertTrue(result.hasPrefix("nsec1"))
    }

    func testHexForCopyPassthrough() {
        let hex = testKeypair.publicKey.hex
        XCTAssertEqual(KeyClipboard.hexForCopy(hex), hex)
    }
}
