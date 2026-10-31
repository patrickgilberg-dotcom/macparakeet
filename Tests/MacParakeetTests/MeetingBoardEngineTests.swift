import XCTest
@testable import MacParakeetCore

private enum BoardFixtureError: Error { case malformedInput, providerChanged }

private struct BoardFixtureInput: Sendable {
    let documentID: String
    let chunk: String
    let stage: String
    let candidateIDs: [String]
    let reopenedCandidateIDs: [String]

    init(_ messages: [ChatMessage]) throws {
        guard let content = messages.last?.content,
            let object = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
            let documentID = object["documentID"] as? String, let chunk = object["source_chunk"] as? String
        else { throw BoardFixtureError.malformedInput }
        self.documentID = documentID; self.chunk = chunk
        stage = object["stage"] as? String ?? "extract"
        candidateIDs = (object["candidates"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        reopenedCandidateIDs =
            (object["candidates"] as? [[String: Any]])?.compactMap {
                $0["reopeningEvidence"] == nil ? nil : $0["id"] as? String
            } ?? []
    }
}

private actor BoardFixtureGate {
    var entered = false
    var opened = false
    var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        if !opened { await withCheckedContinuation { waiter = $0 } }
    }

    func open() { opened = true; waiter?.resume(); waiter = nil }
}

private actor BoardFixture {
    var inputs: [BoardFixtureInput] = []
    var resolutionInputs: [BoardFixtureInput] = []
    var valid = true
    let output: (@Sendable (BoardFixtureInput) throws -> String)?
    let gate: BoardFixtureGate?
    let gateAt: Int
    let gateStage: String
    let reconcileOutput: (@Sendable (BoardFixtureInput) throws -> String)?

    init(
        gate: BoardFixtureGate? = nil, gateAt: Int = 1, gateStage: String = "extract",
        reconcile: (@Sendable (BoardFixtureInput) throws -> String)? = nil,
        output: (@Sendable (BoardFixtureInput) throws -> String)? = nil
    ) {
        self.gate = gate; self.output = output; reconcileOutput = reconcile
        self.gateAt = gateAt; self.gateStage = gateStage
    }

    func setValid(_ value: Bool) { valid = value }
    func validate() throws { if !valid { throw BoardFixtureError.providerChanged } }

    func respond(_ messages: [ChatMessage]) async throws -> String {
        let input = try BoardFixtureInput(messages)
        if input.stage == "reconcile" { resolutionInputs.append(input) } else { inputs.append(input) }
        let stageCount = input.stage == "reconcile" ? resolutionInputs.count : inputs.count
        if input.stage == gateStage && stageCount == gateAt { await gate?.wait() }
        if input.stage == "reconcile" { return try reconcileOutput?(input) ?? "{\"resolved\":[]}" }
        if let output { return try output(input) }
        return try Self.envelope([
            Self.item(documentID: input.documentID, quote: String(input.chunk.prefix(6_000)), text: "Observed source")
        ])
    }

    nonisolated static func item(
        documentID: String, quote: String, text: String = "Send the report", kind: String = "action",
        commitment: String = "confirmed", owner: String? = nil, deadline: String? = nil
    ) -> [String: Any] {
        [
            "kind": kind, "commitment": commitment, "text": text,
            "owner": owner.map { $0 as Any } ?? NSNull(), "deadline": deadline.map { $0 as Any } ?? NSNull(),
            "evidence": [["documentID": documentID, "quote": quote]],
        ]
    }

    nonisolated static func envelope(_ items: [[String: Any]]) throws -> String {
        String(
            decoding: try JSONSerialization.data(withJSONObject: ["items": items], options: [.sortedKeys]),
            as: UTF8.self)
    }

    nonisolated static func resolution(_ input: BoardFixtureInput, quote: String, documentID: String? = nil) throws
        -> String
    {
        let values = input.candidateIDs.map { id in
            ["itemID": id, "resolutionDocumentID": documentID ?? input.documentID, "resolutionQuote": quote]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["resolved": values]), as: UTF8.self)
    }

    nonisolated static func reopening(_ input: BoardFixtureInput, quote: String) throws -> String {
        let values = input.candidateIDs.map { id in
            ["itemID": id, "reopeningDocumentID": input.documentID, "reopeningQuote": quote]
        }
        return String(
            decoding: try JSONSerialization.data(withJSONObject: ["resolved": [], "reopened": values]), as: UTF8.self)
    }
}

