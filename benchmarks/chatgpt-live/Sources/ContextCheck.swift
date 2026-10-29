import Foundation
import MacParakeetCore

/// Synthetic qualification of the production periodic-memory + Ask path.
/// Time advances through fixture snapshots; this does not wait fifteen minutes.
enum ContextCheck {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    struct Coverage: Encodable {
        let mode: String
        let totalCharacters: Int
        let rawCharacters: Int
        let summarizedCharacters: Int
        let overlapCharacters: Int
        let coveredCharacters: Int
        let allSourceProcessed: Bool
        init(_ value: LiveMeetingMemoryCoverage) {
            mode = value.mode.rawValue; totalCharacters = value.totalCharacters; rawCharacters = value.rawCharacters
            summarizedCharacters = value.summarizedCharacters; overlapCharacters = value.overlapCharacters
            coveredCharacters = value.coveredCharacters; allSourceProcessed = value.allSourceProcessed
        }
    }
    struct StreamTrial: Encodable, Sendable {
        let firstTextMs: Double?
        let firstSentenceMs: Double?
        let completionMs: Double
        let completed: Bool
        let output: String
        let error: String?
    }
    struct UpdateStage: Encodable {
        let throughMinute: Int
        let transcriptCharacters: Int
        let durationMs: Double
        let summaryCalls: Int
        let coverage: Coverage?
        let error: String?
    }
    struct AskStage: Encodable {
        let question: String
        let preparationMs: Double
        let summaryCallsDuringPreparation: Int
        let coverage: Coverage
        let summary: String
        let exactExcerpts: String
        let recentCharacters: Int
        let requestCharacters: Int
        let answer: StreamTrial
        let checks: [String: Bool]
        var endToEndFirstTextMs: Double? { answer.firstTextMs.map { preparationMs + $0 } }
    }
    struct Report: Encodable {
        let timestamp: Date
        let transport: ChatGPTTransport
        let model: String
        let reasoningEffort: String?
        let fixtureMinutes: Int
        var periodicUpdates: [UpdateStage] = []
        var asks: [AskStage] = []
        var summaryCalls: [StreamTrial] = []
        var error: String?
        let notes = [
            "All source, summaries and answers are synthetic; no meeting database, audio or transcript is read.",
            "Periodic snapshots at 3/6/9/12 minutes are simulated sequentially with no wall-clock sleep; Ask uses the final 15-minute snapshot.",
            "Coverage means every source range is represented by processed summary or raw text, not that a lossy summary retains every fact.",
            "Grounding checks are lexical review aids. Inspect stored synthetic outputs; they are not a general accuracy score.",
            "Summary preparation and final answer timing are separate. These include provider/session checks, not capture, recognition or UI rendering.",
            "The pinned production session finishes normally only after a completed provider response; failed/partial streams are never retried here.",
        ]
    }
    private actor SummaryTrace {
        var trials: [StreamTrial] = []
        func append(_ trial: StreamTrial) { trials.append(trial) }
        var count: Int { trials.count }
    }

