import Foundation
import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class LiveChatCheckpointViewModelTests: XCTestCase {
    func testQuestionIsDurableBeforeDispatchAndTerminalAnswerBeforeSuccess() async throws {
        let persistence = LiveChatPersistenceProbe(blockUser: true, blockAssistant: true)
        let provider = LiveChatStreamProbe()
        let vm = makeViewModel(persistence: persistence, provider: provider)
        vm.inputText = "Synthetic question?"
        vm.sendMessage()
        try await wait { await persistence.waitingUser }
        XCTAssertEqual(provider.calls, 0)
        await persistence.releaseUser()
        try await wait { await persistence.waitingAssistant }
        XCTAssertEqual(provider.calls, 1)
        XCTAssertTrue(vm.isStreaming, "Terminal provider output is not yet durably saved")
        await persistence.releaseAssistant()
        try await wait { !vm.isStreaming }
        let snapshots = await persistence.saved
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots.map(\.messages.count), [1, 2])
        XCTAssertEqual(snapshots[0].conversationID, snapshots[1].conversationID)
        XCTAssertLessThan(snapshots[0].revision, snapshots[1].revision)
        XCTAssertEqual(vm.liveAnswerTiming?.outcome, "completed")
        XCTAssertNil(vm.liveChatPersistenceError)
        vm.stopLiveMeetingMemory()
    }

    func testUserCheckpointFailurePreventsInferenceAndFlushRetriesOnlySaving() async throws {
        let persistence = LiveChatPersistenceProbe(failUser: true)
        let provider = LiveChatStreamProbe()
        let vm = makeViewModel(persistence: persistence, provider: provider)
        vm.inputText = "Keep my question."
        vm.sendMessage()
        try await wait { !vm.isStreaming }
        XCTAssertEqual(provider.calls, 0)
        XCTAssertNotNil(vm.liveChatPersistenceError)
        XCTAssertEqual(vm.messages.map(\.role), [.user])
        await persistence.setFailures(user: false, assistant: false)
        try await vm.flushLiveChatCheckpoint()
        let saved = await persistence.saved
        XCTAssertEqual(saved.last?.messages.map(\.role), [.user])
        XCTAssertEqual(provider.calls, 0, "A save retry must not issue inference")
        vm.stopLiveMeetingMemory()
    }

    func testCompletedAnswerSurvivesCheckpointFailureWithoutCloudReplay() async throws {
        let persistence = LiveChatPersistenceProbe(failAssistant: true)
        let provider = LiveChatStreamProbe()
        let vm = makeViewModel(persistence: persistence, provider: provider)
        vm.inputText = "Synthetic question?"
        vm.sendMessage()
        try await wait { !vm.isStreaming }
        XCTAssertEqual(vm.messages.last?.content, "Synthetic completed answer.")
        XCTAssertEqual(vm.liveAnswerTiming?.outcome, "completed")
        XCTAssertNotNil(vm.liveChatPersistenceError)
        do { try await vm.flushLiveChatCheckpoint(); XCTFail("Persistent local failure should be visible") } catch {}
        await persistence.setFailures(user: false, assistant: false)
        try await vm.flushLiveChatCheckpoint()
        let saved = await persistence.saved
        XCTAssertEqual(saved.last?.messages.count, 2)
        XCTAssertEqual(provider.calls, 1)
        XCTAssertNil(vm.liveChatPersistenceError)
        vm.stopLiveMeetingMemory()
    }

    func testPartialFailureNeverCheckpointsAnAssistantAsCompleted() async throws {
        let persistence = LiveChatPersistenceProbe()
        let provider = LiveChatStreamProbe(failPartial: true)
        let vm = makeViewModel(persistence: persistence, provider: provider)
        vm.inputText = "Synthetic question?"
        vm.sendMessage()
        try await wait { !vm.isStreaming }
        try await vm.flushLiveChatCheckpoint()
        let saved = await persistence.saved
        XCTAssertTrue(saved.allSatisfy { $0.messages.allSatisfy { $0.role == .user } })
        XCTAssertTrue(vm.messages.last?.content.contains("[Incomplete response]") == true)
        XCTAssertEqual(vm.liveAnswerTiming?.outcome, "failed")
        vm.stopLiveMeetingMemory()
    }

    func testCancelDuringTerminalSaveRollsBackAssistantCheckpoint() async throws {
        let persistence = LiveChatPersistenceProbe(blockAssistant: true)
        let provider = LiveChatStreamProbe()
        let vm = makeViewModel(persistence: persistence, provider: provider)
        vm.inputText = "Synthetic question?"
        vm.sendMessage()
        try await wait { await persistence.waitingAssistant }
        vm.cancelStreaming()
        let stopBoundaryFlush = Task { try await vm.flushLiveChatCheckpoint() }
        await persistence.releaseAssistant()
        try await stopBoundaryFlush.value
        let saved = await persistence.saved
        XCTAssertEqual(saved.last?.messages.map(\.role), [.user])
        XCTAssertEqual(vm.messages.map(\.role), [.user])
        XCTAssertEqual(provider.calls, 1)
        vm.stopLiveMeetingMemory()
    }

    func testClearHistoryCheckpointsEmptyStateSoRecoveryCannotResurrectIt() async throws {
        let persistence = LiveChatPersistenceProbe()
        let provider = LiveChatStreamProbe()
        let vm = makeViewModel(persistence: persistence, provider: provider)
        vm.inputText = "Synthetic question?"
        vm.sendMessage()
        try await wait { !vm.isStreaming }
        vm.clearHistory()
        try await vm.flushLiveChatCheckpoint()
        let saved = await persistence.saved
        XCTAssertEqual(saved.last?.messages, [])
        vm.stopLiveMeetingMemory()
    }

    func testFailedNormalPromotionReportsFailureAndKeepsDurableCheckpointForRecovery() async throws {
        let persistence = LiveChatPersistenceProbe()
        let provider = LiveChatStreamProbe()
        let vm = makeViewModel(persistence: persistence, provider: provider)
        vm.inputText = "Synthetic question?"
        vm.sendMessage()
        try await wait { !vm.isStreaming }
        try await vm.flushLiveChatCheckpoint()
        let promoted = vm.bindPersistedConversation(
            transcriptionId: UUID(), transcriptionRepo: MockTranscriptionRepository(),
            conversationRepo: LiveChatPromotionFailingRepository())
        XCTAssertFalse(promoted, "End must not enqueue finalization after chat promotion failed")
        XCTAssertNotNil(vm.liveChatPersistenceError)
        XCTAssertEqual(vm.messages.last?.content, "Synthetic completed answer.")
        try await vm.flushLiveChatCheckpoint()
        let saved = await persistence.saved
        XCTAssertEqual(saved.last?.messages.count, 2)
        XCTAssertEqual(provider.calls, 1)
        vm.stopLiveMeetingMemory()
    }

    private func makeViewModel(persistence: LiveChatPersistenceProbe, provider: LiveChatStreamProbe)
        -> TranscriptChatViewModel
    {
        let vm = TranscriptChatViewModel()
        vm.configure(llmService: nil, transcriptText: "Synthetic short meeting.")
        vm.configureDirectLiveAnswers(prepareTranscript: {}, stream: { _ in provider.stream() })
        vm.configureLiveChatCheckpoint(recordingID: UUID(), checkpoint: { try await persistence.save($0) })
        return vm
    }

    private func wait(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Synthetic chat checkpoint did not settle")
        throw LiveChatCheckpointTestError.failed
    }
}

