import XCTest
@testable import KeyfobCore

final class CanonicalJSONTests: XCTestCase {
    func testDeterministicSerialization() throws {
        let e = NostrEvent(kind: 1, pubkey: "abc", created_at: 1, tags: [["t","v"]], content: "hello", id: nil, sig: nil)
        let s1 = try CanonicalJSON.serializeEvent(e)
        let s2 = try CanonicalJSON.serializeEvent(e)
        XCTAssertEqual(s1, s2)
    }

    func testKeyOrder() throws {
        let e = NostrEvent(kind: 1, pubkey: "abc", created_at: 100, tags: [], content: "test", id: nil, sig: nil)
        let json = try CanonicalJSON.serializeEvent(e)
        // Keys must appear in alphabetical order: content, created_at, kind, pubkey, tags
        guard let contentIdx = json.range(of: "\"content\""),
              let createdIdx = json.range(of: "\"created_at\""),
              let kindIdx = json.range(of: "\"kind\""),
              let pubkeyIdx = json.range(of: "\"pubkey\""),
              let tagsIdx = json.range(of: "\"tags\"") else {
            XCTFail("Missing expected keys in JSON")
            return
        }
        XCTAssertTrue(contentIdx.lowerBound < createdIdx.lowerBound)
        XCTAssertTrue(createdIdx.lowerBound < kindIdx.lowerBound)
        XCTAssertTrue(kindIdx.lowerBound < pubkeyIdx.lowerBound)
        XCTAssertTrue(pubkeyIdx.lowerBound < tagsIdx.lowerBound)
    }

    func testEscapesNewlineAndTab() throws {
        let e = NostrEvent(kind: 1, pubkey: "pk", created_at: 0, tags: [], content: "line1\nline2\ttab", id: nil, sig: nil)
        let json = try CanonicalJSON.serializeEvent(e)
        XCTAssertTrue(json.contains("line1\\nline2\\ttab"))
    }

    func testEscapesBackslashAndQuote() throws {
        let e = NostrEvent(kind: 1, pubkey: "pk", created_at: 0, tags: [], content: "he said \"hello\\world\"", id: nil, sig: nil)
        let json = try CanonicalJSON.serializeEvent(e)
        XCTAssertTrue(json.contains("he said \\\"hello\\\\world\\\""))
    }

    func testEscapesControlCharacters() throws {
        // Backspace (U+0008) and form feed (U+000C) should use named escapes
        let content = "a\u{08}b\u{0C}c"
        let e = NostrEvent(kind: 1, pubkey: "pk", created_at: 0, tags: [], content: content, id: nil, sig: nil)
        let json = try CanonicalJSON.serializeEvent(e)
        XCTAssertTrue(json.contains("a\\bb\\fc"), "Expected \\b and \\f escapes, got: \(json)")
    }

    func testEscapesLowControlCharacters() throws {
        // U+0001 should be escaped as \u0001
        let content = "x\u{01}y"
        let e = NostrEvent(kind: 1, pubkey: "pk", created_at: 0, tags: [], content: content, id: nil, sig: nil)
        let json = try CanonicalJSON.serializeEvent(e)
        XCTAssertTrue(json.contains("x\\u0001y"), "Expected \\u0001 escape, got: \(json)")
    }

    func testEmptyContent() throws {
        let e = NostrEvent(kind: 1, pubkey: "pk", created_at: 0, tags: [], content: "", id: nil, sig: nil)
        let json = try CanonicalJSON.serializeEvent(e)
        XCTAssertTrue(json.contains("\"content\":\"\""))
    }

    func testTagsSerialization() throws {
        let e = NostrEvent(kind: 1, pubkey: "pk", created_at: 0, tags: [["p","abc"],["e","def","relay"]], content: "", id: nil, sig: nil)
        let json = try CanonicalJSON.serializeEvent(e)
        // Tags should be present as JSON array
        XCTAssertTrue(json.contains("\"tags\":"))
        // Verify it parses as valid JSON
        let data = json.data(using: .utf8)!
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
    }
}
