import Foundation
import Security
import XCTest
@testable import MacParakeetCore

/// All Google HTTPS requests are intercepted by an injected URLProtocol. The
/// only real sockets used below are a synthetic localhost OAuth callback.
final class GoogleCalendarTests: XCTestCase {
    func testPKCEAndReadOnlyAuthorization() throws {
        XCTAssertEqual(
            GoogleCalendarOAuth.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let random = try GoogleCalendarOAuth.randomURLSafe()
        XCTAssertEqual(random.count, 43)
        XCTAssertNotEqual(random, try GoogleCalendarOAuth.randomURLSafe())
        let url = GoogleCalendarOAuth.authorizationURL(
            configuration: try Self.configuration(),
            redirectURI: "http://127.0.0.1:12345/", state: "synthetic-state", verifier: random)
        let values = Dictionary(
            uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map {
                ($0.name, $0.value!)
            })
        XCTAssertEqual(values["redirect_uri"], "http://127.0.0.1:12345/")
        XCTAssertEqual(values["code_challenge_method"], "S256")
        XCTAssertEqual(values["access_type"], "offline")
        XCTAssertEqual(values["response_type"], "code")
        XCTAssertEqual(Set(values["scope"]!.split(separator: " ").map(String.init)), GoogleCalendarOAuth.requiredScopes)
        XCTAssertNil(values["client_secret"])
    }

    func testDesktopDownloadedConfigurationAndTypedMissingConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("client.json")
        do {
            _ = try GoogleCalendarOAuthConfiguration.load(environment: [:], localURL: file)
            XCTFail("Missing registration was accepted")
        } catch let error as GoogleCalendarError { XCTAssertEqual(error.code, "missing_configuration") }
        let data = Data(
            #"{"installed":{"client_id":"synthetic.apps.googleusercontent.com","client_secret":"public-desktop-secret","redirect_uris":["http://localhost"]}}"#
                .utf8)
        try data.write(to: file)
        let configuration = try GoogleCalendarOAuthConfiguration.load(environment: [:], localURL: file)
        XCTAssertEqual(configuration.clientID, "synthetic.apps.googleusercontent.com")
        XCTAssertEqual(configuration.clientSecret, "public-desktop-secret")
    }

    func testCallbackRequiresExactHostPathUniqueStateAndCode() {
        guard case .accepted(let callback) = Self.parse("state=expected&code=synthetic&scope=ignored") else {
            return XCTFail("Valid callback rejected")
        }
        XCTAssertEqual(callback.code, "synthetic")
        for query in ["state=wrong&code=c", "state&state=expected&code=c", "state=expected&state=expected&code=c"] {
            guard case .invalidState = Self.parse(query) else { return XCTFail("Unbound callback accepted") }
        }
        for query in [
            "state=expected&code&code=c", "state=expected&code=a&code=b", "state=expected&code=",
            "state=expected&code=c&error=access_denied",
        ] {
            guard case .failed = Self.parse(query) else { return XCTFail("Ambiguous callback accepted") }
        }
        for request in [
            "GET /other?state=expected&code=c HTTP/1.1\r\nHost: 127.0.0.1:12345\r\n\r\n",
            "GET /?state=expected&code=c HTTP/1.1\r\nHost: localhost:12345\r\n\r\n",
            "POST /?state=expected&code=c HTTP/1.1\r\nHost: 127.0.0.1:12345\r\n\r\n",
        ] {
            guard
                case .unrelated = GoogleCalendarLoopbackListener.parse(request, port: 12345, expectedState: "expected")
            else {
                return XCTFail("Unrelated request accepted")
            }
        }
    }

