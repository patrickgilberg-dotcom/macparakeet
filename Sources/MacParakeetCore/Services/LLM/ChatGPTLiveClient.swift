import Foundation

public struct ChatGPTModel: Codable, Sendable, Identifiable, Equatable {
    public let slug: String
    public let displayName: String
    public var id: String { slug }
    enum CodingKeys: String, CodingKey { case slug; case displayName = "display_name" }
}

public struct ChatGPTModelSelection: Codable, Sendable, Equatable {
    public let model: String
    public let reasoningEffort: String?
    public init(model: String, reasoningEffort: String? = nil) {
        self.model = model
        self.reasoningEffort = reasoningEffort
    }
}

public enum ChatGPTLiveError: LocalizedError, Sendable, Equatable {
    case noModels
    case disconnected
    case http(Int, String)
    case failed(String)
    case incomplete
    case interrupted
    case malformedEvent

    public var errorDescription: String? {
        switch self {
        case .noModels: return "No models are available for this ChatGPT account. Refresh models or manage plan usage."
        case .disconnected: return "Continue with ChatGPT in Settings → AI to connect your ChatGPT plan."
        case .http(let status, let code):
            if code.hasPrefix("subscription_sharing_") { return ChatGPTLiveError.failed(code).errorDescription }
            if status == 401 {
                return "ChatGPT access has expired or was revoked. Sign in again."
            }
            if status == 429 {
                return "ChatGPT usage is limited. Open Manage usage or try again later."
            }
            if status == 503 {
                return "ChatGPT plan usage is temporarily unavailable. Your connection is saved; try again later."
            }
            return "ChatGPT request failed (HTTP \(status), \(code))."
        case .failed(let code):
            switch code {
            case "subscription_sharing_usage_limit_exceeded":
                return "This app has reached its ChatGPT plan usage limit. Open Manage usage."
            case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
                return "ChatGPT plan usage is temporarily unavailable. Try again later."
            case "subscription_sharing_user_not_eligible":
                return "This ChatGPT account is not eligible for plan usage in this app."
            default: return "ChatGPT could not complete the response (\(code))."
            }
        case .incomplete: return "ChatGPT returned an incomplete response. Any text shown is partial."
        case .interrupted: return "The connection ended before ChatGPT completed. Any text shown is partial."
        case .malformedEvent: return "ChatGPT sent an invalid stream event. Any text shown is partial."
        }
    }
}

/// Parses complete SSE events, never equating EOF or a text delta with success.
struct ChatGPTStreamDecoder {
    enum Event: Equatable { case text(String), completed, ignored }
    private var lines: [String] = []
    private var lineBytes = Data()
    private var previousWasCR = false
    private var eventBytes = 0
    private(set) var completed = false

    /// AsyncBytes.lines omits blank lines on macOS. Preserve SSE delimiters at
    /// the byte boundary so a delta can be rendered before the response ends.
    mutating func byte(_ byte: UInt8) throws -> Event {
        if previousWasCR {
            previousWasCR = false
            if byte == 10 { return .ignored }
        }
        if byte == 13 || byte == 10 {
            previousWasCR = byte == 13
            guard let text = String(data: lineBytes, encoding: .utf8) else { throw ChatGPTLiveError.malformedEvent }
            lineBytes.removeAll(keepingCapacity: true)
            return try line(text)
        }
        guard lineBytes.count < 1_048_576 else { throw ChatGPTLiveError.malformedEvent }
        lineBytes.append(byte)
        return .ignored
    }

    mutating func endOfInput() throws -> Event {
        if !lineBytes.isEmpty {
            guard let text = String(data: lineBytes, encoding: .utf8) else { throw ChatGPTLiveError.malformedEvent }
            lineBytes.removeAll(keepingCapacity: true)
            _ = try line(text)
        }
        return try flush()
    }

    mutating func line(_ line: String) throws -> Event {
        if !line.isEmpty {
            eventBytes += line.utf8.count
            guard eventBytes < 1_048_576 else {
                throw ChatGPTLiveError.malformedEvent
            }
            lines.append(line)
            return .ignored
        }
        return try flush()
    }

