import XCTest
import CryptoKit
import NostrSDK
@testable import KeyfobCrypto

final class SignerTests: XCTestCase {

    // MARK: - SignatureResponse

    func testSignatureResponseCoding() throws {
        let resp = SignatureResponse(id: "aabbccdd", sig: "deadbeef", pubkey: "1234abcd")
        let data = try JSONEncoder().encode(resp)
        let back = try JSONDecoder().decode(SignatureResponse.self, from: data)
        XCTAssertEqual(resp, back)
        XCTAssertEqual(back.id, "aabbccdd")
        XCTAssertEqual(back.sig, "deadbeef")
        XCTAssertEqual(back.pubkey, "1234abcd")
    }

    func testSignatureResponseFieldsInJSON() throws {
        let resp = SignatureResponse(id: "id123", sig: "sig456", pubkey: "pk789")
        let data = try JSONEncoder().encode(resp)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json)
        XCTAssertEqual(json?["id"] as? String, "id123")
        XCTAssertEqual(json?["sig"] as? String, "sig456")
        XCTAssertEqual(json?["pubkey"] as? String, "pk789")
        XCTAssertEqual(json?.count, 3)
    }

    // MARK: - Keypair (pubkeyHex init)

    func testKeypairCoding() throws {
        let kp = Keypair(pubkeyHex: "aabb")
        let data = try JSONEncoder().encode(kp)
        let back = try JSONDecoder().decode(Keypair.self, from: data)
        XCTAssertEqual(kp, back)
        XCTAssertEqual(back.pubkeyHex, "aabb")
    }

    func testKeypairEquality() {
        let a = Keypair(pubkeyHex: "aa")
        let b = Keypair(pubkeyHex: "aa")
        let c = Keypair(pubkeyHex: "bb")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - Keypair (SDK type inits)

    func testKeypairFromSDKKeypair() {
        guard let sdkKeypair = NostrSDK.Keypair() else {
            XCTFail("Failed to generate SDK Keypair")
            return
        }
        let kp = Keypair(keypair: sdkKeypair)
        XCTAssertEqual(kp.pubkeyHex, sdkKeypair.publicKey.hex)
        XCTAssertEqual(kp.pubkeyHex.count, 64)
    }

    func testKeypairFromSDKPublicKey() {
        guard let sdkKeypair = NostrSDK.Keypair() else {
            XCTFail("Failed to generate SDK Keypair")
            return
        }
        let kp = Keypair(publicKey: sdkKeypair.publicKey)
        XCTAssertEqual(kp.pubkeyHex, sdkKeypair.publicKey.hex)
    }

    func testKeypairSDKPublicKeyAccessor() {
        guard let sdkKeypair = NostrSDK.Keypair() else {
            XCTFail("Failed to generate SDK Keypair")
            return
        }
        let kp = Keypair(keypair: sdkKeypair)
        XCTAssertNotNil(kp.publicKey, "SDK PublicKey should be reconstructible from valid hex")
        XCTAssertEqual(kp.publicKey?.hex, kp.pubkeyHex)
    }

    func testKeypairNpubAccessor() {
        guard let sdkKeypair = NostrSDK.Keypair() else {
            XCTFail("Failed to generate SDK Keypair")
            return
        }
        let kp = Keypair(keypair: sdkKeypair)
        XCTAssertNotNil(kp.npub, "npub should be available for valid public key")
        XCTAssertTrue(kp.npub!.hasPrefix("npub1"), "npub should start with 'npub1'")
        XCTAssertEqual(kp.npub, sdkKeypair.publicKey.npub)
    }

    func testKeypairInvalidHexReturnsNilSDKTypes() {
        let kp = Keypair(pubkeyHex: "invalid-not-hex")
        XCTAssertNil(kp.publicKey, "Invalid hex should produce nil PublicKey")
        XCTAssertNil(kp.npub, "Invalid hex should produce nil npub")
    }

    func testKeypairShortHexStillCreatesSDKTypes() {
        // The SDK's PublicKey(hex:) does not validate 32-byte length;
        // it accepts any valid hex. Keyfob relies on Keychain/key generation
        // to ensure keys are valid secp256k1 points.
        let kp = Keypair(pubkeyHex: "aabb")
        XCTAssertNotNil(kp.publicKey, "SDK accepts short hex without validation")
        XCTAssertNotNil(kp.npub, "SDK produces npub from short hex")
    }

    func testKeypairCodingPreservesSDKAccess() throws {
        guard let sdkKeypair = NostrSDK.Keypair() else {
            XCTFail("Failed to generate SDK Keypair")
            return
        }
        let original = Keypair(keypair: sdkKeypair)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Keypair.self, from: data)
        XCTAssertEqual(original, decoded)
        XCTAssertEqual(decoded.npub, original.npub)
        XCTAssertEqual(decoded.publicKey?.hex, original.publicKey?.hex)
    }

    func testKeypairFromSDKDiscardsSamePublicKey() {
        guard let sdkKeypair = NostrSDK.Keypair() else {
            XCTFail("Failed to generate SDK Keypair")
            return
        }
        let fromKeypair = Keypair(keypair: sdkKeypair)
        let fromPublicKey = Keypair(publicKey: sdkKeypair.publicKey)
        XCTAssertEqual(fromKeypair, fromPublicKey, "Both inits should produce identical Keypair")
    }

    // MARK: - Signer with SDK Keypair

    func testSignEventWithSDKKeypair() throws {
        guard let sdkKeypair = NostrSDK.Keypair() else {
            XCTFail("Failed to generate SDK Keypair")
            return
        }
        let json = "{\"kind\":1,\"created_at\":1700000000,\"tags\":[],\"content\":\"hello\"}"
        let signer = Signer()
        let resp = try signer.signEvent(eventJSON: json, with: sdkKeypair)

        // Verify the response fields
        XCTAssertEqual(resp.pubkey, sdkKeypair.publicKey.hex)
        XCTAssertEqual(resp.id.count, 64, "Event ID should be 64-char hex")
        XCTAssertEqual(resp.sig.count, 128, "Schnorr signature should be 128-char hex")

        // Verify the signature is valid using SDK's EventVerifying (throws on failure)
        struct _Verifier: EventVerifying {}
        XCTAssertNoThrow(
            try _Verifier().verifySignature(resp.sig, for: resp.id, withPublicKey: resp.pubkey),
            "Signature should verify against the event id and public key"
        )
    }

    func testSignEventWithSDKKeypairProducesDeterministicId() throws {
        guard let sdkKeypair = NostrSDK.Keypair() else {
            XCTFail("Failed to generate SDK Keypair")
            return
        }
        let json = "{\"kind\":1,\"created_at\":100,\"tags\":[],\"content\":\"test\"}"
        let signer = Signer()
        let resp1 = try signer.signEvent(eventJSON: json, with: sdkKeypair)
        let resp2 = try signer.signEvent(eventJSON: json, with: sdkKeypair)
        XCTAssertEqual(resp1.id, resp2.id, "Same input should produce same event id")
        XCTAssertEqual(resp1.pubkey, resp2.pubkey)
        // Signatures may differ due to nonce randomness in Schnorr
    }

    // MARK: - Error enum

    func testCryptoErrorCases() {
        let errors: [KeyfobCryptoError] = [
            .keyNotFound, .exportPasswordRequired, .biometricFailed,
            .encryptionFailed, .importFormatInvalid
        ]
        // Each should have a distinct description
        let descriptions = Set(errors.map { "\($0)" })
        XCTAssertEqual(descriptions.count, errors.count, "All error cases should be distinct")
    }

    // MARK: - Signer.serializeNIP01

    func testSerializeNIP01Format() {
        let s = Signer.serializeNIP01(pubkey: "abc", createdAt: 100, kind: 1, tags: [], content: "hi")
        XCTAssertTrue(s.hasPrefix("[0,"))
        XCTAssertTrue(s.hasSuffix("]"))
        // Must start with [0, then pubkey in quotes
        XCTAssertTrue(s.hasPrefix("[0,\"abc\","))
    }

    func testSerializeNIP01EscapesNewlines() {
        let s = Signer.serializeNIP01(pubkey: "pk", createdAt: 0, kind: 1, tags: [], content: "line1\nline2")
        XCTAssertTrue(s.contains("\\n"), "Newlines must be escaped: \(s)")
        XCTAssertFalse(s.contains("\n"), "Literal newline should not appear in serialization")
    }

    func testSerializeNIP01EscapesQuotes() {
        let s = Signer.serializeNIP01(pubkey: "pk", createdAt: 0, kind: 1, tags: [], content: "say \"hi\"")
        XCTAssertTrue(s.contains("\\\""), "Quotes must be escaped: \(s)")
    }

    func testSerializeNIP01WithNestedTags() {
        let s = Signer.serializeNIP01(
            pubkey: "pk",
            createdAt: 0,
            kind: 1,
            tags: [["p", "abc", "wss://relay.example.com"], ["e", "def"]],
            content: ""
        )
        // Should contain the tags as JSON arrays
        XCTAssertTrue(s.contains("\"p\""), "Tag name 'p' should be present")
        XCTAssertTrue(s.contains("wss://relay.example.com"), "Relay URL should be present")
    }

    // MARK: - Signer.computeNIP01Id

    func testComputeNIP01IdProduces64CharHex() {
        let id = Signer.computeNIP01Id(pubkey: "test", createdAt: 0, kind: 0, tags: [], content: "")
        XCTAssertEqual(id.count, 64)
        XCTAssertNotNil(id.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
    }

    func testComputeNIP01IdMatchesSHA256OfSerialization() {
        let ser = Signer.serializeNIP01(pubkey: "abc", createdAt: 1000, kind: 1, tags: [], content: "hello")
        let expectedDigest = SHA256.hash(data: Data(ser.utf8))
        let expectedHex = expectedDigest.map { String(format: "%02x", $0) }.joined()
        let actual = Signer.computeNIP01Id(pubkey: "abc", createdAt: 1000, kind: 1, tags: [], content: "hello")
        XCTAssertEqual(actual, expectedHex)
    }

    func testComputeNIP01IdIsDeterministic() {
        let a = Signer.computeNIP01Id(pubkey: "x", createdAt: 1, kind: 1, tags: [["t","v"]], content: "c")
        let b = Signer.computeNIP01Id(pubkey: "x", createdAt: 1, kind: 1, tags: [["t","v"]], content: "c")
        XCTAssertEqual(a, b)
    }

    func testComputeNIP01IdSensitiveToAllFields() {
        let base = { Signer.computeNIP01Id(pubkey: "pk", createdAt: 100, kind: 1, tags: [], content: "c") }
        // Change pubkey
        XCTAssertNotEqual(base(), Signer.computeNIP01Id(pubkey: "qk", createdAt: 100, kind: 1, tags: [], content: "c"))
        // Change created_at
        XCTAssertNotEqual(base(), Signer.computeNIP01Id(pubkey: "pk", createdAt: 101, kind: 1, tags: [], content: "c"))
        // Change kind
        XCTAssertNotEqual(base(), Signer.computeNIP01Id(pubkey: "pk", createdAt: 100, kind: 2, tags: [], content: "c"))
        // Change tags
        XCTAssertNotEqual(base(), Signer.computeNIP01Id(pubkey: "pk", createdAt: 100, kind: 1, tags: [["x"]], content: "c"))
        // Change content
        XCTAssertNotEqual(base(), Signer.computeNIP01Id(pubkey: "pk", createdAt: 100, kind: 1, tags: [], content: "d"))
    }

    // MARK: - signEvent without keychain (should throw)

    func testSignEventThrowsWithoutKeychain() {
        let signer = Signer()
        let json = "{\"kind\":1,\"created_at\":0,\"tags\":[],\"content\":\"test\"}"
        // Should throw because no keychain key is available in test environment
        XCTAssertThrowsError(try signer.signEvent(eventJSON: json))
    }

    func testSignEventThrowsOnInvalidJSON() {
        let signer = Signer()
        XCTAssertThrowsError(try signer.signEvent(eventJSON: "not json"))
    }

    func testSignEventThrowsOnEmptyInput() {
        let signer = Signer()
        XCTAssertThrowsError(try signer.signEvent(eventJSON: ""))
    }

    func testSignEventWithSDKKeypairThrowsOnInvalidJSON() {
        guard let sdkKeypair = NostrSDK.Keypair() else {
            XCTFail("Failed to generate SDK Keypair")
            return
        }
        let signer = Signer()
        XCTAssertThrowsError(try signer.signEvent(eventJSON: "not json", with: sdkKeypair))
    }
}
