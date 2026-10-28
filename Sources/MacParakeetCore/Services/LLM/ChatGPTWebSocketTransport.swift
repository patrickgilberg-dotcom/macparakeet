import CoreFoundation
import CryptoKit
import Foundation

public enum ChatGPTTransport: String, Codable, Sendable, CaseIterable {
    case httpSSE = "http-sse"
    case webSocket = "websocket"
}

/// Small injectable boundary: tests never open a socket or read credentials.
protocol ChatGPTWebSocket: Sendable {
    var isReusable: Bool { get }
    func ping() async throws
    func send(_ text: String) async throws
    func receive() async throws -> Data
    func cancel()
}

protocol ChatGPTWebSocketConnecting: Sendable {
    func connect(token: String) throws -> any ChatGPTWebSocket
}

/// Native pong callbacks can be delivered again while a task is closing. Take
/// the continuation once under the mutex, then resume outside the critical section.
final class ChatGPTPingSettlement: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func settle(error: Error?) {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        guard let pending else { return }
        if let error { pending.resume(throwing: error) } else { pending.resume() }
    }
}

private final class NativeChatGPTWebSocket: ChatGPTWebSocket, Sendable {
    let task: URLSessionWebSocketTask
    init(_ task: URLSessionWebSocketTask) { self.task = task }
    var isReusable: Bool { task.state == .running && task.closeCode == .invalid }
    func ping() async throws {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let settlement = ChatGPTPingSettlement(continuation)
                task.sendPing { error in settlement.settle(error: error) }
            }
        } catch { throw ChatGPTWebSocketFailure.map(error, response: task.response) }
    }
    func send(_ text: String) async throws {
        do { try await task.send(.string(text)) } catch {
            throw ChatGPTWebSocketFailure.map(error, response: task.response)
        }
    }
    func receive() async throws -> Data {
        do {
            switch try await task.receive() {
            case .string(let text): return Data(text.utf8)
            case .data(let data): return data
            @unknown default: throw ChatGPTLiveError.malformedEvent
            }
        } catch { throw ChatGPTWebSocketFailure.map(error, response: task.response) }
    }
    func cancel() { task.cancel(with: .goingAway, reason: nil) }
}

enum ChatGPTWebSocketFailure {
    /// Foundation may expose a refused upgrade as URLError. Preserve an actual
    /// HTTP failure status without relabeling later network loss on a 101 socket.
    static func map(_ error: Error, response: URLResponse?) -> Error {
        guard let response = response as? HTTPURLResponse, (400...599).contains(response.statusCode) else {
            return error
        }
        return ChatGPTLiveError.http(response.statusCode, "websocket_handshake_rejected")
    }
}

private final class ChatGPTWebSocketNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

final class NativeChatGPTWebSocketConnector: ChatGPTWebSocketConnecting, Sendable {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 3_600
        session = URLSession(configuration: configuration, delegate: ChatGPTWebSocketNoRedirect(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func connect(token: String) throws -> any ChatGPTWebSocket {
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/responses")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 4 * 1_024 * 1_024
        task.resume()
        return NativeChatGPTWebSocket(task)
    }
}

/// Invalidates both idle and in-flight sockets synchronously, including while
/// the actor is suspended in authorization. No callback runs under this lock.
final class ChatGPTWebSocketControl: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var connectionID: UUID?
    private var ownerID: UUID?
    private var socket: (any ChatGPTWebSocket)?
    var generation: UInt64 { lock.withLock { epoch } }

    func install(_ socket: any ChatGPTWebSocket, connectionID: UUID, generation: UInt64) throws {
        let accepted = lock.withLock {
            guard epoch == generation else { return false }
            self.socket = socket; self.connectionID = connectionID; ownerID = nil
            return true
        }
        if !accepted { socket.cancel(); throw CancellationError() }
    }
    func claim(connectionID: UUID, requestID: UUID, generation: UInt64) throws {
        try lock.withLock {
            guard epoch == generation, self.connectionID == connectionID else { throw CancellationError() }
            ownerID = requestID
        }
    }
    func check(connectionID: UUID, requestID: UUID, generation: UInt64) throws {
        try lock.withLock {
            guard epoch == generation, self.connectionID == connectionID, ownerID == requestID else {
                throw CancellationError()
            }
        }
    }
    func isCurrent(connectionID: UUID, generation: UInt64) -> Bool {
        lock.withLock { epoch == generation && self.connectionID == connectionID }
    }
    func release(requestID: UUID) {
        lock.withLock { if ownerID == requestID { ownerID = nil } }
    }
    func cancel(requestID: UUID? = nil) {
        let previous: (any ChatGPTWebSocket)? = lock.withLock {
            if let requestID, ownerID != requestID { return nil }
            epoch &+= 1
            let previous = socket
            socket = nil; connectionID = nil; ownerID = nil
            return previous
        }
        previous?.cancel()
    }
}

private final class ChatGPTSocketDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var exceeded = false
    func expire() { lock.withLock { exceeded = true } }
    var isExceeded: Bool { lock.withLock { exceeded } }
}

