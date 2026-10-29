import XCTest
@testable import MacParakeetCore

private enum MemoryFixtureError: Error { case requestedFailure, malformedInput }

private struct MemoryFixtureInput: Sendable {
    let prior: String
    let source: String
    let start: Int
    let end: Int
    let frontier: Int
    init(_ messages: [ChatMessage]) throws {
        guard let content = messages.last?.content,
            let object = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
            let prior = object["prior_memory"] as? String, let source = object["source_chunk"] as? String,
            let start = object["source_start_character"] as? Int, let end = object["source_end_character"] as? Int,
            let frontier = object["new_coverage_starts_at_character"] as? Int
        else { throw MemoryFixtureError.malformedInput }
        self.prior = prior; self.source = source; self.start = start; self.end = end; self.frontier = frontier
    }
}

private actor MemoryFixtureRecorder {
    var inputs: [MemoryFixtureInput] = []
    var progress: [LiveMeetingMemoryProgress] = []
    let label: String
    let failAt: Int?
    let invalidAt: Int?
    let invalidOutput: String
    init(label: String = "Memory", failAt: Int? = nil, invalidAt: Int? = nil, invalidOutput: String = "") {
        self.label = label; self.failAt = failAt; self.invalidAt = invalidAt; self.invalidOutput = invalidOutput
    }
    func record(_ messages: [ChatMessage]) throws -> Int {
        inputs.append(try MemoryFixtureInput(messages))
        return inputs.count
    }
    func summarize(_ messages: [ChatMessage]) throws -> String {
        let number = try record(messages)
        if failAt == number { throw MemoryFixtureError.requestedFailure }
        if invalidAt == number { return invalidOutput }
        return "\(label)\(number)"
    }
    func recordProgress(_ value: LiveMeetingMemoryProgress) { progress.append(value) }
}

private actor MemoryFixtureGate {
    var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { waiter = $0 } }
    func open() { waiter?.resume(); waiter = nil }
}

@MainActor
final class LiveMeetingMemoryTests: XCTestCase {
    private func smallMemory(excerpts: Int = 120) -> LiveMeetingMemory {
        LiveMeetingMemory(
            limits: .init(recent: 12, fullRaw: 16, chunk: 20, summary: 100, excerpts: excerpts, overlap: 4))
    }
    private func waitUntil(_ check: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await check()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        let ready = await check(); XCTAssertTrue(ready)
    }

    func testUpTo16000CharactersAreEntirelyRawWithNoCloudCall() async throws {
        let memory = LiveMeetingMemory()
        let recorder = MemoryFixtureRecorder()
        let text = String(repeating: "x", count: 16_000)
        let snapshot = try await memory.prepare(
            transcript: text, question: "What happened?",
            summarize: {
                try await recorder.summarize($0)
            })
        XCTAssertEqual(snapshot.recentTranscript, text)
        XCTAssertEqual(snapshot.earlierSummary, "")
        XCTAssertEqual(snapshot.coverage.mode, .fullRaw)
        XCTAssertEqual(snapshot.coverage.coveredCharacters, text.count)
        XCTAssertTrue(snapshot.coverage.allSourceProcessed)
        let inputs = await recorder.inputs; XCTAssertTrue(inputs.isEmpty)
    }

    func testEveryOlderCharacterIncludingOrdinaryLinesAndUnicodeIsProcessedInBoundedChunks() async throws {
        let older = String(repeating: "Ordinary discussion 🧑🏽‍💻 Café e\u{301} with no special marker.\n", count: 1_200)
        let recent = String(repeating: "R", count: 12_000)
        let memory = LiveMeetingMemory()
        let recorder = MemoryFixtureRecorder()
        let snapshot = try await memory.prepare(
            transcript: older + recent, question: "What was discussed?",
            summarize: { try await recorder.summarize($0) },
            progress: { await recorder.recordProgress($0) })
        let inputs = await recorder.inputs
        let characters = Array(older)
        var frontier = 0
        var reconstructed = ""
        for input in inputs {
            XCTAssertEqual(input.frontier, frontier)
            XCTAssertLessThanOrEqual(input.source.count, 16_000)
            XCTAssertEqual(input.source, String(characters[input.start..<input.end]))
            XCTAssertLessThanOrEqual(input.frontier - input.start, 800)
            reconstructed += String(Array(input.source).dropFirst(input.frontier - input.start))
            frontier = input.end
        }
        XCTAssertGreaterThan(inputs.count, 2)
        XCTAssertEqual(reconstructed, older)
        XCTAssertEqual(frontier, older.count)
        XCTAssertEqual(snapshot.recentTranscript, recent)
        XCTAssertEqual(snapshot.coverage.summarizedCharacters, older.count)
        XCTAssertTrue(snapshot.coverage.allSourceProcessed)
        let progress = await recorder.progress
        XCTAssertEqual(progress.last, .init(coveredCharacters: older.count, totalCharacters: older.count))
    }

