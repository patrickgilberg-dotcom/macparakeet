import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

private actor FocusProviderCapture {
    var requests: [[ChatMessage]] = []
    func respond(_ messages: [ChatMessage]) -> String {
        requests.append(messages)
        if messages.first?.content.contains("Help me answer the latest question") == true {
            return "The current proposal still needs approval."
        }
        return requests.count == 1
            ? "GENERAL: The opening established a finance approval requirement."
            : "FOCUS: The current discussion concerns the revised pilot."
    }
    nonisolated func stream(_ messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(await respond(messages))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor
final class LiveThreeMinuteFocusViewModelTests: XCTestCase {
    func testAskUsesCompletedFocusGeneralBackgroundAndFreshSpeechWithoutAnotherSummary() async throws {
        let provider = FocusProviderCapture()
        var focus = LiveMeetingFocusSource(
            transcript: "Current: Discuss the revised pilot.", startMs: 0, endMs: 180_000)
        let vm = TranscriptChatViewModel()
        vm.configure(
            llmService: nil, transcriptText: "Opening: Finance must approve.\nCurrent: Discuss the revised pilot.")
        vm.configureDirectLiveAnswers(
            prepareTranscript: {
                vm.updateTranscriptText(
                    "Opening: Finance must approve.\nCurrent: Discuss the revised pilot.\nFresh: Security approval is also required."
                )
                focus = .init(
                    transcript: "Current: Discuss the revised pilot.\nFresh: Security approval is also required.",
                    startMs: 20_000, endMs: 200_000)
            }, stream: { provider.stream($0) }, focusSourceProvider: { focus },
            summaryRefreshInterval: .milliseconds(25))
        defer { vm.stopLiveMeetingMemory() }
        try await wait { vm.liveMeetingMemoryLastUpdated != nil }
        vm.stopLiveMeetingMemory()
        vm.helpMeAnswer()
        try await wait { !vm.isStreaming }
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 3, "Only the two ready summaries and one foreground answer should run")
        let payload = try XCTUnwrap(requests.last?.last?.content)
        XCTAssertTrue(payload.contains("<general_meeting_summary>GENERAL:"))
        XCTAssertTrue(payload.contains("<latest_three_minute_summary start_ms=\"0\" end_ms=\"180000\">"))
        XCTAssertTrue(payload.contains("FOCUS: The current discussion"))
        XCTAssertTrue(payload.contains("<live_recent_transcript start_ms=\"20000\" end_ms=\"200000\">"))
        XCTAssertTrue(payload.contains("Security approval is also required."))
        XCTAssertEqual(vm.lastLiveMeetingMemory?.focusSummary?.endMs, 180_000)
        XCTAssertTrue(vm.lastLiveMeetingMemory?.coverage.allSourceProcessed == true)
        XCTAssertEqual(vm.liveAnswerTiming?.outcome, "completed")
    }

    func testSilenceExpiresFocusEvenWhenWholeTranscriptIsUnchanged() async throws {
        let provider = FocusProviderCapture()
        var focus = LiveMeetingFocusSource(transcript: "Current pilot discussion.", startMs: 0, endMs: 180_000)
        let vm = TranscriptChatViewModel()
        vm.configure(
            llmService: nil, transcriptText: "Opening: Finance approval is required. Current pilot discussion.")
        vm.configureDirectLiveAnswers(
            prepareTranscript: {}, stream: { provider.stream($0) }, focusSourceProvider: { focus },
            summaryRefreshInterval: .milliseconds(25))
        defer { vm.stopLiveMeetingMemory() }
        try await wait { vm.liveMeetingMemoryLastUpdated != nil }
        let previous = vm.liveMeetingMemoryLastUpdated
        focus = .init(transcript: "", startMs: 240_000, endMs: 420_000)
        try await wait { vm.liveMeetingMemoryLastUpdated != previous }
        vm.stopLiveMeetingMemory()
        vm.helpMeAnswer()
        try await wait { !vm.isStreaming }
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 3, "Silence should clear focus locally without another model call")
        XCTAssertNil(vm.lastLiveMeetingMemory?.focusSummary)
        XCTAssertFalse(requests.last!.last!.content.contains("FOCUS:"))
        XCTAssertTrue(requests.last!.last!.content.contains("GENERAL:"))
        XCTAssertTrue(requests.last!.last!.content.contains("No recognized speech in this current window."))
    }

    func testEarlyAskUsesFreshSourceAndDisclosesThatSummariesAreNotReady() async throws {
        let provider = FocusProviderCapture()
        let vm = TranscriptChatViewModel()
        vm.configure(llmService: nil, transcriptText: "Current: We still need approval.")
        vm.liveTranscriptHasEarlierGap = true
        vm.configureDirectLiveAnswers(
            prepareTranscript: {}, stream: { provider.stream($0) },
            focusSourceProvider: {
                .init(transcript: "Current: We still need approval.", startMs: 0, endMs: 30_000)
            })
        defer { vm.stopLiveMeetingMemory() }
        vm.helpMeAnswer()
        try await wait { !vm.isStreaming }
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 1)
        let payload = requests[0].last!.content
        XCTAssertTrue(payload.contains("status=\"not_yet_available\""))
        XCTAssertTrue(payload.contains("We still need approval."))
        XCTAssertTrue(payload.contains("<source_limitations>[Earlier live-preview audio was missed;"))
        XCTAssertNil(vm.lastLiveMeetingMemory?.focusSummary)
        XCTAssertEqual(vm.lastLiveMeetingMemory?.coverage.mode, .fullRaw)
    }

    private func wait(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let ready = await condition()
        XCTAssertTrue(ready)
    }
}
