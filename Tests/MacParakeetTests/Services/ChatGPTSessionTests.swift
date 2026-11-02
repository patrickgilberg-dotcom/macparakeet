import Foundation
import XCTest
import Security
@testable import MacParakeetCore

/// Exercises the real refresh/revocation code with synthetic credentials. The
/// injected URLSession cannot issue live requests, and its store is in memory.
final class ChatGPTSessionTests: XCTestCase {
    func testExpiredTokenRefreshRotatesCredentialsAndScopesAtomically() async throws {
        let fixture = try Fixture(
            scenario: Scenario(tokenBody: [
                "access_token": "synthetic-access-new", "refresh_token": "synthetic-refresh-new",
                "token_type": "Bearer", "expires_in": 3_600,
                "scope": "openid email offline_access resource.invoke chatgpt.tokens.use.direct new_scope",
            ]))
        defer { fixture.cleanup() }
        let token = try await fixture.auth.accessToken(expectedAccountID: "synthetic-account")
        XCTAssertEqual(token, "synthetic-access-new")
        let request = try XCTUnwrap(fixture.scenario.requests.first { $0.path.hasSuffix("/oauth/token") })
        XCTAssertEqual(request.fields["grant_type"], "refresh_token")
        XCTAssertEqual(request.fields["client_id"], "oaiapp_synthetic")
        XCTAssertEqual(request.fields["refresh_token"], "synthetic-refresh-old")
        XCTAssertEqual(request.fields["resource"], "https://api.openai.com/v1")
        XCTAssertNil(request.fields["scope"], "Refresh retains its grant without asking for a different scope")
        let account = await fixture.auth.activeAccount()
        XCTAssertTrue(account?.scopes.contains("new_scope") == true)
        XCTAssertFalse(account?.scopes.contains("old_scope") == true)
        XCTAssertEqual(account?.planUsageEnabled, true)
        let saved = try fixture.store.registration()
        let credentials = try XCTUnwrap(saved["credentials"] as? [String: Any])
        XCTAssertEqual(credentials["accessToken"] as? String, "synthetic-access-new")
        XCTAssertEqual(credentials["refreshToken"] as? String, "synthetic-refresh-new")
        XCTAssertNil(saved["pendingRefresh"])
        XCTAssertGreaterThanOrEqual(fixture.store.writes.count, 2, "Rotation is checkpointed before activation")
        for snapshot in fixture.store.writes {
            let item = try registration(in: snapshot)
            let published = try XCTUnwrap(item["credentials"] as? [String: Any])
            if published["accessToken"] as? String == "synthetic-access-new" {
                XCTAssertEqual(published["refreshToken"] as? String, "synthetic-refresh-new")
                XCTAssertTrue((item["scopes"] as? [String])?.contains("new_scope") == true)
                XCTAssertFalse((item["scopes"] as? [String])?.contains("old_scope") == true)
            } else {
                XCTAssertEqual(published["refreshToken"] as? String, "synthetic-refresh-old")
                XCTAssertNotNil(
                    item["pendingRefresh"], "Old credentials remain only behind the protected rotation checkpoint")
            }
        }
    }

    func testRefreshCanOmitUnchangedScopesAndIDToken() async throws {
        let fixture = try Fixture(
            scenario: Scenario(tokenBody: [
                "access_token": "synthetic-access-new", "refresh_token": "synthetic-refresh-new",
                "token_type": "Bearer", "expires_in": 3_600,
            ]))
        defer { fixture.cleanup() }
        _ = try await fixture.auth.accessToken()
        let account = await fixture.auth.activeAccount()
        XCTAssertEqual(Set(account?.scopes ?? []), Set(Fixture.scopes))
        XCTAssertEqual(account?.planUsageEnabled, true)
        let saved = try fixture.store.registration()
        XCTAssertEqual(saved["idToken"] as? String, "synthetic-previous-id-token")
        XCTAssertFalse(
            fixture.scenario.requests.contains { $0.path.contains("jwks") },
            "No refreshed ID token means no new ID-token verification")
    }