    func testBackgroundUpdateSummarizesEntireShortSnapshotAndAskKeepsRawPlusReadySummary() async throws {
        let memory = LiveMeetingMemory()
        let recorder = MemoryFixtureRecorder()
        let text = "Maya: The budget is pending approval."
        let covered = try await memory.update(
            transcript: text, cacheKey: "fixed-session",
            summarize: {
                try await recorder.summarize($0)
            })
        XCTAssertEqual(covered.summarizedCharacters, text.count)
        XCTAssertEqual(covered.rawCharacters, 0)
        let snapshot = try await memory.prepare(
            transcript: text, question: "Budget?", cacheKey: "fixed-session",
            summarize: {
                try await recorder.summarize($0)
            })
        XCTAssertEqual(snapshot.recentTranscript, text)
        XCTAssertEqual(snapshot.earlierSummary, "Memory1")
        XCTAssertEqual(snapshot.coverage.overlapCharacters, text.count)
        XCTAssertEqual(snapshot.coverage.coveredCharacters, text.count)
        let inputs = await recorder.inputs; XCTAssertEqual(inputs.count, 1)
    }

    func testAppendOnlyUpdatesResumeFrontierAndIdenticalSnapshotUsesCache() async throws {
        let memory = smallMemory()
        let recorder = MemoryFixtureRecorder()
        let initial = String(repeating: "a", count: 45)
        _ = try await memory.update(transcript: initial, cacheKey: "A", summarize: { try await recorder.summarize($0) })
        let before = await recorder.inputs
        let appended = initial + "bcd"
        _ = try await memory.update(
            transcript: appended, cacheKey: "A", summarize: { try await recorder.summarize($0) })
        let after = await recorder.inputs
        XCTAssertEqual(after.count, before.count + 1)
        XCTAssertEqual(after.last?.frontier, initial.count)
        XCTAssertEqual(after.last?.prior, "Memory\(before.count)")
        let coverage = try await memory.update(
            transcript: appended, cacheKey: "A", summarize: { try await recorder.summarize($0) })
        let unchanged = await recorder.inputs
        XCTAssertEqual(unchanged.count, after.count)
        XCTAssertEqual(coverage.summarizedCharacters, appended.count)
        XCTAssertTrue(coverage.allSourceProcessed)
    }

    func testAskUsesCachedPrefixAndFullUncoveredTailWithoutGapOrNewSummaryCall() async throws {
        let memory = smallMemory()
        let recorder = MemoryFixtureRecorder()
        let initial = String(repeating: "a", count: 45)
        _ = try await memory.update(transcript: initial, summarize: { try await recorder.summarize($0) })
        let count = await recorder.inputs.count
        let text = initial + "newtail"
        let snapshot = try await memory.prepare(
            transcript: text, question: "Tail?", summarize: { try await recorder.summarize($0) })
        let after = await recorder.inputs.count
        XCTAssertEqual(after, count)
        XCTAssertEqual(snapshot.recentTranscript, String(text.suffix(12)))
        XCTAssertEqual(snapshot.coverage.summarizedCharacters, initial.count)
        XCTAssertEqual(snapshot.coverage.overlapCharacters, 5)
        XCTAssertEqual(snapshot.coverage.coveredCharacters, text.count)
        XCTAssertTrue(snapshot.coverage.allSourceProcessed)
    }

    func testAskCatchesOnlyMiddleGapWhenUncoveredTailExceedsRecentLimit() async throws {
        let memory = smallMemory()
        let recorder = MemoryFixtureRecorder()
        let initial = String(repeating: "a", count: 45)
        _ = try await memory.update(transcript: initial, summarize: { try await recorder.summarize($0) })
        let before = await recorder.inputs.count
        let text = initial + String(repeating: "b", count: 15)
        let snapshot = try await memory.prepare(
            transcript: text, question: "Tail?", summarize: { try await recorder.summarize($0) })
        let inputs = await recorder.inputs
        XCTAssertEqual(inputs.count, before + 1)
        XCTAssertEqual(inputs.last?.frontier, 45)
        XCTAssertEqual(inputs.last?.end, 48)
        XCTAssertEqual(snapshot.coverage.summarizedCharacters, 48)
        XCTAssertEqual(snapshot.coverage.rawCharacters, 12)
        XCTAssertEqual(snapshot.coverage.overlapCharacters, 0)
        XCTAssertTrue(snapshot.coverage.allSourceProcessed)
    }

