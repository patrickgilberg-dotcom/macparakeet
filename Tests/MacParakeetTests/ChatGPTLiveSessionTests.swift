import Foundation
import XCTest
@testable import MacParakeetCore

/// All requests terminate in the injected protocol. Credentials are synthetic;
/// preference writes use only this fixture's unique account keys and are removed.
final class ChatGPTLiveSessionTests: XCTestCase, @unchecked Sendable {
    func testStableIdentityReusesOpaqueCacheKeyWithoutStartingInference() async throws {
        let fixture = try LiveSessionFixture()
        defer { fixture.cleanup() }

        let first = try await fixture.client.liveAnswerSession()
        let second = try await fixture.client.liveAnswerSession()

        XCTAssertFalse(first.cacheKey.isEmpty)
        XCTAssertEqual(first.cacheKey, second.cacheKey)
        XCTAssertFalse(first.cacheKey.contains(fixture.accountA))
        XCTAssertFalse(first.cacheKey.contains(fixture.accountB))
        XCTAssertEqual(fixture.scenario.responseRequests.count, 0)
    }

    func testBoundStreamSendsPinnedModelEffortAndAccountToken() async throws {
        let fixture = try LiveSessionFixture()
        defer { fixture.cleanup() }
        let session = try await fixture.client.liveAnswerSession()

        let text = try await collect(session)

        XCTAssertEqual(text, "Synthetic completed answer.")
        let request = try XCTUnwrap(fixture.scenario.responseRequests.first)
        XCTAssertEqual(request.model, LiveSessionFixture.modelA)
        XCTAssertEqual(request.effort, "none")
        XCTAssertEqual(request.authorization, "Bearer synthetic-live-access-a")
        XCTAssertEqual(fixture.scenario.responseRequests.count, 1)
    }

    func testModelChangeBetweenSummaryAndAnswerRejectsOldSessionBeforeAnotherSend() async throws {
        let fixture = try LiveSessionFixture()
        defer { fixture.cleanup() }
        let session = try await fixture.client.liveAnswerSession()
        _ = try await collect(session)

        try await fixture.client.selectModel(.init(model: LiveSessionFixture.modelB, reasoningEffort: "none"))
        let replacement = try await fixture.client.liveAnswerSession()

        XCTAssertNotEqual(session.cacheKey, replacement.cacheKey)
        await assertRejected(session)
        XCTAssertEqual(
            fixture.scenario.responseRequests.count, 1, "Old memory cannot send a final request on a new model")
    }

    func testEffortChangeBetweenChunksRejectsOldSessionBeforeAnotherSend() async throws {
        let fixture = try LiveSessionFixture()
        defer { fixture.cleanup() }
        let session = try await fixture.client.liveAnswerSession()
        _ = try await collect(session)

        try await fixture.client.selectModel(.init(model: LiveSessionFixture.modelA, reasoningEffort: "low"))
        let replacement = try await fixture.client.liveAnswerSession()

        XCTAssertNotEqual(session.cacheKey, replacement.cacheKey)
        await assertRejected(session)
        XCTAssertEqual(fixture.scenario.responseRequests.count, 1)
    }

    func testAccountChangeRejectsOldSessionWithoutSendingOnTheNewAccount() async throws {
        let fixture = try LiveSessionFixture()
        defer { fixture.cleanup() }
        let session = try await fixture.client.liveAnswerSession()

        try await fixture.auth.selectAccount(id: fixture.accountB)
        let replacement = try await fixture.client.liveAnswerSession()

        XCTAssertNotEqual(session.cacheKey, replacement.cacheKey)
        await assertRejected(session)
        XCTAssertTrue(fixture.scenario.responseRequests.isEmpty)
    }

    func testAccountSwitchDuringResponseCannotPublishTerminalSuccess() async throws {
        let fixture = try LiveSessionFixture()
        defer { fixture.cleanup() }
        let session = try await fixture.client.liveAnswerSession()
        fixture.scenario.beforeTerminal = { try fixture.store.selectAccount(fixture.accountB) }

        await assertRejected(session)

        XCTAssertEqual(fixture.scenario.responseRequests.count, 1)
        XCTAssertEqual(fixture.scenario.responseRequests.first?.authorization, "Bearer synthetic-live-access-a")
        await assertRejected(session)
        XCTAssertEqual(fixture.scenario.responseRequests.count, 1, "A later chunk cannot cross the changed account")
    }

