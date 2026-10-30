import AppKit
import CryptoKit
import Darwin
import Foundation
import Security

/// Safe display data. OAuth credentials never cross this API into views or logs.
public struct ChatGPTAccount: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let email: String?
    public let name: String?
    public let clientID: String
    public let subject: String
    public let scopes: [String]
    public let connected: Bool
    public var planUsageEnabled: Bool { connected && scopes.contains("chatgpt.tokens.use.direct") }
    public var label: String { email ?? name ?? "ChatGPT account" }
}

/// Distinguishes a missing connection from a protected connection this build
/// cannot yet read. Contains only safe display information, never credentials.
public struct ChatGPTCredentialStatus: Sendable, Equatable {
    public let hasSavedConnection: Bool
    public let needsKeychainApproval: Bool
    public let accessError: String?
}

public struct ChatGPTAuthError: Error, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
}

/// The app's own public-client OAuth session. It never reads Codex credentials.
public actor ChatGPTAuth {
    public static let shared = ChatGPTAuth()
    public static let usageURL = URL(string: "https://chatgpt.com/settings/usage")!
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let requestedScopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static let service = "com.patrickgilberg.macparakeet-live.chatgpt"

    private let storageDirectory: URL
    private let store: any KeyValueStore
    private var interactiveStore: (any KeyValueStore)?
    private let interactiveStoreFactory: (@Sendable () -> any KeyValueStore)?
    private let cancelRequests: @Sendable () -> Void
    private var cachedVault: Vault?
    private var accountTransitionID: UUID?
    private var disconnecting = false
    private var authorizationGeneration: UInt64 = 0
    private var signingIn = false
    private var signInAttemptID: UUID?
    private var signInListener: ChatGPTLoopbackListener?
    private let session: URLSession
    private let redirectDelegate = ChatGPTNoRedirectDelegate()
    private var discoveryCache: Discovery?
    private var jwksCache: [JWK] = []

    public init() {
        storageDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacParakeet-Live/ChatGPT", isDirectory: true)
        store = KeychainKeyValueStore(service: Self.service)
        interactiveStoreFactory = { KeychainKeyValueStore(service: Self.service, allowUserInteraction: true) }
        cancelRequests = { ChatGPTLiveClient.cancelAllClients() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
    }

    /// Tests use an isolated store, session, directory and cancellation callback;
    /// no injected instance can touch the signed-in app's Keychain or streams.
    init(
        store: any KeyValueStore, storageDirectory: URL, session: URLSession,
        cancelRequests: @escaping @Sendable () -> Void = {},
        interactiveStoreFactory: (@Sendable () -> any KeyValueStore)? = nil
    ) {
        self.store = store
        self.interactiveStoreFactory = interactiveStoreFactory
        self.storageDirectory = storageDirectory
        self.session = session
        self.cancelRequests = cancelRequests
    }

    public func credentialStatus() -> ChatGPTCredentialStatus {
        do {
            let vault = try loadVault()
            cachedVault = vault
            return ChatGPTCredentialStatus(
                hasSavedConnection: !vault.registrations.isEmpty,
                needsKeychainApproval: false, accessError: nil)
        } catch {
            let blocked =
                (error as? KeychainError).map {
                    [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled].contains($0.status)
                } ?? false
            let message =
                blocked
                ? "MacParakeet Live needs permission to read its saved ChatGPT connection. Choose Unlock saved connection, then allow this app in the macOS Keychain prompt."
                : "The saved ChatGPT connection could not be read. It has been preserved. " + error.localizedDescription
            return ChatGPTCredentialStatus(
                hasSavedConnection: cachedVault?.registrations.isEmpty == false,
                needsKeychainApproval: blocked, accessError: message)
        }
    }

    /// Call only after an explicit Unlock action. macOS owns the access dialog;
    /// the app does not rewrite ACLs or grant itself access to another app's items.
    public func unlockCredentialAccess() async throws {
        guard let factory = interactiveStoreFactory else {
            throw ChatGPTAuthError(
                "interactive_credentials_unavailable", "Interactive credential access is unavailable in this runtime.")
        }
        let candidate = factory()
        let vault = try loadVault(from: candidate)
        interactiveStore = candidate
        cachedVault = vault
    }

    public func accounts() -> [ChatGPTAccount] {
        if let vault = try? loadVault() { cachedVault = vault }
        return cachedVault?.registrations.filter { $0.subject != nil }.map(\.account) ?? []
    }

    public func activeAccount() -> ChatGPTAccount? {
        guard accountTransitionID == nil else { return nil }
        if let vault = try? loadVault() { cachedVault = vault }
        guard let vault = cachedVault else { return nil }
        return vault.registrations.first { $0.id == vault.activeID && $0.subject != nil }?.account
    }

    public func selectAccount(id: String) async throws {
        guard !disconnecting, accountTransitionID == nil || signingIn else { throw Self.transitionError }
        cancelSignIn()
        let transition = beginAccountTransition()
        defer { endAccountTransition(transition) }
        let lock = try await acquireLock()
        defer { lock.release() }
        guard accountTransitionID == transition else { throw CancellationError() }
        var vault = try loadVault()
        guard vault.registrations.contains(where: { $0.id == id && $0.subject != nil }) else {
            throw ChatGPTAuthError("account_missing", "That saved ChatGPT account is unavailable.")
        }
        vault.activeID = id
        try saveVault(vault)
        cancelRequests()
    }

    /// Opens the browser only once the loopback listener is accepting requests.
    /// Pass an existing registration ID to reconnect; nil adds a separate account.
    public func signIn(accountID: String? = nil, requestPlanConsent: Bool = false) async throws -> ChatGPTAccount {
        guard !disconnecting, accountTransitionID == nil || signingIn else { throw Self.transitionError }
        guard !signingIn else {
            throw ChatGPTAuthError("sign_in_pending", "Complete or cancel the current ChatGPT sign-in first.")
        }
        signingIn = true
        let transition = beginAccountTransition()
        let attemptID = UUID()
        signInAttemptID = attemptID
        defer {
            signingIn = false; signInListener?.cancel(); signInListener = nil
            endAccountTransition(transition)
        }
        let vault = try loadVault()
        let previous =
            accountID.flatMap { id in vault.registrations.first { $0.id == id } }
            ?? (accountID == nil ? vault.registrations.last(where: { $0.subject == nil }) : nil)
        if accountID != nil && previous == nil {
            throw ChatGPTAuthError("account_missing", "The saved ChatGPT registration is unavailable.")
        }
        let hostID = try await persistentHostID()
        try await validateSignInAttempt(attemptID)
        let discovery = try await configuration()
        try await validateSignInAttempt(attemptID)
        let state = try Self.randomValue()
        let nonce = try Self.randomValue()
        let verifier = try Self.randomValue()
        let listener = try ChatGPTLoopbackListener(state: state, savedClientID: previous?.clientID)
        signInListener = listener
        var components = URLComponents(url: discovery.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: previous?.clientID ?? "dynamic_agent_client"),
            URLQueryItem(name: "ext_agent_host_id", value: hostID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: listener.redirectURI),
            URLQueryItem(name: "scope", value: Self.requestedScopes),
            URLQueryItem(name: "resource", value: Self.resource),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Self.pkceChallenge(verifier)),
        ]
        if previous == nil { items.append(URLQueryItem(name: "agent_name_hint", value: "MacParakeet Live")) }
        // A login hint avoids placing a retained ID token in browser process arguments.
        if let email = previous?.email { items.append(URLQueryItem(name: "login_hint", value: email)) }
        if requestPlanConsent { items.append(URLQueryItem(name: "prompt", value: "consent")) }
        components.queryItems = items
        guard let authorizationURL = components.url else {
            throw ChatGPTAuthError("invalid_authorization", "Could not prepare ChatGPT sign-in.")
        }
        let opened = await MainActor.run { NSWorkspace.shared.open(authorizationURL) }
        try await validateSignInAttempt(attemptID)
        guard opened else {
            throw ChatGPTAuthError(
                "browser_unavailable", "The default browser could not be opened. Try signing in again.")
        }
        let callback = try await withTaskCancellationHandler {
            try await listener.result()
        } onCancel: {
            listener.cancel()
        }
        try await validateSignInAttempt(attemptID)
        // Save the issued registration before consuming the one-time authorization code.
        let registrationID = previous?.id ?? UUID().uuidString
        do {
            let lock = try await acquireLock()
            defer { lock.release() }
            try await validateSignInAttempt(attemptID)
            var saved = try loadVault()
            if !saved.registrations.contains(where: { $0.id == registrationID }) {
                saved.registrations.append(Registration(id: registrationID, clientID: callback.clientID))
                try saveVault(saved)
            }
        }
        let fields = try await tokenRequest([
            "grant_type": "authorization_code", "client_id": callback.clientID,
            "code": callback.code, "code_verifier": verifier,
            "redirect_uri": listener.redirectURI, "resource": Self.resource,
        ])
        do {
            try await validateSignInAttempt(attemptID)
            guard let idToken = fields.idToken else {
                throw ChatGPTAuthError(
                    "invalid_id_token", "ChatGPT did not return a verifiable identity. Sign in again.")
            }
            let identity = try await verifyIdentity(idToken, clientID: callback.clientID, nonce: nonce)
            try await validateSignInAttempt(attemptID)
            if let subject = previous?.subject, subject != identity.subject {
                throw ChatGPTAuthError(
                    "account_mismatch",
                    "This is a different ChatGPT account. Reconnect the original account or add this one separately.")
            }
            guard let grantedScope = fields.scope else {
                throw ChatGPTAuthError(
                    "invalid_token_response", "ChatGPT did not confirm the granted permissions. Sign in again.")
            }
            let grantedScopes = grantedScope.split(whereSeparator: \.isWhitespace).map(String.init)
            let credentials: Credentials?
            if fields.accessToken == nil && !grantedScopes.contains("offline_access")
                && !grantedScopes.contains("chatgpt.tokens.use.direct")
            {
                credentials = nil
            } else {
                credentials = try fields.credentials(previousScopes: nil)
            }
            try Task.checkCancellation()
            let lock = try await acquireLock()
            defer { lock.release() }
            try await validateSignInAttempt(attemptID)
            var saved = try loadVault()
            var registration = Registration(id: registrationID, clientID: callback.clientID)
            registration.subject = identity.subject
            registration.email = identity.email
            registration.name = identity.name
            registration.idToken = idToken
            registration.credentials = credentials
            registration.scopes = grantedScopes
            registration.authorized = true
            saved.registrations.removeAll { $0.id == registrationID }
            saved.registrations.append(registration)
            saved.activeID = registrationID
            try saveVault(saved)
            cancelRequests()
            return registration.account
        } catch {
            if let refreshToken = fields.refreshToken {
                let confirmed = await Self.revokeUnactivatedSession(
                    refreshToken: refreshToken, clientID: callback.clientID, endpoint: discovery.revocationEndpoint)
                if !confirmed {
                    let original = (error as? ChatGPTAuthError)?.message ?? "ChatGPT sign-in did not complete."
                    throw ChatGPTAuthError(
                        "sign_in_cleanup_unconfirmed",
                        original
                            + " Remote session cleanup could not be confirmed. Disconnect MacParakeet Live in ChatGPT Settings if it remains listed."
                    )
                }
            }
            throw error
        }
    }

    public func cancelSignIn() { signInAttemptID = nil; signInListener?.cancel() }

    /// Performs preparation/refresh outside the UI actor. A file lease serializes
    /// rotating refresh tokens across the GUI and its bundled CLI.
    public func accessToken(expectedAccountID: String? = nil) async throws -> String {
        let epoch = try authorizationEpoch()
        let lock = try await acquireLock()
        defer { lock.release() }
        try validateAuthorizationEpoch(epoch)
        var vault = try loadVault()
        try Self.checkActiveAccount(vault.activeID, expected: expectedAccountID)
        guard let index = vault.registrations.firstIndex(where: { $0.id == vault.activeID }),
            vault.registrations[index].subject != nil
        else {
            throw ChatGPTAuthError(
                "not_connected", "Continue with ChatGPT in Live settings before asking for an answer.")
        }
        var registration = vault.registrations[index]
        guard registration.scopes.contains("chatgpt.tokens.use.direct") else {
            throw ChatGPTAuthError(
                "plan_usage_disabled", "ChatGPT is connected, but plan usage is disabled. Enable it in Live settings.")
        }
        if let pending = registration.pendingRefresh {
            // A rotated token survived a key-service outage. Verify that checkpoint
            // before using it; never reuse the refresh token it replaced.
            try await validateRotation(pending, registration: registration)
            try validateAuthorizationEpoch(epoch)
            registration.credentials = pending.credentials
            registration.scopes = pending.credentials.scopes
            registration.idToken = pending.idToken ?? registration.idToken
            registration.pendingRefresh = nil
            vault.registrations[index] = registration
            try saveVault(vault)
        }
        // A resumed rotation can carry narrower permissions than the old
        // registration. Revalidate the grant after applying that checkpoint.
        guard registration.account.planUsageEnabled else {
            throw ChatGPTAuthError(
                "plan_usage_disabled",
                "ChatGPT plan permission was removed. Enable it again before requesting answers.")
        }
        guard let credentials = registration.credentials else {
            throw ChatGPTAuthError("not_connected", "This ChatGPT account needs to be connected again.")
        }
        if credentials.expiresAt.timeIntervalSinceNow > 90 {
            try validateAuthorizationEpoch(epoch)
            try Self.checkActiveAccount(try loadVault().activeID, expected: expectedAccountID)
            return credentials.accessToken
        }
        guard let refresh = credentials.refreshToken else {
            throw ChatGPTAuthError("session_expired", "Your ChatGPT session expired. Sign in again.")
        }
        do {
            let response = try await tokenRequest([
                "grant_type": "refresh_token", "client_id": registration.clientID,
                "refresh_token": refresh, "resource": Self.resource,
            ])
            let replacement = try response.credentials(previousScopes: registration.scopes)
            guard replacement.refreshToken != nil else {
                throw ChatGPTAuthError(
                    "invalid_token_response", "ChatGPT did not return a replacement session. Sign in again.")
            }
            let pending = Rotation(credentials: replacement, idToken: response.idToken, receivedAt: Date())
            registration.pendingRefresh = pending
            vault.registrations[index] = registration
            try saveVault(vault)
            // Preserve a rotated refresh token even if an account transition
            // began during the request. Its owner can now revoke the new token.
            try validateAuthorizationEpoch(epoch)
            try await validateRotation(pending, registration: registration)
            try validateAuthorizationEpoch(epoch)
            registration.credentials = replacement
            registration.scopes = replacement.scopes
            registration.idToken = response.idToken ?? registration.idToken
            registration.pendingRefresh = nil
            vault.registrations[index] = registration
            try saveVault(vault)
            guard registration.account.planUsageEnabled else {
                throw ChatGPTAuthError(
                    "plan_usage_disabled",
                    "ChatGPT plan permission was removed. Enable it again before requesting answers.")
            }
            try Self.checkActiveAccount(try loadVault().activeID, expected: expectedAccountID)
            try validateAuthorizationEpoch(epoch)
            return replacement.accessToken
        } catch let error as ChatGPTAuthError {
            let terminal = [
                "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                "refresh_token_invalidated", "refresh_token_reused", "account_mismatch", "invalid_id_token",
            ]
            if terminal.contains(error.code) {
                registration.credentials = nil
                registration.pendingRefresh = nil
                registration.idToken = nil
                registration.authorized = false
                vault.registrations[index] = registration
                try saveVault(vault)
            }
            throw error
        }
    }

    public func disconnect() async throws {
        guard !disconnecting else { throw Self.transitionError }
        disconnecting = true
        cancelSignIn()
        let transition = beginAccountTransition()
        defer { endAccountTransition(transition); disconnecting = false }
        let lock = try await acquireLock()
        defer { lock.release() }
        var vault = try loadVault()
        guard let index = vault.registrations.firstIndex(where: { $0.id == vault.activeID }) else { return }
        var registration = vault.registrations[index]
        let refresh = registration.pendingRefresh?.credentials.refreshToken ?? registration.credentials?.refreshToken
        var confirmed = refresh == nil
        if let refresh {
            for attempt in 0..<2 {
                do {
                    let discovery = try await configuration()
                    guard let endpoint = discovery.revocationEndpoint else { break }
                    let (_, response) = try await sendForm(
                        ["token": refresh, "token_type_hint": "refresh_token", "client_id": registration.clientID],
                        to: endpoint)
                    if response.statusCode == 200 { confirmed = true; break }
                    if response.statusCode < 500 { break }
                } catch { /* One bounded retry; local disconnection still completes. */  }
                if attempt == 0 { try? await Task.sleep(for: .milliseconds(300)) }
            }
        }
        registration.credentials = nil
        registration.idToken = nil
        registration.pendingRefresh = nil
        registration.authorized = false
        vault.registrations[index] = registration
        try saveVault(vault)
        cancelRequests()
        if !confirmed {
            throw ChatGPTAuthError(
                "revocation_unconfirmed",
                "Local credentials were removed. Remote disconnection could not be confirmed; disconnect MacParakeet Live in ChatGPT Settings."
            )
        }
    }

    /// Local authorization attempts invalidate already-bound sessions even when
    /// reconnecting/selecting the same account. Normal refresh leaves this stable.
    func authorizationEpoch() throws -> UInt64 {
        guard accountTransitionID == nil else { throw Self.transitionError }
        try Task.checkCancellation()
        return authorizationGeneration
    }

    private func beginAccountTransition() -> UUID {
        authorizationGeneration &+= 1
        let transition = UUID()
        accountTransitionID = transition
        cancelRequests()
        return transition
    }

    private func endAccountTransition(_ transition: UUID) {
        if accountTransitionID == transition { accountTransitionID = nil }
    }

    private func validateAuthorizationEpoch(_ epoch: UInt64) throws {
        try Task.checkCancellation()
        guard accountTransitionID == nil, authorizationGeneration == epoch else { throw CancellationError() }
    }

    private static let transitionError = ChatGPTAuthError(
        "account_transition", "ChatGPT account settings are changing. Wait for that operation to finish.")

    private func validateSignInAttempt(_ attemptID: UUID) async throws {
        guard signInAttemptID == attemptID && !Task.isCancelled else {
            throw ChatGPTAuthError("cancelled", "ChatGPT sign-in was cancelled.")
        }
    }

    /// A cancelled parent must not cancel its own cleanup request immediately.
    /// The independent task has a short whole-resource deadline and no redirects.
    private static func revokeUnactivatedSession(refreshToken: String, clientID: String, endpoint: URL?) async -> Bool {
        guard let endpoint, isOpenAIEndpoint(endpoint) else { return false }
        return await Task.detached(priority: .utility) {
            let delegate = ChatGPTNoRedirectDelegate()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = 4
            configuration.timeoutIntervalForResource = 6
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formBody([
                "token": refreshToken, "token_type_hint": "refresh_token", "client_id": clientID,
            ])
            do {
                let (_, response) = try await session.data(for: request)
                return (response as? HTTPURLResponse)?.statusCode == 200
            } catch { return false }
        }.value
    }

    static func checkActiveAccount(_ active: String?, expected: String?) throws {
        guard expected == nil || active == expected else {
            throw ChatGPTAuthError("account_changed", "The active ChatGPT account changed. Request the answer again.")
        }
    }

    private func validateRotation(_ pending: Rotation, registration: Registration) async throws {
        guard let idToken = pending.idToken else { return }
        let identity = try await verifyIdentity(
            idToken, clientID: registration.clientID, nonce: nil, at: pending.receivedAt)
        guard identity.subject == registration.subject else {
            throw ChatGPTAuthError(
                "account_mismatch", "The refreshed identity did not match this ChatGPT account. Sign in again.")
        }
    }

    private func loadVault(from source: (any KeyValueStore)? = nil) throws -> Vault {
        guard let text = try (source ?? interactiveStore ?? store).getString("connections-v1") else { return Vault() }
        guard let data = text.data(using: .utf8) else {
            throw ChatGPTAuthError("credential_storage", "Saved ChatGPT connections could not be read.")
        }
        do { return try JSONDecoder().decode(Vault.self, from: data) } catch {
            throw ChatGPTAuthError(
                "credential_storage", "Saved ChatGPT connections could not be read. They have been preserved.")
        }
    }

    private func saveVault(_ vault: Vault) throws {
        let data = try JSONEncoder().encode(vault)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ChatGPTAuthError("credential_storage", "Could not save ChatGPT credentials.")
        }
        try (interactiveStore ?? store).setString(text, forKey: "connections-v1")
        cachedVault = vault
    }

    private func acquireLock() async throws -> ChatGPTCredentialLease {
        try FileManager.default.createDirectory(
            at: storageDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storageDirectory.path)
        return try await ChatGPTCredentialLease.acquire(at: storageDirectory.appendingPathComponent("credentials.lock"))
    }

    private func persistentHostID() async throws -> String {
        let lock = try await acquireLock()
        defer { lock.release() }
        let url = storageDirectory.appendingPathComponent("host-id")
        if FileManager.default.fileExists(atPath: url.path) {
            let id = try String(contentsOf: url, encoding: .utf8)
            guard id.hasPrefix("urn:uuid:"), UUID(uuidString: String(id.dropFirst(9))) != nil else {
                throw ChatGPTAuthError(
                    "host_identity", "The saved installation identity is invalid. It has been preserved.")
            }
            return id
        }
        let id = "urn:uuid:\(UUID().uuidString.lowercased())"
        try Data(id.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return id
    }

    private func configuration() async throws -> Discovery {
        if let discoveryCache { return discoveryCache }
        let (data, response) = try await session.data(
            from: URL(string: Self.issuer + "/.well-known/openid-configuration")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ChatGPTAuthError("discovery_unavailable", "ChatGPT sign-in configuration is temporarily unavailable.")
        }
        let value = try JSONDecoder().decode(Discovery.self, from: data)
        guard value.issuer == Self.issuer, Self.isOpenAIEndpoint(value.authorizationEndpoint),
            Self.isOpenAIEndpoint(value.tokenEndpoint), Self.isOpenAIEndpoint(value.jwksURI),
            value.revocationEndpoint.map(Self.isOpenAIEndpoint) ?? true
        else {
            throw ChatGPTAuthError("invalid_discovery", "ChatGPT sign-in configuration could not be verified.")
        }
        discoveryCache = value
        return value
    }

    private static func isOpenAIEndpoint(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "auth.openai.com" && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> TokenResponse {
        let discovery = try await configuration()
        let (data, response) = try await sendForm(fields, to: discovery.tokenEndpoint)
        guard response.statusCode == 200 else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let nested = object?["error"] as? [String: Any]
            let code =
                (object?["error"] as? String) ?? (nested?["code"] as? String) ?? "oauth_http_\(response.statusCode)"
            let safeCode =
                code.count < 100 && code.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) ? code : "oauth_error"
            throw ChatGPTAuthError(
                safeCode, "ChatGPT authorization failed (\(safeCode)). Try reconnecting your account.")
        }
        do { return try JSONDecoder().decode(TokenResponse.self, from: data) } catch {
            throw ChatGPTAuthError("invalid_token_response", "ChatGPT returned incomplete credentials. Sign in again.")
        }
    }

    private func sendForm(_ fields: [String: String], to url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formBody(fields)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ChatGPTAuthError("invalid_response", "ChatGPT did not return an HTTP response.")
        }
        return (data, response)
    }

    static func formBody(_ fields: [String: String]) -> Data {
        // URLQueryItem leaves '+' untouched, which form decoders interpret as a space.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(
            fields.keys.sorted().map { key in
                key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + fields[key]!.addingPercentEncoding(
                    withAllowedCharacters: allowed)!
            }.joined(separator: "&").utf8)
    }

    static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ChatGPTAuthError("randomness_unavailable", "Secure sign-in could not be initialized.")
        }
        return Data(bytes).chatGPTBase64URL
    }

    static func pkceChallenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).chatGPTBase64URL
    }

    private func verifyIdentity(_ token: String, clientID: String, nonce: String?, at date: Date = Date()) async throws
        -> Identity
    {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
            let headerData = Data(chatGPTBase64URL: String(parts[0])),
            let header = try? JSONDecoder().decode(JWTHeader.self, from: headerData),
            header.alg == "RS256", !header.kid.isEmpty,
            let payloadData = Data(chatGPTBase64URL: String(parts[1])),
            let signature = Data(chatGPTBase64URL: String(parts[2]))
        else {
            throw ChatGPTAuthError("invalid_id_token", "The ChatGPT identity could not be verified. Sign in again.")
        }
        let discovery = try await configuration()
        if !jwksCache.contains(where: { $0.kid == header.kid }) {
            do {
                let (data, response) = try await session.data(from: discovery.jwksURI)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw ChatGPTAuthError(
                        "identity_verification_unavailable",
                        "ChatGPT identity verification is temporarily unavailable. Your saved connection is preserved.")
                }
                jwksCache = try JSONDecoder().decode(JWKSet.self, from: data).keys
            } catch {
                throw ChatGPTAuthError(
                    "identity_verification_unavailable",
                    "ChatGPT identity verification is temporarily unavailable. Your saved connection is preserved.")
            }
        }
        guard
            let jwk = jwksCache.first(where: {
                $0.kid == header.kid && $0.kty == "RSA" && ($0.alg == nil || $0.alg == "RS256")
                    && ($0.use == nil || $0.use == "sig")
            })
        else {
            throw ChatGPTAuthError(
                "identity_verification_unavailable",
                "ChatGPT's signing key is temporarily unavailable. Try again shortly.")
        }
        let signed = Data("\(parts[0]).\(parts[1])".utf8)
        guard try Self.verifyRS256Signature(signed, signature: signature, modulus: jwk.n, exponent: jwk.e) else {
            throw ChatGPTAuthError("invalid_id_token", "The ChatGPT identity signature is invalid. Sign in again.")
        }
        return try Self.validateClaims(payloadData, clientID: clientID, nonce: nonce, at: date)
    }

    static func validateClaims(_ payload: Data, clientID: String, nonce: String?, at date: Date) throws -> Identity {
        guard let claims = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
            claims["iss"] as? String == issuer,
            let sub = claims["sub"] as? String, !sub.isEmpty,
            let exp = claims["exp"] as? Double, exp > date.timeIntervalSince1970 - 5,
            let iat = claims["iat"] as? Double, iat <= date.timeIntervalSince1970 + 5
        else {
            throw ChatGPTAuthError(
                "invalid_id_token", "The ChatGPT identity claims are invalid or expired. Sign in again.")
        }
        let audience = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audience.contains(clientID),
            (nonce == nil || claims["nonce"] as? String == nonce),
            (claims["azp"] == nil || claims["azp"] as? String == clientID),
            (audience.count <= 1 || claims["azp"] as? String == clientID),
            (claims["nbf"] as? Double).map({ $0 <= date.timeIntervalSince1970 + 5 }) ?? true
        else {
            throw ChatGPTAuthError(
                "invalid_id_token", "The ChatGPT identity did not match this sign-in. Sign in again.")
        }
        return Identity(subject: sub, email: claims["email"] as? String, name: claims["name"] as? String)
    }

    static func verifyRS256Signature(_ input: Data, signature: Data, modulus: String, exponent: String) throws -> Bool {
        let key = try rsaKey(JWK(kid: "", kty: "RSA", alg: "RS256", use: "sig", n: modulus, e: exponent))
        return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, input as CFData, signature as CFData, nil)
    }

    private static func rsaKey(_ key: JWK) throws -> SecKey {
        guard var modulus = Data(chatGPTBase64URL: key.n), var exponent = Data(chatGPTBase64URL: key.e),
            !modulus.isEmpty, !exponent.isEmpty
        else {
            throw ChatGPTAuthError("invalid_signing_key", "ChatGPT returned an invalid signing key.")
        }
        while modulus.count > 1 && modulus.first == 0 { modulus.removeFirst() }
        while exponent.count > 1 && exponent.first == 0 { exponent.removeFirst() }
        let bits = modulus.count * 8
        if modulus.first! & 0x80 != 0 { modulus.insert(0, at: 0) }
        if exponent.first! & 0x80 != 0 { exponent.insert(0, at: 0) }
        let body = der(0x02, modulus) + der(0x02, exponent)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: bits,
        ]
        guard bits >= 2048,
            let result = SecKeyCreateWithData(der(0x30, body) as CFData, attributes as CFDictionary, nil)
        else { throw ChatGPTAuthError("invalid_signing_key", "ChatGPT returned an unsupported signing key.") }
        return result
    }

    private static func der(_ tag: UInt8, _ bytes: Data) -> Data {
        var length = bytes.count
        var encoded: [UInt8] = []
        repeat { encoded.insert(UInt8(length & 0xff), at: 0); length >>= 8 } while length > 0
        let prefix: [UInt8] = bytes.count < 128 ? [UInt8(bytes.count)] : [0x80 | UInt8(encoded.count)] + encoded
        return Data([tag] + prefix) + bytes
    }

    struct Identity { let subject: String; let email: String?; let name: String? }
    private struct JWTHeader: Decodable { let alg: String; let kid: String }
    private struct JWKSet: Decodable { let keys: [JWK] }
    private struct JWK: Decodable {
        let kid: String; let kty: String; let alg: String?; let use: String?; let n: String; let e: String
    }
    private struct Discovery: Decodable {
        let issuer: String
        let authorizationEndpoint: URL
        let tokenEndpoint: URL
        let revocationEndpoint: URL?
        let jwksURI: URL
        enum CodingKeys: String, CodingKey {
            case issuer; case authorizationEndpoint = "authorization_endpoint"; case tokenEndpoint = "token_endpoint";
            case revocationEndpoint = "revocation_endpoint"; case jwksURI = "jwks_uri"
        }
    }
    private struct Credentials: Codable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date
        let scopes: [String]
    }
    private struct Rotation: Codable { let credentials: Credentials; let idToken: String?; let receivedAt: Date }
    private struct Registration: Codable {
        let id: String
        let clientID: String
        var subject: String?
        var email: String?
        var name: String?
        var scopes: [String] = []
        var authorized: Bool = false
        var idToken: String?
        var credentials: Credentials?
        var pendingRefresh: Rotation?
        var account: ChatGPTAccount {
            ChatGPTAccount(
                id: id, email: email, name: name, clientID: clientID, subject: subject ?? "", scopes: scopes,
                connected: authorized)
        }
    }
    private struct Vault: Codable { var registrations: [Registration] = []; var activeID: String? }
    private struct TokenResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let idToken: String?
        let tokenType: String?
        let expiresIn: Double?
        let scope: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"; case refreshToken = "refresh_token"; case idToken = "id_token";
            case tokenType = "token_type"; case expiresIn = "expires_in"; case scope
        }
        func credentials(previousScopes: [String]?) throws -> Credentials {
            guard let tokenType, tokenType.lowercased() == "bearer", let accessToken, !accessToken.isEmpty,
                let expiresIn, expiresIn.isFinite, expiresIn > 0,
                scope != nil || previousScopes != nil
            else {
                throw ChatGPTAuthError(
                    "invalid_token_response",
                    "ChatGPT did not confirm valid credentials and permissions. Sign in again.")
            }
            let scopes = scope?.split(whereSeparator: \.isWhitespace).map(String.init) ?? previousScopes ?? []
            if scopes.contains("offline_access") && (refreshToken?.isEmpty ?? true) {
                throw ChatGPTAuthError(
                    "invalid_token_response", "ChatGPT did not return the requested renewable session. Sign in again.")
            }
            return Credentials(
                accessToken: accessToken, refreshToken: refreshToken, expiresAt: Date().addingTimeInterval(expiresIn),
                scopes: scopes)
        }
    }
}

private final class ChatGPTNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

private final class ChatGPTCredentialLease: @unchecked Sendable {
    private let fd: Int32
    private let guardLock = NSLock()
    private var released = false
    private init(_ fd: Int32) { self.fd = fd }
    static func acquire(at url: URL) async throws -> ChatGPTCredentialLease {
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw ChatGPTAuthError("credential_lock", "Could not protect the ChatGPT credential store.")
        }
        do {
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK else {
                    throw ChatGPTAuthError("credential_lock", "Could not lock the ChatGPT credential store.")
                }
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(30))
            }
            try Task.checkCancellation()
            return ChatGPTCredentialLease(fd)
        } catch { Darwin.close(fd); throw error }
    }
    func release() {
        guardLock.lock(); defer { guardLock.unlock() }
        if !released { released = true; flock(fd, LOCK_UN); Darwin.close(fd) }
    }
    deinit { release() }
}

extension Data {
    var chatGPTBase64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    init?(chatGPTBase64URL text: String) {
        let base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
    }
}
