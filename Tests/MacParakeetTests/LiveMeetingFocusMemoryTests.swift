import XCTest
@testable import MacParakeetCore

private enum FocusMemoryFixtureError: Error, Equatable { case malformedInput, requestedFailure }

private struct FocusMemoryInput: Sendable {
    let isFocus: Bool
    let prior: String
    let source: String
    let start: Int
    let end: Int
    let frontier: Int
    let windowStart: Int?
    let windowEnd: Int?

    init(_ messages: [ChatMessage]) throws {
        guard let content = messages.last?.content,
            let value = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
            let source = value["source_chunk"] as? String,
            let start = value["source_start_character"] as? Int,
            let end = value["source_end_character"] as? Int,
            let frontier = value["new_coverage_starts_at_character"] as? Int
        else { throw FocusMemoryFixtureError.malformedInput }
        isFocus = value["prior_focus_summary"] != nil
        guard let prior = value[isFocus ? "prior_focus_summary" : "prior_memory"] as? String else {
            throw FocusMemoryFixtureError.malformedInput
        }
        self.prior = prior; self.source = source; self.start = start; self.end = end; self.frontier = frontier
        windowStart = value["window_start_ms"] as? Int; windowEnd = value["window_end_ms"] as? Int
    }
}

private actor FocusMemoryRecorder {
    var inputs: [FocusMemoryInput] = []
    var focusCalls = 0
    var generalCalls = 0
    private let failFocusAt: Int?
    private let invalidFocusOutput: String?

    init(failFocusAt: Int? = nil, invalidFocusOutput: String? = nil) {
        self.failFocusAt = failFocusAt; self.invalidFocusOutput = invalidFocusOutput
    }

    func summarize(_ messages: [ChatMessage]) throws -> String {
        let input = try FocusMemoryInput(messages)
        inputs.append(input)
        if input.isFocus {
            focusCalls += 1
            if failFocusAt == focusCalls { throw FocusMemoryFixtureError.requestedFailure }
            return invalidFocusOutput ?? "Recent focus \(focusCalls)"
        }
        generalCalls += 1
        return "General background \(generalCalls)"
    }
}

private actor FocusMemoryGate {
    var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { waiter = $0 } }
    func open() { waiter?.resume(); waiter = nil }
}

@MainActor
final class LiveMeetingFocusMemoryTests: XCTestCase {
    private func smallMemory() -> LiveMeetingMemory {
        LiveMeetingMemory(
            limits: .init(recent: 12, fullRaw: 16, chunk: 40, summary: 100, excerpts: 0, overlap: 4))
    }

    private func focus(_ text: String, start: Int = 0, end: Int = 180_000) -> LiveMeetingFocusSource {
        .init(transcript: text, startMs: start, endMs: end)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        let ready = await condition(); XCTAssertTrue(ready)
    }

    func testBackgroundBuildsGeneralThenIsolatedRecentSummaryAndAskUsesBothWithoutCloudCall() async throws {
        let memory = LiveMeetingMemory()
        let recorder = FocusMemoryRecorder()
        let recent = focus("Recent: approval remains pending; who can review the checklist?")
        let transcript = "Opening: The budget ceiling is $45,000.\n" + recent.transcript
        let coverage = try await memory.update(
            transcript: transcript, cacheKey: "same-provider", focusSource: recent,
            summarize: { try await recorder.summarize($0) })
        let snapshot = try await memory.prepare(
            transcript: transcript, question: "How should I respond?", cacheKey: "same-provider", focusSource: recent,
            summarize: { try await recorder.summarize($0) })
        let inputs = await recorder.inputs
        XCTAssertEqual(inputs.count, 2)
        XCTAssertFalse(inputs[0].isFocus)
        XCTAssertEqual(inputs[0].source, transcript)
        XCTAssertTrue(inputs[1].isFocus)
        XCTAssertEqual(inputs[1].source, recent.transcript)
        XCTAssertEqual(inputs[1].prior, "")
        XCTAssertFalse(inputs[1].source.contains("$45,000"))
        XCTAssertEqual(snapshot.earlierSummary, "General background 1")
        XCTAssertEqual(
            snapshot.focusSummary, LiveMeetingFocusSummary(text: "Recent focus 1", startMs: 0, endMs: 180_000))
        XCTAssertEqual(snapshot.focusSource, recent)
        XCTAssertEqual(snapshot.recentTranscript, transcript)
        XCTAssertTrue(coverage.allSourceProcessed)
        XCTAssertTrue(snapshot.coverage.allSourceProcessed)
    }