    mutating func flush() throws -> Event {
        defer { lines.removeAll(keepingCapacity: true); eventBytes = 0 }
        let data = lines.filter { $0.hasPrefix("data:") }
            .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        guard !data.isEmpty else { return .ignored }
        guard let raw = data.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
            let type = object["type"] as? String
        else { throw ChatGPTLiveError.malformedEvent }
        switch type {
        case "response.output_text.delta":
            guard let delta = object["delta"] as? String else { throw ChatGPTLiveError.malformedEvent }
            return .text(delta)
        case "response.completed":
            completed = true
            return .completed
        case "response.incomplete": throw ChatGPTLiveError.incomplete
        case "response.failed", "error":
            let response = object["response"] as? [String: Any]
            let error = (response?["error"] as? [String: Any]) ?? (object["error"] as? [String: Any]) ?? object
            throw ChatGPTLiveError.failed(Self.safeCode(error["code"] as? String))
        default: return .ignored
        }
    }

    static func safeCode(_ value: String?) -> String {
        guard let value, !value.isEmpty, value.count <= 100,
            value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" })
        else { return "unknown_error" }
        return value
    }
}

private final class ChatGPTRequestLease: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false
    func bind(_ task: Task<Void, Never>) {
        let cancel = lock.withLock {
            self.task = task; return cancelled
        }
        if cancel { task.cancel() }
    }
    func cancel() {
        let task = lock.withLock {
            cancelled = true; return self.task
        }
        task?.cancel()
    }
}

private final class ChatGPTRequestRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var leases: [UUID: ChatGPTRequestLease] = [:]
    func register(_ id: UUID) -> ChatGPTRequestLease {
        lock.withLock {
            let lease = ChatGPTRequestLease(); leases[id] = lease; return lease
        }
    }
    func remove(_ id: UUID) { _ = lock.withLock { leases.removeValue(forKey: id) } }
    func cancelAll() {
        let active = lock.withLock {
            let active = Array(leases.values); leases.removeAll(); return active
        }
        for lease in active { lease.cancel() }
    }
}

private final class ChatGPTNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private actor ChatGPTModelCache {
    var accountID: String?
    var catalog: [ChatGPTModel] = []
    func cached(for id: String) -> [ChatGPTModel]? { accountID == id && !catalog.isEmpty ? catalog : nil }
    func set(_ models: [ChatGPTModel], accountID: String) { self.accountID = accountID; catalog = models }
    func selection(for id: String) -> ChatGPTModelSelection? {
        guard let data = AppPaths.sharedAppDefaults().data(forKey: "chatgpt.live.selection.\(id)") else { return nil }
        return try? JSONDecoder().decode(ChatGPTModelSelection.self, from: data)
    }
    func save(_ selection: ChatGPTModelSelection, for id: String) throws {
        AppPaths.sharedAppDefaults().set(try JSONEncoder().encode(selection), forKey: "chatgpt.live.selection.\(id)")
    }
}

/// OAuth-only provider. There is deliberately no API-key, CLI, or paid fallback.
public final class ChatGPTLiveClient: LLMClientProtocol, Sendable {
    public static let shared = ChatGPTLiveClient()
    public let transport: ChatGPTTransport
    private let session: URLSession
    private let auth: ChatGPTAuth
    private let webSocket = ChatGPTWebSocketTransport()
    private let cache = ChatGPTModelCache()
    private let redirectDelegate = ChatGPTNoRedirect()
    private let requests = ChatGPTRequestRegistry()

