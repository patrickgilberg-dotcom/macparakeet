import Foundation
import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

private actor RefreshStreamCapture {
    private struct Request: Sendable {
        let id: UUID
        let messages: [ChatMessage]
        let continuation: AsyncThrowingStream<String, Error>.Continuation
    }
    private var requests: [Request] = []
    private var cancellations: Set<UUID> = []
    var count: Int { requests.count }

    nonisolated func stream(_ messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        let id = UUID()
        return AsyncThrowingStream { continuation in
            Task { await self.register(id: id, messages: messages, continuation: continuation) }
            continuation.onTermination = { reason in
                if case .cancelled = reason { Task { await self.cancelled(id) } }
            }
        }
    }
    private func register(
        id: UUID, messages: [ChatMessage], continuation: AsyncThrowingStream<String, Error>.Continuation
    ) {
        requests.append(.init(id: id, messages: messages, continuation: continuation))
    }
    private func cancelled(_ id: UUID) { cancellations.insert(id) }
    func wasCancelled(_ index: Int) -> Bool { cancellations.contains(requests[index].id) }
    func messages(_ index: Int) -> [ChatMessage] { requests[index].messages }
    func emit(_ index: Int, text: String) { requests[index].continuation.yield(text) }
    func finish(_ index: Int, text: String) {
        requests[index].continuation.yield(text)
        requests[index].continuation.finish()
    }
}

@MainActor
private final class RefreshProjection {
    var words: [WordTimestamp] = []
    var elapsedMs = 0
    let speakers = [SpeakerInfo(id: "system:S1", label: "Other person")]

    init() { append("Can we promise a Friday launch?", at: 1_000) }
    func append(_ text: String, at start: Int) {
        let added = text.split(separator: " ").enumerated().map { index, word in
            WordTimestamp(
                word: String(word), startMs: start + index * 300, endMs: start + index * 300 + 250,
                confidence: 1, speakerId: "system:S1")
        }
        words += added
        elapsedMs = max(elapsedMs, (added.last?.endMs ?? start) + 500)
    }
    func replaceLaunchDay() {
        words = words.map { word in
            var copy = word
            if copy.word == "Friday" { copy.word = "Monday" }
            return copy
        }
    }
    var transcript: String {
        LiveMeetingFocusTranscript.project(
            words: words, speakers: speakers, elapsedMs: elapsedMs, includeTimestamps: true
        ).transcript
    }
    var focus: LiveMeetingFocusSource {
        LiveMeetingFocusTranscript.project(
            words: words, speakers: speakers, elapsedMs: elapsedMs, includeTimestamps: true)
    }
    var now: LiveMeetingNowSnapshot {
        LiveMeetingNowTranscript.project(
            words: words, speakers: speakers, elapsedMs: elapsedMs, includeTimestamps: true)
    }
    func publish(to vm: TranscriptChatViewModel) {
        vm.updateTranscriptText(transcript)
        vm.refreshLiveAnswerFreshness()
    }
}

private actor RefreshPersistenceCapture {
    private var firstAssistant = true
    private var gate: CheckedContinuation<Void, Never>?
    var waitingAssistant = false
    var saved: [MeetingLiveChatSnapshot] = []

    func save(_ snapshot: MeetingLiveChatSnapshot) async {
        if firstAssistant, snapshot.messages.last?.role == .assistant {
            firstAssistant = false
            waitingAssistant = true
            await withCheckedContinuation { gate = $0 }
        }
        saved.append(snapshot)
    }
    func release() { gate?.resume(); gate = nil }
}

@MainActor
final class LiveAnswerRefreshViewModelTests: XCTestCase {
    func testNewQuestionMarksStaleWithoutInferenceAndUpdatePreemptsOnlyOldPartial() async throws {
        let projection = RefreshProjection()
        let provider = RefreshStreamCapture()
        let vm = makeVM(projection, provider)
        defer { vm.stopLiveMeetingMemory(); vm.cancelStreaming() }
        vm.helpMeAnswer()
        try await wait { await provider.count == 1 }
        let originalDate = try XCTUnwrap(vm.liveAnswerSnapshotDate)
        XCTAssertTrue(vm.liveAnswerQuestionAnchor?.contains("Friday") == true)
        XCTAssertFalse(vm.liveAnswerConversationMovedOn)
        await provider.emit(0, text: "Old partial answer")

        projection.append("Who owns the security review?", at: 40_000)
        projection.publish(to: vm)
        XCTAssertTrue(vm.liveAnswerConversationMovedOn)
        XCTAssertTrue(vm.canUpdateLiveAnswer)
        let beforeRefresh = await provider.count
        XCTAssertEqual(beforeRefresh, 1)
        vm.updateLiveAnswer()
        try await wait { await provider.count == 2 }
        try await wait { await provider.wasCancelled(0) }
        let refreshedNow = nowBody(await provider.messages(1))
        XCTAssertTrue(refreshedNow.contains("Who owns the security review?"))
        XCTAssertFalse(refreshedNow.contains("Friday"))
        XCTAssertEqual(
            vm.messages.filter { $0.role == .user }.count, 1, "Refresh reuses the admitted in-flight question")
        XCTAssertFalse(vm.messages.contains { $0.content.contains("Old partial answer") })
        XCTAssertTrue(vm.liveAnswerQuestionAnchor?.contains("security review") == true)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(vm.liveAnswerSnapshotDate), originalDate)

