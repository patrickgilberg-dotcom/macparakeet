import Foundation
import MacParakeetCore
import MacParakeetViewModels

/// Quiet production-flow qualification using a fresh in-memory repository and
/// wholly synthetic meeting text. It never reads the user's meeting library.
@MainActor
enum BoardPreparationCheck {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Call: Encodable, Sendable {
        let phase: String
        let kind: String
        let input: [ChatMessage]
        var output = ""
        var completed = false
        var error: String?
    }

    private struct Answer: Encodable, Sendable {
        let label: String
        let text: String
        let questionAnchor: String?
        let firstTextMs: Double?
        let completionMs: Double?
        let extractionCallsDuringAsk: Int
        let summaryCallsDuringAsk: Int
        let checks: [String: Bool]
    }

    private struct Report: Encodable, Sendable {
        let timestamp: Date
        let model: String
        let transport: ChatGPTTransport
        var preparationBoard: MeetingBoardSnapshot?
        var liveBoard: MeetingBoardSnapshot?
        var answers: [Answer] = []
        var checks: [String: Bool] = [:]
        var calls: [Call] = []
        var error: String?
        let notes = [
            "All calendar events, repository rows, project names, notes, transcripts, quotations and questions are synthetic.",
            "No real calendar fetch, user database, microphone, audio file, skill, writing example or saved user preparation is read.",
            "Automatic preparation uses the production 15-minute policy and production extraction engine. Its generated artifact uses a temporary private store.",
            "Live board, Ask and explicit Update use production ViewModels and a normal pinned ChatGPT-plan session. Numeric source time advances without a wall-clock meeting wait.",
            "Streams are marked completed only after their production stream terminates successfully and the pinned session validates. No failed request is automatically replayed.",
            "This quiet functional check does not measure native capture latency or establish percentile performance. Inspect answer text for semantic quality.",
        ]
    }

    private actor Trace {
        private var phase = "initialization"
        private var entries: [Call] = []
        var calls: [Call] { entries }
        var extractionCalls: Int { entries.filter { $0.kind.hasPrefix("board_") }.count }
        var summaryCalls: Int { entries.filter { $0.kind == "summary" }.count }
        var answerCalls: Int { entries.filter { $0.kind == "answer" }.count }

        func setPhase(_ value: String) { phase = value }

        private func begin(_ messages: [ChatMessage]) -> Int {
            let content = messages.last?.content ?? ""
            let object = (try? JSONSerialization.jsonObject(with: Data(content.utf8))) as? [String: Any]
            let kind: String
            if content.contains("<now_focus") {
                kind = "answer"
            } else if object?["stage"] as? String == "reconcile" {
                kind = "board_reconcile"
            } else if object?["documentID"] != nil {
                kind = "board_extract"
            } else {
                kind = "summary"
            }
            entries.append(Call(phase: phase, kind: kind, input: messages))
            return entries.count - 1
        }

        private func finish(_ index: Int, output: String, completed: Bool, error: String?) {
            entries[index].output = output; entries[index].completed = completed; entries[index].error = error
        }

        nonisolated func session(_ pinned: LiveAnswerStreamSession) -> LiveAnswerStreamSession {
            LiveAnswerStreamSession(
                cacheKey: pinned.cacheKey, modelName: pinned.modelName, validate: { try await pinned.validate() },
                stream: { messages in
                    AsyncThrowingStream { continuation in
                        let work = Task {
                            let index = await self.begin(messages)
                            var output = ""
                            do {
                                try await pinned.validate()
                                for try await text in pinned.stream(messages: messages) {
                                    try Task.checkCancellation()
                                    output += text; continuation.yield(text)
                                }
                                try Task.checkCancellation()
                                try await pinned.validate()
                                await self.finish(index, output: output, completed: true, error: nil)
                                continuation.finish()
                            } catch {
                                await self.finish(
                                    index, output: output, completed: false, error: error.localizedDescription)
                                continuation.finish(throwing: error)
                            }
                        }
                        continuation.onTermination = { _ in work.cancel() }
                    }
                })
        }
    }

    private final class Projection {
        let speakers = [SpeakerInfo(id: "team", label: "Team"), SpeakerInfo(id: "customer", label: "Customer")]
        var words: [WordTimestamp] = []
        var elapsedMs = 900_000
        static let question =
            "What should I ask Maya about NORTHSTAR-42 and my retention reminder, and which pilot budget cap should I use now?"
        static let updatedQuestion =
            "Has Maya's NORTHSTAR-42 report been completed, and what is our corrected pilot cap now?"

