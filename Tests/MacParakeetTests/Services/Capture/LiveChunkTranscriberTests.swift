import XCTest
@testable import MacParakeetCore

final class LiveChunkTranscriberTests: XCTestCase {
    func testOldFailureCallbackCannotSkipTheNewSessionsFirstChunk() async throws {
        let submitted = expectation(description: "three requests submitted")
        submitted.expectedFulfillmentCount = 3
        let oldFailureEntered = expectation(description: "old failure callback suspended")
        let prematureResult = expectation(description: "new successor must wait for its own first chunk")
        prematureResult.isInverted = true
        let hold = LiveFailureEventHold()
        let fixture = try await makeFixture { _ in submitted.fulfill() }
        addTeardownBlock { await hold.release() }
        await fixture.transcriber.startSession(
            .init(id: UUID(), chunkFolderURL: fixture.folder, speechEngine: .init(engine: .parakeet))
        ) { event in
            if case .transcriptionFailed = event {
                oldFailureEntered.fulfill()
                await hold.wait()
            }
        }
        await fixture.transcriber.enqueue(chunk: chunk(0), source: .system)
        // Synchronize the first request without consuming the 3-count expectation.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await fixture.client.hasPending("system-0-100.wav")), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        guard await fixture.client.hasPending("system-0-100.wav") else {
            return XCTFail("First recognition did not start")
        }
        await fixture.client.complete("system-0-100.wav", with: .failure(STTError.transcriptionFailed("old failure")))
        await fulfillment(of: [oldFailureEntered], timeout: 5)
        await fixture.transcriber.finishSession()
        await fixture.transcriber.startSession(
            .init(id: UUID(), chunkFolderURL: fixture.folder, speechEngine: .init(engine: .parakeet))
        ) { event in
            await fixture.events.record(event)
            if case .orderedResults = event, !(await hold.hasReleasedFirstNewChunk) {
                prematureResult.fulfill()
            }
        }
        await fixture.transcriber.enqueue(chunk: chunk(0), source: .system)
        await fixture.transcriber.enqueue(chunk: chunk(1), source: .system)
        await fulfillment(of: [submitted], timeout: 5)
        await fixture.client.complete("system-100-200.wav", with: .success(STTResult(text: "second")))
        await hold.release()
        await fulfillment(of: [prematureResult], timeout: 0.3)
        await hold.allowFirstNewChunk()
        await fixture.client.complete("system-0-100.wav", with: .success(STTResult(text: "first")))
        await assertDrained(fixture.transcriber)
        let events = await fixture.events.snapshot()
        XCTAssertEqual(events.results.map(\.text), ["first", "second"])
    }

    func testLiveAnswerDrainTimeoutLeavesRecognitionOwnedAndRecordingWorkIntact() async throws {
        let submitted = expectation(description: "held recognition submitted")
        let fixture = try await makeFixture { _ in submitted.fulfill() }
        await fixture.transcriber.enqueue(chunk: chunk(0), source: .system)
        await fulfillment(of: [submitted], timeout: 5)
        let timedOut = try await fixture.transcriber.waitForCurrentTasksToDrain(timeout: .milliseconds(20))
        XCTAssertFalse(timedOut)
        await fixture.client.complete("system-0-100.wav", with: .success(STTResult(text: "final word")))
        let drained = try await fixture.transcriber.waitForCurrentTasksToDrain(timeout: .seconds(1))
        XCTAssertTrue(drained)
        let events = await fixture.events.snapshot()
        XCTAssertEqual(events.results.map(\.text), ["final word"])
        try assertNoChunkFiles(fixture)
    }

    func testIndividuallyCancelledChunkDoesNotBlockLaterResults() async throws {
        let first = expectation(description: "first chunk submitted")
        let later = expectation(description: "later chunks submitted")
        later.expectedFulfillmentCount = 2
        let fixture = try await makeFixture { name in
            if name == "system-0-100.wav" { first.fulfill() } else { later.fulfill() }
        }
        await fixture.transcriber.enqueue(chunk: chunk(0), source: .system)
        await fulfillment(of: [first], timeout: 5)
        await fixture.client.complete("system-0-100.wav", with: .failure(CancellationError()))
        await assertDrained(fixture.transcriber)

        await fixture.transcriber.enqueue(chunk: chunk(1), source: .system)
        await fixture.transcriber.enqueue(chunk: chunk(2), source: .system)
        await fulfillment(of: [later], timeout: 5)
        await fixture.client.complete("system-200-300.wav", with: .success(STTResult(text: "second")))
        await fixture.client.complete("system-100-200.wav", with: .success(STTResult(text: "first")))
        await assertDrained(fixture.transcriber)

        let events = await fixture.events.snapshot()
        XCTAssertEqual(events.results.map(\.startMs), [100, 200])
        XCTAssertEqual(events.results.map(\.text), ["first", "second"])
        XCTAssertEqual(events.failures, 0)
        XCTAssertEqual(events.drops, 0)
        try assertNoChunkFiles(fixture)
    }

    func testCancellationUnblocksSuccessorsWithoutAffectingOtherSource() async throws {
        let submitted = expectation(description: "both sources submitted")
        submitted.expectedFulfillmentCount = 3
        let fixture = try await makeFixture { _ in submitted.fulfill() }
        await fixture.transcriber.enqueue(chunk: chunk(0), source: .microphone)
        await fixture.transcriber.enqueue(chunk: chunk(1), source: .microphone)
        await fixture.transcriber.enqueue(chunk: chunk(0), source: .system)
        await fulfillment(of: [submitted], timeout: 5)

        await fixture.client.complete("microphone-100-200.wav", with: .success(STTResult(text: "mic")))
        await fixture.client.complete("system-0-100.wav", with: .success(STTResult(text: "system")))
        await fixture.client.complete("microphone-0-100.wav", with: .failure(CancellationError()))
        await assertDrained(fixture.transcriber)

        let events = await fixture.events.snapshot()
        XCTAssertEqual(events.results.filter { $0.source == .microphone }.map(\.text), ["mic"])
        XCTAssertEqual(events.results.filter { $0.source == .system }.map(\.text), ["system"])
        XCTAssertEqual(events.failures, 0)
        XCTAssertEqual(events.drops, 0)
        try assertNoChunkFiles(fixture)
    }

    func testOrdinaryFailureAndBackpressureStillReportAndUnblock() async throws {
        for backpressure in [false, true] {
            let submitted = expectation(description: "failed and succeeding chunks submitted")
            submitted.expectedFulfillmentCount = 2
            let fixture = try await makeFixture { _ in submitted.fulfill() }
            await fixture.transcriber.enqueue(chunk: chunk(0), source: .system)
            await fixture.transcriber.enqueue(chunk: chunk(1), source: .system)
            await fulfillment(of: [submitted], timeout: 5)
            let error: any Error =
                backpressure
                ? STTSchedulerError.droppedDueToBackpressure(job: .meetingLiveChunk)
                : STTError.transcriptionFailed("injected failure")
            await fixture.client.complete("system-100-200.wav", with: .success(STTResult(text: "next")))
            await fixture.client.complete("system-0-100.wav", with: .failure(error))
            await assertDrained(fixture.transcriber)

            let events = await fixture.events.snapshot()
            XCTAssertEqual(events.results.map(\.text), ["next"])
            XCTAssertEqual(events.failures, backpressure ? 0 : 1)
            XCTAssertEqual(events.drops, backpressure ? 1 : 0)
            try assertNoChunkFiles(fixture)
        }
    }

    func testSessionCancellationDoesNotFlushBufferedPreview() async throws {
        let submitted = expectation(description: "chunks submitted before Stop")
        submitted.expectedFulfillmentCount = 2
        let cancelled = expectation(description: "Stop cancelled the held chunk task")
        let fixture = try await makeFixture(
            onRequest: { _ in submitted.fulfill() },
            onCancellation: { name in
                if name == "system-0-100.wav" { cancelled.fulfill() }
            }
        )
        await fixture.transcriber.enqueue(chunk: chunk(0), source: .system)
        await fixture.transcriber.enqueue(chunk: chunk(1), source: .system)
        await fulfillment(of: [submitted], timeout: 5)
        await fixture.client.complete("system-100-200.wav", with: .success(STTResult(text: "discard")))

        let stop = Task { await fixture.transcriber.cancelPendingTasks(waitForCancellation: true) }
        await fulfillment(of: [cancelled], timeout: 5)
        await fixture.client.complete("system-0-100.wav", with: .failure(CancellationError()))
        await stop.value

        let events = await fixture.events.snapshot()
        XCTAssertTrue(events.results.isEmpty, "Stop must not deliver buffered preview while cancelling its tasks")
        XCTAssertEqual(events.failures, 0)
        XCTAssertEqual(events.drops, 0)
        await fixture.transcriber.finishSession()
        try assertNoChunkFiles(fixture)
    }

    func testRestartIgnoresLateSuccessAndCancellationFromPreviousSession() async throws {
        for oldSucceeds in [true, false] {
            let oldRequest = expectation(description: "old session submitted")
            let newRequest = expectation(description: "new session submitted")
            let cancelled = expectation(description: "old task cancellation observed")
            let fixture = try await makeFixture(
                onRequest: { name in
                    if name == "system-0-100.wav" { oldRequest.fulfill() } else { newRequest.fulfill() }
                },
                onCancellation: { name in
                    if name == "system-0-100.wav" { cancelled.fulfill() }
                }
            )
            await fixture.transcriber.enqueue(chunk: chunk(0), source: .system)
            await fulfillment(of: [oldRequest], timeout: 5)
            // Keep an explicit join on the old task even after finishSession clears
            // its pending list. The backend deliberately ignores cancellation.
            let oldDrain = Task { await fixture.transcriber.cancelPendingTasks(waitForCancellation: true) }
            await fulfillment(of: [cancelled], timeout: 5)
            await fixture.transcriber.finishSession()
            let newEvents = LiveChunkEventRecorder()
            await fixture.transcriber.startSession(
                .init(id: UUID(), chunkFolderURL: fixture.folder, speechEngine: .init(engine: .parakeet))
            ) { event in
                await newEvents.record(event)
            }

            let oldResult: Result<STTResult, any Error> =
                oldSucceeds
                ? .success(STTResult(text: "obsolete")) : .failure(CancellationError())
            await fixture.client.complete("system-0-100.wav", with: oldResult)
            await oldDrain.value
            // This is sequence zero in the replacement session, despite its later timestamp.
            await fixture.transcriber.enqueue(chunk: chunk(1), source: .system)
            await fulfillment(of: [newRequest], timeout: 5)
            await fixture.client.complete("system-100-200.wav", with: .success(STTResult(text: "new session")))
            await assertDrained(fixture.transcriber)

            let old = await fixture.events.snapshot()
            let new = await newEvents.snapshot()
            XCTAssertTrue(old.results.isEmpty)
            XCTAssertEqual(new.results.map(\.text), ["new session"])
            XCTAssertEqual(new.failures, 0)
            XCTAssertEqual(new.drops, 0)
            try assertNoChunkFiles(fixture)
        }
    }

    private func chunk(_ index: Int) -> AudioChunker.AudioChunk {
        .init(samples: [Float](repeating: 0.1, count: 1_600), startMs: index * 100, endMs: (index + 1) * 100)
    }

    private func assertDrained(
        _ transcriber: LiveChunkTranscriber, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let drained = await transcriber.waitForPendingTasksToDrain(timeout: .seconds(5))
        XCTAssertTrue(drained, "Live tasks did not drain", file: file, line: line)
    }

    private struct Fixture: Sendable {
        let transcriber: LiveChunkTranscriber
        let client: ControlledLiveChunkSTT
        let events: LiveChunkEventRecorder
        let folder: URL
    }

    private func makeFixture(
        onRequest: @escaping @Sendable (String) -> Void,
        onCancellation: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LiveChunkTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let client = ControlledLiveChunkSTT(onRequest: onRequest, onCancellation: onCancellation)
        let transcriber = LiveChunkTranscriber(sttTranscriber: client)
        let events = LiveChunkEventRecorder()
        await transcriber.startSession(
            .init(id: UUID(), chunkFolderURL: folder, speechEngine: .init(engine: .parakeet))
        ) { event in
            await events.record(event)
        }
        addTeardownBlock {
            await client.shutdown()
            await transcriber.cancelPendingTasks(waitForCancellation: true)
            await transcriber.finishSession()
            try FileManager.default.removeItem(at: folder)
        }
        return Fixture(transcriber: transcriber, client: client, events: events, folder: folder)
    }

    private func assertNoChunkFiles(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path).isEmpty,
            "Temporary live WAVs must be cleaned up", file: file, line: line
        )
    }
}