        projection.append("What is the revised budget ceiling?", at: 70_000)
        projection.publish(to: vm)
        XCTAssertTrue(vm.liveAnswerConversationMovedOn)
        await provider.finish(0, text: "Obsolete late answer A.")
        await provider.finish(1, text: "Refreshed answer B.")
        try await wait { !vm.isStreaming }
        XCTAssertEqual(vm.messages.last?.content, "Refreshed answer B.")
        XCTAssertTrue(vm.liveAnswerConversationMovedOn, "Question C must remain newer than completed answer B")
        XCTAssertTrue(vm.canUpdateLiveAnswer)
        XCTAssertFalse(vm.messages.contains { $0.content.contains("Obsolete late answer A") })
        let requests = await provider.count
        XCTAssertEqual(requests, 2, "Transcript updates alone must not call the model")
    }

    func testCompletedUpdatePreservesPriorAnswerTypedIntentAndUnsentDraft() async throws {
        let projection = RefreshProjection()
        let provider = RefreshStreamCapture()
        let vm = makeVM(projection, provider)
        defer { vm.stopLiveMeetingMemory(); vm.cancelStreaming() }
        vm.inputText = "Review the approval conditions"
        let rich = "Explain the required approvals from this meeting, preserving uncertainty."
        vm.sendMessage(richPrompt: rich)
        try await wait { await provider.count == 1 }
        await provider.finish(0, text: "Original completed answer.")
        try await wait { !vm.isStreaming }

        projection.append("Has the security approval actually been received?", at: 40_000)
        projection.publish(to: vm)
        XCTAssertTrue(vm.liveAnswerConversationMovedOn)
        vm.inputText = "Unsent draft that must remain in the composer"
        vm.updateLiveAnswer()
        try await wait { await provider.count == 2 }
        XCTAssertEqual(vm.inputText, "Unsent draft that must remain in the composer")
        XCTAssertTrue(vm.messages.contains { $0.content == "Original completed answer." })
        XCTAssertEqual(vm.messages.filter { $0.role == .user }.count, 2)
        let request = await provider.messages(1)
        XCTAssertTrue(request.last?.content.contains("Current question: \(rich)") == true)
        await provider.finish(1, text: "Updated completed answer.")
        try await wait { !vm.isStreaming }
        XCTAssertEqual(
            vm.messages.filter { $0.role == .assistant }.map(\.content),
            [
                "Original completed answer.", "Updated completed answer.",
            ])
        XCTAssertFalse(vm.liveAnswerConversationMovedOn)
    }

    func testSilenceAndShortUnfinishedInterjectionDoNotMarkStaleOrInfer() async throws {
        let projection = RefreshProjection()
        let provider = RefreshStreamCapture()
        let vm = makeVM(projection, provider)
        defer { vm.stopLiveMeetingMemory(); vm.cancelStreaming() }
        vm.helpMeAnswer()
        try await wait { await provider.count == 1 }
        projection.elapsedMs = 300_000
        vm.refreshLiveAnswerFreshness()
        XCTAssertFalse(vm.liveAnswerConversationMovedOn, "Elapsed time and an expired window are not new discussion")
        projection.append("Uh", at: 301_000)
        projection.publish(to: vm)
        XCTAssertFalse(vm.liveAnswerConversationMovedOn, "A short unfinished interjection is not a new question")
        let requests = await provider.count
        XCTAssertEqual(requests, 1)
        await provider.finish(0, text: "The original question remains the anchor.")
        try await wait { !vm.isStreaming }
        XCTAssertFalse(vm.liveAnswerConversationMovedOn)
    }

    func testCorrectionToSameQuestionMarksStaleAndRefreshUsesCorrectedSource() async throws {
        let projection = RefreshProjection()
        let provider = RefreshStreamCapture()
        let vm = makeVM(projection, provider)
        defer { vm.stopLiveMeetingMemory(); vm.cancelStreaming() }
        vm.helpMeAnswer()
        try await wait { await provider.count == 1 }
        projection.replaceLaunchDay()
        projection.publish(to: vm)
        XCTAssertTrue(vm.liveAnswerConversationMovedOn)
        let countBefore = await provider.count
        XCTAssertEqual(countBefore, 1)
        vm.updateLiveAnswer()
        try await wait { await provider.count == 2 }
        XCTAssertTrue(vm.liveAnswerQuestionAnchor?.contains("Monday") == true)
        let request = await provider.messages(1)
        XCTAssertTrue(request.last?.content.contains("Monday") == true)
        XCTAssertTrue(nowBody(request).contains("Monday"))
        XCTAssertFalse(nowBody(request).contains("Friday"))
        await provider.finish(1, text: "Monday still needs approval.")
        try await wait { !vm.isStreaming }
        XCTAssertFalse(vm.liveAnswerConversationMovedOn)
    }

    func testUpdateDuringOldTerminalSaveCannotRestoreCancelledAnswer() async throws {
        let projection = RefreshProjection()
        let provider = RefreshStreamCapture()
        let persistence = RefreshPersistenceCapture()
        let vm = makeVM(projection, provider)
        defer { vm.stopLiveMeetingMemory(); vm.cancelStreaming() }
        vm.configureLiveChatCheckpoint(recordingID: UUID(), checkpoint: { await persistence.save($0) })
        vm.helpMeAnswer()
        try await wait { await provider.count == 1 }
        await provider.finish(0, text: "Cancelled answer awaiting local save.")
        try await wait { await persistence.waitingAssistant }
        projection.append("Who owns the security review?", at: 40_000)
        projection.publish(to: vm)
        vm.updateLiveAnswer()
        await persistence.release()
        try await wait { await provider.count == 2 }
        await provider.finish(1, text: "Current durable answer.")
        try await wait { !vm.isStreaming }
        try await vm.flushLiveChatCheckpoint()
        let saved = await persistence.saved
        let final = try XCTUnwrap(saved.last)
        XCTAssertEqual(final.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(final.messages.last?.content, "Current durable answer.")
        XCTAssertFalse(vm.messages.contains { $0.content == "Cancelled answer awaiting local save." })
        XCTAssertEqual(saved.map(\.revision), saved.map(\.revision).sorted())
        XCTAssertNil(vm.liveChatPersistenceError)
    }

    func testNewChatClearsAnchorAndMovedOnStateDespiteLateOldOutput() async throws {
        let projection = RefreshProjection()
        let provider = RefreshStreamCapture()
        let vm = makeVM(projection, provider)
        defer { vm.stopLiveMeetingMemory(); vm.cancelStreaming() }
        vm.helpMeAnswer()
        try await wait { await provider.count == 1 }
        projection.append("Who owns the security review?", at: 40_000)
        projection.publish(to: vm)
        XCTAssertTrue(vm.liveAnswerConversationMovedOn)
        vm.newChat()
        await provider.finish(0, text: "Late output belongs to an abandoned chat.")
        XCTAssertNil(vm.liveAnswerQuestionAnchor)
        XCTAssertNil(vm.liveAnswerSnapshotDate)
        XCTAssertFalse(vm.liveAnswerConversationMovedOn)
        XCTAssertFalse(vm.canUpdateLiveAnswer)
        XCTAssertTrue(vm.messages.isEmpty)
    }

    private func nowBody(_ messages: [ChatMessage]) -> String {
        let payload = messages.last?.content ?? ""
        guard let start = payload.range(of: "<now_focus"),
            let end = payload.range(of: "</now_focus>", range: start.upperBound..<payload.endIndex)
        else { return "" }
        return String(payload[start.lowerBound..<end.upperBound])
    }

    private func makeVM(_ projection: RefreshProjection, _ provider: RefreshStreamCapture) -> TranscriptChatViewModel {
        let vm = TranscriptChatViewModel()
        vm.configure(llmService: nil, transcriptText: projection.transcript)
        vm.configureDirectLiveAnswers(
            prepareTranscript: {}, stream: { provider.stream($0) },
            focusSourceProvider: { projection.focus }, nowSourceProvider: { projection.now })
        return vm
    }

    private func wait(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        let ready = await condition()
        XCTAssertTrue(ready)
    }
}
