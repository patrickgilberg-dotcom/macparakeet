import Foundation
import XCTest
@testable import MacParakeetCore

final class ChatGPTAuthTests: XCTestCase {
    func testPKCES256UsesRFC7636Vector() {
        XCTAssertEqual(
            ChatGPTAuth.pkceChallenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testRandomValuesAreDistinctBase64URL() throws {
        let a = try ChatGPTAuth.randomValue(), b = try ChatGPTAuth.randomValue()
        XCTAssertEqual(a.count, 43)
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(a.contains("+"))
        XCTAssertFalse(a.contains("="))
    }

    func testFormEncodingPreservesPlusAmpersandAndUnicode() {
        let encoded = String(
            data: ChatGPTAuth.formBody(["code": "a+b&c=é", "resource": "https://api.openai.com/v1"]), encoding: .utf8)
        XCTAssertEqual(encoded, "code=a%2Bb%26c%3D%C3%A9&resource=https%3A%2F%2Fapi.openai.com%2Fv1")
    }

    func testValidDynamicRegistrationCallback() {
        let callback = parse("state=expected&code=one-time&client_id=oaiapp_123")
        guard case let .accepted(value) = callback else { return XCTFail("Expected callback") }
        XCTAssertEqual(value.code, "one-time")
        XCTAssertEqual(value.clientID, "oaiapp_123")
    }

    func testReturningRegistrationCanOmitIssuedClientID() {
        guard case let .accepted(value) = parse("state=expected&code=c", saved: "oaiapp_saved") else {
            return XCTFail("Expected callback")
        }
        XCTAssertEqual(value.clientID, "oaiapp_saved")
    }

    func testCallbackCannotReplaceReturningClientID() {
        guard case .failed = parse("state=expected&code=c&client_id=oaiapp_other", saved: "oaiapp_saved") else {
            return XCTFail("Changed client must fail")
        }
    }

    func testCallbackRejectsDuplicateOrWrongStateWithoutConsumingAttempt() {
        for query in [
            "state=wrong&code=c&client_id=x", "state=expected&state=expected&code=c&client_id=x",
            "state&state=expected&code=c&client_id=x", "code=c&client_id=x",
        ] {
            guard case .invalidState = parse(query) else { return XCTFail("Invalid state accepted") }
        }
    }

    func testCallbackRejectsMissingIssuedIDAndDuplicateCodes() {
        for query in [
            "state=expected&code=c", "state=expected&code=c&client_id=dynamic_agent_client",
            "state=expected&code=a&code=b&client_id=x", "state=expected&code&code=c&client_id=x",
            "state=expected&code=c&client_id&client_id=x",
        ] {
            guard case .failed = parse(query) else { return XCTFail("Incomplete registration accepted") }
        }
    }

    func testConsentDenialRequiresValidState() {
        guard case let .failed(error) = parse("state=expected&error=access_denied") else {
            return XCTFail("Expected denied")
        }
        XCTAssertEqual(error.code, "access_denied")
        guard case .invalidState = parse("state=wrong&error=access_denied") else {
            return XCTFail("Unbound denial consumed attempt")
        }
    }

    func testCallbackRejectsWrongHostPathAndMethod() {
        for request in [
            "GET /callback?state=expected&code=c&client_id=x HTTP/1.1\r\nHost: 127.0.0.1:12345\r\n\r\n",
            "GET /auth/callback?state=expected&code=c&client_id=x HTTP/1.1\r\nHost: localhost:12345\r\n\r\n",
            "POST /auth/callback?state=expected&code=c&client_id=x HTTP/1.1\r\nHost: 127.0.0.1:12345\r\n\r\n",
        ] {
            guard
                case .unrelated = ChatGPTLoopbackListener.parse(
                    request, port: 12345, expectedState: "expected", savedClientID: nil)
            else { return XCTFail("Unexpected HTTP request accepted") }
        }
    }

    func testLiveLoopbackRejectsUnrelatedStateThenAcceptsItsCallback() async throws {
        let listener = try ChatGPTLoopbackListener(state: "expected", savedClientID: nil)
        let result = Task { try await listener.result() }
        let (_, wrong) = try await URLSession.shared.data(
            from: URL(string: listener.redirectURI + "?state=wrong&code=c&client_id=oaiapp_test")!)
        XCTAssertEqual((wrong as? HTTPURLResponse)?.statusCode, 400)
        let (_, accepted) = try await URLSession.shared.data(
            from: URL(string: listener.redirectURI + "?state=expected&code=c&client_id=oaiapp_test")!)
        XCTAssertEqual((accepted as? HTTPURLResponse)?.statusCode, 200)
        let callback = try await result.value
        XCTAssertEqual(callback, ChatGPTLoopbackListener.Callback(code: "c", clientID: "oaiapp_test"))
    }

    func testLiveLoopbackCancellationEndsPendingWait() async throws {
        let listener = try ChatGPTLoopbackListener(state: "expected", savedClientID: nil)
        let result = Task { try await listener.result() }
        await Task.yield()
        listener.cancel()
        do {
            _ = try await result.value
            XCTFail("Cancelled listener returned a callback")
        } catch let error as ChatGPTAuthError {
            XCTAssertEqual(error.code, "cancelled")
        }
    }

    func testIdentityClaimsRequireIssuerAudienceNonceExpiryAndSubject() throws {
        let identity = try ChatGPTAuth.validateClaims(claims(), clientID: "oaiapp_test", nonce: "nonce", at: now)
        XCTAssertEqual(identity.subject, "subject")
        let updates: [[String: Any]] = [
            ["iss": "https://evil.example"], ["aud": "other"], ["nonce": "other"],
            ["exp": now.timeIntervalSince1970 - 10], ["iat": now.timeIntervalSince1970 + 10], ["sub": ""],
        ]
        for update in updates {
            XCTAssertThrowsError(
                try ChatGPTAuth.validateClaims(claims(update), clientID: "oaiapp_test", nonce: "nonce", at: now))
        }
    }

    func testMultipleAudiencesRequireAuthorizedParty() {
        XCTAssertThrowsError(
            try ChatGPTAuth.validateClaims(
                claims(["aud": ["oaiapp_test", "other"]]), clientID: "oaiapp_test", nonce: "nonce", at: now))
        XCTAssertNoThrow(
            try ChatGPTAuth.validateClaims(
                claims(["aud": ["oaiapp_test", "other"], "azp": "oaiapp_test"]), clientID: "oaiapp_test",
                nonce: "nonce", at: now))
    }

    func testAccountSwitchInvalidatesExpectedCredentials() {
        XCTAssertNoThrow(try ChatGPTAuth.checkActiveAccount("one", expected: "one"))
        XCTAssertThrowsError(try ChatGPTAuth.checkActiveAccount("two", expected: "one"))
        XCTAssertThrowsError(try ChatGPTAuth.checkActiveAccount(nil, expected: "one"))
    }

    func testRS256SignatureAndTampering() throws {
        let signature = try XCTUnwrap(Data(chatGPTBase64URL: Self.signature))
        XCTAssertTrue(
            try ChatGPTAuth.verifyRS256Signature(
                Data("header.payload".utf8), signature: signature, modulus: Self.modulus, exponent: "AQAB"))
        XCTAssertFalse(
            try ChatGPTAuth.verifyRS256Signature(
                Data("header.changed".utf8), signature: signature, modulus: Self.modulus, exponent: "AQAB"))
        XCTAssertThrowsError(
            try ChatGPTAuth.verifyRS256Signature(Data(), signature: signature, modulus: "AA", exponent: "AQAB"))
    }

    func testConnectedIdentityDoesNotImplyPlanPermission() {
        let account = ChatGPTAccount(
            id: "one", email: nil, name: nil, clientID: "app", subject: "subject", scopes: ["openid"], connected: true)
        XCTAssertFalse(account.planUsageEnabled)
        let disconnected = ChatGPTAccount(
            id: "one", email: nil, name: nil, clientID: "app", subject: "subject",
            scopes: ["chatgpt.tokens.use.direct"], connected: false)
        XCTAssertFalse(disconnected.planUsageEnabled)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func claims(_ update: [String: Any] = [:]) -> Data {
        var values: [String: Any] = [
            "iss": "https://auth.openai.com", "sub": "subject", "aud": "oaiapp_test", "iat": now.timeIntervalSince1970,
            "exp": now.timeIntervalSince1970 + 3600, "nonce": "nonce",
        ]
        values.merge(update, uniquingKeysWith: { _, new in new })
        return try! JSONSerialization.data(withJSONObject: values)
    }
    private func parse(_ query: String, saved: String? = nil) -> ChatGPTLoopbackListener.ParsedCallback {
        ChatGPTLoopbackListener.parse(
            "GET /auth/callback?\(query) HTTP/1.1\r\nHost: 127.0.0.1:12345\r\n\r\n", port: 12345,
            expectedState: "expected", savedClientID: saved)
    }

    // A generated test-only RSA key/signature; no private key is retained.
    private static let modulus =
        "tiJ67crqrIX7huMDNiGysCbNgTIRAzKsqzlAlAZf6VdavKYM0hAXN6yB84An8x9f5Rf4-GDJ3B6RVnxWIKO-HxZVlSfdBLgTjPhbtWrL28e6Ne2swo156EQnJ1DMP4hKTiIs0o_Lq3zxzt-5wK0w7KOSrl6Dl9TiPnQeIctZamimZAR-vcKghdPawwEz9EOTSIHXyOXr5VFczn_sGu_IE_dOLqsTWyMTnCK4qljUMv_yrdQChVOMyaGkBtwcfXPo33eUTB_cccW4_DCQM_245chfU3PYL-YbuOpyfssIUK5UTdGw5bKRudnB1a0P8qyRtSXqp1g9t_qTp_wPiIjWrw"
    private static let signature =
        "DyZLro6a7kkz5cQ7vJzNn3kHNvgOHQ_ixs3S_6B1DHT4Ke00wmk3We3xQTdMyX5PoOoRNEeANl5o2PafLBKrkW1f8ic7rZ0Zd3_uP6-e-RjWiORSK2jvLuICafJfDNXhq1u12aKp2k7YbICWSD7cspxgq9WO-mZ_Rn_VMhZSjDbS3izCTF4OoQKPteO83asgBvjFG-UG2EUE0CJ5wydKNDN19g8yg2zWYNDd9bpN_3BgKZote1sr8e8R_MvfP2uHeSycSqShcOt3-fqle4eyAq3gfsowtZOGKsoSxpS75uncf3S3cGZdUMCUANe0O_D_djkuQg7iKmcZBTsQfDrQWw"
}
