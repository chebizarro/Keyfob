import XCTest
import CryptoKit
@testable import KeyfobCore
@testable import KeyfobCrypto
@testable import NostrSDK

final class NIP01IdTests: XCTestCase {

    // MARK: - Test vectors for NIP-01 serialization

    struct Vec {
        let pubkey: String
        let createdAt: Int
        let kind: Int
        let tags: [[String]]
        let content: String
        let expectedArrayJSON: String
    }

    private func sha256Hex(_ s: String) -> String {
        let data = Data(s.utf8)
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Production code serialization tests

    func testSerializeNIP01BasicEvent() {
        let ser = Signer.serializeNIP01(
            pubkey: "aabbcc",
            createdAt: 1_700_000_000,
            kind: 1,
            tags: [],
            content: "hello"
        )
        XCTAssertEqual(ser, "[0,\"aabbcc\",1700000000,1,[],\"hello\"]")
    }

    func testSerializeNIP01WithTags() {
        let ser = Signer.serializeNIP01(
            pubkey: "ffffffff",
            createdAt: 0,
            kind: 42,
            tags: [["p", "xyz"], ["e", "123"]],
            content: "hi\nthere"
        )
        XCTAssertEqual(ser, "[0,\"ffffffff\",0,42,[[\"p\",\"xyz\"],[\"e\",\"123\"]],\"hi\\nthere\"]")
    }

    func testSerializeNIP01WithBackslashes() {
        let ser = Signer.serializeNIP01(
            pubkey: "abcd",
            createdAt: 1,
            kind: 1,
            tags: [],
            content: "hi\\nthere"
        )
        XCTAssertEqual(ser, "[0,\"abcd\",1,1,[],\"hi\\\\nthere\"]")
    }

    func testSerializeNIP01EmptyContent() {
        let ser = Signer.serializeNIP01(
            pubkey: "0000",
            createdAt: 0,
            kind: 0,
            tags: [],
            content: ""
        )
        XCTAssertEqual(ser, "[0,\"0000\",0,0,[],\"\"]")
    }

    func testSerializeNIP01ContentWithQuotes() {
        let ser = Signer.serializeNIP01(
            pubkey: "aa",
            createdAt: 100,
            kind: 1,
            tags: [],
            content: "he said \"hello\""
        )
        XCTAssertTrue(ser.contains("\"he said \\\"hello\\\"\""), "Quotes must be escaped in content: \(ser)")
    }

    // MARK: - computeNIP01Id matches hand-computed hashes

    func testComputeNIP01IdBasic() {
        let expectedSer = "[0,\"aabbcc\",1700000000,1,[],\"hello\"]"
        let expectedId = sha256Hex(expectedSer)
        let actualId = Signer.computeNIP01Id(
            pubkey: "aabbcc",
            createdAt: 1_700_000_000,
            kind: 1,
            tags: [],
            content: "hello"
        )
        XCTAssertEqual(actualId, expectedId)
        XCTAssertEqual(actualId.count, 64)
    }

    func testComputeNIP01IdWithTags() {
        let expectedSer = "[0,\"ffffffff\",0,42,[[\"p\",\"xyz\"],[\"e\",\"123\"]],\"hi\\nthere\"]"
        let expectedId = sha256Hex(expectedSer)
        let actualId = Signer.computeNIP01Id(
            pubkey: "ffffffff",
            createdAt: 0,
            kind: 42,
            tags: [["p", "xyz"], ["e", "123"]],
            content: "hi\nthere"
        )
        XCTAssertEqual(actualId, expectedId)
    }

    func testComputeNIP01IdIsHexLowercase() {
        let id = Signer.computeNIP01Id(
            pubkey: "ab",
            createdAt: 0,
            kind: 0,
            tags: [],
            content: ""
        )
        XCTAssertEqual(id.count, 64)
        XCTAssertTrue(id.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil, "ID should be lowercase hex")
    }

    // MARK: - Determinism

    func testComputeNIP01IdIsDeterministic() {
        let id1 = Signer.computeNIP01Id(pubkey: "abc", createdAt: 100, kind: 1, tags: [["t", "v"]], content: "test")
        let id2 = Signer.computeNIP01Id(pubkey: "abc", createdAt: 100, kind: 1, tags: [["t", "v"]], content: "test")
        XCTAssertEqual(id1, id2)
    }

    func testComputeNIP01IdChangesWithContent() {
        let id1 = Signer.computeNIP01Id(pubkey: "abc", createdAt: 100, kind: 1, tags: [], content: "hello")
        let id2 = Signer.computeNIP01Id(pubkey: "abc", createdAt: 100, kind: 1, tags: [], content: "world")
        XCTAssertNotEqual(id1, id2)
    }

    func testComputeNIP01IdChangesWithPubkey() {
        let id1 = Signer.computeNIP01Id(pubkey: "aaa", createdAt: 100, kind: 1, tags: [], content: "test")
        let id2 = Signer.computeNIP01Id(pubkey: "bbb", createdAt: 100, kind: 1, tags: [], content: "test")
        XCTAssertNotEqual(id1, id2)
    }

    func testComputeNIP01IdChangesWithKind() {
        let id1 = Signer.computeNIP01Id(pubkey: "abc", createdAt: 100, kind: 1, tags: [], content: "test")
        let id2 = Signer.computeNIP01Id(pubkey: "abc", createdAt: 100, kind: 4, tags: [], content: "test")
        XCTAssertNotEqual(id1, id2)
    }

    // MARK: - Cross-check: local helper vs production code

    func testVectorsMatchProductionCode() throws {
        let vectors: [Vec] = [
            Vec(pubkey: "aabbcc", createdAt: 1_700_000_000, kind: 1, tags: [], content: "hello",
                expectedArrayJSON: "[0,\"aabbcc\",1700000000,1,[],\"hello\"]"),
            Vec(pubkey: "ffffffff", createdAt: 0, kind: 42, tags: [["p","xyz"],["e","123"]], content: "hi\nthere",
                expectedArrayJSON: "[0,\"ffffffff\",0,42,[[\"p\",\"xyz\"],[\"e\",\"123\"]],\"hi\\nthere\"]"),
            Vec(pubkey: "abcd", createdAt: 1, kind: 1, tags: [], content: "hi\\nthere",
                expectedArrayJSON: "[0,\"abcd\",1,1,[],\"hi\\\\nthere\"]"),
        ]
        for v in vectors {
            // Verify serialization matches expected
            let ser = Signer.serializeNIP01(
                pubkey: v.pubkey,
                createdAt: Int64(v.createdAt),
                kind: v.kind,
                tags: v.tags,
                content: v.content
            )
            XCTAssertEqual(ser, v.expectedArrayJSON, "Serialization mismatch for pubkey=\(v.pubkey)")

            // Verify id is SHA-256 of the serialization
            let expectedId = sha256Hex(v.expectedArrayJSON)
            let actualId = Signer.computeNIP01Id(
                pubkey: v.pubkey,
                createdAt: Int64(v.createdAt),
                kind: v.kind,
                tags: v.tags,
                content: v.content
            )
            XCTAssertEqual(actualId, expectedId, "ID mismatch for pubkey=\(v.pubkey)")

            // Cross-validate against SDK's EventSerializer directly
            let sdkTags = Signer.tagsToSDK(v.tags)
            let sdkSer = EventSerializer.serializedEvent(
                withPubkey: v.pubkey,
                createdAt: Int64(v.createdAt),
                kind: v.kind,
                tags: sdkTags,
                content: v.content
            )
            XCTAssertEqual(sdkSer, v.expectedArrayJSON, "SDK EventSerializer mismatch for pubkey=\(v.pubkey)")

            let sdkId = EventSerializer.identifierForEvent(
                withPubkey: v.pubkey,
                createdAt: Int64(v.createdAt),
                kind: v.kind,
                tags: sdkTags,
                content: v.content
            )
            XCTAssertEqual(sdkId, expectedId, "SDK EventSerializer ID mismatch for pubkey=\(v.pubkey)")
        }
    }

    // MARK: - SDK NostrEvent cross-validation

    func testSDKNostrEventIdMatchesManualComputation() {
        // Create an SDK NostrEvent (rumor) and verify its calculated ID matches
        // what we compute via Signer.computeNIP01Id
        guard let sdkKeypair = NostrSDK.Keypair() else {
            XCTFail("Failed to generate SDK Keypair")
            return
        }
        let pubkey = sdkKeypair.publicKey.hex
        let tags: [Tag] = [Tag(name: "t", value: "nostr")]
        let sdkEvent = NostrEvent(kind: .textNote, content: "hello sdk", tags: tags, createdAt: 1700000000, pubkey: pubkey)

        let manualId = Signer.computeNIP01Id(
            pubkey: pubkey,
            createdAt: 1700000000,
            kind: 1,
            tags: [["t", "nostr"]],
            content: "hello sdk"
        )
        XCTAssertEqual(sdkEvent.calculatedId, manualId, "SDK NostrEvent.calculatedId should match Signer.computeNIP01Id")
        XCTAssertEqual(sdkEvent.id, manualId, "SDK NostrEvent.id should match manual computation")
    }

    func testSignedSDKNostrEventVerifies() throws {
        guard let sdkKeypair = NostrSDK.Keypair() else {
            XCTFail("Failed to generate SDK Keypair")
            return
        }
        // Sign via SDK's builder pattern
        let sdkEvent = try NostrEvent(kind: .textNote, content: "signed via sdk", createdAt: 1700000000, signedBy: sdkKeypair)
        XCTAssertNotNil(sdkEvent.signature, "SDK-signed event should have a signature")
        XCTAssertEqual(sdkEvent.id.count, 64)

        // Cross-validate: our Signer produces the same ID for the same event fields
        let ourId = Signer.computeNIP01Id(
            pubkey: sdkKeypair.publicKey.hex,
            createdAt: 1700000000,
            kind: 1,
            tags: Signer.tagsFromSDK(sdkEvent.tags),
            content: "signed via sdk"
        )
        XCTAssertEqual(sdkEvent.id, ourId, "SDK event ID should match our computation")
    }
}
