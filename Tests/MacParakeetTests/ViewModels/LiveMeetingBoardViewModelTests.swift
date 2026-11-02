import Foundation
import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

private actor BoardVMGate {
    var entered = false
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        if !opened { await withCheckedContinuation { waiter = $0 } }
    }

    func open() { opened = true; waiter?.resume(); waiter = nil }
}

private struct BoardVMExtraction: Sendable {
    let documentID: String
    let kind: String
    let source: String
}

private actor BoardVMProjectSource {
    private var source: LiveProjectMeetingSource?
    init(_ source: LiveProjectMeetingSource?) { self.source = source }
    func current() -> LiveProjectMeetingSource? { source }
    func replace(with source: LiveProjectMeetingSource?) { self.source = source }
}

private actor BoardVMProvider {
    var requests: [[ChatMessage]] = []
    var extractions: [BoardVMExtraction] = []
    var answers: [[ChatMessage]] = []
    var reconciliationCount = 0
    var extractionReturns = 0
    var cancelledTerminalValidations = 0
    private let extractionGate: BoardVMGate?
    private let terminalValidationGate: BoardVMGate?
    private var awaitingTerminalValidation = false

    init(extractionGate: BoardVMGate? = nil, terminalValidationGate: BoardVMGate? = nil) {
        self.extractionGate = extractionGate; self.terminalValidationGate = terminalValidationGate
    }

    func validate() async {
        if awaitingTerminalValidation {
            awaitingTerminalValidation = false
            await terminalValidationGate?.wait()
            if Task.isCancelled { cancelledTerminalValidations += 1 }
        }
    }

    func respond(_ messages: [ChatMessage]) async throws -> String {
        requests.append(messages)
        let object =
            messages.last.flatMap { try? JSONSerialization.jsonObject(with: Data($0.content.utf8)) }
            as? [String: Any]
        if object?["stage"] as? String == "reconcile" || object?["candidates"] != nil {
            reconciliationCount += 1
            return "{\"resolved\":[]}"
        }
        if let id = object?["documentID"] as? String, let kind = object?["kind"] as? String,
            let source = object?["source_chunk"] as? String
        {
            extractions.append(.init(documentID: id, kind: kind, source: source))
            if extractions.count == 1 { await extractionGate?.wait() }
            extractionReturns += 1
            awaitingTerminalValidation = terminalValidationGate != nil
            let isNotes = kind == "currentNotes" || kind == "previousNotes"
            let item: [String: Any] = [
                "kind": isNotes ? "note" : "action", "commitment": isNotes ? "noted" : "confirmed",
                "text": "Follow up from \(kind)", "owner": NSNull(), "deadline": NSNull(),
                "evidence": [["documentID": id, "quote": String(source.prefix(6_000))]],
            ]
            let bytes = try JSONSerialization.data(withJSONObject: ["items": [item]], options: [.sortedKeys])
            return String(decoding: bytes, as: UTF8.self)
        }
        if messages.first?.content.contains("Maintain a factual rolling memory") == true {
            return "Meeting background retained with its conditions and uncertainty."
        }
        answers.append(messages)
        return "Synthetic live answer."
    }

    nonisolated func session(key: String = "board-vm-provider") -> LiveAnswerStreamSession {
        LiveAnswerStreamSession(cacheKey: key, validate: { await self.validate() }) { messages in
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        continuation.yield(try await self.respond(messages))
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { @Sendable _ in task.cancel() }
            }
        }
    }
}

@MainActor
final class LiveMeetingBoardViewModelTests: XCTestCase {
    private let title = "Ajay’s Weekly Review — Planning / Q4"
    private let currentTranscript = "Maya: I will review the proposal after finance approval."
    private let currentNotes = "Ask about the revised budget — my reminder, not an accepted assignment."

    private func makeVM(
        _ provider: BoardVMProvider, recordingID: UUID = UUID(), notes: MeetingNotesViewModel? = nil
    ) -> TranscriptChatViewModel {
        let vm = TranscriptChatViewModel()
        vm.configure(llmService: nil, transcriptText: currentTranscript)
        vm.configureDirectLiveAnswers(
            prepareTranscript: {}, sessionProvider: { provider.session() }, summaryRefreshInterval: .seconds(3_600))
        vm.bindUserNotesProvider { [weak notes] in notes?.notesText }
        vm.configureLiveMeetingBoard(recordingID: recordingID, title: title)
        return vm
    }

    private func priorSource() -> LiveProjectMeetingSource {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        return LiveProjectMeetingSource(
            project: MeetingProject(name: "Latest-only project"),
            previous: .init(
                transcriptionID: UUID(), title: "Exact previous calendar title", createdAt: date, updatedAt: date,
                state: .ready, effectiveTranscript: "Lee: I will prepare the latest project comparison.",
                userNotes: "My previous note: check the comparison assumptions.", sourceHash: "latest-source"))
    }

