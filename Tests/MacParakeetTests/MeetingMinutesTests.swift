import Foundation
import GRDB
import XCTest
@testable import MacParakeetCore

final class MeetingMinutesTests: XCTestCase {
    func testFullMinutesHaveFourNotesExactQuoteAndExplicitUnknownFields() async throws {
        let fixture = try Fixture(
            text: "We discussed delivery. I will send the report. The team agreed. The call ended.")
        let model = Model(quote: "I will send the report.")
        let result = try await MeetingMinutesEngine(repository: fixture.repo).run(
            jobID: fixture.job.id, session: model.session(), modelSnapshot: "synthetic-model")
        let output = try XCTUnwrap(result?.content)
        let notes = output.components(separatedBy: "## Verified Action Items")[0]
        XCTAssertEqual(notes.components(separatedBy: "### ").count - 1, 4)
        XCTAssertTrue(output.contains("> I will send the report."))
        XCTAssertTrue(output.contains("**Owner:** Not identifiable from the transcript."))
        XCTAssertTrue(output.contains("**Due Date:** Not stated."))
        XCTAssertTrue(output.contains("**Source:** Transcript lines"))
        XCTAssertEqual(result?.sourceTranscriptHash, fixture.source.canonicalTranscriptHash)
        XCTAssertEqual(result?.modelSnapshot, "synthetic-model")
        XCTAssertEqual(try fixture.repo.fetch(id: fixture.job.id)?.state, .completed)
        let reviews = await model.reviewCount
        XCTAssertEqual(reviews, 1)
    }

    func testZeroActionsAndSeparateConditionalProposedExcludedAreValid() async throws {
        let fixture = try Fixture(text: "We can build dashboards. Maybe we could meet. If approved, we will deploy.")
        let model = Model(quote: "We can build dashboards.", reviewApproves: false)
        let result = try await MeetingMinutesEngine(repository: fixture.repo).run(
            jobID: fixture.job.id, session: model.session())
        XCTAssertTrue(result?.content.contains("No confirmed action items") == true)
        XCTAssertTrue(result?.content.contains("Action-Item Audit: Excluded Candidates") == true)
        XCTAssertEqual(try fixture.repo.fetch(id: fixture.job.id)?.state, .completed)
        let empty = try Fixture(text: "The team reviewed current results. No future work was agreed.")
        let zero = try await MeetingMinutesEngine(repository: empty.repo).run(
            jobID: empty.job.id, session: Model().session())
        XCTAssertTrue(zero?.content.contains("No confirmed action items") == true)
    }

    func testLongUnicodeMeetingProcessesEverySourceCharacterInOrder() async throws {
        let text = (0..<40).map { "Segment \($0): café 👩🏽‍💻 日本語. This ordinary fact must be read.\n" }.joined()
        let fixture = try Fixture(text: text)
        let model = Model()
        _ = try await MeetingMinutesEngine(repository: fixture.repo, chunkCharacters: 140, overlapCharacters: 20)
            .run(jobID: fixture.job.id, session: model.session())
        let progress = try fixture.progress()
        let source = Array(fixture.source.transcript)
        XCTAssertGreaterThan(progress.chunks.count, 10)
        XCTAssertEqual(progress.chunks.map { String(source[$0.start..<$0.end]) }.joined(), fixture.source.transcript)
        XCTAssertEqual(progress.coveredCharacters, source.count)
        let requests = await model.extractions
        XCTAssertEqual(requests.count, progress.chunks.count)
        XCTAssertTrue(requests.allSatisfy { $0.source.count <= 160 })
        XCTAssertFalse(requests.contains { $0.source.contains("content truncated") })
    }

