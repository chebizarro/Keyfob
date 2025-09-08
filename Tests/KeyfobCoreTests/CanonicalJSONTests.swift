import XCTest
@testable import KeyfobCore

final class CanonicalJSONTests: XCTestCase {
    func testDeterministicSerialization() throws {
        let e = NostrEvent(kind: 1, pubkey: "abc", created_at: 1, tags: [["t","v"]], content: "hello", id: nil, sig: nil)
        let s1 = try CanonicalJSON.serializeEvent(e)
        let s2 = try CanonicalJSON.serializeEvent(e)
        XCTAssertEqual(s1, s2)
    }
}
