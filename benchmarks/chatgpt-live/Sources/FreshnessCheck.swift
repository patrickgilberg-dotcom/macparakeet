import Foundation
import MacParakeetCore
import MacParakeetViewModels

/// Quiet functional qualification of the production Ask/Update action. All
/// source words and checkpoints are generated; no meeting library is opened.
@MainActor
enum FreshnessCheck {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private struct Call: Encodable, Sendable {
        let kind: String
        let inputCharacters: Int
        var output = ""
        var completed = false
        var error: String?
    }
    private struct Stage: Encodable, Sendable {
        let label: String
        let anchor: String?
        let nowStartMs: Int?
        let nowEndMs: Int?
        let nowSource: String?
        let focusSummary: String?
        let generalSummary: String?
        let answer: String
        let summaryCallsDuringAsk: Int
        let firstTextMs: Double?
        let firstSentenceMs: Double?
        let completionMs: Double?
        let checks: [String: Bool]
    }
    private struct Report: Encodable, Sendable {
        let timestamp: Date
        let model: String
        let transport: ChatGPTTransport
        var stages: [Stage] = []
        var calls: [Call] = []
        var movedOnBeforeUpdate = false
        var inferenceCallsBeforeNotification = 0
        var inferenceCallsAfterNotification = 0
        var error: String?
        let notes = [
            "All meeting source, summaries, answers and checkpoints are synthetic. No user meeting database, audio, skill, preparation or writing examples are read.",
            "The ViewModel and Update action are production code. Source time advances through numeric word fixtures without microphone capture or wall-clock meeting waits.",
            "A question lasting more than thirty seconds exercises complete-question retention. A later distinct question exercises the conversation-moved-on state and explicit Update.",
            "Foreground answers reuse prepared general/three-minute summaries; raw Now context adds no summarization request.",
            "All normal streams validate their pinned production session before and after terminal completion. Failed or partial inference is never automatically replayed.",
            "These are functional DEBUG-helper observations, not native UI/capture latency measurements or percentile guarantees. Inspect synthetic outputs for semantic quality.",
        ]
    }