    func testFabricatedOrStitchedQuoteFailsWithoutReplacingValidMinutes() async throws {
        let fixture = try Fixture(text: "The platform can generate dashboards. No assignment was made.")
        let old = PromptResult(
            transcriptionId: fixture.row.id, promptName: "Existing minutes", promptContent: "Old skill",
            content: "User-edited valid minutes", contentEditedAt: Date())
        try PromptResultRepository(dbQueue: fixture.database.dbQueue).save(old)
        let model = Model(quote: "Send the recording to Franco.")
        do {
            _ = try await MeetingMinutesEngine(repository: fixture.repo).run(
                jobID: fixture.job.id, session: model.session())
            XCTFail("Example/fabricated quote passed evidence validation")
        } catch let error as MeetingMinutesError { XCTAssertEqual(error, .invalidEvidence) }
        let results = try PromptResultRepository(dbQueue: fixture.database.dbQueue).fetchAll(
            transcriptionId: fixture.row.id)
        XCTAssertEqual(results.map(\.content), [old.content])
        XCTAssertEqual(try fixture.repo.fetch(id: fixture.job.id)?.coveredCharacters, 0)
    }

    func testWrongNumberOfNotesNeverSavesAFinalResult() async throws {
        let fixture = try Fixture(text: "The team discussed the plan. No action was agreed.")
        do {
            _ = try await MeetingMinutesEngine(repository: fixture.repo).run(
                jobID: fixture.job.id, session: Model(noteCount: 3).session())
            XCTFail("Three notes were published")
        } catch let error as MeetingMinutesError { XCTAssertEqual(error, .invalidResponse) }
        XCTAssertEqual(try fixture.repo.fetch(id: fixture.job.id)?.state, .failed)
        XCTAssertNil(try fixture.repo.result(jobID: fixture.job.id))
    }

    func testYieldResumesCompletedChunksWithoutReplayingThem() async throws {
        let fixture = try Fixture(text: String(repeating: "Ordinary source detail.\n", count: 50))
        let model = Model()
        let engine = MeetingMinutesEngine(repository: fixture.repo, chunkCharacters: 150, overlapCharacters: 20)
        let yielded = try await engine.run(
            jobID: fixture.job.id, session: model.session(), shouldYield: { await model.extractionCount > 0 })
        XCTAssertNil(yielded)
        XCTAssertEqual(try fixture.repo.fetch(id: fixture.job.id)?.state, .pending)
        let first = try fixture.progress().chunks
        XCTAssertEqual(first.count, 1)
        _ = try await engine.run(jobID: fixture.job.id, session: model.session())
        let progress = try fixture.progress()
        XCTAssertEqual(progress.chunks.first, first.first)
        let requests = await model.extractions
        XCTAssertEqual(requests.filter { $0.start == 0 }.count, 1)
        XCTAssertEqual(progress.chunks.count, requests.count)
    }

    func testInterruptedRunningJobNeedsExplicitRetryAndRetainsCompletedCheckpoint() throws {
        let fixture = try Fixture(text: "A longer source with several material facts.")
        let work = try fixture.repo.claim(
            jobID: fixture.job.id, providerIdentity: "synthetic-session", provider: "chatgpt-plan", model: nil)
        let attempt = try XCTUnwrap(work.attemptID)
        var progress = MeetingMinutesProgress()
        progress.meetingMap = "Completed first source prefix."
        progress.chunks = [.init(start: 0, end: 10, requestStart: 0)]
        try fixture.repo.checkpoint(jobID: work.id, attemptID: attempt, progress: progress)
        try fixture.repo.recoverInterruptedJobs()
        XCTAssertEqual(try fixture.repo.fetch(id: work.id)?.state, .failed)
        XCTAssertTrue(try fixture.repo.pendingJobs().isEmpty)
        XCTAssertEqual(try fixture.progress().coveredCharacters, 10)
        let retry = try fixture.repo.retry(jobID: work.id)
        XCTAssertEqual(retry.id, work.id)
        XCTAssertEqual(retry.state, .pending)
    }