        init() {
            line("The previous meeting set a pilot cap of $38,000, but we need to revisit that figure.", at: 15_000)
            line(
                "Production rollout still requires security approval. This call has not approved production.",
                at: 70_000)
            line(
                "We are checking prior commitments and the user's personal reminders without assuming they are complete.",
                at: 400_000)
            line(
                "Correction: the current pilot cap is $32,000, replacing $38,000. Production remains unapproved.",
                at: 870_000)
            question(Self.question, at: 882_000)
        }

        private func line(_ text: String, at time: Int) {
            words.append(.init(word: text, startMs: time, endMs: time + 500, confidence: 1, speakerId: "team"))
        }
        private func question(_ text: String, at time: Int) {
            words += text.split(separator: " ").enumerated().map { index, word in
                .init(
                    word: String(word), startMs: time + index * 350, endMs: time + index * 350 + 250,
                    confidence: 1, speakerId: "customer")
            }
        }
        func moveOn() {
            line(
                "Correction: the pilot cap is now $29,000, replacing $32,000. Maya's report completion has not been verified.",
                at: 910_000)
            question(Self.updatedQuestion, at: 915_000)
            elapsedMs = (words.last?.endMs ?? 920_000) + 500
        }
        var transcript: String {
            let labels = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.label) })
            return TranscriptParagraphBuilder.build(from: words).map {
                let seconds = $0.startMs / 1_000
                return
                    "[\(seconds / 60):\(String(format: "%02d", seconds % 60))] \(labels[$0.speakerId ?? ""] ?? "Speaker"): \($0.text)"
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

    static func run(client: ChatGPTLiveClient, outputPath: String) async throws {
        let selection = try await client.selection()
        let trace = Trace()
        let now = Date()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "board-prep-check-" + UUID().uuidString)
        let suiteName = "MacParakeet.BoardPreparationCheck." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw Failure(message: "Temporary preferences are unavailable.")
        }
        defaults.set(true, forKey: LiveMeetingPrepViewModel.enabledPreferenceKey)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: temporary)
        }
        let database = try DatabaseManager()
        let projects = MeetingProjectRepository(dbQueue: database.dbQueue)
        let preparations = MeetingPreparationRepository(dbQueue: database.dbQueue)
        let transcriptions = TranscriptionRepository(dbQueue: database.dbQueue)
        let project = MeetingProject(name: "Synthetic Northstar")
        try projects.save(project)
        let older = Transcription(
            createdAt: now.addingTimeInterval(-172_800), fileName: "Older synthetic decoy",
            rawTranscript: "OLDER-DECOY-DO-NOT-SEND says the pilot cap is $99,000.", status: .completed,
            sourceType: .meeting)
        let notes =
            String(
                repeating:
                    "Personal scratchpad: earlier diagrams were descriptive background; no new commitment here.\n",
                count: 150)
            + "My reminder: ask for retention evidence packet NOTE-TAIL-73 before accepting pilot sign-off."
        let prior = Transcription(
            createdAt: now.addingTimeInterval(-86_400), fileName: "Latest Northstar synthetic meeting",
            rawTranscript:
                "[0:10] Maya: I will send the NORTHSTAR-42 accessibility report by Friday.\n[0:25] Team: We agreed the pilot cap is $38,000. No production rollout is approved.\n[0:40] Ravi: Who will collect the retention evidence packet?",
            status: .completed, sourceType: .meeting, userNotes: notes)
        try transcriptions.save(older); try transcriptions.save(prior)
        try projects.assign(transcriptionIDs: [older.id, prior.id], to: project.id)
        let event = CalendarEvent(
            id: "google/synthetic-shared/synthetic-occurrence", title: "  Northstar — exact calendar title 🦜  ",
            startTime: now.addingTimeInterval(900), endTime: now.addingTimeInterval(2700),
            calendarIdentifier: "synthetic-shared", provider: .google, providerEventID: "synthetic-occurrence",
            isUserMeeting: false)
        let key = MeetingPreparationKey(calendarID: "synthetic-shared", eventID: "synthetic-occurrence")
        let authored = "Review NORTHSTAR-42 follow-ups and my retention reminder."
        try preparations.save(
            .init(
                key: key, context: authored, projectID: project.id, titleSnapshot: event.title,
                scheduledStartAt: event.startTime, scheduledEndAt: event.endTime))
        let store = MeetingGeneratedPreparationStore(directoryURL: temporary)
        let prep = LiveMeetingPrepViewModel(
            projectRepository: projects, preparationRepository: preparations,
            sessionProvider: { trace.session(try await client.liveAnswerSession()) }, store: store, defaults: defaults)
        let projection = Projection()
        let vm = TranscriptChatViewModel()
        defer { prep.stop(); vm.stopLiveMeetingMemory(); vm.cancelStreaming() }
        var report = Report(timestamp: now, model: selection.model, transport: client.transport)
        do {
            await trace.setPhase("automatic_15_minute_preparation")
            await prep.poll(events: [event], now: now)
            guard let generated = prep.preparation(for: event) else {
                throw Failure(message: prep.errorMessage ?? "Automatic 15-minute preparation did not produce a result.")
            }
            report.preparationBoard = generated.board
            let allItems = generated.board.items + generated.board.resolvedItems
            report.checks["exact_google_occurrence_title"] = generated.eventTitle == event.title
            report.checks["manual_preparation_unchanged"] = try preparations.fetch(key: key)?.context == authored
            report.checks["only_latest_project_source"] = generated.board.documents.allSatisfy {
                $0.id.hasPrefix(prior.id.uuidString)
            }
            report.checks["complete_prior_notes_preserved"] = generated.board.documents.contains {
                $0.kind == .previousNotes && $0.text == notes
            }
            report.checks["note_suffix_has_exact_evidence"] = allItems.contains {
                $0.evidence.contains { $0.quote.contains("NOTE-TAIL-73") }
            }
            report.checks["quotes_resolve_exactly"] =
                !allItems.isEmpty
                && allItems.allSatisfy { $0.evidence.allSatisfy { generated.board.resolvedQuote($0) != nil } }
            report.checks["notes_are_not_spoken_commitments"] = allItems.filter { item in
                item.evidence.contains { generated.board.document(for: $0)?.kind.isNotes == true }
            }.allSatisfy { $0.commitment == .noted }
            report.checks["supported_owner_and_relative_deadline_populated"] = allItems.contains {
                $0.kind == .action && $0.owner == "Maya" && $0.deadline?.contains("Friday") == true
            }
            let ready = await prep.validatedPreparation(key: key, projectID: project.id, before: event.startTime)
            guard let ready else {
                throw Failure(message: "Generated preparation failed source/account cache validation.")
            }
            report.checks["generated_cache_validated_without_new_generation"] = ready == generated

            vm.configure(llmService: nil, transcriptText: projection.transcript)
            vm.configureDirectLiveAnswers(
                prepareTranscript: {}, sessionProvider: { trace.session(try await client.liveAnswerSession()) },
                focusSourceProvider: { projection.focus }, nowSourceProvider: { projection.now },
                summaryRefreshInterval: .seconds(3600))
            vm.bindUserNotesProvider { "My current note: confirm security approval before promising production." }
            await trace.setPhase("project_memory_prefetch")
            vm.configureLiveProjectContext(eventPreparation: authored) {
                try await Task.detached {
                    guard let currentProject = try projects.fetch(id: project.id) else {
                        return nil as LiveProjectMeetingSource?
                    }
                    let previous = try projects.latestPreviousMeeting(projectID: project.id, before: event.startTime)
                    return LiveProjectMeetingSource(project: currentProject, previous: previous)
                }.value
            }
            try await wait("project prefetch") {
                vm.liveProjectContextStatus == "Project context checked."
                    || vm.liveProjectContextStatus == "Previous meeting context will retry when you ask."
            }
            guard vm.liveProjectContextStatus == "Project context checked." else {
                throw Failure(message: "Project prefetch failed.")
            }
            vm.configureLiveMeetingBoard(recordingID: UUID(), title: event.title, preparation: ready)
            await trace.setPhase("background_live_board_and_summaries")
            vm.refreshLiveBoard()
            try await wait("live board and summaries") { !vm.isRefreshingLiveBoard }
            guard let liveBoard = vm.liveBoard else {
                throw Failure(message: vm.liveBoardError ?? "Live board did not publish.")
            }
            report.liveBoard = liveBoard
            report.checks["live_board_combines_current_and_latest_prior_sources"] =
                liveBoard.documents.contains { $0.kind == .currentTranscript }
                && liveBoard.documents.contains { $0.kind == .currentNotes }
                && liveBoard.documents.contains { $0.kind == .previousTranscript }
                && liveBoard.documents.contains { $0.kind == .previousNotes }
            vm.stopLiveMeetingMemory()
            let extractionBefore = await trace.extractionCalls
            let summariesBefore = await trace.summaryCalls
            await trace.setPhase("explicit_live_ask")
            vm.helpMeAnswer()
            try await wait("live answer") { !vm.isStreaming }
            guard vm.liveAnswerTiming?.outcome == "completed" else {
                throw Failure(message: vm.errorMessage ?? "Live answer failed.")
            }
            report.answers.append(
                observe(
                    vm, label: "initial", cap: "32000", extractionCalls: await trace.extractionCalls - extractionBefore,
                    summaryCalls: await trace.summaryCalls - summariesBefore))
            let initialAnswer = vm.messages.last?.content
            let answerCount = await trace.answerCalls
            projection.moveOn(); vm.updateTranscriptText(projection.transcript); vm.refreshLiveAnswerFreshness()
            report.checks["fresh_question_makes_update_available"] = vm.canUpdateLiveAnswer
            report.checks["fresh_words_do_not_generate_answer"] = await trace.answerCalls == answerCount
            let updateExtractions = await trace.extractionCalls
            let updateSummaries = await trace.summaryCalls
            await trace.setPhase("explicit_update")
            vm.updateLiveAnswer()
            try await wait("updated live answer") { !vm.isStreaming }
            guard vm.liveAnswerTiming?.outcome == "completed" else {
                throw Failure(message: vm.errorMessage ?? "Updated answer failed.")
            }
            report.answers.append(
                observe(
                    vm, label: "updated", cap: "29000",
                    extractionCalls: await trace.extractionCalls - updateExtractions,
                    summaryCalls: await trace.summaryCalls - updateSummaries))
            report.checks["prior_answer_retained"] = vm.messages.contains {
                $0.role == .assistant && $0.content == initialAnswer
            }
            report.calls = await trace.calls
            report.checks["older_decoy_never_sent"] = !report.calls.contains {
                $0.input.contains { $0.content.contains("OLDER-DECOY-DO-NOT-SEND") }
            }
            let answerInputs = report.calls.filter { $0.kind == "answer" }
            report.checks["prepared_brief_in_both_answer_requests"] =
                answerInputs.count == 2
                && answerInputs.allSatisfy {
                    $0.input.contains {
                        $0.content.contains("<prepared_project_brief>{") && $0.content.contains("NOTE-TAIL-73")
                    }
                }
            report.checks["all_requests_terminally_completed"] = report.calls.allSatisfy(\.completed)
            try await save(report, path: outputPath)
            guard report.checks.values.allSatisfy({ $0 }),
                report.answers.allSatisfy({ $0.checks.values.allSatisfy { $0 } })
            else {
                throw Failure(
                    message:
                        "Board/preparation qualification failed a structural or evidence check; inspect the synthetic report."
                )
            }
            print(
                "Board/preparation qualification completed: \(report.calls.count) terminal requests; two explicit answers; zero foreground extraction calls."
            )
            print("Synthetic report: \(outputPath)")
        } catch {
            report.error = error.localizedDescription; report.calls = await trace.calls
            try await save(report, path: outputPath)
            throw error
        }
    }

    private static func observe(
        _ vm: TranscriptChatViewModel, label: String, cap: String, extractionCalls: Int, summaryCalls: Int
    ) -> Answer {
        let text = vm.messages.last?.content ?? ""
        let normalized = text.replacingOccurrences(of: ",", with: "").lowercased()
        return Answer(
            label: label, text: text, questionAnchor: vm.liveAnswerQuestionAnchor,
            firstTextMs: vm.liveAnswerTiming?.firstTextMs,
            completionMs: vm.liveAnswerTiming?.completionMs, extractionCallsDuringAsk: extractionCalls,
            summaryCallsDuringAsk: summaryCalls,
            checks: [
                "answer_completed": vm.liveAnswerTiming?.outcome == "completed",
                "fresh_cap_used": normalized.contains(cap),
                "three_minute_summary_present": vm.lastLiveMeetingMemory?.focusSummary?.text.isEmpty == false,
                "general_summary_present": vm.lastLiveMeetingMemory?.earlierSummary.isEmpty == false,
                "now_question_present": vm.lastLiveMeetingMemory?.nowContext?.anchor != nil,
                "zero_foreground_extraction": extractionCalls == 0, "zero_foreground_summarization": summaryCalls == 0,
            ])
    }

    private static func wait(_ label: String, condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(180))
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        guard await condition() else { throw Failure(message: "Timed out waiting for \(label).") }
    }

    private static func save(_ report: Report, path: String) async throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys];
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try await Task.detached {
            guard path.hasPrefix("/") else { throw Failure(message: "Report path must be absolute.") }
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }.value
    }
}
