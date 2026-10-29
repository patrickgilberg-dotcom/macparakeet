import Foundation
import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

private actor ProjectVMGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

private actor ProjectVMSource {
    private var source: LiveProjectMeetingSource?
    private var nextGate: ProjectVMGate?
    var delayedLoadReturned = false
    init(_ source: LiveProjectMeetingSource?) { self.source = source }
    func set(_ source: LiveProjectMeetingSource?) { self.source = source }
    func holdNextLoad(_ gate: ProjectVMGate) { nextGate = gate }
    func load() async -> LiveProjectMeetingSource? {
        let captured = source
        if let gate = nextGate {
            nextGate = nil
            await gate.wait()
            delayedLoadReturned = true
        }
        return captured
    }
}

private actor ProjectVMProvider {
    var requests: [[ChatMessage]] = []
    var answers: [[ChatMessage]] = []
    private var terminalHook: (@Sendable () async -> Void)?
    func setTerminalHook(_ hook: @escaping @Sendable () async -> Void) { terminalHook = hook }
    func response(_ messages: [ChatMessage]) async -> String {
        requests.append(messages)
        if messages.first?.content.contains("Maintain a factual rolling memory") == true {
            return "Prior semantic memory."
        }
        answers.append(messages)
        let result = "Synthetic answer \(answers.count)."
        if let terminalHook { await terminalHook() }
        return result
    }
    nonisolated func stream(_ messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(await self.response(messages))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor
final class LiveProjectContextViewModelTests: XCTestCase {
    private func source(_ label: String, state: ProjectPreviousMeeting.State = .ready) -> LiveProjectMeetingSource {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        return .init(
            project: .init(name: "Project " + label),
            previous: .init(
                transcriptionID: UUID(), title: "Previous " + label, createdAt: date, updatedAt: date,
                state: state, effectiveTranscript: "\(label)_PRIVATE_PRIOR_CONTEXT: Finance approval is pending.",
                sourceHash: "synthetic-" + label))
    }

    private func makeVM(_ provider: ProjectVMProvider) -> TranscriptChatViewModel {
        let vm = TranscriptChatViewModel()
        vm.configure(llmService: nil, transcriptText: "Current meeting: What happens next?")
        vm.configureDirectLiveAnswers(
            prepareTranscript: {},
            sessionProvider: {
                LiveAnswerStreamSession(
                    cacheKey: "synthetic-pinned-provider", stream: { messages in provider.stream(messages) })
            }, summaryRefreshInterval: .seconds(3_600))
        return vm
    }

    private func wait(_ check: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await check()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        let fulfilled = await check()
        XCTAssertTrue(fulfilled, file: file, line: line)
    }

    private func ask(_ vm: TranscriptChatViewModel, _ question: String) async throws {
        vm.inputText = question
        vm.sendMessage()
        try await wait { !vm.isStreaming }
        XCTAssertEqual(vm.liveAnswerTiming?.outcome, "completed")
    }

    func testProjectAToBThenBDoesNotRestoreOldProjectHistory() async throws {
        let provider = ProjectVMProvider()
        let vm = makeVM(provider)
        defer { vm.stopLiveMeetingMemory(); vm.cancelStreaming() }
        let sourceA = source("A")
        vm.configureLiveProjectContext(eventPreparation: "Preparation A", sourceProvider: { sourceA })
        try await wait { vm.liveProjectContextStatus == "Project context checked." }
        try await ask(vm, "Question_A_HISTORY_MARKER")

        let sourceB = source("B")
        vm.configureLiveProjectContext(eventPreparation: "Preparation B", sourceProvider: { sourceB })
        try await wait { vm.liveProjectContextStatus == "Project context checked." }
        try await ask(vm, "Question_B_FIRST")
        try await ask(vm, "Question_B_SECOND")

        let answers = await provider.answers
        XCTAssertEqual(answers.count, 3)
        XCTAssertTrue(answers[0].contains { $0.content.contains("A_PRIVATE_PRIOR_CONTEXT") })
        for request in answers.dropFirst() {
            let content = request.map(\.content).joined(separator: "\n")
            XCTAssertFalse(
                content.contains("Question_A_HISTORY_MARKER"), "Old A history must remain excluded on every B Ask")
            XCTAssertFalse(content.contains("A_PRIVATE_PRIOR_CONTEXT"))
            XCTAssertTrue(content.contains("B_PRIVATE_PRIOR_CONTEXT"))
        }
        XCTAssertTrue(
            answers[2].contains { $0.content.contains("Question_B_FIRST") }, "Current-scope history still works")
        XCTAssertTrue(
            vm.messages.contains { $0.content == "Question_A_HISTORY_MARKER" }, "Visible local chat need not be deleted"
        )
        XCTAssertEqual(vm.lastLiveProjectContext?.scopeKey, sourceB.scopeKey)
    }

    func testClearingProjectDuringPendingContextCannotSendOrPublishOldReference() async throws {
        let provider = ProjectVMProvider()
        let vm = makeVM(provider)
        defer { vm.stopLiveMeetingMemory(); vm.cancelStreaming() }
        let box = ProjectVMSource(source("A"))
        vm.configureLiveProjectContext(eventPreparation: "Preparation A", sourceProvider: { await box.load() })
        try await wait { vm.liveProjectContextStatus == "Project context checked." }
        let gate = ProjectVMGate()
        await box.holdNextLoad(gate)
        vm.inputText = "Pending A question"
        vm.sendMessage()
        try await wait { await gate.entered }

        vm.configureLiveProjectContext(eventPreparation: "No selected project", sourceProvider: nil)
        await box.set(nil)
        await gate.open()
        try await wait { await box.delayedLoadReturned }
        for _ in 0..<20 { await Task.yield() }

        let answers = await provider.answers
        XCTAssertTrue(answers.isEmpty, "Cleared project generation cannot send an old A final request")
        XCTAssertNil(vm.lastLiveProjectContext)
        XCTAssertNil(vm.liveProjectContextStatus)
        XCTAssertFalse(vm.isStreaming)
        XCTAssertEqual(vm.liveAnswerTiming?.outcome, "cancelled")
    }

    func testPrefetchOfUnreadyLatestMeetingNeverClaimsItIsReady() async throws {
        let provider = ProjectVMProvider()
        let vm = makeVM(provider)
        defer { vm.stopLiveMeetingMemory(); vm.cancelStreaming() }
        let unavailable = source("A", state: .processing)
        vm.configureLiveProjectContext(eventPreparation: "Preparation A", sourceProvider: { unavailable })
        try await wait { vm.liveProjectContextStatus == "Project context checked." }

        XCTAssertFalse(vm.liveProjectContextStatus?.lowercased().contains("ready") == true)
        let requests = await provider.requests
        XCTAssertTrue(requests.isEmpty, "A pending latest transcript cannot trigger a summary or an older fallback")
        XCTAssertNil(vm.lastLiveProjectContext)
    }

    func testLatestSourceChangeBeforeAnswerTerminalRejectsPublication() async throws {
        let provider = ProjectVMProvider()
        let vm = makeVM(provider)
        defer { vm.stopLiveMeetingMemory(); vm.cancelStreaming() }
        let first = source("A")
        let prior = try XCTUnwrap(first.previous)
        let replacement = LiveProjectMeetingSource(
            project: first.project,
            previous: .init(
                transcriptionID: prior.transcriptionID, title: prior.title, createdAt: prior.createdAt,
                updatedAt: prior.updatedAt.addingTimeInterval(1), state: .ready,
                effectiveTranscript: "A_CORRECTED_PRIOR_CONTEXT", sourceHash: "corrected", correctionRevision: 1))
        let box = ProjectVMSource(first)
        vm.configureLiveProjectContext(eventPreparation: "Preparation A", sourceProvider: { await box.load() })
        try await wait { vm.liveProjectContextStatus == "Project context checked." }
        await provider.setTerminalHook { await box.set(replacement) }

        vm.inputText = "Question while prior source changes"
        vm.sendMessage()
        try await wait { !vm.isStreaming }

        let answers = await provider.answers
        XCTAssertEqual(answers.count, 1)
        XCTAssertNil(vm.lastLiveProjectContext, "Stale source cannot become a completed reference snapshot")
        XCTAssertNil(vm.lastLiveMeetingMemory)
        XCTAssertEqual(vm.liveAnswerTiming?.outcome, "failed")
        XCTAssertTrue(vm.errorMessage?.contains("changed") == true)
        XCTAssertFalse(
            vm.messages.contains { $0.role == .assistant && !$0.isStreaming && $0.content == "Synthetic answer 1." })
    }
}
