import XCTest
import CryptoKit
@testable import KeyfobCore

final class NIP01IdTests: XCTestCase {
    struct Vec {
        let pubkey: String
        let createdAt: Int
        let kind: Int
        let tags: [[String]]
        let content: String
        let expectedArrayJSON: String
    }

    private func arrayJSON(pubkey: String, createdAt: Int, kind: Int, tags: [[String]], content: String) throws -> String {
        // Per NIP-01, the array is: [0, pubkey, created_at, kind, tags, content]
        let tagsData = try JSONSerialization.data(withJSONObject: tags)
        let tagsStr = String(data: tagsData, encoding: .utf8)!
        // Escape content minimal set (quotes and backslashes)
        func esc(_ s: String) -> String {
            var out = ""
            for ch in s.unicodeScalars {
                switch ch {
                case "\\": out += "\\\\"
                case "\"": out += "\\\""
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default: out.append(String(ch))
                }
            }
            return out
        }
        return "[0,\"\(pubkey)\",\(createdAt),\(kind),\(tagsStr),\"\(esc(content))\"]"
    }

    private func sha256Hex(_ s: String) -> String {
        let data = Data(s.utf8)
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    func testVectors() throws {
        let vectors: [Vec] = [
            Vec(pubkey: "aabbcc", createdAt: 1_700_000_000, kind: 1, tags: [], content: "hello", expectedArrayJSON: "[0,\"aabbcc\",1700000000,1,[],\"hello\"]"),
            // Newline content should be escaped as \n in the JSON string
            Vec(pubkey: "ffffffff", createdAt: 0, kind: 42, tags: [["p","xyz"],["e","123"]], content: "hi\nthere", expectedArrayJSON: "[0,\"ffffffff\",0,42,[[\"p\",\"xyz\"],[\"e\",\"123\"]],\"hi\\nthere\"]"),
            // Literal backslash-n in content should preserve as \\n in JSON
            Vec(pubkey: "abcd", createdAt: 1, kind: 1, tags: [], content: "hi\\nthere", expectedArrayJSON: "[0,\"abcd\",1,1,[],\"hi\\\\nthere\"]"),
        ]
        for v in vectors {
            let arr = try arrayJSON(pubkey: v.pubkey, createdAt: v.createdAt, kind: v.kind, tags: v.tags, content: v.content)
            XCTAssertEqual(arr, v.expectedArrayJSON, "Array JSON mismatch for vector")
            let id = sha256Hex(arr)
            XCTAssertEqual(id.count, 64)
            XCTAssertTrue(id.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
        }
    }
}