    private actor Trace {
        private var entries: [Call] = []
        var calls: [Call] { entries }
        var summaries: Int { entries.filter { $0.kind == "summary" }.count }
        var answers: Int { entries.filter { $0.kind == "answer" }.count }

        private func begin(_ messages: [ChatMessage]) -> Int {
            let kind = messages.last?.content.contains("<now_focus") == true ? "answer" : "summary"
            entries.append(Call(kind: kind, inputCharacters: messages.reduce(0) { $0 + $1.modelContent.count }))
            return entries.count - 1
        }
        private func end(_ index: Int, output: String, completed: Bool, error: String?) {
            entries[index].output = output; entries[index].completed = completed; entries[index].error = error
        }
        nonisolated func stream(
            session: LiveAnswerStreamSession, messages: [ChatMessage]
        ) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    let index = await begin(messages)
                    var output = ""
                    do {
                        try await session.validate()
                        for try await delta in session.stream(messages: messages) {
                            try Task.checkCancellation()
                            output += delta
                            continuation.yield(delta)
                        }
                        try Task.checkCancellation()
                        try await session.validate()
                        await end(index, output: output, completed: true, error: nil)
                        continuation.finish()
                    } catch {
                        await end(index, output: output, completed: false, error: error.localizedDescription)
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    private final class Projection {
        var words: [WordTimestamp] = []
        var elapsedMs = 900_000
        let speakers = [
            SpeakerInfo(id: "team", label: "Team"), SpeakerInfo(id: "customer", label: "Customer"),
            SpeakerInfo(id: "hana", label: "Hana"), SpeakerInfo(id: "maya", label: "Maya"),
            SpeakerInfo(id: "liam", label: "Liam"),
        ]
        static let longQuestion =
            "Given that the pilot still needs security approval and we have discussed several launch conditions across this meeting, what is the corrected budget ceiling, and can we promise a production launch on Friday?"
        static let updatedQuestion =
            "Who owns emergency route AMBER-17, and what is our corrected pilot ceiling?"

        init() {
            line("Emergency escalation route AMBER-17 belongs to Hana Lin.", at: 10_000, speaker: "hana")
            line("The proposed cap is $45,000 and it is not final.", at: 75_000, speaker: "maya")
            line(
                "Correction: the pilot budget ceiling is $38,000, replacing $45,000. Use the corrected figure.",
                at: 260_000, speaker: "maya")
            line(
                "Security review must be approved before the test account connects. No production launch is approved.",
                at: 460_000, speaker: "liam")
            for minute in 0..<15 {
                for turn in 0..<(minute == 14 ? 4 : 12) {
                    line(
                        "We compared intake routing and report layouts for the proposed six-week support pilot. This discussion adds no decision or commitment.",
                        at: minute * 60_000 + (minute == 14 ? turn * 4_000 : 20_000 + turn * 1_000), speaker: "team")
                }
            }
            question(Self.longQuestion, at: 860_000, spacing: 1_000)
            words.sort { $0.startMs < $1.startMs }
        }
        private func line(_ text: String, at time: Int, speaker: String) {
            words.append(.init(word: text, startMs: time, endMs: time, confidence: 1, speakerId: speaker))
        }
        private func question(_ text: String, at time: Int, spacing: Int) {
            words += text.split(separator: " ").enumerated().map { index, word in
                .init(
                    word: String(word), startMs: time + index * spacing,
                    endMs: time + index * spacing + min(250, spacing), confidence: 1, speakerId: "customer")
            }
        }
        func moveOn() {
            question(Self.updatedQuestion, at: 910_000, spacing: 300)
            elapsedMs = (words.last?.endMs ?? 910_000) + 500
        }
        var transcript: String {
            let labels = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.label) })
            return TranscriptParagraphBuilder.build(from: words).map { paragraph -> String in
                let seconds = paragraph.startMs / 1_000
                return
                    "[\(seconds / 60):\(String(format: "%02d", seconds % 60))] \(labels[paragraph.speakerId ?? ""] ?? "Speaker"): \(paragraph.text)"
            }.joined(separator: "\n")
        }
        var focus: LiveMeetingFocusSource {
            LiveMeetingFocusTranscript.project(
                words: words, speakers: speakers, elapsedMs: elapsedMs, includeTimestamps: true)
        }
        var now: LiveMeetingNowSnapshot {
            LiveMeetingNowTranscript.project(
                words: words, speakers: speakers, elapsedMs: elapsedMs, includeTimestamps: true)
        }
    }

    static func run(client: ChatGPTLiveClient, requestedModel: String?, outputPath: String) async throws {
        let selection = try await client.selection()
        if let requestedModel, requestedModel != selection.model {
            throw Failure(message: "Select the requested model first; freshnesscheck uses the saved selection.")
        }
        let projection = Projection()
        let trace = Trace()
        let vm = TranscriptChatViewModel()
        vm.configure(llmService: nil, transcriptText: projection.transcript)
        vm.configureDirectLiveAnswers(
            prepareTranscript: {},
            sessionProvider: {
                let pinned = try await client.liveAnswerSession()
                return LiveAnswerStreamSession(
                    cacheKey: pinned.cacheKey, modelName: pinned.modelName,
                    validate: { try await pinned.validate() },
                    stream: { messages in trace.stream(session: pinned, messages: messages) })
            }, focusSourceProvider: { projection.focus }, nowSourceProvider: { projection.now },
            summaryRefreshInterval: .milliseconds(50))
        defer { vm.stopLiveMeetingMemory(); vm.cancelStreaming() }
        var report = Report(timestamp: Date(), model: selection.model, transport: client.transport)
        do {
            try await wait("initial general and recent summaries") {
                vm.liveMeetingMemoryLastUpdated != nil || vm.liveMeetingMemoryBackgroundError != nil
            }
            vm.stopLiveMeetingMemory()
            if let error = vm.liveMeetingMemoryBackgroundError { throw Failure(message: error) }
            let before = await trace.summaries
            vm.helpMeAnswer()
            try await wait("first foreground answer") { !vm.isStreaming }
            guard vm.liveAnswerTiming?.outcome == "completed" else {
                throw Failure(message: vm.errorMessage ?? "Initial synthetic answer did not complete.")
            }
            report.stages.append(stage(vm, label: "initial", summaryCalls: await trace.summaries - before))
            report.calls = await trace.calls
            try await save(report, to: outputPath)

            report.inferenceCallsBeforeNotification = await trace.answers
            projection.moveOn()
            vm.updateTranscriptText(projection.transcript)
            vm.refreshLiveAnswerFreshness()
            report.movedOnBeforeUpdate = vm.liveAnswerConversationMovedOn
            report.inferenceCallsAfterNotification = await trace.answers
            guard vm.liveAnswerConversationMovedOn, vm.canUpdateLiveAnswer else {
                throw Failure(message: "A distinct complete question did not make Update answer available.")
            }
            let priorAnswer = vm.messages.last?.content
            let summariesBeforeUpdate = await trace.summaries
            vm.updateLiveAnswer()
            try await wait("updated foreground answer") { !vm.isStreaming }
            guard vm.liveAnswerTiming?.outcome == "completed" else {
                throw Failure(message: vm.errorMessage ?? "Updated synthetic answer did not complete.")
            }
            var updated = stage(vm, label: "updated", summaryCalls: await trace.summaries - summariesBeforeUpdate)
            var checks = updated.checks
            checks["prior_completed_answer_retained"] = vm.messages.contains {
                $0.role == .assistant && $0.content == priorAnswer
            }
            checks["explicit_update_has_own_visible_user_turn"] = vm.messages.filter { $0.role == .user }.count == 2
            checks["new_now_anchor_contains_latest_complete_question"] =
                vm.liveAnswerQuestionAnchor?.contains("AMBER-17") == true
            checks["new_question_notification_did_not_infer"] =
                report.inferenceCallsBeforeNotification == report.inferenceCallsAfterNotification
            checks["conversation_moved_on_flag_cleared_for_current_snapshot"] = !vm.liveAnswerConversationMovedOn
            checks["updated_answer_mentions_route_and_owner"] =
                updated.answer.lowercased().contains("amber-17") && updated.answer.lowercased().contains("hana")
            checks["updated_answer_preserves_corrected_budget"] = correctedCap(updated.answer)
            updated = Stage(
                label: updated.label, anchor: updated.anchor, nowStartMs: updated.nowStartMs,
                nowEndMs: updated.nowEndMs,
                nowSource: updated.nowSource, focusSummary: updated.focusSummary,
                generalSummary: updated.generalSummary,
                answer: updated.answer, summaryCallsDuringAsk: updated.summaryCallsDuringAsk,
                firstTextMs: updated.firstTextMs, firstSentenceMs: updated.firstSentenceMs,
                completionMs: updated.completionMs, checks: checks)
            report.stages.append(updated)
            report.calls = await trace.calls
            try await save(report, to: outputPath)
            guard report.stages.allSatisfy({ $0.summaryCallsDuringAsk == 0 }),
                report.movedOnBeforeUpdate, report.calls.filter({ $0.kind == "answer" }).count == 2,
                report.calls.allSatisfy(\.completed)
            else {
                throw Failure(
                    message: "Synthetic refresh qualification failed structural completion or call-count checks.")
            }
            print(
                "Freshness qualification completed: \(report.calls.count) terminal requests; two explicit answers; zero foreground summary calls."
            )
            print("Synthetic report: \(outputPath)")
        } catch {
            report.error = error.localizedDescription
            report.calls = await trace.calls
            try await save(report, to: outputPath)
            throw error
        }
    }

    private static func stage(_ vm: TranscriptChatViewModel, label: String, summaryCalls: Int) -> Stage {
        let snapshot = vm.lastLiveMeetingMemory
        let answer = vm.messages.last?.content ?? ""
        var checks = [
            "answer_completed": vm.liveAnswerTiming?.outcome == "completed",
            "all_source_processed": snapshot?.coverage.allSourceProcessed == true,
            "now_source_present": snapshot?.nowContext != nil,
            "three_minute_summary_present": snapshot?.focusSummary?.text.isEmpty == false,
            "general_summary_present": snapshot?.earlierSummary.isEmpty == false,
            "no_foreground_summary_call": summaryCalls == 0,
        ]
        if label == "initial" {
            checks["long_question_retained_from_before_thirty_second_boundary"] =
                snapshot?.nowContext?.anchor?.text.contains("Given that the pilot") == true
                && snapshot?.nowContext?.anchor?.text.contains("Friday?") == true
            checks["answer_preserves_corrected_budget"] = correctedCap(answer)
            let normalized = answer.lowercased().replacingOccurrences(of: "’", with: "'")
            checks["answer_denies_unapproved_launch"] =
                normalized.contains("not approved") || normalized.contains("no production launch")
                || normalized.contains("can't promise") || normalized.contains("cannot promise")
                || normalized.contains("not been approved")
        }
        return Stage(
            label: label, anchor: vm.liveAnswerQuestionAnchor, nowStartMs: snapshot?.nowContext?.source.startMs,
            nowEndMs: snapshot?.nowContext?.source.endMs, nowSource: snapshot?.nowContext?.source.transcript,
            focusSummary: snapshot?.focusSummary?.text, generalSummary: snapshot?.earlierSummary,
            answer: answer, summaryCallsDuringAsk: summaryCalls, firstTextMs: vm.liveAnswerTiming?.firstTextMs,
            firstSentenceMs: vm.liveAnswerTiming?.firstSentenceMs, completionMs: vm.liveAnswerTiming?.completionMs,
            checks: checks)
    }
    private static func correctedCap(_ text: String) -> Bool {
        let normalized = text.replacingOccurrences(of: ",", with: "")
        return normalized.contains("38000") || normalized.contains("38,000")
    }
    private static func wait(_ label: String, condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        guard await condition() else { throw Failure(message: "Timed out waiting for \(label).") }
    }
    private static func save(_ report: Report, to path: String) async throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try await Task.detached {
            let url = URL(fileURLWithPath: path)
            guard path.hasPrefix("/") else { throw Failure(message: "Report path must be absolute.") }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }.value
    }
}