@MainActor
final class MeetingBoardEngineTests: XCTestCase {
    private func session(_ fixture: BoardFixture, key: String = "account-A") -> LiveAnswerStreamSession {
        LiveAnswerStreamSession(cacheKey: key, validate: { try await fixture.validate() }) { messages in
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        continuation.yield(try await fixture.respond(messages))
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { @Sendable _ in task.cancel() }
            }
        }
    }

    private func document(
        _ text: String, id: String = "current", kind: MeetingEvidenceDocument.Kind = .currentTranscript
    ) -> MeetingEvidenceDocument {
        MeetingEvidenceDocument(id: id, kind: kind, title: "Meeting", text: text)
    }

    private func waitUntilEntered(_ gate: BoardFixtureGate) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await gate.entered), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        let entered = await gate.entered; XCTAssertTrue(entered)
    }

    func testFabricatedQuotationAndUnsupportedOwnerOrDeadlineAreDiscarded() async throws {
        let source = "Maya will send the report by Friday."
        let fixture = BoardFixture(output: { input in
            try BoardFixture.envelope([
                BoardFixture.item(documentID: input.documentID, quote: input.chunk, owner: "Maya", deadline: "Friday"),
                BoardFixture.item(documentID: input.documentID, quote: "This was never said."),
                BoardFixture.item(documentID: input.documentID, quote: input.chunk, owner: "Ajay"),
                BoardFixture.item(documentID: input.documentID, quote: input.chunk, deadline: "Monday"),
                BoardFixture.item(documentID: "other-document", quote: input.chunk),
            ])
        })
        let snapshot = try await MeetingBoardEngine().update(
            scopeKey: "recording", documents: [document(source)], session: session(fixture))
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.items.first?.owner, "Maya")
        XCTAssertEqual(snapshot.items.first?.deadline, "Friday")
        XCTAssertTrue(snapshot.coverageDescription.contains("Filtered 4"))
        let evidence = try XCTUnwrap(snapshot.items.first?.evidence.first)
        XCTAssertEqual(snapshot.resolvedQuote(evidence), source)
        XCTAssertNil(snapshot.resolvedQuote(.init(documentID: "current", quote: "Never said")))
    }

    func testCanonicalUnicodeEquivalenceDoesNotEstablishExactQuotation() async throws {
        let fixture = BoardFixture(output: { input in
            try BoardFixture.envelope([BoardFixture.item(documentID: input.documentID, quote: "Café")])
        })
        let snapshot = try await MeetingBoardEngine().update(
            scopeKey: "recording", documents: [document("Cafe\u{301}")], session: session(fixture))
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertTrue(snapshot.coverageDescription.contains("Filtered 1"))
    }

    func testAllNotesIncludingSuffixAreProcessedInBoundedOverlappingChunks() async throws {
        let source = (0..<12).map { "Ordinary note \($0) 🧑🏽‍💻. " }.joined() + "TAIL_ACTION"
        let fixture = BoardFixture()
        let engine = MeetingBoardEngine(chunkCharacters: 40, overlapCharacters: 6)
        let snapshot = try await engine.update(
            scopeKey: "recording", documents: [document(source, kind: .currentNotes)], session: session(fixture))
        let inputs = await fixture.inputs
        var reconstructed = ""
        for (index, input) in inputs.enumerated() {
            XCTAssertLessThanOrEqual(input.chunk.count, 40)
            reconstructed += String(input.chunk.dropFirst(index == 0 ? 0 : 6))
        }
        XCTAssertEqual(reconstructed, source)
        XCTAssertTrue(inputs.last?.chunk.contains("TAIL_ACTION") == true)
        XCTAssertTrue(snapshot.coverageDescription.contains("all \(source.count)"))
        XCTAssertTrue(snapshot.items.allSatisfy { $0.commitment == .noted })
    }

    func testNotesRemainWrittenIntentAndPriorItemsStayHistorical() async throws {
        let docs = [
            document("Ask Maya about renewal.", id: "note", kind: .currentNotes),
            document("Maya will send the report.", id: "prior", kind: .previousTranscript),
            document("Check the old action.", id: "prior-note", kind: .previousNotes),
        ]
        let snapshot = try await MeetingBoardEngine().update(
            scopeKey: "recording", documents: docs, session: session(BoardFixture()))
        let note = try XCTUnwrap(snapshot.items.first { $0.evidence.first?.documentID == "note" })
        let prior = try XCTUnwrap(snapshot.items.first { $0.evidence.first?.documentID == "prior" })
        let priorNote = try XCTUnwrap(snapshot.items.first { $0.evidence.first?.documentID == "prior-note" })
        XCTAssertEqual(note.commitment, .noted)
        XCTAssertEqual(note.provenanceLabel(in: docs), "Your note")
        XCTAssertEqual(prior.commitment, .confirmed)
        XCTAssertTrue(prior.provenanceLabel(in: docs).contains("completion unverified"))
        XCTAssertEqual(priorNote.commitment, .noted)
        XCTAssertTrue(priorNote.provenanceLabel(in: docs).contains("Previous meeting note"))
        XCTAssertTrue(snapshot.quotedContext.contains("historical_completion"))
    }

    func testUnchangedChunksAreCachedAndAppendOnlyReprocessesGrowingTail() async throws {
        let fixture = BoardFixture()
        let engine = MeetingBoardEngine(chunkCharacters: 20, overlapCharacters: 4)
        let initial = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHI"
        let first = try await engine.update(
            scopeKey: "recording", documents: [document(initial)], session: session(fixture))
        let initialCount = await fixture.inputs.count
        let same = try await engine.update(
            scopeKey: "recording", documents: [document(initial)], session: session(fixture))
        let unchangedCount = await fixture.inputs.count
        XCTAssertEqual(unchangedCount, initialCount)
        XCTAssertEqual(first.items, same.items)
        let appended = try await engine.update(
            scopeKey: "recording", documents: [document(initial + "tail")], session: session(fixture))
        let appendedCount = await fixture.inputs.count
        XCTAssertEqual(appendedCount, initialCount + 1)
        XCTAssertNotEqual(first.sourceFingerprint, appended.sourceFingerprint)
    }

    func testCorrectionAccountAndResetInvalidateCachedCoverage() async throws {
        let fixture = BoardFixture()
        let engine = MeetingBoardEngine(chunkCharacters: 20, overlapCharacters: 4)
        let initial = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHI"
        _ = try await engine.update(scopeKey: "recording", documents: [document(initial)], session: session(fixture))
        let firstCount = await fixture.inputs.count
        let corrected = "X" + String(initial.dropFirst())
        _ = try await engine.update(scopeKey: "recording", documents: [document(corrected)], session: session(fixture))
        let correctedCount = await fixture.inputs.count
        XCTAssertEqual(correctedCount, firstCount * 2)
        _ = try await engine.update(
            scopeKey: "recording", documents: [document(corrected)], session: session(fixture, key: "account-B"))
        let accountCount = await fixture.inputs.count
        XCTAssertEqual(accountCount, firstCount * 3)
        await engine.reset()
        _ = try await engine.update(
            scopeKey: "recording", documents: [document(corrected)], session: session(fixture, key: "account-B"))
        let resetCount = await fixture.inputs.count
        XCTAssertEqual(resetCount, firstCount * 4)
    }

    func testCancellationCannotEstablishCachedCoverage() async throws {
        let gate = BoardFixtureGate()
        let fixture = BoardFixture(gate: gate)
        let engine = MeetingBoardEngine()
        let docs = [document("Maya will send the report.")]
        let pinned = session(fixture)
        let task = Task { try await engine.update(scopeKey: "recording", documents: docs, session: pinned) }
        try await waitUntilEntered(gate)
        task.cancel()
        await gate.open()
        do { _ = try await task.value; XCTFail("Cancelled extraction published") } catch is CancellationError {} catch {
            XCTFail("Unexpected \(error)")
        }
        _ = try await engine.update(scopeKey: "recording", documents: docs, session: pinned)
        let count = await fixture.inputs.count; XCTAssertEqual(count, 2)
    }

    func testResetInvalidatesInFlightGeneration() async throws {
        let gate = BoardFixtureGate()
        let fixture = BoardFixture(gate: gate)
        let engine = MeetingBoardEngine()
        let docs = [document("Maya will send the report.")]
        let pinned = session(fixture)
        let task = Task { try await engine.update(scopeKey: "recording", documents: docs, session: pinned) }
        try await waitUntilEntered(gate)
        await engine.reset()
        await gate.open()
        do { _ = try await task.value; XCTFail("Reset generation published") } catch is CancellationError {} catch {
            XCTFail("Unexpected \(error)")
        }
        _ = try await engine.update(scopeKey: "recording", documents: docs, session: pinned)
        let count = await fixture.inputs.count; XCTAssertEqual(count, 2)
    }

    func testProviderChangeBeforeCompletionCannotEstablishCachedCoverage() async throws {
        let gate = BoardFixtureGate()
        let fixture = BoardFixture(gate: gate)
        let engine = MeetingBoardEngine()
        let docs = [document("Maya will send the report.")]
        let pinned = session(fixture)
        let task = Task { try await engine.update(scopeKey: "recording", documents: docs, session: pinned) }
        try await waitUntilEntered(gate)
        await fixture.setValid(false)
        await gate.open()
        do { _ = try await task.value; XCTFail("Changed provider published") } catch BoardFixtureError.providerChanged {
        } catch { XCTFail("Unexpected \(error)") }
        await fixture.setValid(true)
        _ = try await engine.update(scopeKey: "recording", documents: docs, session: pinned)
        let count = await fixture.inputs.count; XCTAssertEqual(count, 2)
    }

    func testEmptySourcesDoNotRunInferenceAndAmbiguousIDsAreRejected() async throws {
        let fixture = BoardFixture()
        let engine = MeetingBoardEngine()
        let empty = try await engine.update(
            scopeKey: "recording", documents: [document(" \n ")], session: session(fixture))
        XCTAssertTrue(empty.items.isEmpty)
        let count = await fixture.inputs.count; XCTAssertEqual(count, 0)
        do {
            _ = try await engine.update(
                scopeKey: "recording", documents: [document("a"), document("b")], session: session(fixture))
            XCTFail("Duplicate document identity accepted")
        } catch MeetingBoardError.invalidDocuments {} catch { XCTFail("Unexpected \(error)") }
    }

    func testStrictEnvelopeAndOutputBounds() async throws {
        for output in ["```json\n{\"items\":[]}\n```", "{\"items\":[],\"extra\":true}"] {
            let fixture = BoardFixture(output: { _ in output })
            do {
                _ = try await MeetingBoardEngine().update(
                    scopeKey: "recording", documents: [document("Source")], session: session(fixture))
                XCTFail("Malformed envelope accepted")
            } catch MeetingBoardError.invalidResponse {} catch { XCTFail("Unexpected \(error)") }
        }
        let oversized = BoardFixture(output: { _ in String(repeating: "x", count: 96_001) })
        do {
            _ = try await MeetingBoardEngine().update(
                scopeKey: "recording", documents: [document("Source")], session: session(oversized))
            XCTFail("Oversized response accepted")
        } catch MeetingBoardError.outputTooLarge {} catch { XCTFail("Unexpected \(error)") }
    }

    func testBoundedBoardAndQuotedContextDiscloseOmittedItemsWithoutClippingQuotes() async throws {
        let fixture = BoardFixture(output: { input in
            try BoardFixture.envelope(
                (0..<6).map { index in
                    BoardFixture.item(documentID: input.documentID, quote: input.chunk, text: "Action \(index)")
                })
        })
        let snapshot = try await MeetingBoardEngine(chunkCharacters: 100, overlapCharacters: 4, maximumItems: 2).update(
            scopeKey: "recording", documents: [document("Maya will send the report.")], session: session(fixture))
        XCTAssertEqual(snapshot.items.count, 2)
        XCTAssertTrue(snapshot.coverageDescription.contains("omitted 4"))

        let quote = String(repeating: "Exact quotation. ", count: 100)
        let evidence = [MeetingEvidenceQuote(documentID: "current", quote: quote)]
        let items = (0..<20).map {
            MeetingBoardItem(kind: .action, commitment: .proposed, text: "Action \($0)", evidence: evidence)
        }
        let large = MeetingBoardSnapshot(
            scopeKey: "recording", documents: [document(quote)], items: items,
            coverageDescription: "All sources processed")
        let context = large.quotedContext
        XCTAssertLessThanOrEqual(context.count, 8_000)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(context.utf8)) as? [String: Any])
        XCTAssertGreaterThan(try XCTUnwrap(json["omitted_items"] as? Int), 0)
        let records = try XCTUnwrap(json["items"] as? [[String: Any]])
        for record in records {
            let quotes = try XCTUnwrap(record["evidence"] as? [[String: Any]])
            XCTAssertEqual(quotes.first?["quote"] as? String, quote)
        }
        let decoded = try JSONDecoder().decode(MeetingBoardSnapshot.self, from: JSONEncoder().encode(large))
        XCTAssertEqual(decoded, large)
        XCTAssertEqual(decoded.items.first?.id, large.items.first?.id)
    }

    func testLaterAnswerResolvesQuestionAndUnchangedSnapshotCachesReconciliation() async throws {
        let question = "What is the launch date?"
        let answer = "The launch date is Friday."
        let fixture = BoardFixture(
            reconcile: { input in try BoardFixture.resolution(input, quote: answer) },
            output: { input in
                try BoardFixture.envelope([
                    BoardFixture.item(
                        documentID: input.documentID, quote: question, text: question, kind: "question",
                        commitment: "unresolved")
                ])
            })
        let engine = MeetingBoardEngine()
        let docs = [document(question + "\n" + answer)]
        let first = try await engine.update(scopeKey: "recording", documents: docs, session: session(fixture))
        XCTAssertTrue(first.items.isEmpty)
        XCTAssertEqual(first.resolvedItems.count, 1)
        let resolved = try XCTUnwrap(first.resolvedItems.first)
        XCTAssertEqual(resolved.resolutionEvidence?.quote, answer)
        XCTAssertEqual(resolved.provenanceLabel(in: docs), "Resolved in current meeting")
        XCTAssertEqual(first.resolvedQuote(try XCTUnwrap(resolved.resolutionEvidence)), answer)
        _ = try await engine.update(scopeKey: "recording", documents: docs, session: session(fixture))
        let resolutionCount = await fixture.resolutionInputs.count; XCTAssertEqual(resolutionCount, 1)
    }

    func testCorrectedAnswerReopensPreviouslyResolvedQuestion() async throws {
        let question = "What is the launch date?"
        let answer = "The launch date is Friday."
        let fixture = BoardFixture(
            reconcile: { input in
                if input.chunk.contains(answer) { return try BoardFixture.resolution(input, quote: answer) }
                return "{\"resolved\":[]}"
            },
            output: { input in
                try BoardFixture.envelope([
                    BoardFixture.item(
                        documentID: input.documentID, quote: question, text: question, kind: "question",
                        commitment: "unresolved")
                ])
            })
        let engine = MeetingBoardEngine()
        let closed = try await engine.update(
            scopeKey: "recording", documents: [document(question + "\n" + answer)], session: session(fixture))
        XCTAssertEqual(closed.resolvedItems.count, 1)
        let reopened = try await engine.update(
            scopeKey: "recording", documents: [document(question + "\nThe date is still unknown.")],
            session: session(fixture))
        XCTAssertEqual(reopened.items.count, 1)
        XCTAssertTrue(reopened.resolvedItems.isEmpty)
    }

    func testEarlierSpeechOwnQuestionAndFabricatedQuoteCannotResolve() async throws {
        let question = "What is the launch date?"
        let earlier = "The old launch date was Friday."
        for invalid in [question, earlier, "The launch date is Monday."] {
            let fixture = BoardFixture(
                reconcile: { input in try BoardFixture.resolution(input, quote: invalid) },
                output: { input in
                    try BoardFixture.envelope([
                        BoardFixture.item(
                            documentID: input.documentID, quote: question, text: question, kind: "question",
                            commitment: "unresolved")
                    ])
                })
            let snapshot = try await MeetingBoardEngine().update(
                scopeKey: "recording",
                documents: [document(earlier + "\n" + question + "\nWe moved to another topic.")],
                session: session(fixture))
            XCTAssertEqual(snapshot.items.count, 1)
            XCTAssertTrue(snapshot.resolvedItems.isEmpty)
        }
    }

    func testSilenceDoesNotResolveAndSingleCompleteEvidenceNeedsNoReconciliationCall() async throws {
        let question = "What is the launch date?"
        let fixture = BoardFixture(output: { input in
            try BoardFixture.envelope([
                BoardFixture.item(
                    documentID: input.documentID, quote: question, text: question, kind: "question",
                    commitment: "unresolved")
            ])
        })
        let engine = MeetingBoardEngine()
        let first = try await engine.update(
            scopeKey: "recording", documents: [document(question)], session: session(fixture))
        let later = try await engine.update(
            scopeKey: "recording", documents: [document(question)], session: session(fixture))
        XCTAssertEqual(first.items, later.items)
        XCTAssertTrue(later.resolvedItems.isEmpty)
        let resolutionCount = await fixture.resolutionInputs.count; XCTAssertEqual(resolutionCount, 0)
    }

    func testHistoricalActionRequiresCurrentTranscriptCompletionAndNotesCannotCompleteIt() async throws {
        let action = "Maya will send the report."
        let completion = "Maya has sent the report."
        let fixture = BoardFixture(
            reconcile: { input in
                input.documentID == "current"
                    ? try BoardFixture.resolution(input, quote: completion) : "{\"resolved\":[]}"
            },
            output: { input in
                try BoardFixture.envelope(
                    input.documentID == "prior"
                        ? [
                            BoardFixture.item(documentID: input.documentID, quote: action)
                        ] : [])
            })
        let prior = document(action, id: "prior", kind: .previousTranscript)
        let notesOnly = try await MeetingBoardEngine().update(
            scopeKey: "recording", documents: [prior, document(completion, kind: .currentNotes)],
            session: session(fixture))
        XCTAssertEqual(notesOnly.items.count, 1)
        XCTAssertTrue(notesOnly.resolvedItems.isEmpty)
        let spoken = try await MeetingBoardEngine().update(
            scopeKey: "recording", documents: [prior, document(completion)], session: session(fixture))
        XCTAssertTrue(spoken.items.isEmpty)
        XCTAssertEqual(spoken.resolvedItems.first?.resolutionEvidence?.quote, completion)
        XCTAssertEqual(spoken.resolvedItems.first?.provenanceLabel(in: spoken.documents), "Resolved in current meeting")
    }

    func testProposalAndConditionRemainVisibleAndMalformedReconciliationFails() async throws {
        let proposal = "We could send the report if approval arrives."
        let fixture = BoardFixture(
            reconcile: { input in try BoardFixture.resolution(input, quote: "We discussed it.") },
            output: { input in
                try BoardFixture.envelope(
                    ["proposed", "conditional"].map { commitment in
                        BoardFixture.item(
                            documentID: input.documentID, quote: proposal, text: proposal, commitment: commitment)
                    })
            })
        let snapshot = try await MeetingBoardEngine().update(
            scopeKey: "recording", documents: [document(proposal + "\nWe discussed it.")], session: session(fixture))
        XCTAssertEqual(snapshot.items.count, 2)
        XCTAssertTrue(snapshot.items.allSatisfy { $0.text.contains("if approval arrives") })
        XCTAssertTrue(snapshot.resolvedItems.isEmpty)
        let count = await fixture.resolutionInputs.count; XCTAssertEqual(count, 0)

        let malformed = BoardFixture(
            reconcile: { _ in "{\"items\":[]}" },
            output: { input in
                try BoardFixture.envelope([
                    BoardFixture.item(documentID: input.documentID, quote: "Send the report.", text: "Send the report")
                ])
            })
        do {
            _ = try await MeetingBoardEngine().update(
                scopeKey: "recording", documents: [document("Send the report. Later discussion.")],
                session: session(malformed))
            XCTFail("Malformed reconciliation claimed success")
        } catch MeetingBoardError.invalidResponse {} catch { XCTFail("Unexpected \(error)") }
    }

    func testSpokenRetractionReopensCompletedActionAndOnlyLaterCompletionClosesItAgain() async throws {
        let action = "Maya will send the report."
        let completion = "Maya: I have sent the report."
        let retraction = "Maya: Correction, I have not sent the report."
        let finalCompletion = "Maya: The report is now actually sent."
        let fixture = BoardFixture(
            reconcile: { input in
                if input.chunk.contains(finalCompletion) {
                    return try BoardFixture.resolution(input, quote: finalCompletion)
                }
                if input.chunk.contains(retraction) { return try BoardFixture.reopening(input, quote: retraction) }
                return try BoardFixture.resolution(input, quote: completion)
            },
            output: { input in
                try BoardFixture.envelope([BoardFixture.item(documentID: input.documentID, quote: action)])
            })
        let engine = MeetingBoardEngine()
        let initial = action + "\n" + completion
        let closed = try await engine.update(
            scopeKey: "recording", documents: [document(initial)], session: session(fixture))
        XCTAssertEqual(closed.resolvedItems.count, 1)
        let reopened = try await engine.update(
            scopeKey: "recording", documents: [document(initial + "\n" + retraction)], session: session(fixture))
        XCTAssertTrue(reopened.resolvedItems.isEmpty)
        XCTAssertEqual(reopened.items.first?.reopeningEvidence?.quote, retraction)
        XCTAssertEqual(reopened.items.first?.provenanceLabel(in: reopened.documents), "Reopened in current meeting")
        let reclosed = try await engine.update(
            scopeKey: "recording", documents: [document(initial + "\n" + retraction + "\n" + finalCompletion)],
            session: session(fixture))
        XCTAssertTrue(reclosed.items.isEmpty)
        XCTAssertEqual(reclosed.resolvedItems.first?.resolutionEvidence?.quote, finalCompletion)
        XCTAssertEqual(reclosed.resolvedItems.first?.reopeningEvidence?.quote, retraction)
        XCTAssertEqual(closed.resolvedItems.first?.id, reclosed.resolvedItems.first?.id)
    }

    func testRetractedAnswerStaysOpenWhenModelTriesToReuseTheOldAnswer() async throws {
        let question = "What is the launch date?"
        let answer = "The launch date is Friday."
        let retraction = "Correction: Friday is wrong; the launch date is still unknown."
        let fixture = BoardFixture(
            reconcile: { input in
                if !input.reopenedCandidateIDs.isEmpty { return try BoardFixture.resolution(input, quote: answer) }
                if input.chunk.contains(retraction) { return try BoardFixture.reopening(input, quote: retraction) }
                return try BoardFixture.resolution(input, quote: answer)
            },
            output: { input in
                try BoardFixture.envelope([
                    BoardFixture.item(
                        documentID: input.documentID, quote: question, text: question, kind: "question",
                        commitment: "unresolved")
                ])
            })
        let engine = MeetingBoardEngine()
        let initial = question + "\n" + answer
        _ = try await engine.update(scopeKey: "recording", documents: [document(initial)], session: session(fixture))
        let corrected = initial + "\n" + retraction
        let reopened = try await engine.update(
            scopeKey: "recording", documents: [document(corrected)], session: session(fixture))
        XCTAssertEqual(reopened.items.first?.reopeningEvidence?.quote, retraction)
        let stillOpen = try await engine.update(
            scopeKey: "recording", documents: [document(corrected + "\nCould you repeat that?")],
            session: session(fixture))
        XCTAssertEqual(stillOpen.items.count, 1)
        XCTAssertTrue(stillOpen.resolvedItems.isEmpty)
    }

    func testSilenceAndNotesDoNotReopenResolvedWork() async throws {
        let action = "Maya will send the report."
        let completion = "Maya has sent the report."
        let fixture = BoardFixture(
            reconcile: { input in try BoardFixture.resolution(input, quote: completion) },
            output: { input in
                try BoardFixture.envelope(
                    input.documentID == "current"
                        ? [BoardFixture.item(documentID: input.documentID, quote: action)] : [])
            })
        let engine = MeetingBoardEngine()
        let transcript = document(action + "\n" + completion)
        let first = try await engine.update(scopeKey: "recording", documents: [transcript], session: session(fixture))
        let silence = try await engine.update(scopeKey: "recording", documents: [transcript], session: session(fixture))
        XCTAssertEqual(first.resolvedItems, silence.resolvedItems)
        let notes = document("Actually I think that report may be unfinished.", id: "notes", kind: .currentNotes)
        let withNotes = try await engine.update(
            scopeKey: "recording", documents: [transcript, notes], session: session(fixture))
        XCTAssertEqual(withNotes.resolvedItems.count, 1)
        XCTAssertTrue(withNotes.items.isEmpty)
        XCTAssertNil(withNotes.resolvedItems.first?.reopeningEvidence)
    }

    func testMultipleExplicitTransitionsInOneChunkFollowRawSourceChronology() async throws {
        let action = "Maya will send the report."
        let completion = "Maya has sent the report."
        let retraction = "Correction: Maya has not sent the report."
        let finalCompletion = "Now Maya has actually sent the report."
        let fixture = BoardFixture(
            reconcile: { input in
                let closed = input.candidateIDs.flatMap { id in
                    [completion, finalCompletion].map { quote in
                        ["itemID": id, "resolutionDocumentID": input.documentID, "resolutionQuote": quote]
                    }
                }
                let opened = input.candidateIDs.map { id in
                    ["itemID": id, "reopeningDocumentID": input.documentID, "reopeningQuote": retraction]
                }
                return String(
                    decoding: try JSONSerialization.data(withJSONObject: ["resolved": closed, "reopened": opened]),
                    as: UTF8.self)
            },
            output: { input in
                try BoardFixture.envelope([BoardFixture.item(documentID: input.documentID, quote: action)])
            })
        let text = [action, completion, retraction, finalCompletion].joined(separator: "\n")
        let snapshot = try await MeetingBoardEngine().update(
            scopeKey: "recording", documents: [document(text)], session: session(fixture))
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertEqual(snapshot.resolvedItems.first?.resolutionEvidence?.quote, finalCompletion)
        XCTAssertEqual(snapshot.resolvedItems.first?.reopeningEvidence?.quote, retraction)
    }

    func testCompletedExtractionChunkSurvivesPreemptionWhilePartialSecondChunkDoesNot() async throws {
        let gate = BoardFixtureGate()
        let fixture = BoardFixture(gate: gate, gateAt: 2)
        let engine = MeetingBoardEngine(chunkCharacters: 20, overlapCharacters: 4)
        let docs = [document("0123456789abcdefghijklmnopqrstuvwxyz")]
        let pinned = session(fixture)
        let first = Task { try await engine.update(scopeKey: "recording", documents: docs, session: pinned) }
        try await waitUntilEntered(gate)
        first.cancel()
        await gate.open()
        do { _ = try await first.value; XCTFail("Preempted pass published") } catch is CancellationError {} catch {
            XCTFail("Unexpected \(error)")
        }
        let snapshot = try await engine.update(scopeKey: "recording", documents: docs, session: pinned)
        let inputs = await fixture.inputs
        XCTAssertEqual(inputs.count, 3)
        XCTAssertEqual(inputs.filter { $0.chunk == inputs[0].chunk }.count, 1)
        XCTAssertEqual(inputs.filter { $0.chunk == inputs[1].chunk }.count, 2)
        XCTAssertTrue(snapshot.coverageDescription.contains("all 36"))
    }

    func testCompletedReconciliationResponseSurvivesPreemptionWithoutPublishingPartialBoard() async throws {
        let question = "Question?"
        let gate = BoardFixtureGate()
        let fixture = BoardFixture(
            gate: gate, gateAt: 2, gateStage: "reconcile",
            output: { input in
                try BoardFixture.envelope(
                    input.chunk.contains(question)
                        ? [
                            BoardFixture.item(
                                documentID: input.documentID, quote: question, text: question, kind: "question",
                                commitment: "unresolved")
                        ] : [])
            })
        let engine = MeetingBoardEngine(chunkCharacters: 40, overlapCharacters: 4)
        let docs = [document(question + String(repeating: "x", count: 80))]
        let pinned = session(fixture)
        let first = Task { try await engine.update(scopeKey: "recording", documents: docs, session: pinned) }
        try await waitUntilEntered(gate)
        first.cancel()
        await gate.open()
        do { _ = try await first.value; XCTFail("Preempted pass published") } catch is CancellationError {} catch {
            XCTFail("Unexpected \(error)")
        }
        let snapshot = try await engine.update(scopeKey: "recording", documents: docs, session: pinned)
        let extractionCount = await fixture.inputs.count
        let responses = await fixture.resolutionInputs
        XCTAssertEqual(extractionCount, 3)
        XCTAssertEqual(responses.count, 4)
        XCTAssertEqual(responses.filter { $0.chunk == responses[0].chunk }.count, 1)
        XCTAssertEqual(responses.filter { $0.chunk == responses[1].chunk }.count, 2)
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertTrue(snapshot.resolvedItems.isEmpty)
    }
}
