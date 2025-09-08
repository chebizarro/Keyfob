import XCTest
@testable import KeyfobCrypto

final class SignerTests: XCTestCase {
    func testSignatureResponseCoding() throws {
        let resp = SignatureResponse(id: "id", sig: "sig", pubkey: "pk")
        let data = try JSONEncoder().encode(resp)
        let back = try JSONDecoder().decode(SignatureResponse.self, from: data)
        XCTAssertEqual(resp, back)
    }
}