/// Holds each STT request until the test releases it, even if its task was cancelled.
/// Cancellation observation synchronizes Stop/restart tests without timing sleeps.
private actor ControlledLiveChunkSTT: SpeechEngineRoutedTranscribing {
    private let onRequest: @Sendable (String) -> Void
    private let onCancellation: @Sendable (String) -> Void
    private var pending: [String: CheckedContinuation<STTResult, any Error>] = [:]
    private var closed = false

    init(onRequest: @escaping @Sendable (String) -> Void, onCancellation: @escaping @Sendable (String) -> Void) {
        self.onRequest = onRequest
        self.onCancellation = onCancellation
    }

    func transcribe(
        audioPath: String, job: STTJobKind, onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        XCTFail("Pinned meeting chunks must use the routed transcriber")
        throw CancellationError()
    }

    func transcribe(
        audioPath: String, job: STTJobKind, speechEngine: SpeechEngineSelection,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        XCTAssertEqual(job, .meetingLiveChunk)
        XCTAssertEqual(speechEngine, .init(engine: .parakeet))
        guard !closed else { throw CancellationError() }
        let name = URL(fileURLWithPath: audioPath).lastPathComponent
        let onCancellation = self.onCancellation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[name] = continuation
                onRequest(name)
            }
        } onCancel: {
            onCancellation(name)
        }
    }

    func complete(_ name: String, with result: Result<STTResult, any Error>) {
        guard let continuation = pending.removeValue(forKey: name) else {
            XCTFail("No pending request for \(name)")
            return
        }
        continuation.resume(with: result)
    }

    func hasPending(_ name: String) -> Bool { pending[name] != nil }

    func shutdown() {
        closed = true
        let continuations = pending.values
        pending = [:]
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }
}

private actor LiveFailureEventHold {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var hasReleasedFirstNewChunk = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
    func allowFirstNewChunk() { hasReleasedFirstNewChunk = true }
}

private actor LiveChunkEventRecorder {
    struct Entry: Sendable {
        let source: AudioSource
        let startMs: Int
        let text: String
    }

    struct Snapshot: Sendable {
        var results: [Entry] = []
        var failures = 0
        var drops = 0
    }

    private var value = Snapshot()

    func record(_ event: LiveChunkTranscriber.Event) {
        switch event {
        case .orderedResults(let results):
            value.results.append(
                contentsOf: results.map {
                    Entry(source: $0.source, startMs: $0.chunk.startMs, text: $0.result.text)
                })
        case .transcriptionFailed: value.failures += 1
        case .backpressureDrop: value.drops += 1
        case .previewLoss: break
        }
    }

    func snapshot() -> Snapshot { value }
}