/// One serialized implicit lane avoids optional multiplexing fields that the
/// current ChatGPT plan route rejects.
/// A cancelled or failed turn closes the connection before another turn starts.
actor ChatGPTWebSocketTransport {
    nonisolated let control = ChatGPTWebSocketControl()
    private let connector: any ChatGPTWebSocketConnecting
    private let now: @Sendable () -> Date
    private let deadline: Duration
    private let healthCheckTimeout: Duration
    private let maximumAge: TimeInterval
    private var connection: Connection?
    private var owner: UUID?
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    private enum HealthResult: Sendable { case pong, timedOut }

    private struct Connection: Sendable {
        let id: UUID
        let generation: UInt64
        let accountID: String
        let model: String
        let tokenFingerprint: Data
        let reuseUntil: Date
        let socket: any ChatGPTWebSocket
    }

    init(
        connector: any ChatGPTWebSocketConnecting = NativeChatGPTWebSocketConnector(),
        now: @escaping @Sendable () -> Date = { Date() }, deadline: Duration = .seconds(90),
        maximumAge: TimeInterval = 55 * 60, healthCheckTimeout: Duration = .seconds(2)
    ) {
        self.connector = connector; self.now = now; self.deadline = deadline; self.maximumAge = maximumAge
        self.healthCheckTimeout = healthCheckTimeout
    }

    nonisolated func cancelAll() { control.cancel() }

    func run(
        accountID: String, model: String, payload: String,
        authorization: @escaping @Sendable () async throws -> String,
        yield: @escaping @Sendable (String) -> Void
    ) async throws {
        let requestID = UUID()
        let control = control
        try await withTaskCancellationHandler {
            try await acquire(requestID)
            defer { release(requestID) }
            try Task.checkCancellation()
            let generation = control.generation
            // Refresh after acquiring the lane: a queued request must not carry
            // an access token obtained before a long preceding response.
            let token = try await authorization()
            try Task.checkCancellation()
            guard generation == control.generation else { throw CancellationError() }
            let cachedID = connection?.id
            var current = try prepare(accountID: accountID, model: model, token: token, generation: generation)
            try control.claim(connectionID: current.id, requestID: requestID, generation: generation)
            do {
                if current.id == cachedID {
                    do {
                        try await checkLiveness(current, requestID: requestID)
                    } catch {
                        // Only a control-frame failure is recoverable here. No
                        // response.create has been attempted on this request.
                        try Task.checkCancellation()
                        try control.check(
                            connectionID: current.id, requestID: requestID, generation: generation)
                        current.socket.cancel()
                        connection = nil
                        let replacementToken = try await authorization()
                        try Task.checkCancellation()
                        guard generation == control.generation else { throw CancellationError() }
                        current = try prepare(
                            accountID: accountID, model: model, token: replacementToken, generation: generation)
                        try control.claim(connectionID: current.id, requestID: requestID, generation: generation)
                    }
                }
                try Task.checkCancellation()
                try await receiveResponse(current, requestID: requestID, payload: payload, yield: yield)
            } catch {
                // Never replay after send was attempted, even if no delta arrived.
                control.cancel(requestID: requestID)
                connection = nil
                throw error
            }
        } onCancel: {
            control.cancel(requestID: requestID)
            Task { await self.cancelWaiter(requestID) }
        }
    }

    func warmUp(
        accountID: String, model: String,
        authorization: @escaping @Sendable () async throws -> String
    ) async throws {
        let requestID = UUID()
        let control = control
        try await withTaskCancellationHandler {
            try await acquire(requestID)
            defer { release(requestID) }
            try Task.checkCancellation()
            let generation = control.generation
            let token = try await authorization()
            try Task.checkCancellation()
            guard generation == control.generation else { throw CancellationError() }
            let current = try prepare(accountID: accountID, model: model, token: token, generation: generation)
            do {
                try control.claim(connectionID: current.id, requestID: requestID, generation: generation)
                try Task.checkCancellation()
                // Resume opens the handshake; no request, fixture or meeting text is sent.
            } catch {
                control.cancel(requestID: requestID)
                connection = nil
                throw error
            }
        } onCancel: {
            control.cancel(requestID: requestID)
            Task { await self.cancelWaiter(requestID) }
        }
    }

    private func prepare(accountID: String, model: String, token: String, generation: UInt64) throws -> Connection {
        let fingerprint = Data(SHA256.hash(data: Data(token.utf8)))
        let date = now()
        if let connection, connection.accountID == accountID, connection.model == model,
            connection.tokenFingerprint == fingerprint, connection.reuseUntil > date,
            connection.socket.isReusable,
            control.isCurrent(connectionID: connection.id, generation: connection.generation)
        {
            return connection
        }
        // Retiring an old connection here does not cancel the current task's lease.
        let retired = connection
        connection = nil
        retired?.socket.cancel()
        let socket = try connector.connect(token: token)
        let id = UUID()
        try control.install(socket, connectionID: id, generation: generation)
        var reuseUntil = date.addingTimeInterval(maximumAge)
        // Expiry is only a conservative reuse bound, never an identity check.
        // Auth remains responsible for validated grants and serialized refresh.
        if let expiry = Self.accessTokenExpiry(token) {
            reuseUntil = min(reuseUntil, expiry.addingTimeInterval(-90))
        }
        let result = Connection(
            id: id, generation: generation, accountID: accountID, model: model,
            tokenFingerprint: fingerprint, reuseUntil: reuseUntil, socket: socket)
        connection = result
        return result
    }

    private func checkLiveness(_ connection: Connection, requestID: UUID) async throws {
        let control = control
        let timeout = healthCheckTimeout
        try await withThrowingTaskGroup(of: HealthResult.self) { group in
            group.addTask {
                try Task.checkCancellation()
                try control.check(
                    connectionID: connection.id, requestID: requestID, generation: connection.generation)
                try await connection.socket.ping()
                try Task.checkCancellation()
                try control.check(
                    connectionID: connection.id, requestID: requestID, generation: connection.generation)
                return .pong
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return .timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw ChatGPTLiveError.interrupted }
            if case .timedOut = result {
                try control.check(
                    connectionID: connection.id, requestID: requestID, generation: connection.generation)
                // Only the parent's selected timeout may close the captured old
                // socket. An already-awake losing timer has no side effects.
                connection.socket.cancel()
                throw ChatGPTLiveError.failed("websocket_health_check_timed_out")
            }
        }
    }

    private func receiveResponse(
        _ connection: Connection, requestID: UUID, payload: String,
        yield: @escaping @Sendable (String) -> Void
    ) async throws {
        let control = control
        let deadline = deadline
        let deadlineState = ChatGPTSocketDeadline()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try control.check(
                        connectionID: connection.id, requestID: requestID, generation: connection.generation)
                    try Task.checkCancellation()
                    try await connection.socket.send(payload)
                    var decoder = ChatGPTWebSocketDecoder()
                    var outputBytes = 0
                    var meaningful = false
                    while true {
                        let data = try await connection.socket.receive()
                        try Task.checkCancellation()
                        try control.check(
                            connectionID: connection.id, requestID: requestID, generation: connection.generation)
                        switch try decoder.decode(data) {
                        case .text(let delta):
                            outputBytes += delta.utf8.count
                            guard outputBytes <= 1_048_576 else { throw ChatGPTLiveError.malformedEvent }
                            meaningful = meaningful || delta.contains(where: { $0.isLetter || $0.isNumber })
                            yield(delta)
                        case .completed:
                            guard meaningful else { throw ChatGPTLiveError.incomplete }
                            return
                        case .ignored: break
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: deadline)
                    deadlineState.expire()
                    control.cancel(requestID: requestID)
                    throw ChatGPTLiveError.failed("response_deadline_exceeded")
                }
                defer { group.cancelAll() }
                guard try await group.next() != nil else { throw ChatGPTLiveError.interrupted }
            }
        } catch {
            if deadlineState.isExceeded { throw ChatGPTLiveError.failed("response_deadline_exceeded") }
            if error is CancellationError, !Task.isCancelled { throw ChatGPTLiveError.interrupted }
            throw error
        }
    }

    private func acquire(_ id: UUID) async throws {
        try Task.checkCancellation()
        if owner == nil { owner = id; return }
        try await withCheckedThrowingContinuation { waiters.append((id, $0)) }
        // The caller installs its release defer before checking cancellation.
    }
    private func release(_ id: UUID) {
        guard owner == id else { return }
        control.release(requestID: id)
        if waiters.isEmpty {
            owner = nil
        } else {
            let next = waiters.removeFirst(); owner = next.0; next.1.resume()
        }
    }
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }

    static func accessTokenExpiry(_ token: String) -> Date? {
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3 else { return nil }
        var encoded = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(
            of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
            let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let expiry = claims["exp"] as? NSNumber, CFGetTypeID(expiry) != CFBooleanGetTypeID(),
            expiry.doubleValue.isFinite
        else { return nil }
        return Date(timeIntervalSince1970: expiry.doubleValue)
    }
}

