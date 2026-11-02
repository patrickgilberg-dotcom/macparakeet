import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class LiveOrganizationAnswerPriorityTests: XCTestCase {
    func testPendingOrganizationBlocksTypedAskHotkeyUpdateAndRegenerationWithoutInference() async throws {
        let provider = OrganizationAnswerProbe()
        let state = OrganizationSaveState()
        let model = makeModel(provider, state: state)
        defer { model.stopLiveMeetingMemory(); model.cancelStreaming() }
        state.isSaving = true
        model.inputText = "Keep my unsent question."
        model.sendMessage()
        model.helpMeAnswer()
        model.updateLiveAnswer()
        model.regenerateLastResponse()
        XCTAssertFalse(model.canSendMessage)
        XCTAssertFalse(model.isStreaming)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertEqual(model.inputText, "Keep my unsent question.")
        XCTAssertTrue(model.errorMessage?.contains("Saving company and project") ?? false)
        let blockedCount = await provider.requests.count
        XCTAssertEqual(blockedCount, 0)

        state.isSaving = false
        XCTAssertTrue(model.canSendMessage)
        model.sendMessage()
        try await waitUntil { !model.isStreaming }
        XCTAssertEqual(model.liveAnswerTiming?.outcome, "completed")
        let completed = model.messages.map(\.content)
        let count = await provider.requests.count
        XCTAssertEqual(count, 1)

        state.isSaving = true
        model.regenerateLastResponse()
        XCTAssertEqual(model.messages.map(\.content), completed, "A blocked regeneration never removes an old answer.")
        let afterRegenerate = await provider.requests.count
        XCTAssertEqual(afterRegenerate, 1)
    }

    func testPreviouslyStartedAnswerCannotPublishAfterPickerShowsPendingNewOrganization() async throws {
        let provider = OrganizationAnswerProbe()
        let state = OrganizationSaveState()
        let model = makeModel(provider, state: state)
        defer { model.stopLiveMeetingMemory(); model.cancelStreaming() }
        await provider.holdNextAnswer()
        model.helpMeAnswer()
        try await waitUntil { await provider.requests.count == 1 }
        state.isSaving = true
        await provider.release()
        try await waitUntil { !model.isStreaming }
        XCTAssertTrue(model.messages.filter { $0.role == .assistant }.isEmpty)
        XCTAssertEqual(model.liveAnswerTiming?.outcome, "cancelled")

        await model.preemptLiveOrganizationWork()
        model.configureLiveProjectContext(eventPreparation: "NEW_FROZEN_CONTEXT")
        state.isSaving = false
        model.helpMeAnswer()
        try await waitUntil { !model.isStreaming }
        XCTAssertEqual(model.liveAnswerTiming?.outcome, "completed")
        let lastRequest = await provider.requests.last?.map(\.content).joined(separator: "\n") ?? ""
        XCTAssertTrue(lastRequest.contains("NEW_FROZEN_CONTEXT"))
        XCTAssertTrue(lastRequest.contains("CURRENT_MEETING_CONTEXT"))
    }

    private func makeModel(
        _ provider: OrganizationAnswerProbe, state: OrganizationSaveState
    ) -> TranscriptChatViewModel {
        let model = TranscriptChatViewModel()
        model.configure(llmService: nil, transcriptText: "CURRENT_MEETING_CONTEXT: What happens next?")
        model.configureDirectLiveAnswers(
            prepareTranscript: {}, stream: { provider.stream($0) }, summaryRefreshInterval: .seconds(3600))
        model.configureLiveOrganizationAvailability { state.isSaving }
        return model
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        let satisfied = await condition()
        XCTAssertTrue(satisfied)
    }
}

@MainActor
private final class OrganizationSaveState { var isSaving = false }

private actor OrganizationAnswerProbe {
    private(set) var requests: [[ChatMessage]] = []
    private var holdsNext = false
    private var continuation: CheckedContinuation<Void, Never>?

    func holdNextAnswer() { holdsNext = true }
    func release() { continuation?.resume(); continuation = nil }

    private func response(_ messages: [ChatMessage]) async -> String {
        requests.append(messages)
        if holdsNext {
            holdsNext = false
            await withCheckedContinuation { continuation = $0 }
        }
        return "The synthetic answer keeps the current conditions explicit."
    }

    nonisolated func stream(_ messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                continuation.yield(await self.response(messages))
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }
}