    func testRecoveredRotationCannotReturnTokenAfterPlanPermissionWasRemoved() async throws {
        let reducedScopes = ["openid", "email", "offline_access", "resource.invoke"]
        let fixture = try Fixture(scenario: Scenario(), pendingRefreshScopes: reducedScopes)
        defer { fixture.cleanup() }
        do {
            _ = try await fixture.auth.accessToken(expectedAccountID: "synthetic-account")
            XCTFail("A recovered rotation without direct permission returned a token")
        } catch let error as ChatGPTAuthError {
            XCTAssertEqual(error.code, "plan_usage_disabled")
        }
        XCTAssertTrue(fixture.scenario.requests.isEmpty, "No inference or refresh should start without plan permission")
        let account = await fixture.auth.activeAccount()
        XCTAssertEqual(account?.connected, true, "Identity remains connected even when plan use is disabled")
        XCTAssertEqual(account?.planUsageEnabled, false)
        XCTAssertEqual(Set(account?.scopes ?? []), Set(reducedScopes))
        let saved = try fixture.store.registration()
        XCTAssertNil(saved["pendingRefresh"])
        XCTAssertEqual(
            (saved["credentials"] as? [String: Any])?["refreshToken"] as? String, "synthetic-pending-refresh")
    }

    func testInvalidGrantClearsTokensButRetainsAccountAndHostIdentity() async throws {
        let fixture = try Fixture(scenario: Scenario(tokenStatus: 400, tokenBody: ["error": "invalid_grant"]))
        defer { fixture.cleanup() }
        do {
            _ = try await fixture.auth.accessToken()
            XCTFail("Invalid grant returned an access token")
        } catch let error as ChatGPTAuthError { XCTAssertEqual(error.code, "invalid_grant") }
        let account = await fixture.auth.activeAccount()
        XCTAssertEqual(account?.id, "synthetic-account")
        XCTAssertEqual(account?.clientID, "oaiapp_synthetic")
        XCTAssertEqual(account?.subject, "synthetic-subject")
        XCTAssertEqual(account?.connected, false)
        XCTAssertEqual(account?.planUsageEnabled, false)
        let saved = try fixture.store.registration()
        XCTAssertNil(saved["credentials"])
        XCTAssertNil(saved["idToken"])
        XCTAssertNil(saved["pendingRefresh"])
        XCTAssertEqual(
            try String(contentsOf: fixture.directory.appendingPathComponent("host-id"), encoding: .utf8), fixture.hostID
        )
    }

    func testTemporaryRefresh503PreservesCredentialsExactly() async throws {
        let fixture = try Fixture(
            scenario: Scenario(tokenStatus: 503, tokenBody: ["detail": "synthetic temporary failure"]))
        defer { fixture.cleanup() }
        let before = try XCTUnwrap(fixture.store.getString("connections-v1"))
        do {
            _ = try await fixture.auth.accessToken()
            XCTFail("Temporary failure returned an access token")
        } catch let error as ChatGPTAuthError { XCTAssertEqual(error.code, "oauth_http_503") }
        XCTAssertEqual(try fixture.store.getString("connections-v1"), before)
        XCTAssertTrue(fixture.store.writes.isEmpty)
        let account = await fixture.auth.activeAccount()
        XCTAssertEqual(account?.connected, true)
    }

    func testConcurrentCallersAcrossTwoAuthInstancesPerformOneRefresh() async throws {
        let fixture = try Fixture(scenario: Scenario(tokenDelay: 0.1))
        defer { fixture.cleanup() }
        let second = ChatGPTAuth(store: fixture.store, storageDirectory: fixture.directory, session: fixture.session)
        let values = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<8 {
                let auth = index.isMultiple(of: 2) ? fixture.auth : second
                group.addTask { try await auth.accessToken(expectedAccountID: "synthetic-account") }
            }
            var values: [String] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(values.count, 8)
        XCTAssertEqual(Set(values), ["synthetic-access-new"])
        XCTAssertEqual(fixture.scenario.requests.filter { $0.path.hasSuffix("/oauth/token") }.count, 1)
        XCTAssertEqual(
            (try fixture.store.registration()["credentials"] as? [String: Any])?["refreshToken"] as? String,
            "synthetic-refresh-new")
    }