struct ChatGPTWebSocketDecoder {
    enum Event: Equatable { case text(String), completed, ignored }
    private var responseID: String?
    mutating func decode(_ data: Data) throws -> Event {
        guard data.count <= 4 * 1_024 * 1_024,
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let type = object["type"] as? String
        else { throw ChatGPTLiveError.malformedEvent }
        if type == "error" {
            let failure = object["error"] as? [String: Any]
            let code = ChatGPTStreamDecoder.safeCode(failure?["code"] as? String)
            if let status = object["status"] as? Int { throw ChatGPTLiveError.http(status, code) }
            throw ChatGPTLiveError.failed(code)
        }
        switch type {
        case "response.created":
            guard responseID == nil, let response = object["response"] as? [String: Any],
                let id = response["id"] as? String, !id.isEmpty
            else { throw ChatGPTLiveError.malformedEvent }
            responseID = id
            return .ignored
        case "response.output_text.delta":
            if let suppliedID = object["response_id"] {
                guard let id = suppliedID as? String, id == responseID else { throw ChatGPTLiveError.malformedEvent }
            }
            guard responseID != nil, let delta = object["delta"] as? String else {
                throw ChatGPTLiveError.malformedEvent
            }
            return .text(delta)
        case "response.completed":
            guard let response = object["response"] as? [String: Any],
                let id = response["id"] as? String, id == responseID,
                response["status"] as? String == "completed",
                response["error"] == nil || response["error"] is NSNull
            else { throw ChatGPTLiveError.malformedEvent }
            return .completed
        case "response.incomplete": throw ChatGPTLiveError.incomplete
        case "response.failed":
            let response = object["response"] as? [String: Any]
            let failure = response?["error"] as? [String: Any]
            throw ChatGPTLiveError.failed(ChatGPTStreamDecoder.safeCode(failure?["code"] as? String))
        default: return .ignored
        }
    }
}