    func testFocusChunksCoverOnlyItsCompleteUnicodeSourceWithBoundedOverlap() async throws {
        let memory = LiveMeetingMemory()
        let recorder = FocusMemoryRecorder()
        let text = String(repeating: "Recent discussion 🧑🏽‍💻 Café e\u{301} pending approval.\n", count: 1_200)
        let recent = focus(text, start: 180_000, end: 360_000)
        _ = try await memory.update(
            transcript: "Opening context outside this window.\n" + text, focusSource: recent,
            summarize: { try await recorder.summarize($0) })
        let allInputs = await recorder.inputs
        let inputs = allInputs.filter(\.isFocus)
        XCTAssertGreaterThan(inputs.count, 2)
        let characters = Array(text)
        var frontier = 0
        var reconstructed = ""
        for (index, input) in inputs.enumerated() {
            XCTAssertEqual(input.frontier, frontier)
            XCTAssertLessThanOrEqual(input.source.count, 16_000)
            XCTAssertLessThanOrEqual(input.frontier - input.start, 800)
            XCTAssertEqual(input.source, String(characters[input.start..<input.end]))
            XCTAssertEqual(input.windowStart, 180_000)
            XCTAssertEqual(input.windowEnd, 360_000)
            XCTAssertEqual(input.prior, index == 0 ? "" : "Recent focus \(index)")
            reconstructed += String(Array(input.source).dropFirst(input.frontier - input.start))
            frontier = input.end
        }
        XCTAssertEqual(reconstructed, text)
        XCTAssertEqual(frontier, text.count)
    }

    func testIdenticalFocusReusesCacheButChangedIntervalRebuildsOnlyFocus() async throws {
        let memory = LiveMeetingMemory()
        let recorder = FocusMemoryRecorder()
        let text = "All available discussion stays unchanged."
        let first = focus("A speaker asks for review.")
        _ = try await memory.update(
            transcript: text, focusSource: first, summarize: { try await recorder.summarize($0) })
        _ = try await memory.update(
            transcript: text, focusSource: first, summarize: { try await recorder.summarize($0) })
        let cachedCount = await recorder.inputs.count
        XCTAssertEqual(cachedCount, 2)
        let later = focus(first.transcript, start: 1_000, end: 181_000)
        _ = try await memory.update(
            transcript: text, focusSource: later, summarize: { try await recorder.summarize($0) })
        let inputs = await recorder.inputs
        XCTAssertEqual(inputs.count, 3)
        XCTAssertTrue(inputs.last?.isFocus == true)
        XCTAssertEqual(inputs.last?.prior, "", "A new window cannot inherit an earlier window's focus facts")
        XCTAssertEqual(inputs.last?.windowStart, 1_000)
    }

    func testAskKeepsActualCachedIntervalWithFreshSpeechAndOmitsItAtNoOverlapBoundary() async throws {
        let memory = LiveMeetingMemory()
        let recorder = FocusMemoryRecorder()
        let original = "Earlier words."
        let completed = focus(original)
        _ = try await memory.update(
            transcript: original, focusSource: completed, summarize: { try await recorder.summarize($0) })
        let current = focus("Latest question captured by the freshness barrier.", start: 60_000, end: 240_000)
        let snapshot = try await memory.prepare(
            transcript: original + current.transcript, question: "Latest question", focusSource: current,
            summarize: { try await recorder.summarize($0) })
        XCTAssertEqual(snapshot.focusSummary?.startMs, 0)
        XCTAssertEqual(snapshot.focusSummary?.endMs, 180_000)
        XCTAssertEqual(snapshot.focusSource, current)
        XCTAssertTrue(snapshot.recentTranscript.contains(current.transcript))
        let expired = try await memory.prepare(
            transcript: original + current.transcript, question: "Latest question",
            focusSource: focus(current.transcript, start: 180_000, end: 360_000),
            summarize: { try await recorder.summarize($0) })
        XCTAssertNil(expired.focusSummary)
        let calls = await recorder.inputs.count
        XCTAssertEqual(calls, 2, "Explicit Ask must not add a focus-summary round trip")
    }