    func testSameLengthSourceCorrectionInvalidatesCachedSummary() async throws {
        let memory = smallMemory()
        let recorder = MemoryFixtureRecorder()
        let original = String(repeating: "a", count: 50)
        _ = try await memory.update(transcript: original, summarize: { try await recorder.summarize($0) })
        let before = await recorder.inputs.count
        let corrected = "Z" + original.dropFirst()
        _ = try await memory.update(transcript: corrected, summarize: { try await recorder.summarize($0) })
        let inputs = await recorder.inputs
        XCTAssertEqual(inputs[before].frontier, 0)
        XCTAssertEqual(inputs[before].prior, "")
        XCTAssertTrue(inputs[before].source.hasPrefix("Z"))
    }

    func testProviderPolicyCacheKeyChangeInvalidatesSameSource() async throws {
        let memory = smallMemory()
        let recorder = MemoryFixtureRecorder()
        let text = String(repeating: "a", count: 45)
        _ = try await memory.update(
            transcript: text, cacheKey: "account-model-policy-A", summarize: { try await recorder.summarize($0) })
        let before = await recorder.inputs.count
        _ = try await memory.update(
            transcript: text, cacheKey: "account-model-policy-B", summarize: { try await recorder.summarize($0) })
        let inputs = await recorder.inputs
        XCTAssertEqual(inputs[before].frontier, 0)
        XCTAssertEqual(inputs[before].prior, "")
    }

    func testFailureEmptyAndOversizedOutputsRetainOnlyCompletedCheckpoint() async throws {
        for failure in 0..<3 {
            let memory = smallMemory()
            let first = MemoryFixtureRecorder(
                failAt: failure == 0 ? 2 : nil, invalidAt: failure == 0 ? nil : 2,
                invalidOutput: failure == 1 ? " ... \n" : String(repeating: "x", count: 101))
            let text = String(repeating: "a", count: 60)
            do {
                _ = try await memory.update(transcript: text, summarize: { try await first.summarize($0) })
                XCTFail("Incomplete memory must not claim full requested coverage")
            } catch {}
            let retry = MemoryFixtureRecorder(label: "Retry")
            let covered = try await memory.update(transcript: text, summarize: { try await retry.summarize($0) })
            let inputs = await retry.inputs
            XCTAssertEqual(inputs.first?.frontier, 20)
            XCTAssertEqual(inputs.first?.prior, "Memory1")
            XCTAssertTrue(covered.allSourceProcessed)
        }
    }

    func testCancellationDuringModelAwaitNeverCommitsCancelledChunk() async throws {
        let memory = smallMemory()
        let gate = MemoryFixtureGate()
        let text = String(repeating: "a", count: 45)
        let task = Task {
            try await memory.update(
                transcript: text,
                summarize: { _ in
                    await gate.wait(); return "Cancelled memory"
                })
        }
        try await waitUntil { await gate.entered }
        task.cancel(); await gate.open()
        do { _ = try await task.value; XCTFail("Cancelled generation must throw") } catch is CancellationError {} catch
        { XCTFail("Unexpected error") }
        let retry = MemoryFixtureRecorder()
        _ = try await memory.update(transcript: text, summarize: { try await retry.summarize($0) })
        let inputs = await retry.inputs
        XCTAssertEqual(inputs.first?.frontier, 0)
        XCTAssertEqual(inputs.first?.prior, "")
    }

    func testResetInvalidatesInFlightSummaryAndClearsPreviousScope() async throws {
        let memory = smallMemory()
        let gate = MemoryFixtureGate()
        let text = String(repeating: "a", count: 45)
        let task = Task {
            try await memory.update(
                transcript: text,
                summarize: { _ in
                    await gate.wait(); return "Old meeting memory"
                })
        }
        try await waitUntil { await gate.entered }
        await memory.reset(); await gate.open()
        do { _ = try await task.value; XCTFail("Reset must invalidate publication") } catch is CancellationError {
        } catch { XCTFail("Unexpected error") }
        let recorder = MemoryFixtureRecorder()
        _ = try await memory.update(transcript: text, summarize: { try await recorder.summarize($0) })
        let inputs = await recorder.inputs
        XCTAssertEqual(inputs.first?.frontier, 0)
    }