private enum LiveChatCheckpointTestError: Error { case failed }

private struct LiveChatPromotionFailingRepository: ChatConversationRepositoryProtocol {
    func save(_ conversation: ChatConversation) throws { throw LiveChatCheckpointTestError.failed }
    func fetch(id: UUID) throws -> ChatConversation? { nil }
    func fetchAll(transcriptionId: UUID) throws -> [ChatConversation] { [] }
    func delete(id: UUID) throws -> Bool { false }
    func deleteAll(transcriptionId: UUID) throws {}
    func deleteEmpty(transcriptionId: UUID) throws {}
    func updateMessages(id: UUID, messages: [ChatMessage]?) throws {}
    func updateTitle(id: UUID, title: String) throws {}
    func hasConversations(transcriptionId: UUID) throws -> Bool { false }
}

private actor LiveChatPersistenceProbe {
    private var failUser: Bool
    private var failAssistant: Bool
    private let blockUser: Bool
    private let blockAssistant: Bool
    private var userGate: CheckedContinuation<Void, Never>?
    private var assistantGate: CheckedContinuation<Void, Never>?
    private(set) var waitingUser = false
    private(set) var waitingAssistant = false
    private(set) var saved: [MeetingLiveChatSnapshot] = []

    init(failUser: Bool = false, failAssistant: Bool = false, blockUser: Bool = false, blockAssistant: Bool = false) {
        self.failUser = failUser; self.failAssistant = failAssistant
        self.blockUser = blockUser; self.blockAssistant = blockAssistant
    }

    func save(_ snapshot: MeetingLiveChatSnapshot) async throws {
        let assistant = snapshot.messages.last?.role == .assistant
        if assistant && blockAssistant && !waitingAssistant {
            waitingAssistant = true
            await withCheckedContinuation { assistantGate = $0 }
        } else if !assistant && blockUser && !waitingUser {
            waitingUser = true
            await withCheckedContinuation { userGate = $0 }
        }
        if assistant ? failAssistant : failUser { throw LiveChatCheckpointTestError.failed }
        saved.append(snapshot)
    }

    func releaseUser() { userGate?.resume(); userGate = nil }
    func releaseAssistant() { assistantGate?.resume(); assistantGate = nil }
    func setFailures(user: Bool, assistant: Bool) { failUser = user; failAssistant = assistant }
}

private final class LiveChatStreamProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let failPartial: Bool
    var calls: Int { lock.withLock { count } }
    init(failPartial: Bool = false) { self.failPartial = failPartial }
    func stream() -> AsyncThrowingStream<String, Error> {
        lock.withLock { count += 1 }
        return AsyncThrowingStream { continuation in
            continuation.yield(failPartial ? "Synthetic partial answer" : "Synthetic completed answer.")
            if failPartial {
                continuation.finish(throwing: LiveChatCheckpointTestError.failed)
            } else {
                continuation.finish()
            }
        }
    }
}