    func testChangedSourceBeforeCommitFailsAndExplicitRetryCapturesCurrentSource() async throws {
        let fixture = try Fixture(text: "Original final transcript. No task was assigned.")
        let model = Model(blockNotes: true)
        let engine = MeetingMinutesEngine(repository: fixture.repo)
        let run = Task { try await engine.run(jobID: fixture.job.id, session: model.session()) }
        try await wait { await model.waitingForNotes }
        var changed = fixture.row
        changed.rawTranscript = "Corrected final transcript. This replaces the earlier version."
        changed.updatedAt = Date()
        try fixture.rows.save(changed)
        await model.releaseNotes()
        do { _ = try await run.value; XCTFail("Stale source was published") } catch let error as MeetingMinutesError {
            XCTAssertEqual(error, .sourceChanged)
        }
        XCTAssertNil(try fixture.repo.result(jobID: fixture.job.id))
        let replacement = try fixture.repo.retry(
            jobID: fixture.job.id,
            source: fixture.repo.captureSource(transcriptionID: changed.id), skill: fixture.skill)
        XCTAssertNotEqual(replacement.id, fixture.job.id)
        XCTAssertEqual(replacement.state, .pending)
        XCTAssertEqual(try fixture.repo.jobsFor(transcriptionID: changed.id).count, 2)
    }

    func testDeletingSourceDuringGenerationCannotResurrectJobOrMinutes() async throws {
        let fixture = try Fixture(text: "Synthetic meeting with enough source to prepare notes.")
        let model = Model(blockNotes: true)
        let engine = MeetingMinutesEngine(repository: fixture.repo)
        let run = Task { try await engine.run(jobID: fixture.job.id, session: model.session()) }
        try await wait { await model.waitingForNotes }
        _ = try fixture.rows.delete(id: fixture.row.id)
        await model.releaseNotes()
        do { _ = try await run.value; XCTFail("Deleted source was recreated") } catch {}
        XCTAssertNil(try fixture.rows.fetch(id: fixture.row.id))
        XCTAssertTrue(try fixture.repo.allJobs().isEmpty)
        XCTAssertTrue(
            try PromptResultRepository(dbQueue: fixture.database.dbQueue).fetchAll(transcriptionId: fixture.row.id)
                .isEmpty)
    }

    func testDeletedCompletedMinutesStayDeletedOnEnqueueAndRun() async throws {
        let fixture = try Fixture(text: "Synthetic meeting with no future commitment.")
        let model = Model()
        let engine = MeetingMinutesEngine(repository: fixture.repo)
        let completed = try await engine.run(jobID: fixture.job.id, session: model.session())
        let result = try XCTUnwrap(completed)
        let calls = await model.totalCalls
        _ = try PromptResultRepository(dbQueue: fixture.database.dbQueue).delete(id: result.id)
        let duplicate = try fixture.repo.enqueue(source: fixture.source, skill: fixture.skill)
        XCTAssertEqual(duplicate.id, fixture.job.id)
        XCTAssertEqual(duplicate.state, .completed)
        let rerun = try await engine.run(jobID: duplicate.id, session: model.session())
        XCTAssertNil(rerun)
        let laterCalls = await model.totalCalls
        XCTAssertEqual(laterCalls, calls)
    }

    func testProviderChangeOnYieldRequiresExplicitRetryAndRestartsChunks() async throws {
        let fixture = try Fixture(text: String(repeating: "Synthetic source.\n", count: 40))
        let first = Model()
        let engine = MeetingMinutesEngine(repository: fixture.repo, chunkCharacters: 150, overlapCharacters: 20)
        _ = try await engine.run(
            jobID: fixture.job.id, session: first.session(key: "first"),
            shouldYield: { await first.extractionCount > 0 })
        let second = Model()
        do {
            _ = try await engine.run(jobID: fixture.job.id, session: second.session(key: "second"));
            XCTFail("Account/model silently changed")
        } catch let error as MeetingMinutesError { XCTAssertEqual(error, .providerChanged) }
        let rejectedCalls = await second.totalCalls
        XCTAssertEqual(rejectedCalls, 0)
        _ = try fixture.repo.retry(jobID: fixture.job.id)
        _ = try await engine.run(jobID: fixture.job.id, session: second.session(key: "second"))
        let secondStart = await second.extractions.first?.start
        XCTAssertEqual(secondStart, 0)
    }

