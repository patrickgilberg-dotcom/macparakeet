import GRDB
import XCTest
@testable import MacParakeetCore

final class MeetingProjectPreparationRepositoryTests: XCTestCase {
    private var manager: DatabaseManager!
    private var projects: MeetingProjectRepository!
    private var preparations: MeetingPreparationRepository!
    private var transcriptions: TranscriptionRepository!

    override func setUpWithError() throws {
        manager = try DatabaseManager()
        projects = MeetingProjectRepository(dbQueue: manager.dbQueue)
        preparations = MeetingPreparationRepository(dbQueue: manager.dbQueue)
        transcriptions = TranscriptionRepository(dbQueue: manager.dbQueue)
    }

    func testProjectCRUDAndFolderDeletionPreserveTranscript() throws {
        let project = MeetingProject(name: "  Tangerine  ")
        try projects.save(project)
        XCTAssertEqual(try projects.fetch(id: project.id)?.name, "Tangerine")
        let row = meeting(at: 10, text: "Preserved source.")
        try transcriptions.save(row)
        try projects.assign(transcriptionIDs: [row.id], to: project.id)
        XCTAssertEqual(try projects.project(for: row.id)?.id, project.id)
        XCTAssertEqual(try projects.projectIDs(for: [row.id]), [row.id: project.id])
        XCTAssertEqual(try projects.transcriptionIDs(in: project.id), [row.id])
        try projects.setArchived(id: project.id, isArchived: true)
        XCTAssertTrue(try projects.fetchAll().isEmpty)
        XCTAssertEqual(try projects.fetchAll(includeArchived: true).count, 1)
        XCTAssertTrue(try projects.delete(id: project.id))
        XCTAssertNil(try projects.project(for: row.id))
        XCTAssertEqual(try transcriptions.fetch(id: row.id)?.rawTranscript, row.rawTranscript)
        XCTAssertEqual(try transcriptions.fetch(id: row.id)?.filePath, row.filePath)
    }

    func testBulkMoveIsAtomicAndUnfileDoesNotTouchTranscriptionMetadata() throws {
        let first = MeetingProject(name: "First")
        let second = MeetingProject(name: "Second")
        try projects.save(first); try projects.save(second)
        let row = meeting(at: 10, text: "Existing words.")
        try transcriptions.save(row)
        try projects.assign(transcriptionIDs: [row.id], to: first.id)
        XCTAssertThrowsError(try projects.assign(transcriptionIDs: [row.id, UUID()], to: second.id))
        XCTAssertEqual(try projects.project(for: row.id)?.id, first.id)
        try projects.assign(transcriptionIDs: [row.id], to: second.id)
        XCTAssertEqual(try projects.project(for: row.id)?.id, second.id)
        try projects.assign(transcriptionIDs: [row.id], to: nil)
        XCTAssertNil(try projects.project(for: row.id))
        XCTAssertEqual(try transcriptions.fetch(id: row.id)?.updatedAt, row.updatedAt)
    }

    func testLatestIsSelectedBeforeReadinessWithoutOlderFallback() throws {
        let project = MeetingProject(name: "Pilot")
        try projects.save(project)
        let older = meeting(at: 10, text: "Old completed source.")
        var latest = meeting(at: 20, text: nil)
        latest.status = .processing
        try transcriptions.save(older); try transcriptions.save(latest)
        try projects.assign(transcriptionIDs: [older.id, latest.id], to: project.id)
        for (status, expected) in [
            (Transcription.TranscriptionStatus.processing, ProjectPreviousMeeting.State.processing),
            (.error, .failed), (.cancelled, .cancelled), (.completed, .empty),
        ] {
            latest.status = status
            try transcriptions.save(latest)
            let result = try XCTUnwrap(projects.latestPreviousMeeting(projectID: project.id, before: date(30)))
            XCTAssertEqual(result.transcriptionID, latest.id)
            XCTAssertEqual(result.state, expected)
            XCTAssertNil(result.effectiveTranscript)
        }
    }

    func testLatestIgnoresUpdatedDateFutureNonmeetingAndExcludedIDs() throws {
        let project = MeetingProject(name: "Project")
        try projects.save(project)
        var older = meeting(at: 10, text: "Earlier.")
        older.updatedAt = date(100)
        let latest = meeting(at: 20, text: "Latest imported meeting is eligible.")
        let future = meeting(at: 40, text: "Future.")
        let file = Transcription(
            createdAt: date(25), fileName: "File", rawTranscript: "Not a meeting.", status: .completed)
        for row in [older, latest, future, file] { try transcriptions.save(row) }
        try projects.assign(transcriptionIDs: [older.id, latest.id, future.id, file.id], to: project.id)
        XCTAssertEqual(
            try projects.latestPreviousMeeting(projectID: project.id, before: date(30))?.transcriptionID, latest.id)
        XCTAssertEqual(
            try projects.latestPreviousMeeting(
                projectID: project.id, before: date(30), excludingRecordingID: nil,
                excludingTranscriptionID: latest.id)?.transcriptionID,
            older.id)
        let recordingID = UUID()
        try preparations.saveRecordingAssociation(
            .init(
                recordingID: recordingID, projectID: project.id, titleSnapshot: "Snapshot", contextSnapshot: ""))
        try preparations.bindRecording(recordingID: recordingID, to: latest.id)
        XCTAssertEqual(
            try projects.latestPreviousMeeting(
                projectID: project.id, before: date(30), excludingRecordingID: recordingID,
                excludingTranscriptionID: nil)?.transcriptionID,
            older.id)
    }