    func testSelectionSwitchDuringResponseCannotPublishTerminalSuccess() async throws {
        let fixture = try LiveSessionFixture()
        defer { fixture.cleanup() }
        let session = try await fixture.client.liveAnswerSession()
        fixture.scenario.beforeTerminal = {
            try fixture.saveSelection(
                .init(model: LiveSessionFixture.modelB, reasoningEffort: "none"), for: fixture.accountA)
        }

        await assertRejected(session)

        XCTAssertEqual(fixture.scenario.responseRequests.count, 1)
        await assertRejected(session)
        XCTAssertEqual(fixture.scenario.responseRequests.count, 1)
    }

    func testAccountSwitchDuringCatalogFetchCannotCreateBoundSession() async throws {
        let fixture = try LiveSessionFixture()
        defer { fixture.cleanup() }
        fixture.scenario.beforeCatalog = { try fixture.store.selectAccount(fixture.accountB) }

        do {
            _ = try await fixture.client.liveAnswerSession()
            XCTFail("An account switch during identity preparation must reject the session")
        } catch {}

        XCTAssertTrue(fixture.scenario.responseRequests.isEmpty)
    }

    func testDisconnectCancelsForegroundAndDedicatedClientStreams() async throws {
        let fixture = try LiveSessionFixture(cancelAllClientsOnAuthChange: true)
        defer { fixture.cleanup() }
        let dedicated = ChatGPTLiveClient(auth: fixture.auth, session: fixture.session, transport: .httpSSE)
        fixture.scenario.holdResponses = true
        let foregroundSession = try await fixture.client.liveAnswerSession()
        let dedicatedSession = try await dedicated.liveAnswerSession()
        let foregroundOutcome = LiveSessionCancellationOutcome()
        let dedicatedOutcome = LiveSessionCancellationOutcome()
        let foreground = collectUntilFinished(foregroundSession, outcome: foregroundOutcome)
        let background = collectUntilFinished(dedicatedSession, outcome: dedicatedOutcome)
        defer { foreground.cancel(); background.cancel(); dedicated.cancelAll() }
        try await waitUntil { fixture.scenario.responseRequests.count == 2 }

        try await fixture.auth.disconnect()

        try await waitUntil { foregroundOutcome.finished && dedicatedOutcome.finished }
        XCTAssertFalse(foregroundOutcome.succeeded)
        XCTAssertFalse(dedicatedOutcome.succeeded)
        await assertRejected(foregroundSession)
        await assertRejected(dedicatedSession)
        XCTAssertEqual(fixture.scenario.responseRequests.count, 2, "Disconnect must not replay either request")
    }

    func testAccountSwitchCancelsDedicatedStreamAndRejectsItsOldScope() async throws {
        let fixture = try LiveSessionFixture(cancelAllClientsOnAuthChange: true)
        defer { fixture.cleanup() }
        let dedicated = ChatGPTLiveClient(auth: fixture.auth, session: fixture.session, transport: .httpSSE)
        fixture.scenario.holdResponses = true
        let original = try await dedicated.liveAnswerSession()
        let outcome = LiveSessionCancellationOutcome()
        let pending = collectUntilFinished(original, outcome: outcome)
        defer { pending.cancel(); dedicated.cancelAll() }
        try await waitUntil { fixture.scenario.responseRequests.count == 1 }

        try await fixture.auth.selectAccount(id: fixture.accountB)

        try await waitUntil { outcome.finished }
        XCTAssertFalse(outcome.succeeded)
        let replacement = try await dedicated.liveAnswerSession()
        XCTAssertNotEqual(original.cacheKey, replacement.cacheKey)
        await assertRejected(original)
        XCTAssertEqual(fixture.scenario.responseRequests.count, 1, "Old scope cannot send on the replacement account")
    }

