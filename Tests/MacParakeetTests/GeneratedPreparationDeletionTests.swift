import XCTest
@testable import MacParakeetCore

final class GeneratedPreparationDeletionTests: XCTestCase {
    func testCoordinatorPurgesOnlyAfterSuccessfulFullMeetingDeletion() throws {
        let manager = try DatabaseManager()
        let repository = TranscriptionRepository(dbQueue: manager.dbQueue)
        let meeting = Transcription(
            fileName: "Synthetic meeting", rawTranscript: "A saved meeting.", status: .completed,
            sourceType: .meeting, userNotes: "My authored notes.")
        try repository.save(meeting)
        var purged: [Set<UUID>] = []
        XCTAssertThrowsError(
            try TranscriptionDeletionCoordinator.delete(
                meeting, repository: repository, purgeGeneratedPreparation: { purged.append($0) },
                removeAssets: { _ in throw DeletionCleanupFixtureError.requestedFailure }))
        XCTAssertTrue(purged.isEmpty)
        XCTAssertEqual(try repository.fetch(id: meeting.id)?.userNotes, "My authored notes.")
        XCTAssertTrue(
            try TranscriptionDeletionCoordinator.delete(
                meeting, repository: repository,
                purgeGeneratedPreparation: { ids in
                    XCTAssertNil(
                        try repository.fetch(id: meeting.id), "The purge hook must follow a successful row deletion")
                    purged.append(ids)
                }, removeAssets: { _ in }))
        XCTAssertEqual(purged, [[meeting.id]])
        XCTAssertFalse(
            try TranscriptionDeletionCoordinator.delete(
                meeting, repository: repository, purgeGeneratedPreparation: { purged.append($0) },
                removeAssets: { _ in }))
        XCTAssertEqual(purged.count, 1, "No-op deletion must not purge unrelated preparation")
    }

    func testNonMeetingDeletionDoesNotInvokeMeetingPreparationCleanup() throws {
        let manager = try DatabaseManager()
        let repository = TranscriptionRepository(dbQueue: manager.dbQueue)
        let file = Transcription(fileName: "Synthetic file", rawTranscript: "File text.", status: .completed)
        try repository.save(file)
        var wasPurged = false
        XCTAssertTrue(
            try TranscriptionDeletionCoordinator.delete(
                file, repository: repository, purgeGeneratedPreparation: { _ in wasPurged = true },
                removeAssets: { _ in }))
        XCTAssertFalse(wasPurged)
    }
}

private enum DeletionCleanupFixtureError: Error { case requestedFailure }