    func testPreviousUsesEffectiveEditedTranscriptAndHash() throws {
        let project = MeetingProject(name: "Edited")
        try projects.save(project)
        var row = meeting(at: 10, text: "Outdated source.")
        row.cleanTranscript = "Corrected source with no approval."
        row.isTranscriptEdited = true
        try transcriptions.save(row)
        try projects.assign(transcriptionIDs: [row.id], to: project.id)
        let previous = try XCTUnwrap(projects.latestPreviousMeeting(projectID: project.id, before: date(30)))
        XCTAssertEqual(previous.state, .ready)
        XCTAssertEqual(previous.effectiveTranscript, row.cleanTranscript)
        XCTAssertEqual(previous.sourceHash, CardContentFingerprint.transcriptHash(for: row.cleanTranscript!))
        XCTAssertNotNil(previous.sourceFingerprint)
    }

    func testPreviousAppliesSpeakerCorrectionsAndRetainsRevision() async throws {
        let project = MeetingProject(name: "Corrected speakers")
        try projects.save(project)
        var row = meeting(at: 10, text: "Pending.")
        row.wordTimestamps = [.init(word: "Pending.", startMs: 0, endMs: 1_000, confidence: 1, speakerId: "S1")]
        row.speakers = [.init(id: "S1", label: "Speaker 1")]
        row.transcriptSegments = [
            .init(
                startMs: 0, endMs: 1_000, speakerId: "S1", speakerLabel: "Speaker 1",
                text: "Pending.", wordRange: .init(startIndex: 0, endIndexExclusive: 1))
        ]
        try transcriptions.save(row)
        try projects.assign(transcriptionIDs: [row.id], to: project.id)
        let before = try XCTUnwrap(projects.latestPreviousMeeting(projectID: project.id, before: date(30)))
        let input = try XCTUnwrap(
            SpeakerAttributionReadService(dbQueue: manager.dbQueue).resolve(transcriptionId: row.id))
        _ = try await SpeakerCorrectionService(dbQueue: manager.dbQueue).apply(
            transcriptionId: row.id, command: .rename(speakerID: "S1", label: "Alice"),
            expectedFingerprint: input.attribution.fingerprint, expectedRevision: 0)
        let after = try XCTUnwrap(projects.latestPreviousMeeting(projectID: project.id, before: date(30)))
        XCTAssertTrue(after.effectiveTranscript?.contains("Alice") == true)
        XCTAssertEqual(after.correctionRevision, 1)
        XCTAssertNotEqual(before.sourceHash, after.sourceHash)
    }

    func testSplitChildCannotDisplaceLatestActualMeeting() throws {
        let project = MeetingProject(name: "Actual meeting")
        try projects.save(project)
        let parent = meeting(at: 10, text: "Full source.")
        var child = meeting(at: 20, text: "Derived child.")
        child.splitProvenance = .init(
            operationId: UUID(), sourceId: parent.id, sourceTitle: parent.fileName,
            approvedStartMs: 0, approvedEndMs: 1_000, ordinal: 0, splitCreatedAt: date(20))
        try transcriptions.save(parent); try transcriptions.save(child)
        try projects.assign(transcriptionIDs: [parent.id, child.id], to: project.id)
        XCTAssertEqual(
            try projects.latestPreviousMeeting(projectID: project.id, before: date(30))?.transcriptionID,
            parent.id)
    }

