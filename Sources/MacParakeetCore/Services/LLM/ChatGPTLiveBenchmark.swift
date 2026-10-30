import Foundation
import Darwin

public struct ChatGPTBenchmarkTrial: Codable, Sendable {
    public let model: String
    public let transport: ChatGPTTransport
    public let reasoningEffort: String?
    public let condition: String
    public let inputCharacters: Int
    public let firstTextMs: Double?
    public let firstSentenceMs: Double?
    public let completionMs: Double
    public let completed: Bool
    public let output: String
    public let error: String?
    public let errorStatus: Int?
    public let errorCode: String?
}

public struct ChatGPTBenchmarkSummary: Codable, Sendable {
    public let model: String
    public let transport: ChatGPTTransport
    public let condition: String
    public let trials: Int
    public let failures: Int
    public let medianFirstTextMs: Double?
    public let p95FirstTextMs: Double?
    public let medianFirstSentenceMs: Double?
    public let p95FirstSentenceMs: Double?
    public let medianCompletionMs: Double?
    public let p95CompletionMs: Double?
}

public struct ChatGPTBenchmarkReport: Codable, Sendable {
    public let timestamp: Date
    public let operatingSystem: String
    public let processorCount: Int
    public let hardware: String
    public let memoryGB: UInt64
    public let trials: [ChatGPTBenchmarkTrial]
    public let summaries: [ChatGPTBenchmarkSummary]
    public let notes: [String]
}

/// Uses the same native persistent connection pool and streaming provider as Live Ask.
/// Fixtures contain invented business context; no meeting data is included in the report.
public enum ChatGPTLiveBenchmark {
    public static let instructions = LiveAnswerContext.instructions

    public static func firstSentencePresent(_ text: String) -> Bool {
        LiveAnswerTiming.containsSentence(text)
    }

    public static func trial(client: ChatGPTLiveClient = .shared, model: String, effort: String?, condition: String)
        async -> ChatGPTBenchmarkTrial
    {
        let messages = messages(condition: condition)
        let start = ProcessInfo.processInfo.systemUptime
        var firstText: Double?
        var firstSentence: Double?
        var output = ""
        var failure: String?
        var errorStatus: Int?
        var errorCode: String?
        var completed = false
        do {
            for try await event in client.detailedStream(messages: messages, model: model, reasoningEffort: effort) {
                let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1_000
                switch event {
                case .text(let delta):
                    output += delta
                    if firstText == nil, output.contains(where: { $0.isLetter || $0.isNumber }) { firstText = elapsed }
                    if firstSentence == nil, firstSentencePresent(output) { firstSentence = elapsed }
                case .completed: completed = true
                }
            }
        } catch {
            failure = error.localizedDescription
            if let liveError = error as? ChatGPTLiveError {
                switch liveError {
                case .http(let status, let code): errorStatus = status; errorCode = code
                case .failed(let code): errorCode = code
                default: break
                }
            }
        }
        return ChatGPTBenchmarkTrial(
            model: model, transport: client.transport, reasoningEffort: effort, condition: condition,
            inputCharacters: messages.reduce(0) { $0 + $1.modelContent.count },
            firstTextMs: firstText, firstSentenceMs: firstSentence,
            completionMs: (ProcessInfo.processInfo.systemUptime - start) * 1_000,
            completed: completed, output: output, error: failure, errorStatus: errorStatus, errorCode: errorCode)
    }

    public static func messages(condition: String) -> [ChatMessage] {
        LiveAnswerContext.messages(
            question: "Help me answer the customer's latest question.",
            transcript: condition.contains("long") ? longContext : recentContext,
            notes: "Next decision is Friday. No production rollout is approved.",
            preparation: preparation, history: [])
    }

    public static func report(_ trials: [ChatGPTBenchmarkTrial]) -> ChatGPTBenchmarkReport {
        let groups = Dictionary(grouping: trials, by: { $0.model + "|" + $0.transport.rawValue + "|" + $0.condition })
        let summaries = groups.keys.sorted().compactMap { key -> ChatGPTBenchmarkSummary? in
            guard let group = groups[key], let first = group.first else { return nil }
            let completed = group.filter(\.completed)
            return ChatGPTBenchmarkSummary(
                model: first.model, transport: first.transport, condition: first.condition,
                trials: group.count, failures: group.count - completed.count,
                medianFirstTextMs: percentile(completed.compactMap(\.firstTextMs), 0.5),
                p95FirstTextMs: percentile(completed.compactMap(\.firstTextMs), 0.95),
                medianFirstSentenceMs: percentile(completed.compactMap(\.firstSentenceMs), 0.5),
                p95FirstSentenceMs: percentile(completed.compactMap(\.firstSentenceMs), 0.95),
                medianCompletionMs: percentile(completed.map(\.completionMs), 0.5),
                p95CompletionMs: percentile(completed.map(\.completionMs), 0.95))
        }
        return ChatGPTBenchmarkReport(
            timestamp: Date(), operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            processorCount: ProcessInfo.processInfo.processorCount, hardware: hardwareName(),
            memoryGB: ProcessInfo.processInfo.physicalMemory / 1_073_741_824, trials: trials, summaries: summaries,
            notes: [
                "First sentence timing uses punctuation after 12 characters; inspect stored outputs for usefulness.",
                "First-process requests follow catalog retrieval and any rejected effort probes; they do not establish untouched network/server cold latency.",
                "Transport is explicit in each trial and summary. WebSocket reuses one socket after a completed response, with full bounded input on each turn.",
                "Provider timings exclude microphone, transcription, hotkey dispatch and UI rendering. Live Ask measures those separately.",
                "p95 uses nearest-rank sampling. Small trial counts are exploratory, not a service guarantee.",
            ])
    }

    private static func hardwareName() -> String {
        var count = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &count, nil, 0) == 0, count > 0 else { return "Unknown" }
        var bytes = [CChar](repeating: 0, count: count)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &count, nil, 0) == 0 else { return "Unknown" }
        return String(cString: bytes)
    }

    static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1))]
    }

    private static let preparation =
        "We are proposing a six-week pilot for a support team. Success means reducing median response time by 20% while maintaining quality. Integration is read-only. No production rollout is approved."

    private static let recentContext = """
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
            count: 600) + recentContext
}
