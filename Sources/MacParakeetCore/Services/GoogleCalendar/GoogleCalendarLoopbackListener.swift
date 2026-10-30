import CryptoKit
import Darwin
import Foundation

/// Minimal single-purpose loopback HTTP listener. Bound before browser launch;
/// socket polling and reads run off both the main actor and the auth actor.
final class GoogleCalendarLoopbackListener: @unchecked Sendable {
    struct Callback: Sendable, Equatable { let code: String }
    enum ParsedCallback {
        case unrelated
        case invalidState
        case failed(GoogleCalendarError)
        case accepted(Callback)
    }

    let redirectURI: String
    private let descriptor: Int32
    private let port: UInt16
    private let state: String
    private let lock = NSLock()
    private var cancelled = false
    private var closed = false
    private var consumed = false

    init(state: String) throws {
        self.state = state
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw GoogleCalendarError(
                "callback_unavailable", "Could not start the local Google Calendar callback listener.")
        }
        descriptor = fd
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 4) == 0 else {
            Darwin.close(fd);
            throw GoogleCalendarError(
                "callback_unavailable", "Could not bind the local Google Calendar callback listener.")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else {
            Darwin.close(fd);
            throw GoogleCalendarError("callback_unavailable", "Could not inspect the local sign-in port.")
        }
        port = UInt16(bigEndian: address.sin_port)
        redirectURI = "http://127.0.0.1:\(port)/"
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    }

    func result() async throws -> Callback {
        guard beginConsuming() else {
            throw GoogleCalendarError("callback_consumed", "This Google Calendar sign-in was already handled.")
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) { [self] in
                defer { closeListener() }
                let deadline = Date().addingTimeInterval(600)
                while Date() < deadline {
                    if isCancelled { throw GoogleCalendarError("cancelled", "Google Calendar sign-in was cancelled.") }
                    var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                    let ready = poll(&event, 1, 200)
                    if ready < 0 && errno == EINTR { continue }
                    guard ready >= 0 else {
                        throw GoogleCalendarError(
                            "callback_failed", "The Google Calendar callback listener stopped. Try again.")
                    }
                    guard ready > 0, event.revents & Int16(POLLIN) != 0 else { continue }
                    let client = Darwin.accept(descriptor, nil, nil)
                    guard client >= 0 else { continue }
                    let result: ParsedCallback
                    if let request = readRequest(client) {
                        result = Self.parse(request, port: port, expectedState: state)
                    } else {
                        result = .unrelated
                    }
                    switch result {
                    case .unrelated:
                        respond(client, status: "404 Not Found", body: "Not found")
                    case .invalidState:
                        respond(
                            client, status: "400 Bad Request",
                            body: "Invalid sign-in state. Return to the browser tab that started sign-in.")
                    case let .failed(error):
                        respond(client, status: "200 OK", body: Self.completionHTML)
                        Darwin.close(client)
                        throw error
                    case let .accepted(callback):
                        respond(client, status: "200 OK", body: Self.completionHTML)
                        Darwin.close(client)
                        return callback
                    }
                    Darwin.close(client)
                }
                throw GoogleCalendarError("sign_in_timeout", "Google Calendar sign-in timed out. Try again.")
            }.value
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        if !closed { Darwin.shutdown(descriptor, SHUT_RDWR) }
        lock.unlock()
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private func beginConsuming() -> Bool {
        lock.lock(); defer { lock.unlock() }; if consumed { return false }; consumed = true; return true
    }
    private func closeListener() {
        lock.lock(); defer { lock.unlock() }; if !closed { closed = true; Darwin.close(descriptor) }
    }
    deinit { closeListener() }

    private func readRequest(_ client: Int32) -> String? {
        _ = fcntl(client, F_SETFL, O_NONBLOCK)
        var buffer = Data()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && buffer.count < 16_384 && !isCancelled {
            var event = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            guard poll(&event, 1, 100) > 0 else { continue }
            var bytes = [UInt8](repeating: 0, count: 2_048)
            let count = Darwin.recv(client, &bytes, bytes.count, 0)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: bytes.prefix(count))
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil { return String(data: buffer, encoding: .utf8) }
        }
        return nil
    }

    private func respond(_ client: Int32, status: String, body: String) {
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let scriptHash = Data(SHA256.hash(data: Data(Self.completionScript.utf8))).base64EncodedString()
        let headers =
            "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; script-src 'sha256-\(scriptHash)'; frame-ancestors 'none'; base-uri 'none'\r\n\r\n"
        let data = Data((headers + body).utf8)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < data.count {
                let count = Darwin.send(client, base.advanced(by: written), data.count - written, 0)
                if count <= 0 { break }
                written += count
            }
        }
    }

    static func parse(_ request: String, port: UInt16, expectedState: String) -> ParsedCallback {
        let lines = request.components(separatedBy: "\r\n")
        guard let first = lines.first else { return .unrelated }
        let parts = first.split(separator: " ")
        let hostHeaders = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
        guard parts.count == 3, parts[0] == "GET", parts[2] == "HTTP/1.1", hostHeaders.count == 1,
            hostHeaders[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == "127.0.0.1:\(port)",
            parts[1].hasPrefix("/"), !parts[1].hasPrefix("//"),
            let components = URLComponents(string: "http://127.0.0.1:\(port)\(parts[1])"),
            components.host == "127.0.0.1", components.path == "/"
        else { return .unrelated }
        let items = components.queryItems ?? []
        func values(_ key: String) -> [String] { items.filter { $0.name == key }.compactMap(\.value) }
        let states = values("state")
        guard items.filter({ $0.name == "state" }).count == 1, states.count == 1,
            constantTimeEqual(states[0], expectedState)
        else { return .invalidState }
        let errors = values("error")
        let codes = values("code")
        guard items.filter({ $0.name == "error" }).count <= 1,
            items.filter({ $0.name == "code" }).count <= 1,
            !(items.contains { $0.name == "error" } && items.contains { $0.name == "code" })
        else { return .failed(GoogleCalendarError("invalid_callback", "Google did not complete sign-in. Try again.")) }
        if items.contains(where: { $0.name == "error" }) {
            return .failed(
                GoogleCalendarError(
                    errors.first == "access_denied" ? "access_denied" : "authorization_denied",
                    "Google Calendar access was declined. You can connect again when ready."))
        }
        guard codes.count == 1, !codes[0].isEmpty, codes[0].utf8.count <= 8192 else {
            return .failed(GoogleCalendarError("invalid_callback", "Google did not complete sign-in. Try again."))
        }
        return .accepted(Callback(code: codes[0]))
    }

    private static func constantTimeEqual(_ left: String, _ right: String) -> Bool {
        let a = Array(left.utf8), b = Array(right.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    private static let completionScript = "history.replaceState(null, '', '/complete');"
    private static var completionHTML: String {
        "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><title>Return to MacParakeet Live</title><h1>Return to MacParakeet Live</h1><p>The app will finish checking your Google Calendar connection. You can close this tab.</p><script>\(completionScript)</script></html>"
    }
}