    func testCancellationRegistryDoesNotRetainAnUnusedDedicatedClient() throws {
        let fixture = try LiveSessionFixture()
        defer { fixture.cleanup() }
        var dedicated: ChatGPTLiveClient? = ChatGPTLiveClient(
            auth: fixture.auth, session: fixture.session, transport: .httpSSE)
        weak var observed = dedicated
        dedicated = nil
        XCTAssertNil(observed, "Registering a transport lane must not keep its client alive")
    }

    func testDisconnectInvalidatesIdleSessionsBeforeRevocationFinishes() async throws {
        let fixture = try LiveSessionFixture(cancelAllClientsOnAuthChange: true, renewable: true)
        defer { fixture.cleanup() }
        let bound = try await fixture.client.liveAnswerSession()
        fixture.scenario.holdRevocation = true
        let disconnection = Task { try await fixture.auth.disconnect() }
        defer { disconnection.cancel(); fixture.scenario.releaseRevocation() }
        try await waitUntil { fixture.scenario.revocationIsWaiting }

        XCTAssertTrue(try fixture.store.activeRegistrationIsAuthorized(), "Remote revocation is still gated")
        let active = await fixture.auth.activeAccount()
        XCTAssertNil(active)
        do { try await bound.validate(); XCTFail("An idle session survived disconnect intent") } catch {}
        do {
            _ = try await fixture.client.liveAnswerSession()
            XCTFail("A new session was admitted during disconnect")
        } catch {}
        do {
            _ = try await fixture.auth.accessToken(expectedAccountID: fixture.accountA)
            XCTFail("Credentials escaped during disconnect")
        } catch {}
        XCTAssertTrue(fixture.scenario.responseRequests.isEmpty)

        fixture.scenario.releaseRevocation()
        try await disconnection.value
        do { try await bound.validate(); XCTFail("A disconnected session became valid again") } catch {}
    }

    func testSameAccountTransitionRejectsOldSessionWithoutChangingDurableProviderKey() async throws {
        let fixture = try LiveSessionFixture(cancelAllClientsOnAuthChange: true)
        defer { fixture.cleanup() }
        let original = try await fixture.client.liveAnswerSession()
        try await fixture.auth.selectAccount(id: fixture.accountA)
        let replacement = try await fixture.client.liveAnswerSession()

        do { try await original.validate(); XCTFail("Same-account transition revived the old session") } catch {}
        try await replacement.validate()
        XCTAssertEqual(original.cacheKey, replacement.cacheKey, "A local epoch is not durable provider identity")
        let restartedAuth = ChatGPTAuth(
            store: fixture.store, storageDirectory: fixture.directory, session: fixture.session)
        let restartedClient = ChatGPTLiveClient(auth: restartedAuth, session: fixture.session, transport: .httpSSE)
        let restarted = try await restartedClient.liveAnswerSession()
        XCTAssertEqual(restarted.cacheKey, replacement.cacheKey, "Safe checkpoints must survive app restart")
        XCTAssertTrue(fixture.scenario.responseRequests.isEmpty)
    }

    private func collectUntilFinished(
        _ session: LiveAnswerStreamSession, outcome: LiveSessionCancellationOutcome
    ) -> Task<Void, Never> {
        Task {
            do {
                _ = try await collect(session)
                outcome.finish(succeeded: true)
            } catch {
                outcome.finish(succeeded: false)
            }
        }
    }

    private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Synthetic client cancellation did not settle")
        throw URLError(.timedOut)
    }

    private func collect(_ session: LiveAnswerStreamSession) async throws -> String {
        var text = ""
        for try await delta in session.stream(messages: [.init(role: .user, content: "Synthetic question.")]) {
            text += delta
        }
        return text
    }

    private func assertRejected(
        _ session: LiveAnswerStreamSession, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await collect(session)
            XCTFail("Changed identity must not complete a bound stream", file: file, line: line)
        } catch {}
    }
}

private final class LiveSessionFixture: @unchecked Sendable {
    static let modelA = "synthetic-live-luna"
    static let modelB = "synthetic-live-other"
    private static let scopes = ["openid", "resource.invoke", "chatgpt.tokens.use.direct"]
    let accountA = "macparakeet.tests.live-session.a." + UUID().uuidString
    let accountB = "macparakeet.tests.live-session.b." + UUID().uuidString
    let directory: URL
    let store: LiveSessionStore
    let scenario = LiveSessionScenario()
    let identifier = UUID().uuidString
    let session: URLSession
    let auth: ChatGPTAuth
    let client: ChatGPTLiveClient