    func testPreparationIdentitySurvivesRenameRescheduleAndSeparatesOccurrences() throws {
        let key = MeetingPreparationKey(calendarID: "calendar-one", eventID: "series_instance_one")
        let initial = MeetingPreparation(
            key: key, context: "Prepare offline.", titleSnapshot: " Exact Event ", scheduledStartAt: date(20))
        let saved = try preparations.save(initial)
        let renamed = try preparations.save(
            MeetingPreparation(
                key: key, context: "Updated preparation.", titleSnapshot: "Renamed Event", scheduledStartAt: date(40)))
        XCTAssertEqual(renamed.id, saved.id)
        XCTAssertEqual(renamed.createdAt.timeIntervalSince1970, saved.createdAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(try preparations.fetch(key: key)?.context, "Updated preparation.")
        XCTAssertEqual(try preparations.fetch(id: saved.id)?.scheduledStartAt, date(40))
        XCTAssertNil(try preparations.fetch(key: .init(calendarID: "calendar-one", eventID: "series_instance_two")))
        XCTAssertNil(try preparations.fetch(key: .init(calendarID: "calendar-two", eventID: key.eventID)))
        XCTAssertThrowsError(try preparations.fetch(key: .init(calendarID: "", eventID: "event")))
    }

    func testRecordingSnapshotPrecedesRowAndBindingIsIdempotentAfterUserMove() throws {
        let first = MeetingProject(name: "First")
        let second = MeetingProject(name: "Second")
        try projects.save(first); try projects.save(second)
        let draft = try preparations.save(
            .init(
                key: .init(calendarID: "calendar", eventID: "instance"), context: "Original context.",
                projectID: first.id, titleSnapshot: "Exact Google Event"))
        let association = RecordingMeetingAssociation(
            recordingID: UUID(), preparationID: draft.id, projectID: first.id,
            titleSnapshot: draft.titleSnapshot, contextSnapshot: draft.context,
            calendarID: draft.calendarID, eventID: draft.eventID, projectNameSnapshot: first.name)
        try preparations.saveRecordingAssociation(association)
        XCTAssertNil(try preparations.fetchRecordingAssociation(recordingID: association.recordingID)?.transcriptionID)
        var editedDraft = draft
        editedDraft.context = "Later edit must not rewrite recording."
        try preparations.save(editedDraft)
        let row = meeting(at: 10, text: "Recorded speech.")
        try transcriptions.save(row)
        try preparations.bindRecording(recordingID: association.recordingID, to: row.id)
        XCTAssertEqual(try projects.project(for: row.id)?.id, first.id)
        try projects.assign(transcriptionIDs: [row.id], to: second.id)
        try preparations.bindRecording(recordingID: association.recordingID, to: row.id)
        XCTAssertEqual(try projects.project(for: row.id)?.id, second.id)
        XCTAssertEqual(
            try preparations.fetchRecordingAssociation(recordingID: association.recordingID)?.contextSnapshot,
            "Original context.")
        XCTAssertTrue(try preparations.delete(id: draft.id))
        XCTAssertEqual(
            try preparations.fetchRecordingAssociation(recordingID: association.recordingID)?.preparationID, draft.id)
        var conflicting = association
        conflicting.contextSnapshot = "Conflicting intent."
        XCTAssertThrowsError(try preparations.saveRecordingAssociation(conflicting))
    }

    func testMissingBindRollsBackAndFolderDeletionKeepsPreparationSnapshot() throws {
        let project = MeetingProject(name: "Keep source")
        try projects.save(project)
        let preparation = try preparations.save(
            .init(
                key: .init(calendarID: "calendar", eventID: "event"), context: "Typed context.",
                projectID: project.id, titleSnapshot: "Event"))
        let association = RecordingMeetingAssociation(
            recordingID: UUID(), preparationID: preparation.id, projectID: project.id,
            titleSnapshot: preparation.titleSnapshot, contextSnapshot: preparation.context,
            projectNameSnapshot: project.name)
        try preparations.saveRecordingAssociation(association)
        XCTAssertThrowsError(try preparations.bindRecording(recordingID: association.recordingID, to: UUID()))
        XCTAssertNil(try preparations.fetchRecordingAssociation(recordingID: association.recordingID)?.transcriptionID)
        XCTAssertTrue(try projects.delete(id: project.id))
        XCTAssertNil(try preparations.fetch(id: preparation.id)?.projectID)
        let frozen = try XCTUnwrap(preparations.fetchRecordingAssociation(recordingID: association.recordingID))
        XCTAssertNil(frozen.projectID)
        XCTAssertEqual(frozen.projectNameSnapshot, project.name)
        XCTAssertEqual(frozen.contextSnapshot, "Typed context.")
    }

    func testMigrationAddsOnlyNewTablesAndPreservesExistingTranscription() throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        let migrator = DatabaseManager.makeMigrator()
        try migrator.migrate(queue, upTo: "v0.49-ask-conversations")
        let repo = TranscriptionRepository(dbQueue: queue)
        let row = meeting(at: 10, text: "Preserve this row.")
        try repo.save(row)
        try migrator.migrate(queue)
        XCTAssertEqual(try repo.fetch(id: row.id)?.rawTranscript, row.rawTranscript)
        XCTAssertTrue(try queue.read { try $0.tableExists("meeting_projects") })
        XCTAssertTrue(try queue.read { try $0.tableExists("recording_meeting_associations") })
    }

    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }
    private func meeting(at seconds: TimeInterval, text: String?) -> Transcription {
        Transcription(
            createdAt: date(seconds), fileName: "Fixture meeting", filePath: "/synthetic/preserved.m4a",
            rawTranscript: text, status: .completed, sourceType: .meeting, updatedAt: date(seconds))
    }
}
