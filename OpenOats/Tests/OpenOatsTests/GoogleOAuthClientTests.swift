import XCTest
@testable import OpenOatsKit

final class GoogleOAuthClientTests: XCTestCase {
    func testCodeChallengeIsBase64URLEncodedSHA256() {
        // RFC 7636 appendix B test vector.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = GoogleOAuthClient.codeChallenge(forVerifier: verifier)
        XCTAssertEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testRandomCodeVerifierLengthAndCharset() {
        let verifier = GoogleOAuthClient.randomCodeVerifier(length: 64)
        XCTAssertEqual(verifier.count, 64)
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertTrue(verifier.allSatisfy { allowed.contains($0) })
    }

    func testFormEncodeProducesURLEncodedPairs() {
        let result = GoogleOAuthClient.formEncode([
            "code": "abc/def",
            "client_id": "id",
        ])
        let pairs = Set(result.split(separator: "&").map(String.init))
        XCTAssertEqual(pairs, ["code=abc%2Fdef", "client_id=id"])
    }
}