    init(cancelAllClientsOnAuthChange: Bool = false, renewable: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "macparakeet-live-bound-session-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func registration(id: String, suffix: String) -> [String: Any] {
            var credentials: [String: Any] = [
                "accessToken": "synthetic-live-access-" + suffix,
                "expiresAt": Date().addingTimeInterval(3_600).timeIntervalSinceReferenceDate,
                "scopes": Self.scopes,
            ]
            if renewable { credentials["refreshToken"] = "synthetic-live-refresh-" + suffix }
            return [
                "id": id, "clientID": "oaiapp_synthetic_" + suffix,
                "subject": "synthetic-subject-" + suffix, "authorized": true,
                "scopes": Self.scopes,
                "credentials": credentials,
            ]
        }
        let vault = try JSONSerialization.data(withJSONObject: [
            "activeID": accountA,
            "registrations": [registration(id: accountA, suffix: "a"), registration(id: accountB, suffix: "b")],
        ])
        store = LiveSessionStore(seed: String(decoding: vault, as: UTF8.self))
        LiveSessionProtocol.registry.register(scenario, id: identifier)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveSessionProtocol.self]
        configuration.httpAdditionalHeaders = ["X-MacParakeet-Live-Session-Test": identifier]
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
        auth = ChatGPTAuth(
            store: store, storageDirectory: directory, session: session,
            cancelRequests: {
                if cancelAllClientsOnAuthChange { ChatGPTLiveClient.cancelAllClients() }
            })
        client = ChatGPTLiveClient(auth: auth, session: session, transport: .httpSSE)
        try saveSelection(.init(model: Self.modelA, reasoningEffort: "none"), for: accountA)
        try saveSelection(.init(model: Self.modelA, reasoningEffort: "none"), for: accountB)
    }

    func saveSelection(_ selection: ChatGPTModelSelection, for accountID: String) throws {
        AppPaths.sharedAppDefaults().set(
            try JSONEncoder().encode(selection), forKey: "chatgpt.live.selection.\(accountID)")
    }

    func cleanup() {
        scenario.releaseRevocation()
        client.cancelAll()
        session.invalidateAndCancel()
        LiveSessionProtocol.registry.remove(id: identifier)
        for id in [accountA, accountB] {
            AppPaths.sharedAppDefaults().removeObject(forKey: "chatgpt.live.selection.\(id)")
        }
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class LiveSessionStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    init(seed: String) { values = ["connections-v1": seed] }
    func getString(_ key: String) throws -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) throws { lock.withLock { values[key] = value } }
    func delete(_ key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
    func selectAccount(_ id: String) throws {
        try lock.withLock {
            var vault = try JSONSerialization.jsonObject(with: Data(values["connections-v1"]!.utf8)) as! [String: Any]
            vault["activeID"] = id
            values["connections-v1"] = String(
                decoding: try JSONSerialization.data(withJSONObject: vault), as: UTF8.self)
        }
    }
    func activeRegistrationIsAuthorized() throws -> Bool {
        try lock.withLock {
            let vault = try JSONSerialization.jsonObject(with: Data(values["connections-v1"]!.utf8)) as! [String: Any]
            let registrations = vault["registrations"] as! [[String: Any]]
            return registrations.first { $0["id"] as? String == vault["activeID"] as? String }?["authorized"] as? Bool
                == true
        }
    }
}