    func testForegroundPreemptsBackgroundButKeepsCompletedPrefix() async throws {
        let memory = smallMemory()
        let gate = MemoryFixtureGate()
        let background = MemoryFixtureRecorder(label: "Background")
        let text = String(repeating: "a", count: 60)
        let task = Task {
            try await memory.update(
                transcript: text,
                summarize: { messages in
                    let number = try await background.record(messages)
                    if number == 2 { await gate.wait(); return "Late background memory" }
                    return "Background\(number)"
                })
        }
        try await waitUntil { await gate.entered }
        let foreground = MemoryFixtureRecorder(label: "Ask")
        let snapshot = try await memory.prepare(
            transcript: text, question: "Current question", summarize: { try await foreground.summarize($0) })
        let inputs = await foreground.inputs
        XCTAssertEqual(inputs.first?.frontier, 20)
        XCTAssertEqual(inputs.first?.prior, "Background1")
        await gate.open()
        do { _ = try await task.value; XCTFail("Superseded background cannot publish") } catch is CancellationError {
        } catch { XCTFail("Unexpected error") }
        let calls = await foreground.inputs.count
        let again = try await memory.prepare(
            transcript: text, question: "Another question", summarize: { try await foreground.summarize($0) })
        let after = await foreground.inputs.count
        XCTAssertEqual(after, calls)
        XCTAssertEqual(again.earlierSummary, snapshot.earlierSummary)
        XCTAssertTrue(again.coverage.allSourceProcessed)
    }

    func testBackgroundCannotSupersedeAnActiveAsk() async throws {
        let memory = smallMemory()
        let gate = MemoryFixtureGate()
        let foreground = MemoryFixtureRecorder()
        let background = MemoryFixtureRecorder()
        let text = String(repeating: "a", count: 60)
        let task = Task {
            try await memory.prepare(
                transcript: text, question: "Current question",
                summarize: { messages in
                    let number = try await foreground.record(messages)
                    if number == 1 { await gate.wait() }
                    return "Ask\(number)"
                })
        }
        try await waitUntil { await gate.entered }
        do {
            _ = try await memory.update(transcript: text, summarize: { try await background.summarize($0) })
            XCTFail("Timer must defer while foreground work owns the memory")
        } catch { XCTAssertEqual(error as? LiveMeetingMemoryError, .backgroundDeferred) }
        await gate.open()
        let snapshot = try await task.value
        XCTAssertTrue(snapshot.coverage.allSourceProcessed)
        let inputs = await background.inputs; XCTAssertTrue(inputs.isEmpty)
    }

    func testQuestionSpecificExactOlderQuotesRecomputeWithoutSummaryCalls() async throws {
        let limits = LiveMeetingMemory.Limits(
            recent: 12, fullRaw: 16, chunk: 200, summary: 100, excerpts: 120, overlap: 20)
        let memory = LiveMeetingMemory(limits: limits)
        let recorder = MemoryFixtureRecorder()
        let zephyr = "[00:03] Maya: Zephyr ceiling is $45,000, not $50,000.\n"
        let cobalt = "[22:10] Liam: Cobalt ceiling is $72,000, pending approval.\n"
        let older =
            zephyr + String(repeating: "Ordinary discussion.\n", count: 70) + cobalt
            + String(repeating: "More ordinary discussion.\n", count: 70)
        let text = older + String(repeating: "R", count: 12)
        let first = try await memory.prepare(
            transcript: text, question: "Zephyr ceiling", summarize: { try await recorder.summarize($0) })
        let calls = await recorder.inputs.count
        let second = try await memory.prepare(
            transcript: text, question: "Cobalt ceiling", summarize: { try await recorder.summarize($0) })
        let after = await recorder.inputs.count
        XCTAssertEqual(after, calls)
        XCTAssertTrue(first.questionExcerpts.contains(zephyr.trimmingCharacters(in: .newlines)))
        XCTAssertTrue(second.questionExcerpts.contains(cobalt.trimmingCharacters(in: .newlines)))
        XCTAssertNotEqual(first.questionExcerpts, second.questionExcerpts)
        XCTAssertLessThanOrEqual(first.questionExcerpts.count, 120)
        XCTAssertLessThanOrEqual(second.questionExcerpts.count, 120)
    }

    func testStreamSessionPreservesOpaqueKeyAndInjectedStream() async throws {
        let session = LiveAnswerStreamSession(cacheKey: "fixed-provider-policy") { _ in
            AsyncThrowingStream { continuation in
                continuation.yield("Completed answer."); continuation.finish()
            }
        }
        var text = ""
        for try await delta in session.stream(messages: [ChatMessage(role: .user, content: "Synthetic question")]) {
            text += delta
        }
        XCTAssertEqual(session.cacheKey, "fixed-provider-policy")
        XCTAssertEqual(text, "Completed answer.")
    }
}
