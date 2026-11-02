import Foundation
import MacParakeetCore

/// An isolated experiment, not the app's live provider. Uses the app's own OAuth
/// grant and the public Responses socket, with no paid service-tier override.
enum WebSocketProbe {
    static let outputPath = "/tmp/macparakeet-live-websocket.json"

    struct Trial: Codable, Sendable {
        let transport: String
        let condition: String
        let firstTextMs: Double?
        let firstSentenceMs: Double?
        let completionMs: Double
        let completed: Bool
        let output: String
        let error: String?
    }
    struct Summary: Codable {
        let transport: String
        let condition: String
        let trials: Int
        let failures: Int
        let medianFirstTextMs: Double?
        let p95FirstTextMs: Double?
        let medianFirstSentenceMs: Double?
        let p95FirstSentenceMs: Double?
        let medianCompletionMs: Double?
        let p95CompletionMs: Double?
    }
    struct Report: Codable {
        let timestamp: Date
        let model: String
        let reasoningEffort: String?
        let operatingSystem: String
        let processorCount: Int
        let trials: [Trial]
        let summaries: [Summary]
        let notes: [String]
    }
    enum Event: Equatable {
        case text(String)
        case completed
        case ignored
    }
    struct ProbeError: LocalizedError, Sendable {
        let code: String
        var errorDescription: String? { "WebSocket benchmark failed (\(code)). Any streamed text is partial." }
    }
    private final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var output = ""
        private var firstText: Double?
        private var firstSentence: Double?
        func append(_ delta: String, elapsed: Double) throws {
            try lock.withLock {
                output += delta
                guard output.utf8.count <= 1_048_576 else { throw ProbeError(code: "response_too_large") }
                if firstText == nil, output.contains(where: { $0.isLetter || $0.isNumber }) {
                    firstText = elapsed
                }
                if firstSentence == nil, ChatGPTLiveBenchmark.firstSentencePresent(output) { firstSentence = elapsed }
            }
        }
        func record(condition: String, elapsed: Double, completed: Bool, error: String?) -> Trial {
            lock.withLock {
                Trial(
                    transport: "websocket", condition: condition, firstTextMs: firstText,
                    firstSentenceMs: firstSentence, completionMs: elapsed, completed: completed,
                    output: output, error: error)
            }
        }
        var hasText: Bool { lock.withLock { !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) { completionHandler(nil) }
    }