private final class LiveSessionScenario: @unchecked Sendable {
    struct Request: Sendable {
        let model: String?
        let effort: String?
        let authorization: String?
    }
    private let lock = NSLock()
    private var requests: [Request] = []
    private var catalogHook: (@Sendable () throws -> Void)?
    private var terminalHook: (@Sendable () throws -> Void)?
    private var holdsResponses = false
    private var holdsRevocation = false
    private var pendingRevocation: (@Sendable () -> Void)?
    var responseRequests: [Request] { lock.withLock { requests } }
    var holdResponses: Bool {
        get { lock.withLock { holdsResponses } }
        set { lock.withLock { holdsResponses = newValue } }
    }
    var holdRevocation: Bool {
        get { lock.withLock { holdsRevocation } }
        set { lock.withLock { holdsRevocation = newValue } }
    }
    var revocationIsWaiting: Bool { lock.withLock { pendingRevocation != nil } }
    func receiveRevocation(_ completion: @escaping @Sendable () -> Void) {
        let held = lock.withLock {
            guard holdsRevocation else { return false }
            pendingRevocation = completion
            return true
        }
        if !held { completion() }
    }
    func releaseRevocation() {
        let completion = lock.withLock {
            holdsRevocation = false
            let completion = pendingRevocation
            pendingRevocation = nil
            return completion
        }
        completion?()
    }
    var beforeCatalog: (@Sendable () throws -> Void)? {
        get { lock.withLock { catalogHook } }
        set { lock.withLock { catalogHook = newValue } }
    }
    var beforeTerminal: (@Sendable () throws -> Void)? {
        get { lock.withLock { terminalHook } }
        set { lock.withLock { terminalHook = newValue } }
    }
    func record(_ request: URLRequest) throws {
        let object = try JSONSerialization.jsonObject(with: Self.body(request)) as! [String: Any]
        let reasoning = object["reasoning"] as? [String: Any]
        let item = Request(
            model: object["model"] as? String, effort: reasoning?["effort"] as? String,
            authorization: request.value(forHTTPHeaderField: "Authorization"))
        lock.withLock { requests.append(item) }
    }
    private static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}

private final class LiveSessionCancellationOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    var finished: Bool { lock.withLock { result != nil } }
    var succeeded: Bool { lock.withLock { result == true } }
    func finish(succeeded: Bool) { lock.withLock { result = succeeded } }
}

private final class LiveSessionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var scenarios: [String: LiveSessionScenario] = [:]
    func register(_ scenario: LiveSessionScenario, id: String) { lock.withLock { scenarios[id] = scenario } }
    func remove(id: String) { _ = lock.withLock { scenarios.removeValue(forKey: id) } }
    func scenario(id: String) -> LiveSessionScenario? { lock.withLock { scenarios[id] } }
}

private final class LiveSessionProtocol: URLProtocol, @unchecked Sendable {
    static let registry = LiveSessionRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-MacParakeet-Live-Session-Test"),
            let scenario = Self.registry.scenario(id: id), let url = request.url
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        do {
            switch url.path {
            case "/.well-known/openid-configuration":
                let data = try JSONSerialization.data(withJSONObject: [
                    "issuer": "https://auth.openai.com",
                    "authorization_endpoint": "https://auth.openai.com/api/accounts/authorize",
                    "token_endpoint": "https://auth.openai.com/api/accounts/oauth/token",
                    "revocation_endpoint": "https://auth.openai.com/api/accounts/oauth/revoke",
                    "jwks_uri": "https://auth.openai.com/.well-known/jwks.json",
                ])
                receive(data, type: "application/json", url: url)
            case "/api/accounts/oauth/revoke":
                scenario.receiveRevocation { [self] in receive(Data(), type: "application/json", url: url) }
            case "/v1/models":
                try scenario.beforeCatalog?()
                let data = try JSONSerialization.data(withJSONObject: [
                    "models": [LiveSessionFixture.modelA, LiveSessionFixture.modelB].map {
                        ["slug": $0, "display_name": $0, "visibility": "list"]
                    }
                ])
                receive(data, type: "application/json", url: url)
            case "/v1/responses":
                try scenario.record(request)
                let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/event-stream"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(
                    self,
                    didLoad: Data(
                        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Synthetic completed answer.\"}\n\n"
                            .utf8))
                if scenario.holdResponses { return }
                try scenario.beforeTerminal?()
                client?.urlProtocol(self, didLoad: Data("data: {\"type\":\"response.completed\"}\n\n".utf8))
                client?.urlProtocolDidFinishLoading(self)
            default:
                throw URLError(.unsupportedURL)
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    private func receive(_ data: Data, type: String, url: URL) {
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