    func testLoopbackRejectsWrongStateThenAcceptsExactCallback() async throws {
        let listener = try GoogleCalendarLoopbackListener(state: "expected")
        let result = Task { try await listener.result() }
        let (_, rejected) = try await URLSession.shared.data(
            from: URL(string: listener.redirectURI + "?state=wrong&code=c")!)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 400)
        let (_, accepted) = try await URLSession.shared.data(
            from: URL(string: listener.redirectURI + "?state=expected&code=c")!)
        XCTAssertEqual((accepted as? HTTPURLResponse)?.statusCode, 200)
        let callback = try await result.value
        XCTAssertEqual(callback.code, "c")
    }

    func testRefreshRetainsRefreshTokenWhenGoogleOmitsRotation() async throws {
        let fixture = try GoogleFixture(
            expired: true,
            scenario: GoogleScenario(tokenBody: [
                "access_token": "synthetic-access-new", "expires_in": 3600, "token_type": "Bearer",
            ]))
        defer { fixture.cleanup() }
        let access = try await fixture.auth.accessToken(expectedAccountID: "synthetic-account")
        XCTAssertEqual(access, "synthetic-access-new")
        let stored = try XCTUnwrap(fixture.store.record())
        XCTAssertEqual(stored.refreshToken, "synthetic-refresh-old")
        XCTAssertEqual(stored.accessToken, "synthetic-access-new")
        let request = try XCTUnwrap(fixture.scenario.requests.first { $0.url?.path == "/token" })
        let fields = GoogleScenario.fields(request)
        XCTAssertEqual(fields["grant_type"], "refresh_token")
        XCTAssertEqual(fields["client_id"], "synthetic.apps.googleusercontent.com")
        XCTAssertEqual(fields["refresh_token"], "synthetic-refresh-old")
    }

    func testRefreshRotatesCredentialsAndScopesInOneWrite() async throws {
        let scenario = GoogleScenario(tokenBody: [
            "access_token": "synthetic-access-new", "refresh_token": "synthetic-refresh-new",
            "expires_in": 3600, "token_type": "Bearer",
            "scope": GoogleCalendarOAuth.requiredScopes.sorted().joined(separator: " ") + " extra_scope",
        ])
        let fixture = try GoogleFixture(expired: true, scenario: scenario)
        defer { fixture.cleanup() }
        _ = try await fixture.auth.accessToken()
        let saved = try XCTUnwrap(fixture.store.record())
        XCTAssertEqual(saved.refreshToken, "synthetic-refresh-new")
        XCTAssertTrue(saved.connection.scopes.contains("extra_scope"))
        XCTAssertEqual(fixture.store.writeCount, 1)
    }

    func testConcurrentExpiredCallersUseSingleRefresh() async throws {
        let fixture = try GoogleFixture(expired: true, scenario: GoogleScenario(tokenDelay: 0.08))
        defer { fixture.cleanup() }
        let auth = fixture.auth
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<12 { group.addTask { try await auth.accessToken(expectedAccountID: "synthetic-account") } }
            var result: [String] = []
            for try await token in group { result.append(token) }
            return result
        }
        XCTAssertEqual(tokens.count, 12)
        XCTAssertTrue(tokens.allSatisfy { $0 == "synthetic-access-new" })
        XCTAssertEqual(fixture.scenario.requests.filter { $0.url?.path == "/token" }.count, 1)
    }

    func testTerminalInvalidGrantDisconnectsAndTemporary503PreservesCredentials() async throws {
        for status in [400, 503] {
            let scenario = GoogleScenario(
                tokenStatus: status, tokenBody: ["error": status == 400 ? "invalid_grant" : "temporarily_unavailable"])
            let fixture = try GoogleFixture(expired: true, scenario: scenario)
            defer { fixture.cleanup() }
            let before = try fixture.store.getString(GoogleCalendarAuth.storageKey)
            do { _ = try await fixture.auth.accessToken(); XCTFail("Failure returned token") } catch let error
                as GoogleCalendarError
            {
                XCTAssertEqual(error.code, status == 400 ? "invalid_grant" : "authorization_unavailable")
            }
            let connection = await fixture.auth.connection()
            if status == 400 {
                XCTAssertNil(connection)
                XCTAssertNil(try fixture.store.record())
                XCTAssertFalse(fixture.auth.isConnected)
            } else {
                XCTAssertNotNil(connection)
                XCTAssertEqual(try fixture.store.getString(GoogleCalendarAuth.storageKey), before)
            }
        }
    }

    func testReducedRefreshScopesNeverReturnToken() async throws {
        let fixture = try GoogleFixture(
            expired: true,
            scenario: GoogleScenario(tokenBody: [
                "access_token": "synthetic-access-new", "expires_in": 3600, "token_type": "Bearer",
                "scope": "openid email",
            ]))
        defer { fixture.cleanup() }
        do { _ = try await fixture.auth.accessToken(); XCTFail("Reduced grant returned a token") } catch let error
            as GoogleCalendarError
        { XCTAssertEqual(error.code, "insufficient_scope") }
        XCTAssertNil(try fixture.store.record())
    }

    func testExpectedAccountMismatchMakesNoRequest() async throws {
        let fixture = try GoogleFixture(expired: true)
        defer { fixture.cleanup() }
        do {
            _ = try await fixture.auth.accessToken(expectedAccountID: "different-account"); XCTFail("Mixed account")
        } catch let error as GoogleCalendarError { XCTAssertEqual(error.code, "account_changed") }
        XCTAssertTrue(fixture.scenario.requests.isEmpty)
    }

    func testDisconnectRevokesAndLateRefreshCannotPublish() async throws {
        let fixture = try GoogleFixture(expired: true, scenario: GoogleScenario(tokenDelay: 0.15))
        defer { fixture.cleanup() }
        let refresh = Task { try await fixture.auth.accessToken() }
        try await waitForRequest("/token", scenario: fixture.scenario)
        try await fixture.auth.disconnect()
        do { _ = try await refresh.value; XCTFail("Late refresh returned token") } catch {}
        XCTAssertNil(try fixture.store.record())
        let connection = await fixture.auth.connection()
        XCTAssertNil(connection)
        XCTAssertTrue(fixture.scenario.requests.contains { $0.url?.path == "/revoke" })
    }

    func testKeychainFailureIsVisibleAndExplicitUnlockRestoresSavedConnection() async throws {
        let fixture = try GoogleFixture()
        defer { fixture.cleanup() }
        let auth = GoogleCalendarAuth(
            store: GoogleBlockedStore(), interactiveStore: fixture.store,
            session: fixture.session, configurationProvider: { try Self.configuration() })
        XCTAssertFalse(auth.isConnected)
        let error = await auth.credentialAccessError()
        XCTAssertNotNil(error)
        let connection = try await auth.unlockCredentialAccess()
        XCTAssertEqual(connection?.id, "synthetic-account")
        XCTAssertTrue(auth.isConnected)
    }

    func testInFlightProjectRevocationBlocksReconnectAndSecondDisconnectUntilSettled() async throws {
        let fixture = try GoogleFixture(scenario: GoogleScenario(revocationDelay: 0.15))
        defer { fixture.cleanup() }
        let disconnect = Task { try await fixture.auth.disconnect() }
        try await waitForRequest("/revoke", scenario: fixture.scenario)
        do {
            _ = try await fixture.auth.signIn()
            XCTFail("Reconnect raced an in-flight project-wide revocation")
        } catch let error as GoogleCalendarError { XCTAssertEqual(error.code, "connection_busy") }
        do {
            try await fixture.auth.disconnect()
            XCTFail("A second Disconnect raced the first")
        } catch let error as GoogleCalendarError { XCTAssertEqual(error.code, "connection_busy") }
        try await disconnect.value
        XCTAssertNil(try fixture.store.record())
        XCTAssertEqual(fixture.scenario.requests.filter { $0.url?.path == "/revoke" }.count, 1)
        do {
            _ = try await fixture.auth.signIn()
            XCTFail("The injected browser should not open")
        } catch let error as GoogleCalendarError {
            XCTAssertEqual(error.code, "browser_unavailable", "Reconnect gate must release once revocation settles")
        }
    }

    func testCancellationAfterCodeExchangeCannotActivateAccount() async throws {
        let fixture = try GoogleFixture(
            seed: false, scenario: GoogleScenario(identityDelay: 0.15), automaticCallback: true)
        defer { fixture.cleanup() }
        let signIn = Task { try await fixture.auth.signIn() }
        try await waitForRequest("/v1/userinfo", scenario: fixture.scenario)
        await fixture.auth.cancelSignIn()
        do { _ = try await signIn.value; XCTFail("Cancelled sign-in activated") } catch {}
        XCTAssertNil(try fixture.store.record())
        let connection = await fixture.auth.connection()
        XCTAssertNil(connection)
        try await waitForRequest("/revoke", scenario: fixture.scenario)
    }

    func testSignInUsesVerifiedUserInfoAndItsOwnAtomicStore() async throws {
        let fixture = try GoogleFixture(seed: false, automaticCallback: true)
        defer { fixture.cleanup() }
        let account = try await fixture.auth.signIn()
        XCTAssertEqual(account.id, "synthetic-new-account")
        XCTAssertEqual(account.email, "patrick@example.invalid")
        XCTAssertEqual(Set(account.scopes), GoogleCalendarOAuth.requiredScopes)
        let saved = try XCTUnwrap(fixture.store.record())
        XCTAssertEqual(saved.connection, account)
        XCTAssertEqual(saved.refreshToken, "synthetic-login-refresh")
        XCTAssertTrue(fixture.auth.isConnected)
        XCTAssertEqual(fixture.store.writeCount, 1)
    }

    func testPaginatedCalendarAndEventReadsPreserveOccurrenceIdentity() async throws {
        let scenario = GoogleScenario(calendarHandler: { request in
            let url = request.url!
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first {
                $0.name == "pageToken"
            }?.value
            if url.path.hasSuffix("calendarList") {
                if page == nil {
                    return [
                        "items": [["id": "primary@example.invalid", "summary": "My Calendar", "primary": true]],
                        "nextPageToken": "cal-page-2",
                    ]
                }
                return ["items": [["id": "shared@example.invalid", "summary": "Ajay", "timeZone": "America/Edmonton"]]]
            }
            if url.path.contains("primary@example.invalid") {
                if page == nil { return ["items": [Self.event(id: "first")], "nextPageToken": "events-page-2"] }
                return ["items": [Self.event(id: "second")]]
            }
            var moved = Self.event(id: "moved-instance")
            moved["recurringEventId"] = "series-id"
            moved["iCalUID"] = "ical-series@example.invalid"
            moved["originalStartTime"] = ["dateTime": "2026-10-28T09:00:00-06:00"]
            return ["items": [moved]]
        })
        let fixture = try GoogleFixture(scenario: scenario)
        defer { fixture.cleanup() }
        let service = GoogleCalendarService(auth: fixture.auth, session: fixture.session)
        let events = try await service.fetchUpcomingEvents(from: Self.referenceDate, days: 2)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(Set(events.map(\.id)).count, 3)
        let moved = try XCTUnwrap(events.first { $0.providerEventID == "moved-instance" })
        XCTAssertEqual(moved.provider, .google)
        XCTAssertEqual(moved.calendarIdentifier, "shared@example.invalid")
        XCTAssertEqual(moved.providerRecurringEventID, "series-id")
        XCTAssertEqual(moved.externalId, "ical-series@example.invalid")
        XCTAssertNotNil(moved.originalOccurrenceStart)
        XCTAssertEqual(moved.title, "Exact Synthetic Title")
        XCTAssertTrue(
            scenario.requests.filter { $0.url?.path.hasSuffix("/events") == true }.allSatisfy {
                let query = URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.queryItems!
                return query.contains(URLQueryItem(name: "singleEvents", value: "true"))
                    && query.contains(URLQueryItem(name: "orderBy", value: "startTime"))
            })
    }

    func testSharedOwnerSelfDoesNotImplyConnectedUserAttends() throws {
        let calendar = try decodeCalendar(["id": "ajay@example.invalid", "summary": "Ajay", "primary": false])
        var body = Self.event(id: "ajay-only")
        body["attendees"] = [["email": "ajay@example.invalid", "self": true, "responseStatus": "accepted"]]
        body["organizer"] = ["email": "ajay@example.invalid", "self": true]
        let resource = try JSONDecoder().decode(
            GoogleCalendarService.EventResource.self, from: JSONSerialization.data(withJSONObject: body))
        let event = try XCTUnwrap(resource.calendarEvent(calendar: calendar, accountEmail: "patrick@example.invalid"))
        XCTAssertEqual(event.isUserMeeting, false)
        XCTAssertNil(event.userStatus)
        XCTAssertEqual(event.participants.first?.email, "ajay@example.invalid")
        body["attendees"] = [["email": "PATRICK@example.invalid", "self": false, "responseStatus": "tentative"]]
        let invited = try JSONDecoder().decode(
            GoogleCalendarService.EventResource.self, from: JSONSerialization.data(withJSONObject: body))
        let invitation = try XCTUnwrap(
            invited.calendarEvent(calendar: calendar, accountEmail: "patrick@example.invalid"))
        XCTAssertEqual(invitation.isUserMeeting, true)
        XCTAssertEqual(invitation.userStatus, .tentative)
        XCTAssertTrue(invitation.participants.isEmpty)
    }

    func testAllDayParsingUsesCalendarZoneAndCancelledEventsAreSkipped() throws {
        let calendar = try decodeCalendar(["id": "shared", "timeZone": "America/Edmonton"])
        var body = Self.event(id: "all-day")
        body["start"] = ["date": "2026-10-28"]
        body["end"] = ["date": "2026-10-29"]
        let resource = try JSONDecoder().decode(
            GoogleCalendarService.EventResource.self, from: JSONSerialization.data(withJSONObject: body))
        let event = try XCTUnwrap(resource.calendarEvent(calendar: calendar, accountEmail: "patrick@example.invalid"))
        XCTAssertTrue(event.isAllDay)
        XCTAssertEqual(event.startTime, ISO8601DateFormatter().date(from: "2026-10-28T06:00:00Z"))
        body["status"] = "cancelled"
        let cancelled = try JSONDecoder().decode(
            GoogleCalendarService.EventResource.self, from: JSONSerialization.data(withJSONObject: body))
        XCTAssertNil(cancelled.calendarEvent(calendar: calendar, accountEmail: "patrick@example.invalid"))
    }

    func testSelectionChangeDiscardsInFlightResultsAndExclusionsAvoidRequests() async throws {
        let scenario = GoogleScenario(
            calendarDelay: 0.1,
            calendarHandler: { request in
                if request.url!.path.hasSuffix("calendarList") {
                    return ["items": [["id": "shared", "summary": "Shared"]]]
                }
                return ["items": [Self.event(id: "one")]]
            })
        let fixture = try GoogleFixture(scenario: scenario)
        defer { fixture.cleanup() }
        let service = GoogleCalendarService(auth: fixture.auth, session: fixture.session)
        let pending = Task { try await service.fetchUpcomingEvents(from: Self.referenceDate, days: 1) }
        try await waitForRequest("/calendar/v3/users/me/calendarList", scenario: scenario)
        await service.setExcludedCalendarIDs(["shared"])
        do { _ = try await pending.value; XCTFail("Stale selection published") } catch let error as GoogleCalendarError
        { XCTAssertEqual(error.code, "calendar_selection_changed") }
        let events = try await service.fetchUpcomingEvents(from: Self.referenceDate, days: 1)
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(scenario.requests.contains { $0.url?.path.hasSuffix("/events") == true })
    }

    func testDisconnectDiscardsInFlightCalendarPage() async throws {
        let scenario = GoogleScenario(
            calendarDelay: 0.1, calendarHandler: { _ in ["items": [["id": "shared", "summary": "Shared"]]] })
        let fixture = try GoogleFixture(scenario: scenario)
        defer { fixture.cleanup() }
        let service = GoogleCalendarService(auth: fixture.auth, session: fixture.session)
        let pending = Task { try await service.loadAvailableCalendars() }
        try await waitForRequest("/calendar/v3/users/me/calendarList", scenario: scenario)
        try await fixture.auth.disconnect()
        do { _ = try await pending.value; XCTFail("Disconnected response published") } catch let error
            as GoogleCalendarError
        { XCTAssertEqual(error.code, "account_changed") }
        XCTAssertEqual(service.permissionStatus, .notDetermined)
    }

    func testCalendarIDIsEncodedAsSinglePathSegment() {
        let url = GoogleCalendarService.eventsURL(
            calendarID: "shared/one+two@example.invalid?x", from: Self.referenceDate,
            to: Self.referenceDate.addingTimeInterval(3600), page: nil)
        XCTAssertTrue(url.absoluteString.contains("shared%2Fone%2Btwo%40example.invalid%3Fx/events"))
        XCTAssertNil(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "x" })
    }

    private func decodeCalendar(_ object: [String: Any]) throws -> GoogleCalendarService.CalendarResource {
        try JSONDecoder().decode(
            GoogleCalendarService.CalendarResource.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private static let referenceDate = ISO8601DateFormatter().date(from: "2026-10-28T12:00:00Z")!
    private static func event(id: String) -> [String: Any] {
        [
            "id": id, "summary": "Exact Synthetic Title", "status": "confirmed",
            "start": ["dateTime": "2026-10-28T10:00:00-06:00"], "end": ["dateTime": "2026-10-28T11:00:00-06:00"],
        ]
    }
    private static func configuration() throws -> GoogleCalendarOAuthConfiguration {
        try GoogleCalendarOAuthConfiguration(clientID: "synthetic.apps.googleusercontent.com")
    }
    private static func parse(_ query: String) -> GoogleCalendarLoopbackListener.ParsedCallback {
        GoogleCalendarLoopbackListener.parse(
            "GET /?\(query) HTTP/1.1\r\nHost: 127.0.0.1:12345\r\n\r\n", port: 12345, expectedState: "expected")
    }
    private func waitForRequest(_ path: String, scenario: GoogleScenario) async throws {
        for _ in 0..<200 {
            if scenario.requests.contains(where: { $0.url?.path == path }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Synthetic request was not issued")
        throw URLError(.timedOut)
    }
}

private struct GoogleFixture {
    let store: GoogleMemoryStore
    let session: URLSession
    let auth: GoogleCalendarAuth
    let scenario: GoogleScenario
    let identifier = UUID().uuidString

    init(
        expired: Bool = false, seed: Bool = true, scenario: GoogleScenario = GoogleScenario(),
        automaticCallback: Bool = false
    ) throws {
        self.scenario = scenario
        store = GoogleMemoryStore()
        if seed {
            let record = GoogleCalendarAuth.StoredConnection(
                connection: GoogleCalendarConnection(
                    id: "synthetic-account", email: "patrick@example.invalid",
                    scopes: GoogleCalendarOAuth.requiredScopes.sorted()),
                clientID: "synthetic.apps.googleusercontent.com", accessToken: "synthetic-access-old",
                refreshToken: "synthetic-refresh-old",
                expiresAt: Date().addingTimeInterval(expired ? -60 : 3600))
            store.seed(String(decoding: try JSONEncoder().encode(record), as: UTF8.self))
        }
        GoogleTestProtocol.registry.register(scenario, id: identifier)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoogleTestProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Google-Test-ID": identifier]
        session = URLSession(configuration: configuration)
        auth = GoogleCalendarAuth(
            store: store, session: session,
            configurationProvider: {
                try GoogleCalendarOAuthConfiguration(clientID: "synthetic.apps.googleusercontent.com")
            },
            openBrowser: { url in
                guard automaticCallback else { return false }
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                let redirect = query.first { $0.name == "redirect_uri" }!.value!
                let state = query.first { $0.name == "state" }!.value!
                Task {
                    _ = try? await URLSession.shared.data(
                        from: URL(string: redirect + "?state=" + state + "&code=synthetic-code")!)
                }
                return true
            })
    }
    func cleanup() {
        session.invalidateAndCancel()
        GoogleTestProtocol.registry.remove(id: identifier)
    }
}

private final class GoogleMemoryStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var text: String?
    private var writes = 0
    var writeCount: Int { lock.withLock { writes } }
    func seed(_ value: String) { lock.withLock { text = value } }
    func getString(_ key: String) throws -> String? { lock.withLock { text } }
    func setString(_ value: String, forKey key: String) throws {
        lock.withLock {
            text = value; writes += 1
        }
    }
    func delete(_ key: String) throws { lock.withLock { text = nil } }
    func record() throws -> GoogleCalendarAuth.StoredConnection? {
        try getString(GoogleCalendarAuth.storageKey).map {
            try JSONDecoder().decode(GoogleCalendarAuth.StoredConnection.self, from: Data($0.utf8))
        }
    }
}

private struct GoogleBlockedStore: KeyValueStore {
    func getString(_ key: String) throws -> String? { throw KeychainError(status: errSecInteractionNotAllowed) }
    func setString(_ value: String, forKey key: String) throws {
        throw KeychainError(status: errSecInteractionNotAllowed)
    }
    func delete(_ key: String) throws { throw KeychainError(status: errSecInteractionNotAllowed) }
}

private final class GoogleScenario: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let tokenStatus: Int
    private let tokenData: Data
    private let tokenDelay: TimeInterval
    private let identityDelay: TimeInterval
    private let revocationDelay: TimeInterval
    private let calendarDelay: TimeInterval
    private let calendarHandler: @Sendable (URLRequest) -> [String: Any]
    var requests: [URLRequest] { lock.withLock { recorded } }

    init(
        tokenStatus: Int = 200,
        tokenBody: [String: Any] = [
            "access_token": "synthetic-access-new", "refresh_token": "synthetic-refresh-new", "expires_in": 3600,
            "token_type": "Bearer",
        ],
        tokenDelay: TimeInterval = 0, identityDelay: TimeInterval = 0, revocationDelay: TimeInterval = 0,
        calendarDelay: TimeInterval = 0,
        calendarHandler: @escaping @Sendable (URLRequest) -> [String: Any] = { _ in ["items": []] }
    ) {
        self.tokenStatus = tokenStatus
        tokenData = try! JSONSerialization.data(withJSONObject: tokenBody)
        self.tokenDelay = tokenDelay
        self.identityDelay = identityDelay
        self.revocationDelay = revocationDelay
        self.calendarDelay = calendarDelay
        self.calendarHandler = calendarHandler
    }

    func respond(to request: URLRequest) throws -> (HTTPURLResponse, Data) {
        var request = request
        if request.httpBody == nil, request.httpBodyStream != nil {
            request.httpBody = Self.body(request)
        }
        lock.withLock { recorded.append(request) }
        let status: Int
        let data: Data
        switch request.url!.path {
        case "/token":
            if tokenDelay > 0 { Thread.sleep(forTimeInterval: tokenDelay) }
            status = tokenStatus
            if Self.fields(request)["grant_type"] == "authorization_code" {
                data = try JSONSerialization.data(withJSONObject: [
                    "access_token": "synthetic-login-access", "refresh_token": "synthetic-login-refresh",
                    "expires_in": 3600, "token_type": "Bearer",
                ])
            } else {
                data = tokenData
            }
        case "/v1/userinfo":
            if identityDelay > 0 { Thread.sleep(forTimeInterval: identityDelay) }
            status = 200
            data = Data(
                #"{"sub":"synthetic-new-account","email":"patrick@example.invalid","email_verified":true}"#.utf8)
        case "/revoke":
            if revocationDelay > 0 { Thread.sleep(forTimeInterval: revocationDelay) }
            status = 200; data = Data()
        default:
            guard request.url?.host == "www.googleapis.com", request.url!.path.hasPrefix("/calendar/v3/") else {
                throw URLError(.unsupportedURL)
            }
            if calendarDelay > 0 { Thread.sleep(forTimeInterval: calendarDelay) }
            status = 200
            data = try JSONSerialization.data(withJSONObject: calendarHandler(request))
        }
        return (
            HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!, data
        )
    }

    static func fields(_ request: URLRequest) -> [String: String] {
        let data = body(request)
        var result: [String: String] = [:]
        for pair in String(decoding: data, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                result[String(parts[0]).removingPercentEncoding ?? ""] = String(parts[1]).removingPercentEncoding ?? ""
            }
        }
        return result
    }

    private static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        var data = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        return data
    }
}

private final class GoogleScenarioRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: GoogleScenario] = [:]
    func register(_ value: GoogleScenario, id: String) { lock.withLock { values[id] = value } }
    func remove(id: String) { _ = lock.withLock { values.removeValue(forKey: id) } }
    func value(id: String) -> GoogleScenario? { lock.withLock { values[id] } }
}

private final class GoogleTestProtocol: URLProtocol, @unchecked Sendable {
    static let registry = GoogleScenarioRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-Google-Test-ID"), let scenario = Self.registry.value(id: id)
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