    static func run(client: ChatGPTLiveClient, requestedModel: String?, outputPath: String) async throws {
        try fixtureChecks()
        let selection = try await client.selection()
        if let requestedModel, requestedModel != selection.model {
            throw Failure(
                message: "Select the requested model and accepted effort first; contextcheck uses the saved selection.")
        }
        let session = try await client.liveAnswerSession()
        guard try await client.selection() == selection else { throw CancellationError() }
        try await session.validate()
        let memory = LiveMeetingMemory()
        let trace = SummaryTrace()
        let summarize: @Sendable ([ChatMessage]) async throws -> String = { messages in
            let trial = await collect(session: session, messages: messages)
            await trace.append(trial)
            guard trial.completed, !trial.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure(message: trial.error ?? "Synthetic meeting summary did not complete.")
            }
            return trial.output
        }
        var report = Report(
            timestamp: Date(), transport: client.transport, model: selection.model,
            reasoningEffort: selection.reasoningEffort, fixtureMinutes: 15)
        do {
            for minute in [3, 6, 9, 12] {
                try Task.checkCancellation()
                try await session.validate()
                let transcript = fixture(throughMinute: minute)
                let before = await trace.count
                let start = ProcessInfo.processInfo.systemUptime
                do {
                    let coverage = try await memory.update(
                        transcript: transcript, cacheKey: session.cacheKey, summarize: summarize)
                    try await session.validate()
                    let calls = await trace.count - before
                    report.periodicUpdates.append(
                        .init(
                            throughMinute: minute, transcriptCharacters: transcript.count, durationMs: elapsed(start),
                            summaryCalls: calls, coverage: Coverage(coverage), error: nil))
                    print(
                        "Memory through minute \(minute): \(Int(elapsed(start)))ms; \(calls) summary calls; source covered \(coverage.coveredCharacters)/\(coverage.totalCharacters)."
                    )
                } catch {
                    let calls = await trace.count - before
                    report.periodicUpdates.append(
                        .init(
                            throughMinute: minute, transcriptCharacters: transcript.count, durationMs: elapsed(start),
                            summaryCalls: calls, coverage: nil, error: error.localizedDescription))
                    throw error
                }
                report.summaryCalls = await trace.trials
                try save(report, to: outputPath)
            }
            let transcript = fixture(throughMinute: 15)
            var history: [ChatMessage] = []
            for (index, question) in questions.enumerated() {
                let before = await trace.count
                let start = ProcessInfo.processInfo.systemUptime
                let snapshot = try await memory.prepare(
                    transcript: transcript, question: question, cacheKey: session.cacheKey, summarize: summarize)
                try await session.validate()
                let preparationMs = elapsed(start)
                let calls = await trace.count - before
                let messages = LiveAnswerContext.messages(
                    question: question, context: snapshot,
                    notes: "Only explicit approvals count. No production launch has been approved.",
                    preparation: "Synthetic six-week support pilot; preserve corrections and approval conditions.",
                    history: history)
                let answer = await collect(session: session, messages: messages)
                let evidence =
                    snapshot.earlierSummary + "\n" + snapshot.questionExcerpts + "\n" + snapshot.recentTranscript
                let checks = [
                    "all_source_ranges_covered": snapshot.coverage.allSourceProcessed,
                    "cached_prepare_made_no_summary_call": calls == 0,
                    "summary_retains_early_unrelated_route": containsRoute(snapshot.earlierSummary),
                    "summary_retains_corrected_cap": containsCorrectedCap(snapshot.earlierSummary),
                    "combined_context_retains_early_unrelated_route": containsRoute(evidence),
                    "combined_context_retains_corrected_cap": containsCorrectedCap(evidence),
                    "raw_tail_contains_latest_customer_question": snapshot.recentTranscript.contains(latestQuestion),
                    "answer_mentions_corrected_cap": containsCorrectedCap(answer.output),
                    "answer_mentions_route_owner_when_asked": index == 0 || containsRoute(answer.output),
                    "answer_preserves_launch_uncertainty_when_asked": index != 0 || preservesApproval(answer.output),
                ]
                report.asks.append(
                    .init(
                        question: question, preparationMs: preparationMs, summaryCallsDuringPreparation: calls,
                        coverage: Coverage(snapshot.coverage), summary: snapshot.earlierSummary,
                        exactExcerpts: snapshot.questionExcerpts, recentCharacters: snapshot.recentTranscript.count,
                        requestCharacters: messages.reduce(0) { $0 + $1.modelContent.count }, answer: answer,
                        checks: checks))
                report.summaryCalls = await trace.trials
                try save(report, to: outputPath)
                print(
                    "Ask \(index + 1): prepare \(Int(preparationMs))ms; cache summary calls \(calls); text \(answer.firstTextMs.map { String(Int($0)) } ?? "—")ms; sentence \(answer.firstSentenceMs.map { String(Int($0)) } ?? "—")ms; \(answer.completed ? "completed" : "FAILED")."
                )
                guard snapshot.coverage.allSourceProcessed, answer.completed,
                    !answer.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    throw Failure(message: answer.error ?? "Synthetic context/answer qualification did not complete.")
                }
                guard calls == 0 else {
                    throw Failure(message: "Unchanged synthetic Ask unexpectedly rebuilt its cached summary.")
                }
                history += [
                    ChatMessage(role: .user, content: question), ChatMessage(role: .assistant, content: answer.output),
                ]
            }
            print("Context qualification report: \(outputPath)")
        } catch {
            report.error = error.localizedDescription
            report.summaryCalls = await trace.trials
            try save(report, to: outputPath)
            throw error
        }
    }

    private static func collect(session: LiveAnswerStreamSession, messages: [ChatMessage]) async -> StreamTrial {
        let start = ProcessInfo.processInfo.systemUptime
        var output = ""
        var firstText: Double?
        var firstSentence: Double?
        var completed = false
        var failure: String?
        do {
            try await session.validate()
            for try await text in session.stream(messages: messages) {
                try Task.checkCancellation()
                output += text
                guard output.utf8.count <= 1_048_576 else {
                    throw Failure(message: "Synthetic response exceeded its report limit.")
                }
                let duration = elapsed(start)
                if firstText == nil, LiveAnswerTiming.containsMeaningfulText(output) { firstText = duration }
                if firstSentence == nil, LiveAnswerTiming.containsSentence(output) { firstSentence = duration }
            }
            try Task.checkCancellation()
            try await session.validate()
            guard LiveAnswerTiming.containsMeaningfulText(output) else {
                throw Failure(message: "Completed stream had no meaningful text.")
            }
            completed = true
        } catch { failure = error.localizedDescription }
        return .init(
            firstTextMs: firstText, firstSentenceMs: firstSentence, completionMs: elapsed(start),
            completed: completed, output: output, error: failure)
    }

    private static func save(_ report: Report, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    private static func elapsed(_ start: TimeInterval) -> Double {
        (ProcessInfo.processInfo.systemUptime - start) * 1_000
    }
    private static func containsRoute(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("amber-17") && lower.contains("hana")
    }
    private static func containsCorrectedCap(_ text: String) -> Bool {
        let lower = text.lowercased().replacingOccurrences(of: ",", with: "")
        return lower.contains("38000") || lower.contains("38k")
    }
    private static func preservesApproval(_ text: String) -> Bool {
        let lower = text.lowercased()
        return [
            "not approved", "no approval", "unapproved", "not authorized", "cannot promise", "can't promise",
            "pending", "subject to", "security approval", "require approval", "would need",
        ].contains(where: lower.contains)
    }

    private static let latestQuestion =
        "Customer: What is the corrected cap, and can we promise a production launch on Friday?"
    private static let questions = [
        "Help me answer the customer's latest question about the corrected cap and Friday production launch.",
        "Who owns emergency route AMBER-17, and what was the corrected pilot budget ceiling?",
    ]
    private static func fixture(throughMinute count: Int) -> String {
        var text = ""
        for minute in 0..<count {
            let prefix = String(format: "%02d", minute)
            text += "[\(prefix):00] Facilitator: We are reviewing a proposed six-week support pilot.\n"
            if minute == 0 {
                text +=
                    "[00:10] Hana: Emergency escalation route AMBER-17 belongs to Hana Lin; it is unrelated to the pilot budget.\n"
            }
            if minute == 1 { text += "[01:15] Maya: The proposed cap is $45,000; it is not final.\n" }
            if minute == 4 {
                text +=
                    "[04:20] Maya: Correction: the pilot budget ceiling is $38,000, replacing $45,000. Use the corrected figure.\n"
            }
            if minute == 7 {
                text +=
                    "[07:40] Liam: Security review must be approved before the test account connects. No production launch is approved.\n"
            }
            for turn in 0..<12 {
                text +=
                    "[\(prefix):\(String(format: "%02d", turn + 20))] Team: We compared intake routing and report layouts. This discussion adds no decision or commitment.\n"
            }
            if minute == 14 { text += "[14:55] \(latestQuestion)\n" }
        }
        return text
    }
    private static func fixtureChecks() throws {
        let earlier = fixture(throughMinute: 12)
        let full = fixture(throughMinute: 15)
        guard full.hasPrefix(earlier), full.count > 16_000,
            full.count - earlier.count <= 12_000,
            !String(full.suffix(12_000)).contains("AMBER-17"),
            full.contains("$45,000"), full.contains("$38,000"), full.contains(latestQuestion)
        else {
            throw Failure(message: "Synthetic fixture does not exercise cached older memory plus the latest raw tail.")
        }
    }
}
