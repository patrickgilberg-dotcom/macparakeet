import AppKit
import Foundation

public extension Notification.Name {
    static let googleCalendarConnectionDidChange = Notification.Name(
        "MacParakeetLive.googleCalendarConnectionDidChange")
}

public struct GoogleCalendarConnection: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let email: String
    public let scopes: [String]

    public init(id: String, email: String, scopes: [String]) {
        self.id = id
        self.email = email
        self.scopes = scopes
    }
}

private final class GoogleCalendarConnectionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var connected = false
    var value: Bool { lock.withLock { connected } }
    func set(_ value: Bool) { lock.withLock { connected = value } }
}

/// This app's independent Google Desktop OAuth connection. No OS Calendar,
/// connector, browser-cookie, or other app's credentials are read.
public actor GoogleCalendarAuth {
    public static let shared = GoogleCalendarAuth()
    static let storageKey = "connection-v1"
    private static let keychainService = "com.patrickgilberg.macparakeet-live.google-calendar"

    struct StoredConnection: Codable, Sendable {
        let connection: GoogleCalendarConnection
        let clientID: String
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
    }

    struct Authorization: Sendable {
        let accountID: String
        let generation: UInt64
        let accessToken: String
    }

    private struct TokenResponse: Decodable, Sendable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double
        let token_type: String
        let scope: String?
    }

    private let store: any KeyValueStore
    private let interactiveStore: any KeyValueStore
    private let session: URLSession
    private let configurationProvider: @Sendable () throws -> GoogleCalendarOAuthConfiguration
    private let openBrowser: @Sendable (URL) async -> Bool
    private let now: @Sendable () -> Date
    private nonisolated let connectionFlag = GoogleCalendarConnectionFlag()
    private var stored: StoredConnection?
    private var storageAccessFailed = false
    private var generation: UInt64 = 0
    private var signInRunning = false
    private var disconnectRunning = false
    private var signInAttemptID: UUID?
    private var listener: GoogleCalendarLoopbackListener?
    private var pendingRefresh: (id: UUID, generation: UInt64, task: Task<TokenResponse, Error>)?

    public init() {
        self.init(
            store: KeychainKeyValueStore(service: Self.keychainService),
            interactiveStore: KeychainKeyValueStore(service: Self.keychainService, allowUserInteraction: true),
            session: GoogleCalendarNetworkDelegate.session(),
            configurationProvider: { try GoogleCalendarOAuthConfiguration.load() },
            openBrowser: { url in await MainActor.run { NSWorkspace.shared.open(url) } },
            now: { Date() })
    }

    /// Injection is internal so tests cannot touch the real Keychain or browser.
    init(
        store: any KeyValueStore, interactiveStore: (any KeyValueStore)? = nil,
        session: URLSession, configurationProvider: @escaping @Sendable () throws -> GoogleCalendarOAuthConfiguration,
        openBrowser: @escaping @Sendable (URL) async -> Bool = { _ in false },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.interactiveStore = interactiveStore ?? store
        self.session = session
        self.configurationProvider = configurationProvider
        self.openBrowser = openBrowser
        self.now = now
        do {
            stored = try Self.read(store)
            connectionFlag.set(stored != nil)
        } catch {
            storageAccessFailed = true
        }
    }

    /// A cheap local provider status; never opens a privacy pane or Keychain UI.
    public nonisolated var isConnected: Bool { connectionFlag.value }

    public func connection() -> GoogleCalendarConnection? { stored?.connection }

    public func credentialAccessError() -> String? {
        storageAccessFailed ? "Google Calendar's saved sign-in is locked. Unlock it or connect again." : nil
    }

    /// May show the standard macOS Keychain consent prompt. Call only from an
    /// explicit Unlock action, never polling or background calendar refresh.
    @discardableResult
    public func unlockCredentialAccess() async throws -> GoogleCalendarConnection? {
        let captured = generation
        do {
            let value = try Self.read(interactiveStore)
            guard captured == generation else { throw Self.changedError }
            generation &+= 1
            pendingRefresh?.task.cancel()
            pendingRefresh = nil
            stored = value
            storageAccessFailed = false
            connectionFlag.set(value != nil)
            notifyChange()
            return value?.connection
        } catch {
            if captured == generation { storageAccessFailed = true }
            throw Self.storageError
        }
    }

    @discardableResult
    public func signIn() async throws -> GoogleCalendarConnection {
        // Google revokes a user's entire project grant. Do not let cleanup
        // from an older attempt race a second attempt's newly issued grant.
        guard !disconnectRunning else { throw Self.connectionBusyError }
        guard !signInRunning else {
            throw GoogleCalendarError(
                "sign_in_in_progress", "Google sign-in is already in progress. Complete or cancel it first.")
        }
        signInRunning = true
        defer { signInRunning = false }
        cancelSignIn()
        let configuration = try configurationProvider()
        let attempt = UUID()
        signInAttemptID = attempt
        let verifier = try GoogleCalendarOAuth.randomURLSafe()
        let state = try GoogleCalendarOAuth.randomURLSafe()
        let callback = try GoogleCalendarLoopbackListener(state: state)
        listener = callback
        var issuedRefreshToken: String?
        defer {
            callback.cancel()
            if signInAttemptID == attempt { signInAttemptID = nil; listener = nil }
        }
        do {
            let authorizationURL = GoogleCalendarOAuth.authorizationURL(
                configuration: configuration, redirectURI: callback.redirectURI, state: state, verifier: verifier)
            guard await openBrowser(authorizationURL) else {
                throw GoogleCalendarError("browser_unavailable", "The default browser could not open Google sign-in.")
            }
            try checkAttempt(attempt)
            let response = try await callback.result()
            try checkAttempt(attempt)
            var form = [
                "client_id": configuration.clientID, "grant_type": "authorization_code",
                "code": response.code, "redirect_uri": callback.redirectURI, "code_verifier": verifier,
            ]
            form["client_secret"] = configuration.clientSecret
            let tokens = try await Self.requestTokens(session: session, form: form)
            issuedRefreshToken = tokens.refresh_token
            try checkAttempt(attempt)
            let scopes = GoogleCalendarOAuth.normalizedScopes(tokens.scope) ?? GoogleCalendarOAuth.requiredScopes
            try Self.validate(tokens, scopes: scopes)
            guard let refreshToken = tokens.refresh_token, Self.validToken(refreshToken) else {
                throw GoogleCalendarError(
                    "offline_access_missing",
                    "Google did not grant a renewable Calendar connection. Connect again and allow the requested read access."
                )
            }
            let identity = try await Self.userInfo(session: session, accessToken: tokens.access_token)
            try checkAttempt(attempt)
            let connection = GoogleCalendarConnection(id: identity.sub, email: identity.email, scopes: scopes.sorted())
            let record = StoredConnection(
                connection: connection, clientID: configuration.clientID,
                accessToken: tokens.access_token, refreshToken: refreshToken,
                expiresAt: now().addingTimeInterval(tokens.expires_in))
            // No suspension between the final attempt check, atomic Keychain
            // write, and account activation. Late callbacks cannot reconnect.
            try checkAttempt(attempt)
            try persist(record, interactive: true)
            generation &+= 1
            pendingRefresh?.task.cancel()
            pendingRefresh = nil
            stored = record
            storageAccessFailed = false
            connectionFlag.set(true)
            issuedRefreshToken = nil
            notifyChange()
            return connection
        } catch {
            if let issuedRefreshToken {
                // A cancelled caller cannot cancel cleanup immediately. Google's
                // revocation is project-wide for this user's grant; never log it.
                let cleanupSession = session
                let cleanup = Task.detached {
                    do { try await Self.revoke(session: cleanupSession, token: issuedRefreshToken); return true } catch
                    { return false }
                }
                if await !cleanup.value {
                    throw GoogleCalendarError(
                        "cleanup_unconfirmed",
                        "Google Calendar sign-in did not finish. Google could not confirm removal of its temporary access; you can remove this app in your Google Account's app permissions."
                    )
                }
            }
            throw error
        }
    }

    public func cancelSignIn() {
        signInAttemptID = nil
        listener?.cancel()
        listener = nil
    }

    /// Local state is removed first. A failed remote revoke is explicit, and
    /// cannot restore a connection or a refresh task after Disconnect.
    public func disconnect() async throws {
        guard !disconnectRunning else { throw Self.connectionBusyError }
        disconnectRunning = true
        defer { disconnectRunning = false }
        cancelSignIn()
        generation &+= 1
        pendingRefresh?.task.cancel()
        pendingRefresh = nil
        let token = stored?.refreshToken
        stored = nil
        connectionFlag.set(false)
        notifyChange()
        do {
            try store.delete(Self.storageKey)
            storageAccessFailed = false
        } catch {
            storageAccessFailed = true
            throw Self.storageError
        }
        if let token {
            do { try await Self.revoke(session: session, token: token) } catch {
                throw GoogleCalendarError(
                    "revocation_unconfirmed",
                    "Disconnected locally. Google could not confirm removal of Calendar access; you can remove it in your Google Account's app permissions."
                )
            }
        }
    }

    public func accessToken(expectedAccountID: String? = nil) async throws -> String {
        guard let original = stored else {
            if storageAccessFailed { throw Self.storageError }
            throw Self.disconnectedError
        }
        try checkAccount(expectedAccountID)
        try Task.checkCancellation()
        guard original.expiresAt <= now().addingTimeInterval(60) else { return original.accessToken }
        let captured = generation
        let refreshID: UUID
        let task: Task<TokenResponse, Error>
        if let pending = pendingRefresh, pending.generation == captured {
            refreshID = pending.id
            task = pending.task
        } else {
            let configuration = try configurationProvider()
            guard configuration.clientID == original.clientID else {
                throw GoogleCalendarError(
                    "registration_changed", "The Google Calendar client registration changed. Connect again.")
            }
            var form = [
                "client_id": original.clientID, "refresh_token": original.refreshToken, "grant_type": "refresh_token",
            ]
            form["client_secret"] = configuration.clientSecret
            let requestForm = form
            let requestSession = session
            task = Task { try await Self.requestTokens(session: requestSession, form: requestForm) }
            refreshID = UUID()
            pendingRefresh = (refreshID, captured, task)
        }
        let result: TokenResponse
        do { result = try await task.value } catch {
            if generation == captured, pendingRefresh?.id == refreshID {
                pendingRefresh = nil
                if let error = error as? GoogleCalendarError, error.code == "invalid_grant" {
                    try invalidateCurrent()
                }
            }
            throw error
        }
        try Task.checkCancellation()
        guard generation == captured else { throw Self.changedError }
        try checkAccount(expectedAccountID)
        if pendingRefresh?.id == refreshID {
            let scopes = GoogleCalendarOAuth.normalizedScopes(result.scope) ?? Set(original.connection.scopes)
            do { try Self.validate(result, scopes: scopes) } catch {
                pendingRefresh = nil; try invalidateCurrent(); throw error
            }
            let connection = GoogleCalendarConnection(
                id: original.connection.id, email: original.connection.email,
                scopes: scopes.sorted())
            let record = StoredConnection(
                connection: connection, clientID: original.clientID,
                accessToken: result.access_token,
                refreshToken: result.refresh_token ?? original.refreshToken,
                expiresAt: now().addingTimeInterval(result.expires_in))
            try persist(record)
            stored = record
            pendingRefresh = nil
        }
        guard let latest = stored else { throw Self.disconnectedError }
        try checkAccount(expectedAccountID)
        return latest.accessToken
    }

    func authorization() async throws -> Authorization {
        guard let account = stored?.connection else { throw Self.disconnectedError }
        let captured = generation
        let token = try await accessToken(expectedAccountID: account.id)
        guard captured == generation else { throw Self.changedError }
        return Authorization(accountID: account.id, generation: captured, accessToken: token)
    }

    func validate(_ authorization: Authorization) throws {
        guard authorization.generation == generation, authorization.accountID == stored?.connection.id else {
            throw Self.changedError
        }
        try Task.checkCancellation()
    }

    func rejectUnauthorized(_ authorization: Authorization) throws {
        try validate(authorization)
        try invalidateCurrent()
    }

    private func checkAccount(_ expected: String?) throws {
        guard let current = stored else { throw Self.disconnectedError }
        if let expected, expected != current.connection.id { throw Self.changedError }
    }

    private func checkAttempt(_ attempt: UUID) throws {
        try Task.checkCancellation()
        guard signInAttemptID == attempt else {
            throw GoogleCalendarError("cancelled", "Google Calendar sign-in was cancelled.")
        }
    }

    private func invalidateCurrent() throws {
        generation &+= 1
        stored = nil
        connectionFlag.set(false)
        notifyChange()
        do { try store.delete(Self.storageKey) } catch { storageAccessFailed = true; throw Self.storageError }
    }

    private func persist(_ record: StoredConnection, interactive: Bool = false) throws {
        do {
            let text = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
            try (interactive ? interactiveStore : store).setString(text, forKey: Self.storageKey)
        } catch { storageAccessFailed = true; throw Self.storageError }
    }

    private static func read(_ store: any KeyValueStore) throws -> StoredConnection? {
        guard let text = try store.getString(storageKey) else { return nil }
        let value = try JSONDecoder().decode(StoredConnection.self, from: Data(text.utf8))
        guard !value.connection.id.isEmpty, !value.connection.email.isEmpty,
            requiredScopesPresent(Set(value.connection.scopes)), validToken(value.accessToken),
            validToken(value.refreshToken), value.expiresAt.timeIntervalSince1970.isFinite
        else {
            throw storageError
        }
        return value
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: .googleCalendarConnectionDidChange, object: nil)
    }

    private static func requiredScopesPresent(_ scopes: Set<String>) -> Bool {
        GoogleCalendarOAuth.requiredScopes.isSubset(of: scopes)
    }

    private static func validToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 32_768 && token.utf8.allSatisfy { (33...126).contains($0) }
    }

    private static func validate(_ value: TokenResponse, scopes: Set<String>) throws {
        guard value.token_type.lowercased() == "bearer", validToken(value.access_token),
            value.expires_in.isFinite, value.expires_in > 0, value.expires_in <= 86_400,
            value.refresh_token == nil || validToken(value.refresh_token!)
        else {
            throw GoogleCalendarError(
                "invalid_token_response", "Google returned an invalid Calendar authorization response. Connect again.")
        }
        guard requiredScopesPresent(scopes) else {
            throw GoogleCalendarError(
                "insufficient_scope",
                "Google Calendar needs permission to read your calendar list and events. Connect again and allow both.")
        }
    }

    private static func requestTokens(session: URLSession, form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: GoogleCalendarOAuth.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GoogleCalendarOAuth.form(form)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw unavailableError }
        guard response.statusCode == 200 else {
            struct Failure: Decodable { let error: String? }
            let code = (try? JSONDecoder().decode(Failure.self, from: data))?.error
            if code == "invalid_grant" {
                throw GoogleCalendarError(
                    "invalid_grant", "Google Calendar access expired or was removed. Connect again.")
            }
            if code == "invalid_client" || code == "unauthorized_client" {
                throw GoogleCalendarError(
                    "invalid_client", "Google Calendar's desktop client registration was not accepted.")
            }
            throw unavailableError
        }
        guard data.count <= 131_072, let value = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw GoogleCalendarError(
                "invalid_token_response", "Google returned an invalid Calendar authorization response.")
        }
        return value
    }

    private struct Identity: Decodable { let sub: String; let email: String; let email_verified: Bool }

    private static func userInfo(session: URLSession, accessToken: String) async throws -> Identity {
        // The identity is fetched over Google's authenticated HTTPS UserInfo
        // endpoint. Unverified ID-token payloads are never used as identity.
        var request = URLRequest(url: GoogleCalendarOAuth.userInfoURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 65_536,
            let identity = try? JSONDecoder().decode(Identity.self, from: data),
            !identity.sub.isEmpty, identity.sub.utf8.count <= 255,
            identity.email_verified, !identity.email.isEmpty, identity.email.utf8.count <= 1024
        else {
            throw GoogleCalendarError(
                "identity_unverified", "Google could not verify the Calendar account. Connect again.")
        }
        return identity
    }

    private static func revoke(session: URLSession, token: String) async throws {
        var request = URLRequest(url: GoogleCalendarOAuth.revocationURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GoogleCalendarOAuth.form(["token": token])
        let (_, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw unavailableError }
    }

    private static let storageError = GoogleCalendarError(
        "credential_access_failed", "Google Calendar's saved sign-in could not be accessed. Unlock it or connect again."
    )
    private static let changedError = GoogleCalendarError(
        "account_changed", "The Google Calendar connection changed. Try again.")
    private static let disconnectedError = GoogleCalendarError(
        "not_connected", "Connect Google Calendar to see upcoming meetings.")
    private static let unavailableError = GoogleCalendarError(
        "authorization_unavailable", "Google Calendar authorization is temporarily unavailable. Try again.")
    private static let connectionBusyError = GoogleCalendarError(
        "connection_busy", "Google Calendar is finishing a connection change. Try again in a moment.")
}
