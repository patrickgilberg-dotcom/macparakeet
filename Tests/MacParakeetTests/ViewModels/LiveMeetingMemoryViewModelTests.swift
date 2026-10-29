import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

private actor RollingMemoryProvider {
    var requests: [[ChatMessage]] = []
    var heldSummaries = false
    var cancelledSummaries = 0

    func holdSummaries(_ hold: Bool) { heldSummaries = hold }
    func record(_ messages: [ChatMessage]) async throws -> String {
        requests.append(messages)
        if messages.first?.content.contains("Maintain a factual rolling memory") == true {
            do {
                if heldSummaries { try await Task.sleep(for: .seconds(20)) }
                return "Earlier decision: $45,000 ceiling, subject to finance approval. Maya owns the review."
            } catch {
                cancelledSummaries += 1
                throw error
            }
        }
        return "Maya can review it, subject to finance approval."
    }

    nonisolated func stream(_ messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(try await record(messages))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor
final class LiveMeetingMemoryViewModelTests: XCTestCase {
    func testTimerSkipsEmptyAndUnchangedSourcesButRollsForwardNewSpeech() async throws {
        let provider = RollingMemoryProvider()
        let vm = makeVM(provider)
        defer { vm.stopLiveMeetingMemory() }
        vm.liveTranscriptHasEarlierGap = true
        try await Task.sleep(for: .milliseconds(75))
        let emptyRequests = await provider.requests
        XCTAssertTrue(emptyRequests.isEmpty)

        vm.updateTranscriptText("Maya: The ceiling is $45,000, subject to finance approval.")
        try await wait { vm.liveMeetingMemoryLastUpdated != nil }
        let firstUpdate = vm.liveMeetingMemoryLastUpdated
        try await Task.sleep(for: .milliseconds(75))
        let firstRequests = await provider.requests
        XCTAssertEqual(firstRequests.count, 1)
        XCTAssertEqual(vm.liveMeetingMemoryLastUpdated, firstUpdate)

        vm.updateTranscriptText("Maya: The ceiling is $45,000, subject to finance approval.\nLee: Review it on Friday.")
        try await wait { await provider.requests.count == 2 }
        let requests = await provider.requests
        XCTAssertTrue(requests[1].last!.content.contains("prior_memory"))
        XCTAssertTrue(requests[1].last!.content.contains("finance approval"))
        XCTAssertTrue(requests[1].last!.content.contains("Review it on Friday"))
    }

    func testAskCombinesReadySummaryWithFreshRawSpeechAndDoesNotSummarizeAgain() async throws {
        let provider = RollingMemoryProvider()
        let vm = TranscriptChatViewModel()
        vm.configure(llmService: nil, transcriptText: "Maya: Budget ceiling is $45,000, subject to finance approval.")
        vm.configureDirectLiveAnswers(
            prepareTranscript: { [weak vm] in
                vm?.updateTranscriptText(
                    "Maya: Budget ceiling is $45,000, subject to finance approval.\nLee: Can Maya review this today?")
            }, stream: { messages in provider.stream(messages) }, summaryRefreshInterval: .milliseconds(20))
        defer { vm.stopLiveMeetingMemory() }
        try await wait { vm.liveMeetingMemoryLastUpdated != nil }
        vm.stopLiveMeetingMemory()
        vm.helpMeAnswer()
        try await wait { !vm.isStreaming }
        XCTAssertEqual(vm.liveAnswerTiming?.outcome, "completed")
        XCTAssertNotNil(vm.liveAnswerTiming?.contextReadyMs)
        XCTAssertEqual(vm.lastLiveMeetingMemory?.coverage.mode, .fullRaw)
        XCTAssertFalse(vm.lastLiveMeetingMemory?.earlierSummary.isEmpty ?? true)
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.last!.last!.content.contains("Can Maya review this today?"))
        XCTAssertTrue(requests.last!.last!.content.contains("$45,000"))
        XCTAssertTrue(vm.lastLiveMeetingMemory?.coverage.allSourceProcessed == true)
    }

    func testLongAskProcessesEveryOlderChunkAndUsesLatestRawWords() async throws {
        let provider = RollingMemoryProvider()
        let transcript =
            "Opening: approval was conditional.\n"
            + String(repeating: "Speaker: detailed context for the meeting.\n", count: 420)
            + "Middle: the special identifier is QZ-71.\n"
            + String(repeating: "Speaker: more discussion without a decision.\n", count: 420)
            + "Latest: Can Maya review this today?"
        let vm = makeVM(provider, transcript: transcript, interval: .seconds(180))
        defer { vm.stopLiveMeetingMemory() }
        vm.helpMeAnswer()
        try await wait { !vm.isStreaming }
        let requests = await provider.requests
        XCTAssertGreaterThan(requests.count, 2)
        let summaryPayloads = requests.dropLast().compactMap { $0.last?.content }.joined()
        XCTAssertTrue(summaryPayloads.contains("approval was conditional"))
        XCTAssertTrue(summaryPayloads.contains("QZ-71"))
        XCTAssertTrue(requests.last!.last!.content.contains("Latest: Can Maya review this today?"))
        XCTAssertTrue(requests.last!.last!.content.contains("<earlier_meeting_summary>"))
        XCTAssertEqual(vm.lastLiveMeetingMemory?.coverage.totalCharacters, transcript.count)
        XCTAssertTrue(vm.lastLiveMeetingMemory?.coverage.allSourceProcessed == true)
    }

    func testExplicitAskCancelsRunningPeriodicSummaryAndPublishesOnlyAnswerContext() async throws {
        let provider = RollingMemoryProvider()
        await provider.holdSummaries(true)
        let vm = makeVM(provider, transcript: "Maya: Review the proposal only after finance approval.")
        defer { vm.stopLiveMeetingMemory() }
        try await wait { await provider.requests.count == 1 }
        vm.helpMeAnswer()
        try await wait { !vm.isStreaming }
        try await wait { await provider.cancelledSummaries == 1 }
        XCTAssertEqual(vm.liveAnswerTiming?.outcome, "completed")
        XCTAssertNil(vm.liveMeetingMemoryLastUpdated)
        XCTAssertNil(vm.liveMeetingMemoryBackgroundError)
        XCTAssertEqual(vm.messages.last?.content, "Maya can review it, subject to finance approval.")
        XCTAssertEqual(vm.lastLiveMeetingMemory?.earlierSummary, "")
    }

    func testPauseCancelsInFlightUpdateAndResumeRestartsCadence() async throws {
        let provider = RollingMemoryProvider()
        await provider.holdSummaries(true)
        let vm = makeVM(provider, transcript: "Maya: First recognized words.")
        defer { vm.stopLiveMeetingMemory() }
        try await wait { await provider.requests.count == 1 }
        vm.stopLiveMeetingMemory()
        await provider.holdSummaries(false)
        vm.updateTranscriptText("Maya: First recognized words. Lee: Additional recognized words.")
        try await Task.sleep(for: .milliseconds(75))
        let pausedRequests = await provider.requests
        XCTAssertEqual(pausedRequests.count, 1)
        XCTAssertNil(vm.liveMeetingMemoryLastUpdated)
        XCTAssertNil(vm.liveMeetingMemoryProgress)
        vm.resumeLiveMeetingMemory()
        try await wait { vm.liveMeetingMemoryLastUpdated != nil }
        let resumedRequests = await provider.requests
        XCTAssertEqual(resumedRequests.count, 2)
        XCTAssertTrue(resumedRequests.last!.last!.content.contains("Additional recognized words"))
    }

    func testCancelledValidationNeverPublishesSummaryOrCompletedAnswerContext() async throws {
        let provider = RollingMemoryProvider()
        let vm = TranscriptChatViewModel()
        vm.configure(llmService: nil, transcriptText: "Maya: Finance approval is still pending.")
        vm.configureDirectLiveAnswers(
            prepareTranscript: {},
            sessionProvider: {
                LiveAnswerStreamSession(
                    cacheKey: "changed-identity", validate: { throw CancellationError() },
                    stream: { messages in provider.stream(messages) })
            }, summaryRefreshInterval: .milliseconds(20))
        defer { vm.stopLiveMeetingMemory() }
        try await wait { await provider.requests.count == 1 }
        try await Task.sleep(for: .milliseconds(10))
        vm.stopLiveMeetingMemory()
        XCTAssertNil(vm.liveMeetingMemoryLastUpdated)
        vm.helpMeAnswer()
        try await wait { !vm.isStreaming }
        XCTAssertNil(vm.lastLiveMeetingMemory)
        XCTAssertEqual(vm.liveAnswerTiming?.outcome, "cancelled")
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 1, "Validation must reject the final answer before sending it")
    }

    func testNewChatClearsTheCompletedAnswerContext() async throws {
        let provider = RollingMemoryProvider()
        let vm = makeVM(provider, transcript: "Maya: Finance approval is pending.", interval: .seconds(180))
        defer { vm.stopLiveMeetingMemory() }
        vm.helpMeAnswer()
        try await wait { !vm.isStreaming }
        XCTAssertNotNil(vm.lastLiveMeetingMemory)
        vm.newChat()
        XCTAssertNil(vm.lastLiveMeetingMemory)
    }

    private func makeVM(
        _ provider: RollingMemoryProvider, transcript: String = "", interval: Duration = .milliseconds(20)
    ) -> TranscriptChatViewModel {
        let vm = TranscriptChatViewModel()
        vm.configure(llmService: nil, transcriptText: transcript)
        vm.configureDirectLiveAnswers(
            prepareTranscript: {}, stream: { messages in provider.stream(messages) }, summaryRefreshInterval: interval)
        return vm
    }

    private func wait(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let satisfied = await condition()
        XCTAssertTrue(satisfied)
    }
}
