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
                source(text: "Partial text must not be used.", notes: nil, state: $0)
            } + [source(text: " \n ", notes: nil, state: .ready)]
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
        XCTAssertEqual(context["prior_user_notes"], item.previous?.userNotes)
        XCTAssertNil(context["prior_user_notes_summary"], "Short notes fit in full without another model request")
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
        XCTAssertEqual(context["prior_user_notes"]?.count, 2_000)
        XCTAssertLessThanOrEqual(try XCTUnwrap(context["prior_user_notes_summary"]).count, 4_000)
        XCTAssertLessThanOrEqual((context["exact_prior_user_note_excerpts"] ?? "").count, 4_000)
        XCTAssertTrue(
            try XCTUnwrap(context["prior_user_notes_coverage"]).contains("All 6000 note characters processed"))
        XCTAssertNil(context["calendarEventSnapshot"])
        XCTAssertNil(context["attendees"])
        XCTAssertNil(context["organizer"])
    }

    func testShortNotesRemainAvailableWhenLatestTranscriptIsUnavailableWithoutInference() async throws {
        let recorder = ProjectMemoryRecorder()
        let memory = LiveProjectMeetingMemory()
        let notes = "My reminder: ask Maya whether finance has approved the revised budget."
        for state in [ProjectPreviousMeeting.State.processing, .failed, .cancelled, .empty] {
            let item = source(text: "Unready spoken text must stay unavailable.", notes: notes, state: state)
            try await memory.prefetch(source: item, session: recorder.session())
            let snapshot = try await memory.prepare(source: item, question: "Budget?", session: recorder.session())
            let context = try payload(snapshot)
            XCTAssertNil(context["prior_meeting_summary"])
            XCTAssertNil(context["recent_prior_transcript"])
            XCTAssertEqual(context["prior_user_notes"], notes)
            XCTAssertEqual(context["prior_user_notes_raw_scope"], "Complete notes.")
            XCTAssertTrue(try XCTUnwrap(context["prior_user_notes_provenance"]).contains("not a spoken transcript"))
            XCTAssertTrue(snapshot.statusLabel.contains("no older meeting was substituted"))
            XCTAssertTrue(snapshot.statusLabel.contains("notes from that latest meeting"))
        }
        let requests = await recorder.requests
        let validations = await recorder.validations
        XCTAssertTrue(requests.isEmpty)
        XCTAssertGreaterThan(validations, 0, "Even raw notes require the pinned current provider identity")
    }

    func testLongNotesPrefetchCoversEveryCharacterAndAskReusesSeparateNoteMemory() async throws {
        let recorder = ProjectMemoryRecorder()
        let memory = LiveProjectMeetingMemory()
        let notes =
            "Opening priority: check Zephyr approval.\n"
            + String(repeating: "User reminder, not an accepted assignment.\n", count: 1_000)
            + "Final priority: confirm the orchard release exception."
        let item = source(text: nil, notes: notes, state: .failed)
        try await memory.prefetch(source: item, session: recorder.session())
        let prefetched = await recorder.requests
        XCTAssertGreaterThan(prefetched.count, 1)
        let characters = Array(notes)
        var frontier = 0
        for request in prefetched {
            let instructions = try XCTUnwrap(request.first?.content)
            XCTAssertTrue(instructions.contains("user's typed notes"))
            XCTAssertTrue(instructions.contains("Never infer an owner, deadline or commitment"))
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(request.last!.content.utf8)) as? [String: Any])
            let start = try XCTUnwrap(body["source_start_character"] as? Int)
            let end = try XCTUnwrap(body["source_end_character"] as? Int)
            XCTAssertEqual(body["new_coverage_starts_at_character"] as? Int, frontier)
            XCTAssertLessThanOrEqual(start, frontier)
            XCTAssertGreaterThan(end, frontier)
            XCTAssertEqual(body["source_chunk"] as? String, String(characters[start..<end]))
            frontier = end
        }
        XCTAssertEqual(frontier, notes.count, "The notes after the old 4,000-character cutoff must also be processed")
        let snapshot = try await memory.prepare(
            source: item, question: "Orchard release exception?", session: recorder.session())
        let after = await recorder.requests
        XCTAssertEqual(
            after.count, prefetched.count, "Ask must reuse the note prefetch without another summary request")
        let context = try payload(snapshot)
        XCTAssertNil(context["prior_meeting_summary"], "A note summary must never occupy the transcript summary field")
        XCTAssertFalse(try XCTUnwrap(context["prior_user_notes_summary"]).isEmpty)
        XCTAssertTrue(
            try XCTUnwrap(context["prior_user_notes"]).hasSuffix(
                "Final priority: confirm the orchard release exception."))
        XCTAssertTrue(
            try XCTUnwrap(context["prior_user_notes_coverage"]).contains("All \(notes.count) note characters processed")
        )
        XCTAssertTrue(snapshot.statusLabel.contains("no older meeting was substituted"))
    }

    func testLongNoteQuestionExcerptsAreExactAndChangeWithoutAnotherSummary() async throws {
        let zephyr = "My note: Zephyr ceiling needs finance approval before anyone commits.\n"
        let cobalt = "My note: Cobalt Friday deadline is only a proposal pending security review.\n"
        let notes =
            zephyr + String(repeating: "Ordinary planning note.\n", count: 150)
            + cobalt + String(repeating: "Other reminder detail.\n", count: 300)
        let recorder = ProjectMemoryRecorder()
        let memory = LiveProjectMeetingMemory()
        let item = source(text: nil, notes: notes, state: .processing)
        let first = try await memory.prepare(source: item, question: "Zephyr ceiling?", session: recorder.session())
        let before = await recorder.requests.count
        let second = try await memory.prepare(source: item, question: "Cobalt deadline?", session: recorder.session())
        let after = await recorder.requests.count
        XCTAssertEqual(after, before)
        let firstQuotes = try XCTUnwrap(payload(first)["exact_prior_user_note_excerpts"])
        let secondQuotes = try XCTUnwrap(payload(second)["exact_prior_user_note_excerpts"])
        XCTAssertTrue(firstQuotes.contains(zephyr.trimmingCharacters(in: .newlines)))
        XCTAssertTrue(secondQuotes.contains(cobalt.trimmingCharacters(in: .newlines)))
        XCTAssertNotEqual(firstQuotes, secondQuotes)
        for quotes in [firstQuotes, secondQuotes] {
            XCTAssertLessThanOrEqual(quotes.count, 4_000)
            for quote in quotes.components(separatedBy: "\n[…]\n") where !quote.isEmpty {
                XCTAssertTrue(notes.contains(quote))
            }
        }
    }

    func testEmptyNotesAddNoPayloadOrInferenceToTranscriptLane() async throws {
        let recorder = ProjectMemoryRecorder()
        let memory = LiveProjectMeetingMemory()
        let snapshot = try await memory.prepare(
            source: source(notes: " \n "), question: "Budget?", session: recorder.session())
        let context = try payload(snapshot)
        XCTAssertFalse(try XCTUnwrap(context["prior_meeting_summary"]).isEmpty)
        XCTAssertFalse(context.keys.contains(where: { $0.contains("user_note") }))
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
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

    func testLongNoteEditsAndProviderChangesInvalidateSeparateNoteCache() async throws {
        let recorder = ProjectMemoryRecorder()
        let memory = LiveProjectMeetingMemory()
        let notes = String(repeating: "A typed reminder, not a spoken commitment.\n", count: 120)
        _ = try await memory.prepare(
            source: source(text: nil, notes: notes, state: .failed), question: "First", session: recorder.session())
        let changed = source(text: nil, notes: notes + "New final reminder.", state: .failed)
        _ = try await memory.prepare(source: changed, question: "Second", session: recorder.session())
        _ = try await memory.prepare(
            source: changed, question: "Third", session: recorder.session(key: "other-provider"))
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 3)
        for request in requests {
            XCTAssertTrue(try XCTUnwrap(request.first?.content).contains("user's typed notes"))
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(request.last!.content.utf8)) as? [String: Any])
            XCTAssertEqual(
                body["prior_memory"] as? String, "", "Changed notes/provider cannot retain prior note memory")
        }
    }

    func testFailedLatestNoteCoverageCannotPublishCachedOlderNotesOrRawTruncation() async throws {
        let memory = LiveProjectMeetingMemory()
        let notes = String(repeating: "Reminder requiring complete coverage.\n", count: 150)
        let first = ProjectMemoryRecorder()
        _ = try await memory.prepare(
            source: source(text: nil, notes: notes, state: .failed), question: "First", session: first.session())
        let failed = ProjectMemoryRecorder(fails: true)
        do {
            _ = try await memory.prepare(
                source: source(text: nil, notes: notes + "New latest note.", state: .failed, id: UUID()),
                question: "Second", session: failed.session())
            XCTFail("Failed note coverage must not return older semantic memory or only a raw note prefix")
        } catch {}
        let empty = try await memory.prepare(
            source: source(text: nil, notes: nil, state: .failed, id: UUID()),
            question: "Third", session: first.session())
        let context = try payload(empty)
        XCTAssertNil(context["prior_user_notes"])
        XCTAssertNil(context["prior_user_notes_summary"])
        XCTAssertNil(context["exact_prior_user_note_excerpts"])
        XCTAssertTrue(empty.statusLabel.contains("no older meeting was substituted"))
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
        for item in [source(), source(text: nil, notes: String(repeating: "Reminder. ", count: 600), state: .failed)] {
            let memory = LiveProjectMeetingMemory()
            let gate = ProjectMemoryGate()
            let delayed = ProjectMemoryRecorder(gate: gate)
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
    }

    func testPrefetchCannotInvalidateAnActiveForegroundReference() async throws {
        for item in [source(), source(text: nil, notes: String(repeating: "Reminder. ", count: 600), state: .failed)] {
            let memory = LiveProjectMeetingMemory()
            let gate = ProjectMemoryGate()
            let delayed = ProjectMemoryRecorder(gate: gate)
            let task = Task { try await memory.prepare(source: item, question: "First", session: delayed.session()) }
            try await waitUntil { await gate.entered }
            do {
                try await memory.prefetch(source: item, session: delayed.session())
                XCTFail("Background work must defer to foreground")
            } catch { XCTAssertEqual(error as? LiveMeetingMemoryError, .backgroundDeferred) }
            await gate.open()
            let snapshot = try await task.value
            let summaryKey = item.previous?.state == .ready ? "prior_meeting_summary" : "prior_user_notes_summary"
            XCTAssertFalse(try XCTUnwrap(payload(snapshot)[summaryKey]).isEmpty)
        }
    }

    func testCancelledPrefetchCannotCommitItsPendingSummary() async throws {
        for item in [source(), source(text: nil, notes: String(repeating: "Reminder. ", count: 600), state: .failed)] {
            let memory = LiveProjectMeetingMemory()
            let gate = ProjectMemoryGate()
            let delayed = ProjectMemoryRecorder(gate: gate)
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
    }

    func testIdentityValidationRejectsCachedReferenceWithoutAnotherModelRequest() async throws {
        let items = [
            source(), source(text: nil, notes: "A short reminder.", state: .failed),
            source(text: nil, notes: String(repeating: "Reminder. ", count: 600), state: .failed),
        ]
        for item in items {
            let memory = LiveProjectMeetingMemory()
            let recorder = ProjectMemoryRecorder()
            try await memory.prefetch(source: item, session: recorder.session())
            let before = await recorder.requests.count
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
            XCTAssertEqual(requests.count, before)
        }
    }
}