    func testDisconnectRevokesRenewableSessionAndClearsOnlyInjectedCredentials() async throws {
        let fixture = try Fixture(scenario: Scenario())
        defer { fixture.cleanup() }
        try await fixture.auth.disconnect()
        let revocation = try XCTUnwrap(fixture.scenario.requests.first { $0.path.hasSuffix("/oauth/revoke") })
        XCTAssertEqual(revocation.fields["token"], "synthetic-refresh-old")
        XCTAssertEqual(revocation.fields["token_type_hint"], "refresh_token")
        XCTAssertEqual(revocation.fields["client_id"], "oaiapp_synthetic")
        XCTAssertFalse(fixture.scenario.requests.contains { $0.path.hasSuffix("/oauth/token") })
        let account = await fixture.auth.activeAccount()
        XCTAssertEqual(account?.connected, false)
        XCTAssertEqual(account?.id, "synthetic-account")
        let saved = try fixture.store.registration()
        XCTAssertNil(saved["credentials"])
        XCTAssertNil(saved["idToken"])
        XCTAssertEqual(
            try String(contentsOf: fixture.directory.appendingPathComponent("host-id"), encoding: .utf8), fixture.hostID
        )
    }

    func testBlockedCredentialStatusIsVisibleAndExplicitUnlockUsesOnlyInjectedStore() async throws {
        let fixture = try Fixture(scenario: Scenario())
        defer { fixture.cleanup() }
        let blocked = BlockedSessionStore()
        let auth = ChatGPTAuth(
            store: blocked, storageDirectory: fixture.directory, session: fixture.session,
            interactiveStoreFactory: { fixture.store })
        let before = await auth.credentialStatus()
        XCTAssertTrue(before.needsKeychainApproval)
        XCTAssertNotNil(before.accessError)
        XCTAssertFalse(before.hasSavedConnection)
        let invisible = await auth.activeAccount()
        XCTAssertNil(invisible)
        try await auth.unlockCredentialAccess()
        let after = await auth.credentialStatus()
        XCTAssertFalse(after.needsKeychainApproval)
        XCTAssertNil(after.accessError)
        XCTAssertTrue(after.hasSavedConnection)
        let account = await auth.activeAccount()
        XCTAssertEqual(account?.id, "synthetic-account")
        XCTAssertEqual(account?.planUsageEnabled, true)
        let token = try await auth.accessToken()
        XCTAssertEqual(
            token, "synthetic-access-new", "Subsequent refresh must use the explicitly unlocked injected store")
    }

    private func registration(in text: String) throws -> [String: Any] { try SessionStore.registration(in: text) }
}

private final class Fixture: @unchecked Sendable {
    static let scopes = [
        "openid", "email", "offline_access", "resource.invoke", "chatgpt.tokens.use.direct", "old_scope",
    ]
    let directory: URL
    let store: SessionStore
    let session: URLSession
    let auth: ChatGPTAuth
    let scenario: Scenario
    let identifier = UUID().uuidString
    let hostID = "urn:uuid:" + UUID().uuidString.lowercased()
    init(scenario: Scenario, pendingRefreshScopes: [String]? = nil) throws {
        self.scenario = scenario
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "macparakeet-auth-session-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(hostID.utf8).write(to: directory.appendingPathComponent("host-id"), options: .atomic)
        let credentials: [String: Any] = [
            "accessToken": "synthetic-access-old", "refreshToken": "synthetic-refresh-old",
            "expiresAt": Date().addingTimeInterval(-3_600).timeIntervalSinceReferenceDate,
            "scopes": Self.scopes,
        ]
        var registration: [String: Any] = [
            "id": "synthetic-account", "clientID": "oaiapp_synthetic", "subject": "synthetic-subject",
            "email": "synthetic@example.invalid", "name": "Synthetic Account", "authorized": true,
            "scopes": Self.scopes, "idToken": "synthetic-previous-id-token", "credentials": credentials,
        ]
        if let pendingRefreshScopes {
            registration["pendingRefresh"] = [
                "credentials": [
                    "accessToken": "synthetic-pending-access", "refreshToken": "synthetic-pending-refresh",
                    "expiresAt": Date().addingTimeInterval(3_600).timeIntervalSinceReferenceDate,
                    "scopes": pendingRefreshScopes,
                ],
                "receivedAt": Date().timeIntervalSinceReferenceDate,
            ]
        }
        let seed = try JSONSerialization.data(
            withJSONObject: ["activeID": "synthetic-account", "registrations": [registration]], options: [.sortedKeys])
        store = SessionStore(seed: String(decoding: seed, as: UTF8.self))
        SessionProtocol.registry.register(scenario, id: identifier)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SessionProtocol.self]
        configuration.httpAdditionalHeaders = ["X-MacParakeet-Test-ID": identifier]
        session = URLSession(configuration: configuration)
        auth = ChatGPTAuth(store: store, storageDirectory: directory, session: session)
    }
    func cleanup() {
        session.invalidateAndCancel()
        SessionProtocol.registry.remove(id: identifier)
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class SessionStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private var history: [String] = []
    init(seed: String) { values = ["connections-v1": seed] }
    var writes: [String] { lock.withLock { history } }
    func getString(_ key: String) throws -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) throws {
        lock.withLock {
            values[key] = value; history.append(value)
        }
    }
    func delete(_ key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
    func registration() throws -> [String: Any] { try Self.registration(in: getString("connections-v1")!) }
    static func registration(in text: String) throws -> [String: Any] {
        let vault = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        return (vault["registrations"] as! [[String: Any]])[0]
    }
}