    func testQuietWindowClearsOldFocusWithoutACloudCallForUnchangedTranscript() async throws {
        for clearViaUpdate in [false, true] {
            let memory = LiveMeetingMemory()
            let recorder = FocusMemoryRecorder()
            let initial = focus("Earlier recognized words.")
            _ = try await memory.update(
                transcript: initial.transcript, focusSource: initial,
                summarize: { try await recorder.summarize($0) })
            let quiet = focus(" \n", start: 180_000, end: 360_000)
            if clearViaUpdate {
                _ = try await memory.update(
                    transcript: initial.transcript, focusSource: quiet,
                    summarize: { try await recorder.summarize($0) })
            } else {
                let snapshot = try await memory.prepare(
                    transcript: initial.transcript, question: "Anything new?", focusSource: quiet,
                    summarize: { try await recorder.summarize($0) })
                XCTAssertNil(snapshot.focusSummary)
                XCTAssertEqual(snapshot.focusSource, quiet)
            }
            let later = try await memory.prepare(
                transcript: initial.transcript, question: "Check cache", focusSource: initial,
                summarize: { try await recorder.summarize($0) })
            XCTAssertNil(later.focusSummary)
            XCTAssertEqual(later.earlierSummary, "General background 1")
            let calls = await recorder.inputs.count
            XCTAssertEqual(calls, 2)
        }
    }

    func testProviderCorrectionAndResetEachInvalidateTheCompletedFocus() async throws {
        for invalidation in 0..<3 {
            let memory = LiveMeetingMemory()
            let recorder = FocusMemoryRecorder()
            let initial = focus("Recognized source.")
            _ = try await memory.update(
                transcript: initial.transcript, cacheKey: "A", focusSource: initial,
                summarize: { try await recorder.summarize($0) })
            if invalidation == 2 { await memory.reset() }
            let snapshot = try await memory.prepare(
                transcript: invalidation == 1 ? "Corrected source." : initial.transcript,
                question: "Current question", cacheKey: invalidation == 0 ? "B" : "A", focusSource: initial,
                summarize: { try await recorder.summarize($0) })
            XCTAssertNil(snapshot.focusSummary)
            XCTAssertEqual(snapshot.earlierSummary, "")
            let calls = await recorder.inputs.count
            XCTAssertEqual(calls, 2)
        }
    }

    func testChangedProjectionForSameIntervalCannotReuseOldFocus() async throws {
        let memory = LiveMeetingMemory()
        let recorder = FocusMemoryRecorder()
        let transcript = "Speaker labels were corrected."
        _ = try await memory.update(
            transcript: transcript, focusSource: focus("Unknown: Review the report."),
            summarize: { try await recorder.summarize($0) })
        let snapshot = try await memory.prepare(
            transcript: transcript, question: "Who?", focusSource: focus("Maya: Review the report."),
            summarize: { try await recorder.summarize($0) })
        XCTAssertNil(snapshot.focusSummary)
        let calls = await recorder.inputs.count
        XCTAssertEqual(calls, 2)
    }

    func testFailedFocusDiscardsPartialWindowButRetainsCompletedGeneralCoverage() async throws {
        let memory = smallMemory()
        let failing = FocusMemoryRecorder(failFocusAt: 2)
        let text = String(repeating: "a", count: 70)
        let recent = focus(text)
        do {
            _ = try await memory.update(
                transcript: text, focusSource: recent, summarize: { try await failing.summarize($0) })
            XCTFail("The failed focus window must not be published")
        } catch { XCTAssertEqual(error as? FocusMemoryFixtureError, .requestedFailure) }
        let snapshot = try await memory.prepare(
            transcript: text, question: "Current question", focusSource: recent,
            summarize: { try await failing.summarize($0) })
        XCTAssertNil(snapshot.focusSummary)
        XCTAssertFalse(snapshot.earlierSummary.isEmpty)
        XCTAssertTrue(snapshot.coverage.allSourceProcessed)
        let retry = FocusMemoryRecorder()
        _ = try await memory.update(
            transcript: text, focusSource: recent, summarize: { try await retry.summarize($0) })
        let inputs = await retry.inputs
        XCTAssertTrue(inputs.allSatisfy(\.isFocus))
        XCTAssertEqual(inputs.first?.frontier, 0)
        XCTAssertEqual(inputs.first?.prior, "")
    }