    func testCandidateScanSkipsOlderEmptyAndHistoricalRowsWithoutBlockingLaterMeeting() throws {
        let fixture = try Fixture(text: "Already queued valid meeting.")
        let activation = Date(timeIntervalSince1970: 1_700_000_000)
        let empty = Transcription(
            createdAt: activation.addingTimeInterval(1), fileName: "Empty", rawTranscript: " \n ", status: .completed,
            sourceType: .meeting)
        let historical = Transcription(
            createdAt: activation.addingTimeInterval(-1), fileName: "Historical", rawTranscript: "Old source",
            status: .completed, sourceType: .meeting)
        let later = Transcription(
            createdAt: activation.addingTimeInterval(2), fileName: "New", rawTranscript: "New complete source",
            status: .completed, sourceType: .meeting)
        for row in [empty, historical, later] { try fixture.rows.save(row) }
        XCTAssertEqual(try fixture.repo.candidateIDs(createdAtOrAfter: activation), [later.id])
    }

    func testWorkedExampleIsStoredButNeverUsedAsMeetingFacts() throws {
        let markdown =
            "# Rules\nExactly four notes.\n# Worked Example Using the Supplied Meeting\nFACTORY_EXAMPLE_FACT\n# Final Quality Standard\nNever invent actions."
        let runtime = try MeetingMinutesEngine.runtimeSkill(markdown)
        XCTAssertFalse(runtime.contains("FACTORY_EXAMPLE_FACT"))
        XCTAssertTrue(runtime.contains("Never invent actions."))
        let fixture = try Fixture(text: "Actual source only.", skillMarkdown: markdown)
        let saved = try fixture.database.dbQueue.read {
            try XCTUnwrap(MeetingMinutesWork.fetchOne($0, key: fixture.job.id)).skill
        }
        XCTAssertEqual(saved.markdown, markdown)
    }

    func testInternalStageJSONContractComesAfterConflictingMarkdownSkillTemplate() async throws {
        let skill = "# Meeting skill\nAlways output Markdown headings, never JSON.\nWrite four meeting notes."
        let fixture = try Fixture(text: "Synthetic finalized meeting source.", skillMarkdown: skill)
        let model = Model()
        let result = try await MeetingMinutesEngine(repository: fixture.repo).run(
            jobID: fixture.job.id, session: model.session())
        XCTAssertNotNil(result)
        let instructions = await model.systemInstructions
        XCTAssertEqual(instructions.count, 2)
        for instruction in instructions {
            let template = try XCTUnwrap(instruction.range(of: "Always output Markdown headings, never JSON."))
            let wire = try XCTUnwrap(instruction.range(of: "FINAL INTERNAL RESPONSE FORMAT:"))
            XCTAssertLessThan(template.lowerBound, wire.lowerBound)
            XCTAssertTrue(instruction[wire.lowerBound...].contains("Return ONLY one valid JSON object"))
            XCTAssertTrue(instruction[wire.lowerBound...].contains("takes precedence"))
        }
    }

