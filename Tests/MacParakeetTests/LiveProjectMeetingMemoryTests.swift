import Foundation
import XCTest
@testable import MacParakeetCore

private enum ProjectMemoryFixtureError: Error { case requestedFailure }

private actor ProjectMemoryGate {
    var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { waiter = $0 } }
    func open() { waiter?.resume(); waiter = nil }
}

private actor ProjectMemoryRecorder {
    var requests: [[ChatMessage]] = []
    var validations = 0
    let gate: ProjectMemoryGate?
    let fails: Bool
    init(gate: ProjectMemoryGate? = nil, fails: Bool = false) { self.gate = gate; self.fails = fails }
    func validate() { validations += 1 }
    func reply(_ messages: [ChatMessage]) async throws -> String {
        requests.append(messages)
        if let gate { await gate.wait() }
        if fails { throw ProjectMemoryFixtureError.requestedFailure }
        return "Historical semantic memory; finance approval remained conditional."
    }
    nonisolated func session(key: String = "synthetic-provider") -> LiveAnswerStreamSession {
        LiveAnswerStreamSession(cacheKey: key, validate: { await self.validate() }) { messages in
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        continuation.yield(try await self.reply(messages))
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
}

@MainActor
final class LiveProjectMeetingMemoryTests: XCTestCase {
    private let project = MeetingProject(name: "Synthetic project")
    private let previousID = UUID()
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func source(
        text: String? = "Maya: Finance approval is pending.", notes: String? = "Confirm the budget.",
        state: ProjectPreviousMeeting.State = .ready, id: UUID? = nil,
        hash: String? = "declared-hash", fingerprint: String? = "fingerprint", revision: Int = 0,
        title: String = "Prior calendar title", updatedAt: Date? = nil
    ) -> LiveProjectMeetingSource {
        .init(
            project: project,
            previous: .init(
                transcriptionID: id ?? previousID, title: title, createdAt: date,
                updatedAt: updatedAt ?? date, state: state, effectiveTranscript: text, userNotes: notes,
                sourceHash: hash, sourceFingerprint: fingerprint, correctionRevision: revision))
    }

    private func payload(_ snapshot: LiveProjectMeetingSnapshot) throws -> [String: String] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(snapshot.quotedContext.utf8)) as? [String: String])
    }

    private func waitUntil(_ check: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await check()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        let ready = await check()
        XCTAssertTrue(ready)
    }

    func testMissingOrUnreadyLatestMeetingUsesStatusOnlyAndNeverCallsProvider() async throws {
        let recorder = ProjectMemoryRecorder()
        let memory = LiveProjectMeetingMemory()
        let missing = LiveProjectMeetingSource(project: project, previous: nil)
        let sources =
            [missing]
            + [ProjectPreviousMeeting.State.processing, .failed, .cancelled, .empty].map {
                source(text: "Partial text must not be used.", state: $0)
            } + [source(text: " \n ", state: .ready)]
        for item in sources {
            try await memory.prefetch(source: item, session: recorder.session())
            let snapshot = try await memory.prepare(source: item, question: "Budget?", session: recorder.session())
            let context = try payload(snapshot)
            XCTAssertNil(context["prior_meeting_summary"])
            XCTAssertNil(context["prior_user_notes"])
            XCTAssertNil(context["recent_prior_transcript"])
            XCTAssertFalse(snapshot.statusLabel.isEmpty)
        }
        let requests = await recorder.requests
        let validations = await recorder.validations
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(validations, 0, "Unavailable prior context needs no auth/catalog validation or model request")
    }

    func testShortPriorMeetingIsSummarizedDuringPrefetchAndReusedByAsk() async throws {
        let recorder = ProjectMemoryRecorder()
        let memory = LiveProjectMeetingMemory()
        let item = source()
        try await memory.prefetch(source: item, session: recorder.session())
        let snapshot = try await memory.prepare(source: item, question: "Budget?", session: recorder.session())
        let context = try payload(snapshot)
        XCTAssertFalse(try XCTUnwrap(context["prior_meeting_summary"]).isEmpty)
        XCTAssertEqual(context["recent_prior_transcript"], item.previous?.effectiveTranscript)
        XCTAssertEqual(context["prior_title"], "Prior calendar title")
        XCTAssertEqual(context["prior_started_at"], "2027-01-15T08:00:00.000Z")
        XCTAssertTrue(snapshot.statusLabel.contains("not independently verified"))
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testExactQuestionQuotesRecomputeWithoutAnotherSummaryOrOtherProjectData() async throws {
        let zephyr = "Maya: Zephyr ceiling is $45,000, subject to finance approval.\n"
        let cobalt = "Lee: Cobalt deadline is Friday, conditional on security review.\n"
        let text =
            zephyr + String(repeating: "Ordinary planning words.\n", count: 150)
            + cobalt + String(repeating: "Other discussion words.\n", count: 300)
        let recorder = ProjectMemoryRecorder()
        let memory = LiveProjectMeetingMemory()
        let item = source(text: text)
        let first = try await memory.prepare(source: item, question: "Zephyr ceiling?", session: recorder.session())
        let count = await recorder.requests.count
        let second = try await memory.prepare(source: item, question: "Cobalt deadline?", session: recorder.session())
        let after = await recorder.requests.count
        XCTAssertEqual(after, count)
        let firstQuotes = try XCTUnwrap(payload(first)["exact_prior_excerpts"])
        let secondQuotes = try XCTUnwrap(payload(second)["exact_prior_excerpts"])
        XCTAssertTrue(firstQuotes.contains(zephyr.trimmingCharacters(in: .newlines)))
        XCTAssertTrue(secondQuotes.contains(cobalt.trimmingCharacters(in: .newlines)))
        XCTAssertNotEqual(firstQuotes, secondQuotes)
        for quote in firstQuotes.components(separatedBy: "\n[…]\n") where !quote.isEmpty {
            XCTAssertTrue(text.contains(quote))
        }
    }

    func testQuotedPayloadHasIndependentSummaryRawQuoteAndNoteBounds() async throws {
        let recorder = ProjectMemoryRecorder()
        let memory = LiveProjectMeetingMemory()
        let item = source(
            text: String(repeating: "Budget remains conditional.\n", count: 2_000),
            notes: String(repeating: "N", count: 6_000))
        let snapshot = try await memory.prepare(source: item, question: "Budget?", session: recorder.session())
        let context = try payload(snapshot)
        XCTAssertLessThanOrEqual(context["prior_meeting_summary"]!.count, 8_000)
        XCTAssertLessThanOrEqual(context["recent_prior_transcript"]!.count, 3_000)
        XCTAssertLessThanOrEqual(context["exact_prior_excerpts"]!.count, 6_000)
        XCTAssertEqual(context["prior_user_notes"]?.count, 4_000)
        XCTAssertNil(context["calendarEventSnapshot"])
        XCTAssertNil(context["attendees"])
        XCTAssertNil(context["organizer"])
    }

    func testOpaqueScopeChangesForCorrectionsNotesReadinessAndIdentity() {
        let original = source()
        let changed = [
            source(text: "A corrected transcript", hash: "declared-hash"), source(notes: "Changed notes"),
            source(state: .processing), source(id: UUID()), source(hash: "new-hash"),
            source(fingerprint: "new-fingerprint"), source(revision: 1), source(title: "New title"),
            source(updatedAt: date.addingTimeInterval(1)),
            LiveProjectMeetingSource(project: .init(name: "Other project"), previous: original.previous),
        ]
        XCTAssertEqual(original.scopeKey, source().scopeKey)
        XCTAssertFalse(original.scopeKey.contains(project.id.uuidString))
        XCTAssertFalse(original.scopeKey.contains("Finance"))
        for item in changed { XCTAssertNotEqual(item.scopeKey, original.scopeKey) }
    }

    func testNotesAndProviderChangesInvalidateSummaryCache() async throws {
        let recorder = ProjectMemoryRecorder()
        let memory = LiveProjectMeetingMemory()
        _ = try await memory.prepare(source: source(), question: "First", session: recorder.session())
        _ = try await memory.prepare(source: source(notes: "New note"), question: "Second", session: recorder.session())
        _ = try await memory.prepare(
            source: source(notes: "New note"), question: "Third", session: recorder.session(key: "other-provider"))
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 3)
        for request in requests {
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(request.last!.content.utf8)) as? [String: Any])
            XCTAssertEqual(
                body["prior_memory"] as? String, "", "A new source/provider scope starts without old meeting memory")
        }
    }

    func testNewLatestMeetingFailureCannotFallBackToCachedOlderReference() async throws {
        let memory = LiveProjectMeetingMemory()
        let first = ProjectMemoryRecorder()
        _ = try await memory.prepare(source: source(), question: "First", session: first.session())
        let failed = ProjectMemoryRecorder(fails: true)
        do {
            _ = try await memory.prepare(source: source(id: UUID()), question: "Second", session: failed.session())
            XCTFail("A failed latest reference must not return old context")
        } catch {}
        let unavailable = try await memory.prepare(
            source: source(state: .failed, id: UUID()), question: "Third", session: first.session())
        XCTAssertNil(try payload(unavailable)["prior_meeting_summary"])
        XCTAssertTrue(unavailable.statusLabel.contains("no older meeting was substituted"))
    }

    func testResetRejectsLateSummaryAndNextRequestStartsWithoutOldMemory() async throws {
        let memory = LiveProjectMeetingMemory()
        let gate = ProjectMemoryGate()
        let delayed = ProjectMemoryRecorder(gate: gate)
        let item = source()
        let task = Task { try await memory.prepare(source: item, question: "First", session: delayed.session()) }
        try await waitUntil { await gate.entered }
        await memory.reset()
        await gate.open()
        do { _ = try await task.value; XCTFail("Reset must reject stale publication") } catch is CancellationError {
        } catch { XCTFail("Unexpected error") }
        let fresh = ProjectMemoryRecorder()
        let snapshot = try await memory.prepare(source: item, question: "Second", session: fresh.session())
        XCTAssertEqual(snapshot.scopeKey, item.scopeKey)
        let requests = await fresh.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testPrefetchCannotInvalidateAnActiveForegroundReference() async throws {
        let memory = LiveProjectMeetingMemory()
        let gate = ProjectMemoryGate()
        let delayed = ProjectMemoryRecorder(gate: gate)
        let item = source()
        let task = Task { try await memory.prepare(source: item, question: "First", session: delayed.session()) }
        try await waitUntil { await gate.entered }
        do {
            try await memory.prefetch(source: item, session: delayed.session())
            XCTFail("Background work must defer to foreground")
        } catch { XCTAssertEqual(error as? LiveMeetingMemoryError, .backgroundDeferred) }
        await gate.open()
        let snapshot = try await task.value
        XCTAssertFalse(try XCTUnwrap(payload(snapshot)["prior_meeting_summary"]).isEmpty)
    }

    func testCancelledPrefetchCannotCommitItsPendingSummary() async throws {
        let memory = LiveProjectMeetingMemory()
        let gate = ProjectMemoryGate()
        let delayed = ProjectMemoryRecorder(gate: gate)
        let item = source()
        let task = Task { try await memory.prefetch(source: item, session: delayed.session()) }
        try await waitUntil { await gate.entered }
        task.cancel()
        await gate.open()
        do { try await task.value; XCTFail("Cancelled prefetch must fail") } catch is CancellationError {} catch {
            XCTFail("Unexpected error")
        }
        let fresh = ProjectMemoryRecorder()
        _ = try await memory.prepare(source: item, question: "Current question", session: fresh.session())
        let requests = await fresh.requests
        XCTAssertEqual(requests.count, 1, "The cancelled summary cannot satisfy a later request from cache")
    }

    func testIdentityValidationRejectsCachedReferenceWithoutAnotherModelRequest() async throws {
        let memory = LiveProjectMeetingMemory()
        let recorder = ProjectMemoryRecorder()
        let item = source()
        try await memory.prefetch(source: item, session: recorder.session())
        let invalidated = LiveAnswerStreamSession(
            cacheKey: "synthetic-provider", validate: { throw CancellationError() },
            stream: { _ in
                XCTFail("Changed provider identity cannot send model input")
                return AsyncThrowingStream { $0.finish() }
            })
        do {
            _ = try await memory.prepare(source: item, question: "Current question", session: invalidated)
            XCTFail("Even cached references must validate their current provider identity")
        } catch is CancellationError {} catch { XCTFail("Unexpected error") }
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
    }
}