    public init(
        auth: ChatGPTAuth = .shared, session: URLSession? = nil, transport: ChatGPTTransport = .webSocket
    ) {
        self.auth = auth
        self.transport = transport
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 45
            config.timeoutIntervalForResource = 180
            config.httpMaximumConnectionsPerHost = 4
            config.urlCache = nil
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            self.session = URLSession(configuration: config)
        }
    }

    public func models(refresh: Bool = false) async throws -> [ChatGPTModel] {
        guard let account = await auth.activeAccount() else { throw ChatGPTLiveError.disconnected }
        if !refresh, let models = await cache.cached(for: account.id) { return models }
        let token = try await auth.accessToken(expectedAccountID: account.id)
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request, delegate: redirectDelegate)
        try Self.validateHTTP(response, data: data)
        guard await auth.activeAccount()?.id == account.id else { throw CancellationError() }
        struct Catalog: Decodable {
            struct Item: Decodable {
                let slug: String; let display_name: String; let visibility: String
            }
            let models: [Item]
        }
        let result = try JSONDecoder().decode(Catalog.self, from: data).models
            .filter { $0.visibility == "list" }
            .map { ChatGPTModel(slug: $0.slug, displayName: $0.display_name) }
        guard !result.isEmpty else { throw ChatGPTLiveError.noModels }
        await cache.set(result, accountID: account.id)
        return result
    }

    public func selection() async throws -> ChatGPTModelSelection {
        guard let account = await auth.activeAccount() else { throw ChatGPTLiveError.disconnected }
        let available = try await models()
        guard await auth.activeAccount()?.id == account.id else { throw CancellationError() }
        if let saved = await cache.selection(for: account.id), available.contains(where: { $0.slug == saved.model }) {
            return saved
        }
        return ChatGPTModelSelection(model: available[0].slug)
    }

    public func selectModel(_ selection: ChatGPTModelSelection) async throws {
        guard let account = await auth.activeAccount() else { throw ChatGPTLiveError.disconnected }
        guard try await models().contains(where: { $0.slug == selection.model }) else {
            throw ChatGPTLiveError.noModels
        }
        guard await auth.activeAccount()?.id == account.id else { throw CancellationError() }
        try await cache.save(selection, for: account.id)
    }

    public func warmUp() async throws {
        guard let account = await auth.activeAccount(), account.planUsageEnabled else {
            throw ChatGPTLiveError.disconnected
        }
        let selected = try await selection()
        if transport == .webSocket {
            try await webSocket.warmUp(accountID: account.id, model: selected.model) { [auth] in
                let token = try await auth.accessToken(expectedAccountID: account.id)
                guard let current = await auth.activeAccount(), current.id == account.id, current.planUsageEnabled
                else {
                    throw CancellationError()
                }
                return token
            }
        } else {
            _ = try await auth.accessToken(expectedAccountID: account.id)
        }
    }

    public func cancelAll() {
        requests.cancelAll()
        webSocket.cancelAll()
    }

    public func configuration() async throws -> LLMProviderConfig {
        let selection = try await selection()
        // Compatibility metadata only. Credentials never enter an API-key config.
        return LLMProviderConfig(
            id: .openai, baseURL: URL(string: "https://api.openai.com/v1")!,
            apiKey: nil, modelName: selection.model, isLocal: false)
    }

    static func requestBody(messages: [ChatMessage], model: String, effort: String?) throws -> Data {
        let instructions = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        let input = messages.filter { $0.role != .system }.map {
            ["role": $0.role.rawValue, "content": $0.modelContent]
        }
        var body: [String: Any] = ["model": model, "input": input, "store": false, "stream": true]
        if !instructions.isEmpty { body["instructions"] = instructions }
        if let effort { body["reasoning"] = ["effort": effort] }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private static func diagnosticValue(_ value: String) -> String {
        guard !value.isEmpty, value.utf8.count <= 128,
            value.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || $0 == 45 || $0 == 46 || $0 == 47 || $0 == 95
            })
        else { return "unrecognized" }
        return value
    }

    static func webSocketRequestBody(messages: [ChatMessage], model: String, effort: String?) throws -> Data {
        let data = try requestBody(messages: messages, model: model, effort: effort)
        var body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        body.removeValue(forKey: "stream")
        body["type"] = "response.create"
        return try JSONSerialization.data(withJSONObject: body)
    }

    public func stream(messages: [ChatMessage], model: String? = nil, reasoningEffort: String? = nil)
        -> AsyncThrowingStream<String, Error>
    {
        let source = detailedStream(messages: messages, model: model, reasoningEffort: reasoningEffort)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in source {
                        if case .text(let text) = event { continuation.yield(text) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func detailedStream(messages: [ChatMessage], model: String? = nil, reasoningEffort: String? = nil)
        -> AsyncThrowingStream<LLMStreamEvent, Error>
    {
        AsyncThrowingStream { continuation in
            let requestID = UUID()
            let lease = requests.register(requestID)
            let task = Task {
                defer { self.requests.remove(requestID) }
                do {
                    guard let account = await self.auth.activeAccount() else { throw ChatGPTLiveError.disconnected }
                    let selected = try await self.selection()
                    let chosenModel = model ?? selected.model
                    let effort = reasoningEffort ?? (model == nil ? selected.reasoningEffort : nil)
                    AudioCaptureDiagnostics.appendAsync(
                        "chatgpt_live_request model=\(Self.diagnosticValue(chosenModel)) effort=\(Self.diagnosticValue(effort ?? "provider-default")) transport=\(self.transport.rawValue)",
                        correlation: nil)
                    if self.transport == .webSocket {
                        let payload = try Self.webSocketRequestBody(
                            messages: messages, model: chosenModel, effort: effort)
                        try await self.webSocket.run(
                            accountID: account.id, model: chosenModel,
                            payload: String(decoding: payload, as: UTF8.self),
                            authorization: { [auth = self.auth] in
                                let token = try await auth.accessToken(expectedAccountID: account.id)
                                guard let current = await auth.activeAccount(), current.id == account.id,
                                    current.planUsageEnabled
                                else { throw CancellationError() }
                                return token
                            }, yield: { continuation.yield(.text($0)) })
                        try Task.checkCancellation()
                        continuation.yield(.completed(LLMStreamTerminal(provider: "chatgpt-plan", model: chosenModel)))
                        continuation.finish()
                        return
                    }
                    let token = try await self.auth.accessToken(expectedAccountID: account.id)
                    try Task.checkCancellation()
                    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.httpBody = try Self.requestBody(messages: messages, model: chosenModel, effort: effort)
                    guard let current = await self.auth.activeAccount(), current.id == account.id,
                        current.planUsageEnabled
                    else { throw CancellationError() }
                    try Task.checkCancellation()
                    let (bytes, response) = try await self.session.bytes(for: request, delegate: self.redirectDelegate)
                    guard let http = response as? HTTPURLResponse else { throw ChatGPTLiveError.interrupted }
                    guard (200..<300).contains(http.statusCode) else {
                        var errorData = Data()
                        for try await byte in bytes {
                            errorData.append(byte)
                            if errorData.count >= 16_384 { break }
                        }
                        try Self.validateHTTP(response, data: errorData)
                        throw ChatGPTLiveError.interrupted
                    }
                    var decoder = ChatGPTStreamDecoder()
                    var meaningfulTextReceived = false
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        switch try decoder.byte(byte) {
                        case .text(let text):
                            meaningfulTextReceived =
                                meaningfulTextReceived || text.contains(where: { $0.isLetter || $0.isNumber })
                            continuation.yield(.text(text))
                        case .completed: break
                        case .ignored: break
                        }
                        if decoder.completed { break }
                    }
                    if !decoder.completed {
                        switch try decoder.endOfInput() {
                        case .text(let text):
                            meaningfulTextReceived =
                                meaningfulTextReceived || text.contains(where: { $0.isLetter || $0.isNumber })
                            continuation.yield(.text(text))
                        default: break
                        }
                    }
                    try Task.checkCancellation()
                    guard decoder.completed else { throw ChatGPTLiveError.interrupted }
                    guard meaningfulTextReceived else { throw ChatGPTLiveError.incomplete }
                    continuation.yield(.completed(LLMStreamTerminal(provider: "chatgpt-plan", model: chosenModel)))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            lease.bind(task)
            continuation.onTermination = { _ in lease.cancel() }
        }
    }

    static func validateHTTP(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw ChatGPTLiveError.interrupted }
        guard (200..<300).contains(http.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = object?["error"] as? [String: Any]
            let code = ChatGPTStreamDecoder.safeCode((error?["code"] ?? object?["code"]) as? String)
            throw ChatGPTLiveError.http(http.statusCode, code)
        }
    }

    public func chatCompletion(messages: [ChatMessage], context: LLMExecutionContext, options: ChatCompletionOptions)
        async throws -> ChatCompletionResponse
    {
        var text = ""
        for try await event in chatCompletionDetailedStream(messages: messages, context: context, options: options) {
            if case .text(let delta) = event { text += delta }
        }
        return ChatCompletionResponse(content: text, finishReason: "completed", model: context.providerConfig.modelName)
    }

    public func chatCompletionStream(
        messages: [ChatMessage], context: LLMExecutionContext, options: ChatCompletionOptions
    )
        -> AsyncThrowingStream<String, Error>
    {
        stream(
            messages: messages, model: context.providerConfig.modelName,
            reasoningEffort: options.reasoningEffort?.rawValue)
    }

    public func chatCompletionDetailedStream(
        messages: [ChatMessage], context: LLMExecutionContext, options: ChatCompletionOptions
    )
        -> AsyncThrowingStream<LLMStreamEvent, Error>
    {
        detailedStream(
            messages: messages, model: context.providerConfig.modelName,
            reasoningEffort: options.reasoningEffort?.rawValue)
    }

    public func listModels(context: LLMExecutionContext) async throws -> [String] { try await models().map(\.slug) }

    public func testConnection(context: LLMExecutionContext) async throws {
        _ = try await chatCompletion(
            messages: [ChatMessage(role: .user, content: "Say exactly: Connected.")],
            context: context, options: ChatCompletionOptions())
    }
}