    func testEmptyAndOversizedFocusOutputNeverEstablishACompletedFocus() async throws {
        for output in [" ... \n", String(repeating: "a", count: 3_001)] {
            let memory = LiveMeetingMemory()
            let recorder = FocusMemoryRecorder(invalidFocusOutput: output)
            let recent = focus("A current question.")
            do {
                _ = try await memory.update(
                    transcript: recent.transcript, focusSource: recent,
                    summarize: { try await recorder.summarize($0) })
                XCTFail("Invalid focus output must fail")
            } catch {
                XCTAssertEqual(
                    error as? LiveMeetingMemoryError,
                    output.count > 3_000 ? .focusSummaryTooLarge(limit: 3_000) : .emptyFocusSummary)
            }
            let snapshot = try await memory.prepare(
                transcript: recent.transcript, question: "Current question", focusSource: recent,
                summarize: { try await recorder.summarize($0) })
            XCTAssertNil(snapshot.focusSummary)
            XCTAssertEqual(snapshot.earlierSummary, "General background 1")
        }
    }

    func testCancelledFocusCannotPublishLateOutputAndRetryStartsTheWindowAgain() async throws {
        let memory = smallMemory()
        let recorder = FocusMemoryRecorder()
        let gate = FocusMemoryGate()
        let text = String(repeating: "a", count: 70)
        let recent = focus(text)
        let task = Task {
            try await memory.update(
                transcript: text, focusSource: recent,
                summarize: { messages in
                    let result = try await recorder.summarize(messages)
                    let input = try FocusMemoryInput(messages)
                    if input.isFocus, input.frontier > 0 { await gate.wait() }
                    return result
                })
        }
        try await waitUntil { await gate.entered }
        task.cancel(); await gate.open()
        do { _ = try await task.value; XCTFail("Cancelled focus must throw") } catch is CancellationError {
        } catch { XCTFail("Unexpected error: \(error)") }
        let retry = FocusMemoryRecorder()
        let snapshot = try await memory.prepare(
            transcript: text, question: "Current question", focusSource: recent,
            summarize: { try await retry.summarize($0) })
        XCTAssertNil(snapshot.focusSummary)
        XCTAssertTrue(snapshot.coverage.allSourceProcessed)
        _ = try await memory.update(
            transcript: text, focusSource: recent, summarize: { try await retry.summarize($0) })
        let inputs = await retry.inputs
        XCTAssertEqual(inputs.first?.frontier, 0)
        XCTAssertEqual(inputs.first?.prior, "")
        XCTAssertTrue(inputs.allSatisfy(\.isFocus))
    }

    func testForegroundAskPreemptsLateFocusWithoutAnAdditionalSummaryRequest() async throws {
        let memory = LiveMeetingMemory()
        let recorder = FocusMemoryRecorder()
        let gate = FocusMemoryGate()
        let recent = focus("A current question.")
        let background = Task {
            try await memory.update(
                transcript: recent.transcript, focusSource: recent,
                summarize: { messages in
                    let result = try await recorder.summarize(messages)
                    if try FocusMemoryInput(messages).isFocus { await gate.wait() }
                    return result
                })
        }
        try await waitUntil { await gate.entered }
        let snapshot = try await memory.prepare(
            transcript: recent.transcript, question: "Answer now", focusSource: recent,
            summarize: { try await recorder.summarize($0) })
        XCTAssertNil(snapshot.focusSummary)
        XCTAssertEqual(snapshot.earlierSummary, "General background 1")
        await gate.open()
        do { _ = try await background.value; XCTFail("Preempted focus must not commit") } catch is CancellationError {
        } catch { XCTFail("Unexpected error: \(error)") }
        let calls = await recorder.inputs.count
        XCTAssertEqual(calls, 2)
    }
}