    /// Each response sends the same full fixture as HTTP, deliberately avoiding
    /// conversation-chain or prompt warmup advantages in this first comparison.
    static func run(model: String, trials: Int) async throws {
        guard (1...50).contains(trials) else { throw ProbeError(code: "trials_must_be_1_to_50") }
        try contractChecks()
        let auth = ChatGPTAuth.shared
        let client = ChatGPTLiveClient(transport: .httpSSE)
        guard let account = await auth.activeAccount(), account.planUsageEnabled else {
            throw ProbeError(code: "chatgpt_plan_not_connected")
        }
        let available = try await client.models()
        guard available.contains(where: { $0.slug == model }) else {
            throw ProbeError(code: "model_not_in_account_catalog")
        }
        let selected = try await client.selection()
        guard selected.model == model else {
            throw ProbeError(code: "select_model_before_testing_its_reasoning_setting")
        }
        let token = try await auth.accessToken(expectedAccountID: account.id)
        guard await auth.activeAccount()?.id == account.id else { throw CancellationError() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 3_600
        let delegate = NoRedirect()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/responses")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 4 * 1_024 * 1_024
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        var records: [Trial] = []
        var firstSocketRequest = true
        for condition in ["warm-recent", "warm-long-meeting"] {
            for _ in 0..<trials {
                try Task.checkCancellation()
                guard let active = await auth.activeAccount(), active.id == account.id, active.planUsageEnabled else {
                    throw ProbeError(code: "account_changed")
                }
                let websocketCondition = firstSocketRequest ? "socket-first-request-includes-handshake" : condition
                let payload = try requestBody(
                    model: model, effort: selected.reasoningEffort,
                    messages: ChatGPTLiveBenchmark.messages(condition: condition))
                let websocket = await trial(socket: socket, payload: payload, condition: websocketCondition)
                firstSocketRequest = false
                records.append(websocket)
                printTrial(websocket)
                try save(records, model: model, effort: selected.reasoningEffort)
                try Task.checkCancellation()
                guard let active = await auth.activeAccount(), active.id == account.id, active.planUsageEnabled else {
                    throw ProbeError(code: "account_changed")
                }
                let http = await ChatGPTLiveBenchmark.trial(
                    client: client, model: model, effort: selected.reasoningEffort, condition: condition)
                let httpRecord = Trial(
                    transport: "http-sse", condition: condition,
                    firstTextMs: http.firstTextMs, firstSentenceMs: http.firstSentenceMs,
                    completionMs: http.completionMs,
                    completed: http.completed && !http.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    output: http.output, error: http.error)
                records.append(httpRecord)
                printTrial(httpRecord)
                try save(records, model: model, effort: selected.reasoningEffort)
                guard websocket.completed else {
                    // An incomplete lane may still be running; never send the next
                    // question into it or confuse its remaining deltas with a trial.
                    throw ProbeError(code: websocket.error ?? "socket_response_incomplete")
                }
            }
        }
        print("WebSocket/HTTP comparison: \(outputPath)")
    }

    private static func trial(socket: URLSessionWebSocketTask, payload: String, condition: String) async -> Trial {
        let start = ProcessInfo.processInfo.systemUptime
        let progress = Progress()
        do {
            return try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Trial.self) { group in
                    group.addTask {
                        try await socket.send(.string(payload))
                        while true {
                            try Task.checkCancellation()
                            let message = try await socket.receive()
                            let data: Data
                            switch message {
                            case .string(let text): data = Data(text.utf8)
                            case .data(let bytes): data = bytes
                            @unknown default: throw ProbeError(code: "unsupported_websocket_message")
                            }
                            let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1_000
                            switch try decode(data) {
                            case .text(let delta):
                                try progress.append(delta, elapsed: elapsed)
                            case .completed:
                                guard progress.hasText else { throw ProbeError(code: "completed_without_text") }
                                return progress.record(
                                    condition: condition, elapsed: elapsed, completed: true, error: nil)
                            case .ignored: break
                            }
                        }
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(90))
                        socket.cancel(with: .goingAway, reason: nil)
                        throw ProbeError(code: "response_deadline_exceeded")
                    }
                    defer { group.cancelAll() }
                    guard let result = try await group.next() else { throw ProbeError(code: "no_response") }
                    return result
                }
            } onCancel: {
                socket.cancel(with: .goingAway, reason: nil)
            }
        } catch {
            socket.cancel(with: .goingAway, reason: nil)
            let code: String
            if error is CancellationError {
                code = "cancelled"
            } else if let failure = error as? ProbeError {
                code = failure.code
            } else if let failure = error as? URLError {
                code = "url_error_\(failure.code.rawValue)"
            } else {
                code = "stream_interrupted"
            }
            return progress.record(
                condition: condition,
                elapsed: (ProcessInfo.processInfo.systemUptime - start) * 1_000, completed: false, error: code)
        }
    }

    static func requestBody(model: String, effort: String?, context: String) throws -> String {
        try requestBody(
            model: model, effort: effort,
            messages: [
                ChatMessage(role: .system, content: ChatGPTLiveBenchmark.instructions),
                ChatMessage(role: .user, content: context),
            ])
    }

    static func requestBody(model: String, effort: String?, messages: [ChatMessage]) throws -> String {
        var body: [String: Any] = [
            "type": "response.create", "model": model, "store": false,
            "instructions": messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n"),
            "input": messages.filter { $0.role != .system }.map {
                ["role": $0.role.rawValue, "content": $0.modelContent]
            },
        ]
        if let effort { body["reasoning"] = ["effort": effort] }
        return String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
    }

    static func decode(_ data: Data) throws -> Event {
        guard data.count <= 4 * 1_024 * 1_024,
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let type = object["type"] as? String
        else { throw ProbeError(code: "malformed_event") }
        switch type {
        case "response.output_text.delta":
            guard let text = object["delta"] as? String else { throw ProbeError(code: "malformed_delta") }
            return .text(text)
        case "response.completed":
            let response = object["response"] as? [String: Any]
            if let status = response?["status"] as? String, status != "completed" {
                throw ProbeError(code: "invalid_completed_status")
            }
            return .completed
        case "response.incomplete": throw ProbeError(code: "response_incomplete")
        case "response.failed", "error":
            let response = object["response"] as? [String: Any]
            let error = (response?["error"] as? [String: Any]) ?? (object["error"] as? [String: Any]) ?? object
            throw ProbeError(code: safeCode(error["code"] as? String))
        default: return .ignored
        }
    }

    private static func safeCode(_ value: String?) -> String {
        guard let value, !value.isEmpty, value.utf8.count <= 100,
            value.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
            })
        else { return "unknown_error" }
        return value
    }

    /// Pure contract checks run before any network or credentials are touched.
    static func contractChecks() throws {
        func require(_ condition: Bool, _ code: String) throws {
            if !condition { throw ProbeError(code: "contract_check_" + code) }
        }
        let body = try requestBody(model: "catalog-model", effort: "low", context: "fixture")
        let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as! [String: Any]
        try require(object["type"] as? String == "response.create", "event_type")
        try require(object["store"] as? Bool == false, "store_false")
        try require(
            object["stream"] == nil && object["background"] == nil && object["previous_response_id"] == nil
                && object["service_tier"] == nil, "unsupported_fields_absent")
        try require(object["input"] is [[String: String]], "input_array")
        try require(
            try decode(Data(#"{"type":"response.output_text.delta","delta":"Hello"}"#.utf8)) == .text("Hello"),
            "text_delta")
        try require(
            try decode(Data(#"{"type":"response.completed","response":{"status":"completed"}}"#.utf8)) == .completed,
            "completed")
        for raw in [
            #"{"type":"response.incomplete"}"#,
            #"{"type":"response.failed","response":{"error":{"code":"usage_limit"}}}"#,
            #"{"type":"error","error":{"code":"unsupported"}}"#, #"{"type":"response.output_text.delta"}"#, "invalid",
        ] {
            do { _ = try decode(Data(raw.utf8)); throw ProbeError(code: "contract_check_failure_accepted") } catch let
                error as ProbeError
            { if error.code == "contract_check_failure_accepted" { throw error } }
        }
    }

    private static func save(_ records: [Trial], model: String, effort: String?) throws {
        let groups = Dictionary(grouping: records, by: { $0.transport + "|" + $0.condition })
        let summaries = groups.keys.sorted().compactMap { key -> Summary? in
            guard let group = groups[key], let first = group.first else { return nil }
            let successful = group.filter(\.completed)
            return Summary(
                transport: first.transport, condition: first.condition, trials: group.count,
                failures: group.count - successful.count,
                medianFirstTextMs: percentile(successful.compactMap(\.firstTextMs), fraction: 0.5),
                p95FirstTextMs: percentile(successful.compactMap(\.firstTextMs), fraction: 0.95),
                medianFirstSentenceMs: percentile(successful.compactMap(\.firstSentenceMs), fraction: 0.5),
                p95FirstSentenceMs: percentile(successful.compactMap(\.firstSentenceMs), fraction: 0.95),
                medianCompletionMs: percentile(successful.map(\.completionMs), fraction: 0.5),
                p95CompletionMs: percentile(successful.map(\.completionMs), fraction: 0.95))
        }
        let report = Report(
            timestamp: Date(), model: model, reasoningEffort: effort,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            processorCount: ProcessInfo.processInfo.processorCount, trials: records, summaries: summaries,
            notes: [
                "Synthetic fixture text matches the existing HTTP benchmark; no meeting data or credentials are saved.",
                "One OAuth-authenticated socket sends full input on every request, without previous_response_id, generate:false warmup, or service-tier override.",
                "The first socket request includes handshake latency and is excluded from warm request groups.",
                "WebSocket then HTTP trials alternate. OS/server caches and workload can change; this is exploratory, not a latency guarantee.",
                "First-sentence latency uses the same punctuation proxy as HTTP; inspect the synthetic outputs for usefulness.",
                "Each socket response has a 90-second hard deadline. A failed socket stops the experiment to avoid mixing residual deltas into another trial.",
                "Provider timings exclude audio, transcription, hotkeys, and UI rendering.",
            ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }

    private static func printTrial(_ trial: Trial) {
        print(
            "\(trial.transport) \(trial.condition): \(trial.completed ? "completed" : "FAILED"); text \(trial.firstTextMs.map { String(Int($0)) } ?? "—")ms; sentence \(trial.firstSentenceMs.map { String(Int($0)) } ?? "—")ms; total \(Int(trial.completionMs))ms\(trial.error.map { "; " + $0 } ?? "")"
        )
    }
    private static func percentile(_ values: [Double], fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1))]
    }

    // Keep these fixtures byte-equivalent to ChatGPTLiveBenchmark's private
    // recentContext and longContext, so the transports receive equivalent work.
    private static let recentContext = """
        Prepared meeting context: We are proposing a six-week pilot for a support team. Success means reducing median response time by 20% while maintaining quality. Integration is read-only. No production rollout is approved.
        Recent transcript:
        Customer: We can provide a test account next Monday.
        Me: We need a security review before we connect it.
        Customer: If security takes two weeks, does that put the pilot at risk, and what would you do in the meantime?
        Help me answer the customer's latest question.
        """
    private static let longContext = """
        Compact facts from earlier in a 90-minute meeting: Pilot lasts six weeks. Sponsor is Maya. Budget is still pending. Success is 20% lower median response time with no quality regression. Read-only integration. Security review required before connection. Next decision is Friday. No production rollout approved. Customer's data export can be used for offline workflow mapping, subject to their approval. Do not claim the budget or export is approved.
        """
        + String(
            repeating:
                "Earlier discussion: The team compared routing, reporting and onboarding. No additional commitments were made.\n",
            count: 45) + recentContext
}
