import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

private actor FocusSnapshotPreferencesGate {
    var entered = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    func load() async -> LiveMeetingPreferences {
        entered = true
        if !released { await withCheckedContinuation { waiter = $0 } }
        return LiveMeetingPreferences(
            skillMarkdown: "Synthetic meeting skill.", automaticMinutesEnabled: false, answerStyleEnabled: false)
    }

    func release() {
        released = true
        waiter?.resume(); waiter = nil
    }
}

private actor FocusSnapshotRequestCapture {
    var requests: [[ChatMessage]] = []
    func record(_ messages: [ChatMessage]) { requests.append(messages) }

    nonisolated func stream(_ messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await record(messages)
                continuation.yield("Approval remains unconfirmed.")
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor
private final class FocusSnapshotProjection {
    var source: LiveMeetingFocusSource
    init(_ source: LiveMeetingFocusSource) { self.source = source }
}

@MainActor
final class LiveFocusSnapshotConsistencyTests: XCTestCase {
    func testPreferencesAwaitCannotMixNewFocusWithPreviouslyCapturedTranscript() async throws {
        let originalFocus = LiveMeetingFocusSource(
            transcript: "Unknown: Approval is pending.", startMs: 0, endMs: 30_000)
        let correctedFocus = LiveMeetingFocusSource(
            transcript: "Maya: Approval was explicitly declined.", startMs: 0, endMs: 30_000)
        let originalTranscript = "Opening: Review the proposal.\n" + originalFocus.transcript
        let correctedTranscript = "Opening: Review the proposal.\n" + correctedFocus.transcript
        let projection = FocusSnapshotProjection(originalFocus)
        let preferences = FocusSnapshotPreferencesGate()
        let capture = FocusSnapshotRequestCapture()
        let vm = TranscriptChatViewModel()
        vm.configure(llmService: nil, transcriptText: originalTranscript)
        vm.configureLiveAnswerPreferences { await preferences.load() }
        vm.configureDirectLiveAnswers(
            prepareTranscript: {}, stream: { capture.stream($0) },
            focusSourceProvider: { projection.source }, summaryRefreshInterval: .seconds(180))
        defer { vm.stopLiveMeetingMemory() }

        vm.helpMeAnswer()
        try await waitUntil { await preferences.entered }
        vm.updateTranscriptText(correctedTranscript)
        projection.source = correctedFocus
        await preferences.release()
        try await waitUntil { !vm.isStreaming }

        XCTAssertEqual(vm.liveAnswerTiming?.outcome, "completed")
        XCTAssertEqual(vm.lastLiveMeetingMemory?.recentTranscript, originalTranscript)
        XCTAssertEqual(vm.lastLiveMeetingMemory?.focusSource, originalFocus)
        XCTAssertNil(vm.lastLiveMeetingMemory?.focusSummary)
        let firstRequests = await capture.requests
        XCTAssertEqual(firstRequests.count, 1, "A short Ask must not add a summary request")
        let firstPayload = try XCTUnwrap(firstRequests.first?.last?.content)
        XCTAssertTrue(firstPayload.contains(originalTranscript))
        XCTAssertTrue(firstPayload.contains(originalFocus.transcript))
        XCTAssertFalse(firstPayload.contains(correctedFocus.transcript))

        vm.helpMeAnswer()
        try await waitUntil { !vm.isStreaming }

        XCTAssertEqual(vm.liveAnswerTiming?.outcome, "completed")
        XCTAssertEqual(vm.lastLiveMeetingMemory?.recentTranscript, correctedTranscript)
        XCTAssertEqual(vm.lastLiveMeetingMemory?.focusSource, correctedFocus)
        let allRequests = await capture.requests
        XCTAssertEqual(allRequests.count, 2, "Each short Ask should make one final answer request")
        let secondPayload = try XCTUnwrap(allRequests.last?.last?.content)
        XCTAssertTrue(secondPayload.contains(correctedTranscript))
        XCTAssertTrue(secondPayload.contains(correctedFocus.transcript))
        XCTAssertFalse(secondPayload.contains(originalFocus.transcript))
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        let ready = await condition(); XCTAssertTrue(ready)
    }
}