    private func wait(
        _ check: @MainActor () async -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await check()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        let satisfied = await check()
        XCTAssertTrue(satisfied, file: file, line: line)
    }

    private func refresh(_ vm: TranscriptChatViewModel) async throws -> MeetingBoardSnapshot {
        vm.refreshLiveBoard()
        try await wait { !vm.isRefreshingLiveBoard }
        return try XCTUnwrap(vm.liveBoard)
    }

    private func ask(_ vm: TranscriptChatViewModel) async throws {
        vm.inputText = "What should I follow up on?"
        vm.sendMessage()
        try await wait { !vm.isStreaming }
        XCTAssertEqual(vm.liveAnswerTiming?.outcome, "completed")
    }

    func testBoardCapturesExactCurrentSourcesAndOnlyLatestProjectMeetingWithoutEditingNotes() async throws {
        let provider = BoardVMProvider()
        let notes = MeetingNotesViewModel()
        notes.notesBinding.wrappedValue = currentNotes
        let recordingID = UUID()
        let vm = makeVM(provider, recordingID: recordingID, notes: notes)
        defer { vm.stopLiveMeetingMemory(); vm.cancelStreaming() }
        let prior = priorSource()
        vm.configureLiveProjectContext(eventPreparation: "User-authored event preparation", sourceProvider: { prior })
        try await wait { vm.liveProjectContextStatus == "Project context checked." }
        XCTAssertFalse(
            vm.isPerformingLiveAIWork, "Completed project prefetch must release automatic preparation priority")
        let snapshot = try await refresh(vm)
        let previous = try XCTUnwrap(prior.previous)
        let expected = [
            recordingID.uuidString + ":transcript": currentTranscript,
            recordingID.uuidString + ":notes": currentNotes,
            previous.transcriptionID.uuidString + ":transcript": previous.effectiveTranscript!,
            previous.transcriptionID.uuidString + ":notes": previous.userNotes!,
        ]
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: snapshot.documents.map { ($0.id, $0.text) }), expected)
        XCTAssertEqual(snapshot.documents.first { $0.kind == .currentTranscript }?.title, title)
        XCTAssertEqual(snapshot.scopeKey, recordingID.uuidString + "|" + prior.scopeKey)
        XCTAssertEqual(notes.notesText, currentNotes, "Generated items must never be inserted into authored Notes")
        XCTAssertFalse(vm.liveBoardIsStale)
        XCTAssertTrue(
            snapshot.items.filter { item in
                item.evidence.contains { snapshot.document(for: $0)?.kind.isNotes == true }
            }.allSatisfy { $0.commitment == .noted })
        for item in snapshot.items {
            for quote in item.evidence { XCTAssertEqual(snapshot.resolvedQuote(quote), quote.quote) }
        }
        let inputs = await provider.extractions
        XCTAssertEqual(Set(inputs.map(\.documentID)), Set(expected.keys))
        XCTAssertEqual(inputs.count, 4)
    }

    func testUnchangedRefreshReusesCompletedBoardWithoutAnotherExtractionOrReconciliation() async throws {
        let provider = BoardVMProvider()
        let vm = makeVM(provider)
        defer { vm.stopLiveMeetingMemory(); vm.cancelStreaming() }
        let first = try await refresh(vm)
        let before = await provider.extractions.count
        let beforeReconciliation = await provider.reconciliationCount
        let second = try await refresh(vm)
        let after = await provider.extractions.count
        let afterReconciliation = await provider.reconciliationCount
        XCTAssertEqual(second, first)
        XCTAssertEqual(before, 1)
        XCTAssertEqual(after, before)
        XCTAssertEqual(afterReconciliation, beforeReconciliation)
    }

    func testBackgroundProviderWaitsForPriorityCallbackAndStopRejectsItsLateReturn() async throws {
        for stopWhileWaiting in [false, true] {
            let gate = BoardVMGate()
            let provider = BoardVMProvider()
            let vm = makeVM(provider)
            defer { vm.stopLiveMeetingMemory(); vm.cancelStreaming() }
            vm.configureLiveBackgroundWorkPriority { await gate.wait() }
            vm.refreshLiveBoard()
            try await wait { await gate.entered }
            let heldRequests = await provider.requests
            XCTAssertTrue(
                heldRequests.isEmpty, "Background summaries and board extraction must await foreground priority")
            XCTAssertTrue(vm.isPerformingLiveAIWork)
            if stopWhileWaiting { vm.stopLiveMeetingMemory() }
            await gate.open()
            if stopWhileWaiting {
                for _ in 0..<20 { await Task.yield() }
                let stoppedRequests = await provider.requests
                XCTAssertTrue(
                    stoppedRequests.isEmpty, "A stopped generation cannot claim the provider after priority returns")
                XCTAssertNil(vm.liveBoard)
                XCTAssertFalse(vm.isPerformingLiveAIWork)
            } else {
                try await wait { !vm.isRefreshingLiveBoard }
                XCTAssertNotNil(vm.liveBoard)
                let extractions = await provider.extractions
                XCTAssertEqual(extractions.count, 1)
                XCTAssertFalse(vm.isPerformingLiveAIWork)
            }
        }
    }

    func testAskCancelsAndAwaitsHeldBoardValidationWithoutForegroundBoardInference() async throws {
        let gate = BoardVMGate()
        let provider = BoardVMProvider(terminalValidationGate: gate)
        let vm = makeVM(provider)
        defer { vm.stopLiveMeetingMemory(); vm.cancelStreaming() }
        vm.refreshLiveBoard()
        try await wait { await gate.entered }
        vm.inputText = "Can I commit before finance approval?"
        vm.sendMessage()
        for _ in 0..<20 { await Task.yield() }
        let heldAnswers = await provider.answers
        XCTAssertTrue(heldAnswers.isEmpty, "Ask must await the cancelled background operation's terminal validation")
        XCTAssertTrue(vm.isStreaming)
        await gate.open()
        try await wait { !vm.isStreaming }
        let extractions = await provider.extractions
        let answers = await provider.answers
        let cancelled = await provider.cancelledTerminalValidations
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(extractions.count, 1, "Ask must not run board extraction on its foreground path")
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(vm.liveAnswerTiming?.outcome, "completed")
        XCTAssertNil(vm.liveBoard, "A cancelled partial board must not publish after Ask")
    }

    func testTranscriptCorrectionOrNoteEditDuringExtractionRejectsPublication() async throws {
        for changeNotes in [false, true] {
            let gate = BoardVMGate()
            let provider = BoardVMProvider(extractionGate: gate)
            let notes = MeetingNotesViewModel()
            notes.notesBinding.wrappedValue = currentNotes
            let vm = makeVM(provider, notes: notes)
            defer { vm.stopLiveMeetingMemory(); vm.cancelStreaming() }
            vm.refreshLiveBoard()
            try await wait { await gate.entered }
            if changeNotes {
                notes.notesBinding.wrappedValue = "Corrected personal reminder: no budget commitment was made."
            } else {
                vm.updateTranscriptText("Maya: Correction: I have not accepted the proposal review.")
            }
            await gate.open()
            try await wait { !vm.isRefreshingLiveBoard }
            XCTAssertNil(vm.liveBoard, "A source correction or note edit cannot publish the older captured board")
            XCTAssertNil(vm.liveBoardError)
            XCTAssertEqual(
                notes.notesText,
                changeNotes
                    ? "Corrected personal reminder: no budget commitment was made." : currentNotes)
        }
    }

    func testAppendedSpeechAllowsCapturedSnapshotAndMarksItStaleUntilNextRefresh() async throws {
        let gate = BoardVMGate()
        let provider = BoardVMProvider(extractionGate: gate)
        let vm = makeVM(provider)
        defer { vm.stopLiveMeetingMemory(); vm.cancelStreaming() }
        vm.refreshLiveBoard()
        try await wait { await gate.entered }
        let appended = currentTranscript + "\nLee: What about the revised release date?"
        vm.updateTranscriptText(appended)
        await gate.open()
        try await wait { !vm.isRefreshingLiveBoard }
        let captured = try XCTUnwrap(vm.liveBoard)
        XCTAssertEqual(captured.documents.first { $0.kind == .currentTranscript }?.text, currentTranscript)
        XCTAssertTrue(vm.liveBoardIsStale, "New speech must not make an older source snapshot look current")
        let refreshed = try await refresh(vm)
        XCTAssertEqual(refreshed.documents.first { $0.kind == .currentTranscript }?.text, appended)
        XCTAssertFalse(vm.liveBoardIsStale)
    }

    func testStopOrDifferentRecordingRejectsLateBoardPublication() async throws {
        for stopRecording in [false, true] {
            let gate = BoardVMGate()
            let provider = BoardVMProvider(extractionGate: gate)
            let vm = makeVM(provider)
            defer { vm.stopLiveMeetingMemory(); vm.cancelStreaming() }
            vm.refreshLiveBoard()
            try await wait { await gate.entered }
            if stopRecording {
                vm.stopLiveMeetingMemory()
            } else {
                vm.configureLiveMeetingBoard(recordingID: UUID(), title: "A different meeting")
            }
            await gate.open()
            try await wait { await provider.extractionReturns > 0 }
            try await wait { !vm.isRefreshingLiveBoard }
            for _ in 0..<20 { await Task.yield() }
            XCTAssertNil(vm.liveBoard)
            XCTAssertNil(vm.liveBoardError)
        }
    }

    func testPreparedBriefIsUsedOnlyForExplicitAskWithMatchingSourceProviderAndManualContext() async throws {
        for mismatch in ["none", "source", "provider", "manual"] {
            let provider = BoardVMProvider()
            let recordingID = UUID()
            let vm = makeVM(provider, recordingID: recordingID)
            defer { vm.stopLiveMeetingMemory(); vm.cancelStreaming() }
            let prior = priorSource()
            vm.configureLiveProjectContext(
                eventPreparation: "Authored preparation stays separate", sourceProvider: { prior })
            try await wait { vm.liveProjectContextStatus == "Project context checked." }
            let previous = try XCTUnwrap(prior.previous)
            let document = MeetingEvidenceDocument(
                id: previous.transcriptionID.uuidString + ":notes", kind: .previousNotes,
                title: previous.title, text: previous.userNotes!)
            let preparedBoard = MeetingBoardSnapshot(
                scopeKey: prior.scopeKey, documents: [document],
                items: [
                    .init(
                        kind: .note, commitment: .noted,
                        text: "PREPARATION_ONLY_MARKER: revisit the comparison assumptions.",
                        evidence: [.init(documentID: document.id, quote: document.text)])
                ],
                coverageDescription: "All selected prior meeting sources were processed.")
            let preparation = MeetingGeneratedPreparation(
                key: .init(calendarID: "synthetic-calendar", eventID: "synthetic-occurrence"),
                projectID: prior.project.id, projectName: prior.project.name,
                sourceScopeKey: mismatch == "source" ? "different-source" : prior.scopeKey,
                manualContextHash: MeetingGeneratedPreparation.hash(
                    mismatch == "manual" ? "Different authored meeting goals" : "Authored preparation stays separate"),
                eventTitle: title, startTime: Date(timeIntervalSince1970: 1_800_001_000), board: preparedBoard,
                providerIdentityHash: MeetingGeneratedPreparation.hash(
                    mismatch == "provider" ? "different-provider" : "board-vm-provider"),
                sourceStatus: "Latest project meeting only; prior action completion unverified.")
            vm.configureLiveMeetingBoard(recordingID: recordingID, title: title, preparation: preparation)
            _ = try await refresh(vm)
            let background = await provider.requests
            XCTAssertFalse(background.flatMap { $0 }.contains { $0.content.contains("PREPARATION_ONLY_MARKER") })
            try await ask(vm)
            let answers = await provider.answers
            let answerBody = try XCTUnwrap(answers.last?.last?.content)
            XCTAssertEqual(answerBody.contains("PREPARATION_ONLY_MARKER"), mismatch == "none")
            XCTAssertEqual(vm.generatedMeetingPreparation != nil, mismatch == "none")
        }
    }

    func testRemovedProjectSourceClearsVisibleBoardAndPriorProjectHistoryBeforeNextAsk() async throws {
        let provider = BoardVMProvider()
        let vm = makeVM(provider)
        defer { vm.stopLiveMeetingMemory(); vm.cancelStreaming() }
        let prior = priorSource()
        let source = BoardVMProjectSource(prior)
        vm.configureLiveProjectContext(
            eventPreparation: "Frozen authored goals", sourceProvider: { await source.current() })
        try await wait { vm.liveProjectContextStatus == "Project context checked." }
        let board = try await refresh(vm)
        XCTAssertTrue(board.documents.contains { $0.kind == .previousTranscript })

        vm.inputText = "OLD_PROJECT_ASK_MARKER: What is our comparison follow-up?"
        vm.sendMessage()
        try await wait { !vm.isStreaming }
        XCTAssertEqual(vm.liveAnswerTiming?.outcome, "completed")
        XCTAssertNotNil(vm.liveBoard)
        await source.replace(with: nil)
        let extractionBefore = await provider.extractions.count
        try await ask(vm)

        XCTAssertNil(vm.liveBoard, "A deleted project cannot leave its prior source available as the current board")
        XCTAssertNil(vm.lastLiveProjectContext)
        let requests = await provider.answers
        XCTAssertEqual(requests.count, 2)
        let latest = try XCTUnwrap(requests.last).map(\.content).joined(separator: "\n")
        XCTAssertFalse(
            latest.contains("OLD_PROJECT_ASK_MARKER"), "History from the removed project must leave the model scope")
        let previous = try XCTUnwrap(prior.previous)
        XCTAssertFalse(latest.contains(previous.title))
        XCTAssertFalse(latest.contains(previous.transcriptionID.uuidString))
        XCTAssertFalse(latest.contains(try XCTUnwrap(previous.effectiveTranscript)))
        XCTAssertFalse(latest.contains(try XCTUnwrap(previous.userNotes)))
        let extractionAfter = await provider.extractions.count
        XCTAssertEqual(extractionAfter, extractionBefore, "Invalidation must not add foreground board inference")
    }
}