    private func wait(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<400 { if await condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Synthetic minutes request did not reach the gate")
        throw MeetingMinutesError.interrupted
    }
}

private struct Fixture {
    let database: DatabaseManager
    let rows: TranscriptionRepository
    let repo: MeetingMinutesJobRepository
    let row: Transcription
    let source: MeetingMinutesSourceSnapshot
    let skill: MeetingMinutesSkillSnapshot
    let job: MeetingMinutesJob
    init(text: String, skillMarkdown: String = "Use exactly four notes and only evidenced actions.") throws {
        database = try DatabaseManager()
        rows = TranscriptionRepository(dbQueue: database.dbQueue)
        repo = MeetingMinutesJobRepository(dbQueue: database.dbQueue)
        row = Transcription(
            fileName: "Synthetic meeting", rawTranscript: text, status: .completed, sourceType: .meeting)
        try rows.save(row)
        source = try repo.captureSource(transcriptionID: row.id)
        skill = MeetingMinutesSkillSnapshot(
            markdown: skillMarkdown, revision: MeetingMinutesIdentity.hash(skillMarkdown))
        job = try repo.enqueue(source: source, skill: skill)
    }
    func progress() throws -> MeetingMinutesProgress {
        try database.dbQueue.read { try XCTUnwrap(MeetingMinutesWork.fetchOne($0, key: job.id)).progress }
    }
}

private actor Model {
    struct Extraction: Sendable { let start: Int; let end: Int; let source: String }
    private let quote: String?
    private let reviewApproves: Bool
    private let noteCount: Int
    private let blockNotes: Bool
    private var notesGate: CheckedContinuation<Void, Never>?
    private(set) var waitingForNotes = false
    private(set) var extractions: [Extraction] = []
    private(set) var reviewCount = 0
    private(set) var totalCalls = 0
    private(set) var systemInstructions: [String] = []
    var extractionCount: Int { extractions.count }
    init(quote: String? = nil, reviewApproves: Bool = true, noteCount: Int = 4, blockNotes: Bool = false) {
        self.quote = quote; self.reviewApproves = reviewApproves; self.noteCount = noteCount;
        self.blockNotes = blockNotes
    }
    nonisolated func session(key: String = "synthetic-session") -> LiveAnswerStreamSession {
        LiveAnswerStreamSession(
            cacheKey: key,
            stream: { messages in
                AsyncThrowingStream { continuation in
                    let task = Task {
                        do { continuation.yield(try await self.respond(messages)); continuation.finish() } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            })
    }
    func releaseNotes() { notesGate?.resume(); notesGate = nil }
    private func respond(_ messages: [ChatMessage]) async throws -> String {
        totalCalls += 1
        systemInstructions.append(messages.first?.content ?? "")
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(messages.last!.content.utf8)) as? [String: Any])
        let stage = payload["stage"] as? String
        let object: [String: Any]
        switch stage {
        case "extract":
            let source = payload["source"] as! String
            extractions.append(
                .init(start: payload["newSourceStartsAt"] as! Int, end: payload["sourceEnd"] as! Int, source: source))
            var candidates: [[String: Any]] = []
            if let quote {
                candidates.append([
                    "classification": "confirmed", "headline": "Send the report",
                    "description": "Send the report as explicitly committed.", "quote": quote,
                    "owner": NSNull(), "recipient": NSNull(), "dueDate": NSNull(), "trigger": NSNull(),
                    "ownerCertainty": "Unknown — no speaker identity", "why": "The source contains a commitment.",
                    "doNotOverstate": "No owner or deadline was supplied.",
                ])
            }
            object = [
                "meetingMap":
                    "The team discussed delivery and unresolved requirements. No additional facts were inferred.",
                "candidates": candidates,
            ]
        case "review":
            reviewCount += 1
            object = [
                "approved": reviewApproves, "futureWork": reviewApproves, "concreteDeliverable": reviewApproves,
                "commitment": reviewApproves, "attributionSupported": reviewApproves, "scopeMatches": reviewApproves,
                "classification": reviewApproves ? "confirmed" : "excluded",
                "reason": reviewApproves
                    ? "The exact quote creates this obligation." : "A capability is not a future assignment.",
            ]
        case "notes":
            if blockNotes { waitingForNotes = true; await withCheckedContinuation { notesGate = $0 } }
            object = [
                "notes": (0..<noteCount).map {
                    [
                        "headline": "Material point \($0 + 1)",
                        "description": "The team discussed the source. The issue remained unresolved.",
                    ]
                }
            ]
        default: throw MeetingMinutesError.invalidResponse
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
