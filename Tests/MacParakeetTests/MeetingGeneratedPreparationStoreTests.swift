import XCTest
@testable import MacParakeetCore

private enum PreparationCleanupFixtureError: Error { case requestedFailure }

final class MeetingGeneratedPreparationStoreTests: XCTestCase {
    func testAtomicRoundTripUsesPrivateHashedPathAndPreservesExactEventTitle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingGeneratedPreparationStore(directoryURL: directory)
        let key = MeetingPreparationKey(calendarID: "../private-calendar", eventID: "meeting/instance")
        let original = value(key: key)
        try await store.save(original)
        let restored = try await store.load(key: key)
        XCTAssertEqual(restored, original)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].lastPathComponent.count, 69)
        XCTAssertFalse(files[0].lastPathComponent.contains("private"))
        let attributes = try FileManager.default.attributesOfItem(atPath: files[0].path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let second = value(key: key, title: "  Renamed — Unicode 🦜  ")
        try await store.save(second)
        let replacement = try await store.load(key: key)
        XCTAssertEqual(replacement, second)
    }

    func testMissingAndCorruptDerivedArtifactsDoNotTouchOtherKeys() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingGeneratedPreparationStore(directoryURL: directory)
        let missing = try await store.load(key: .init(calendarID: "none", eventID: "none"))
        XCTAssertNil(missing)
        let key = MeetingPreparationKey(calendarID: "calendar", eventID: "chosen")
        try await store.save(value(key: key))
        let file = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { !$0.lastPathComponent.hasPrefix(".") })
        try Data("invalid".utf8).write(to: file)
        do {
            _ = try await store.load(key: key)
            XCTFail("Corrupt generated preparation must not be accepted.")
        } catch MeetingGeneratedPreparationStoreError.invalidFile {}
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: file.path), "No implicit deletion of user-local artifacts.")
    }

    func testPurgeRemovesOnlyExactSourceReferencesAndPreservesOtherPreparation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingGeneratedPreparationStore(directoryURL: directory)
        let sourceID = UUID()
        let matching = value(key: .init(calendarID: "calendar", eventID: "matching"), sourceID: sourceID)
        let other = value(key: .init(calendarID: "calendar", eventID: "other"), sourceID: UUID())
        try await store.save(matching)
        try await store.save(other)
        let none = try await store.purge(transcriptionIDs: [UUID()])
        XCTAssertTrue(none.isEmpty)
        let matchingBefore = try await store.load(key: matching.key)
        let otherBefore = try await store.load(key: other.key)
        XCTAssertEqual(matchingBefore, matching)
        XCTAssertEqual(otherBefore, other)
        let removed = try await store.purge(transcriptionIDs: [sourceID])
        XCTAssertEqual(removed, [matching.key])
        let matchingAfter = try await store.load(key: matching.key)
        let otherAfter = try await store.load(key: other.key)
        XCTAssertNil(matchingAfter)
        XCTAssertEqual(otherAfter, other)
        XCTAssertTrue(store.isPurged(matching), "Loaded UI preparation must be invalidated synchronously")
        XCTAssertFalse(store.isPurged(other))
    }

    func testDurablePurgeRejectsLateCapturedSaveAcrossStoreInstances() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceID = UUID()
        let captured = value(key: .init(calendarID: "calendar", eventID: "held-result"), sourceID: sourceID)
        let store = MeetingGeneratedPreparationStore(directoryURL: directory)
        try await store.save(captured)
        try await store.purge(transcriptionIDs: [sourceID])
        let reopened = MeetingGeneratedPreparationStore(directoryURL: directory)
        do {
            try await reopened.save(captured)
            XCTFail("A late generation cannot recreate private copies of the deleted source")
        } catch MeetingGeneratedPreparationStoreError.sourceDeleted {}
        let restored = try await reopened.load(key: captured.key)
        XCTAssertNil(restored)
    }

    func testFailedOrNoopSourceDeletionPreservesArtifactsAndRollsBackIntent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceID = UUID()
        let original = value(key: .init(calendarID: "calendar", eventID: "selected"), sourceID: sourceID)
        let store = MeetingGeneratedPreparationStore(directoryURL: directory)
        try await store.save(original)
        do {
            _ = try MeetingGeneratedPreparationStore.withSourceDeletion([sourceID], directoryURL: directory) {
                throw PreparationCleanupFixtureError.requestedFailure
            }
            XCTFail("The failed deletion must propagate its error")
        } catch PreparationCleanupFixtureError.requestedFailure {}
        XCTAssertFalse(store.isPurged(original))
        let afterFailure = try await store.load(key: original.key)
        XCTAssertEqual(afterFailure, original)
        XCTAssertFalse(
            try MeetingGeneratedPreparationStore.withSourceDeletion([sourceID], directoryURL: directory) { false })
        XCTAssertFalse(store.isPurged(original))
        let afterNoop = try await store.load(key: original.key)
        XCTAssertEqual(afterNoop, original)
        XCTAssertTrue(
            try MeetingGeneratedPreparationStore.withSourceDeletion([sourceID], directoryURL: directory) { true })
        XCTAssertTrue(store.isPurged(original))
        let afterDeletion = try await store.load(key: original.key)
        XCTAssertNil(afterDeletion)
    }

    func testFailedFileRemovalRetainsDurableIntentAndNextLoadRetriesWithoutReuse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceID = UUID()
        let original = value(key: .init(calendarID: "calendar", eventID: "selected"), sourceID: sourceID)
        let failing = MeetingGeneratedPreparationStore(directoryURL: directory) { _ in
            throw PreparationCleanupFixtureError.requestedFailure
        }
        try await failing.save(original)
        do {
            try await failing.purge(transcriptionIDs: [sourceID])
            XCTFail("A file failure must be visible")
        } catch PreparationCleanupFixtureError.requestedFailure {}
        XCTAssertTrue(failing.isPurged(original))
        do {
            _ = try await failing.load(key: original.key)
            XCTFail("Failed cleanup must never return the deleted private source")
        } catch PreparationCleanupFixtureError.requestedFailure {}
        let retry = MeetingGeneratedPreparationStore(directoryURL: directory)
        let reloaded = try await retry.load(key: original.key)
        XCTAssertNil(reloaded, "The durable intent retries file cleanup on reload")
        do {
            try await retry.save(original)
            XCTFail("Successful cleanup cannot allow a delayed stale write")
        } catch MeetingGeneratedPreparationStoreError.sourceDeleted {}
    }

    func testPreparedContextFitsLiveBoundWithoutClippingQuotationRecords() throws {
        let quote = String(repeating: "A source quotation with details. ", count: 60)
        let document = MeetingEvidenceDocument(id: "prior", kind: .previousTranscript, title: "Prior", text: quote)
        let items = (0..<30).map { index in
            MeetingBoardItem(
                kind: .note, commitment: .noted, text: "Detail \(index)",
                evidence: [.init(documentID: "prior", quote: quote)])
        }
        let preparation = MeetingGeneratedPreparation(
            key: .init(calendarID: "calendar", eventID: "event"), projectID: UUID(), projectName: "Delivery",
            sourceScopeKey: "source", manualContextHash: "manual", eventTitle: "Upcoming", startTime: Date(),
            board: .init(
                scopeKey: "source", documents: [document], items: items, coverageDescription: "All source processed."),
            providerIdentityHash: "provider", sourceStatus: "Historical source.")
        let context = preparation.quotedContext
        XCTAssertLessThanOrEqual(context.count, 8_000)
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(context.utf8)) as? [String: Any])
        let board = try XCTUnwrap(decoded["latest_meeting_evidence_board"] as? [String: Any])
        let retained = try XCTUnwrap(board["items"] as? [[String: Any]])
        XCTAssertFalse(retained.isEmpty)
        for item in retained {
            let evidence = try XCTUnwrap(item["evidence"] as? [[String: Any]])
            XCTAssertEqual(evidence.first?["quote"] as? String, quote)
        }
    }

    private func value(
        key: MeetingPreparationKey, title: String = "  Exact title  ", sourceID: UUID? = nil
    ) -> MeetingGeneratedPreparation {
        let documents =
            sourceID.map { id in
                [
                    MeetingEvidenceDocument(
                        id: id.uuidString + ":notes", kind: .previousNotes, title: "Saved prior notes",
                        text: "Private authored notes copied for preparation.")
                ]
            } ?? []
        return MeetingGeneratedPreparation(
            key: key, projectID: UUID(), projectName: "Delivery", sourceScopeKey: "current-source",
            manualContextHash: MeetingGeneratedPreparation.hash("My own agenda"), eventTitle: title, startTime: Date(),
            board: .init(
                scopeKey: "current-source", documents: documents, items: [], coverageDescription: "No source yet."),
            providerIdentityHash: MeetingGeneratedPreparation.hash("test-account"), sourceStatus: "No prior meeting.")
    }
}