private final class Scenario: @unchecked Sendable {
    struct Request: Sendable { let path: String; let fields: [String: String] }
    private let lock = NSLock()
    private var recorded: [Request] = []
    private let tokenStatus: Int
    private let tokenData: Data
    private let tokenDelay: TimeInterval
    var requests: [Request] { lock.withLock { recorded } }
    init(
        tokenStatus: Int = 200,
        tokenBody: [String: Any] = [
            "access_token": "synthetic-access-new", "refresh_token": "synthetic-refresh-new",
            "token_type": "Bearer", "expires_in": 3_600,
            "scope": ChatGPTAuth.requestedScopes,
        ], tokenDelay: TimeInterval = 0
    ) {
        self.tokenStatus = tokenStatus
        self.tokenData = try! JSONSerialization.data(withJSONObject: tokenBody)
        self.tokenDelay = tokenDelay
    }
    func respond(to request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let path = request.url!.path
        let body: Data
        if let bytes = request.httpBody {
            body = bytes
        } else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var collected = Data(), bytes = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                collected.append(contentsOf: bytes.prefix(count))
            }
            body = collected
        } else {
            body = Data()
        }
        var fields: [String: String] = [:]
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pieces.count == 2 {
                fields[String(pieces[0]).removingPercentEncoding ?? ""] =
                    String(pieces[1]).removingPercentEncoding ?? ""
            }
        }
        lock.withLock { recorded.append(Request(path: path, fields: fields)) }
        let status: Int, data: Data
        switch path {
        case "/.well-known/openid-configuration":
            status = 200
            data = try JSONSerialization.data(withJSONObject: [
                "issuer": "https://auth.openai.com",
                "authorization_endpoint": "https://auth.openai.com/api/accounts/authorize",
                "token_endpoint": "https://auth.openai.com/api/accounts/oauth/token",
                "revocation_endpoint": "https://auth.openai.com/api/accounts/oauth/revoke",
                "jwks_uri": "https://auth.openai.com/.well-known/jwks.json",
            ])
        case "/api/accounts/oauth/token":
            // A short synthetic delay ensures competing actor instances overlap.
            if tokenDelay > 0 { Thread.sleep(forTimeInterval: tokenDelay) }
            status = tokenStatus; data = tokenData
        case "/api/accounts/oauth/revoke": status = 200; data = Data()
        default: throw URLError(.unsupportedURL)
        }
        return (
            HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!, data
        )
    }
}

private final class ScenarioRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var scenarios: [String: Scenario] = [:]
    func register(_ scenario: Scenario, id: String) { lock.withLock { scenarios[id] = scenario } }
    func remove(id: String) { _ = lock.withLock { scenarios.removeValue(forKey: id) } }
    func scenario(id: String) -> Scenario? { lock.withLock { scenarios[id] } }
}
private final class SessionProtocol: URLProtocol, @unchecked Sendable {
    static let registry = ScenarioRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // This protocol is installed only on the injected URLSession. Unknown
        // requests fail closed rather than falling through to the real network.
        guard let id = request.value(forHTTPHeaderField: "X-MacParakeet-Test-ID"),
            let scenario = Self.registry.scenario(id: id)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        do {
            let (response, data) = try scenario.respond(to: request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private struct BlockedSessionStore: KeyValueStore {
    func getString(_ key: String) throws -> String? { throw KeychainError(status: errSecInteractionNotAllowed) }
    func setString(_ value: String, forKey key: String) throws {
        throw KeychainError(status: errSecInteractionNotAllowed)
    }
    func delete(_ key: String) throws { throw KeychainError(status: errSecInteractionNotAllowed) }
}
