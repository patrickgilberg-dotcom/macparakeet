import CryptoKit
import Foundation
import Security

public struct GoogleCalendarError: Error, LocalizedError, Sendable, Equatable {
    public let code: String
    private let message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// Registration for this app's own Google Desktop OAuth client. Desktop
/// client secrets are optional public-client metadata, not user credentials.
public struct GoogleCalendarOAuthConfiguration: Sendable, Equatable {
    public let clientID: String
    public let clientSecret: String?

    public init(clientID: String, clientSecret: String? = nil) throws {
        let identifier = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard identifier.hasSuffix(".apps.googleusercontent.com"), identifier.utf8.count <= 512,
            identifier.utf8.allSatisfy({ (33...126).contains($0) })
        else {
            throw GoogleCalendarError(
                "invalid_configuration", "The Google Calendar desktop client registration is invalid.")
        }
        self.clientID = identifier
        self.clientSecret = clientSecret.flatMap { $0.isEmpty ? nil : $0 }
    }

    public static var localConfigurationURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacParakeet-Live/GoogleCalendar/client.json")
    }

    /// Accepts Google's downloaded {"installed": {...}} desktop-client JSON.
    /// No user-entered callback URI or connector credentials are accepted.
    public static func load(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        localURL: URL? = nil
    ) throws -> Self {
        let clientID =
            environment["MACPARAKEET_GOOGLE_CALENDAR_CLIENT_ID"]
            ?? bundle.object(forInfoDictionaryKey: "GoogleCalendarOAuthClientID") as? String
        let secret =
            environment["MACPARAKEET_GOOGLE_CALENDAR_CLIENT_SECRET"]
            ?? bundle.object(forInfoDictionaryKey: "GoogleCalendarOAuthClientSecret") as? String
        if let clientID, !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !clientID.contains("$(")
        {
            return try Self(clientID: clientID, clientSecret: secret)
        }
        let url: URL
        if let path = environment["MACPARAKEET_GOOGLE_CALENDAR_CLIENT_CONFIG"], !path.isEmpty {
            url = URL(fileURLWithPath: path)
        } else {
            url = localURL ?? localConfigurationURL
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GoogleCalendarError(
                "missing_configuration", "Google Calendar sign-in is not configured for this app yet.")
        }
        struct Client: Decodable { let client_id: String; let client_secret: String? }
        struct Download: Decodable { let installed: Client }
        do {
            let values = try JSONDecoder().decode(Download.self, from: Data(contentsOf: url))
            return try Self(clientID: values.installed.client_id, clientSecret: values.installed.client_secret)
        } catch {
            throw GoogleCalendarError(
                "invalid_configuration", "The local Google Calendar desktop client registration could not be read.")
        }
    }
}

enum GoogleCalendarOAuth {
    static let requiredScopes: Set<String> = [
        "openid", "email", "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
        "https://www.googleapis.com/auth/calendar.events.readonly",
    ]
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    static let revocationURL = URL(string: "https://oauth2.googleapis.com/revoke")!
    static let userInfoURL = URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!

    static func normalizedScopes(_ value: String?) -> Set<String>? {
        value.map {
            Set(
                $0.split(whereSeparator: { $0.isWhitespace }).map { scope in
                    scope == "https://www.googleapis.com/auth/userinfo.email" ? "email" : String(scope)
                })
        }
    }

    static func randomURLSafe() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw GoogleCalendarError("random_unavailable", "Could not securely start Google sign-in. Try again.")
        }
        return base64URL(Data(bytes))
    }

    static func challenge(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func authorizationURL(
        configuration: GoogleCalendarOAuthConfiguration,
        redirectURI: String, state: String, verifier: String
    ) -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: requiredScopes.sorted().joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge(verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            // Explicit Connect is also the supported account-switch/reconnect flow.
            URLQueryItem(name: "prompt", value: "consent select_account"),
        ]
        return components.url!
    }

    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(
            values.sorted(by: { $0.key < $1.key }).map {
                "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
            }.joined(separator: "&").utf8)
    }
}

/// Tokens stay on fixed Google HTTPS endpoints; redirects never forward a
/// token request or bearer authorization to another location.
final class GoogleCalendarNetworkDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        return URLSession(configuration: configuration, delegate: GoogleCalendarNetworkDelegate(), delegateQueue: nil)
    }
}
