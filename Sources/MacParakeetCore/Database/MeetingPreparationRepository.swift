import Foundation
import GRDB

public protocol MeetingPreparationRepositoryProtocol: Sendable {
    @discardableResult func save(_ preparation: MeetingPreparation) throws -> MeetingPreparation
    func fetch(id: UUID) throws -> MeetingPreparation?
    func fetch(key: MeetingPreparationKey) throws -> MeetingPreparation?
    func delete(id: UUID) throws -> Bool
    @discardableResult func saveRecordingAssociation(_ association: RecordingMeetingAssociation) throws
        -> RecordingMeetingAssociation
    func fetchRecordingAssociation(recordingID: UUID) throws -> RecordingMeetingAssociation?
    @discardableResult func bindRecording(recordingID: UUID, to transcriptionID: UUID) throws
        -> RecordingMeetingAssociation
}

public final class MeetingPreparationRepository: MeetingPreparationRepositoryProtocol, @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    public init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    @discardableResult
    public func save(_ preparation: MeetingPreparation) throws -> MeetingPreparation {
        try Self.validate(key: preparation.key)
        return try dbQueue.write { db in
            var value = preparation
            if let projectID = value.projectID, try MeetingProject.fetchOne(db, key: projectID) == nil {
                throw MeetingProjectRepositoryError.projectMissing
            }
            if let existingID = try MeetingPreparation.fetchOne(db, key: preparation.id),
                existingID.key != preparation.key
            {
                throw MeetingProjectRepositoryError.preparationIdentityChanged
            }
            if let existing = try Self.fetch(key: preparation.key, in: db) {
                // A second editor for one occurrence updates its stable local ID.
                value.id = existing.id
                value.createdAt = existing.createdAt
            }
            try value.save(db)
            return value
        }
    }

    public func fetch(id: UUID) throws -> MeetingPreparation? {
        try dbQueue.read { db in try MeetingPreparation.fetchOne(db, key: id) }
    }

    public func fetch(key: MeetingPreparationKey) throws -> MeetingPreparation? {
        try Self.validate(key: key)
        return try dbQueue.read { db in try Self.fetch(key: key, in: db) }
    }

    private static func fetch(key: MeetingPreparationKey, in db: Database) throws -> MeetingPreparation? {
        try MeetingPreparation
            .filter(MeetingPreparation.Columns.calendarID == key.calendarID)
            .filter(MeetingPreparation.Columns.eventID == key.eventID).fetchOne(db)
    }

    public func delete(id: UUID) throws -> Bool {
        try dbQueue.write { db in try MeetingPreparation.deleteOne(db, key: id) }
    }

    @discardableResult
    public func saveRecordingAssociation(_ association: RecordingMeetingAssociation) throws
        -> RecordingMeetingAssociation
    {
        if association.calendarID != nil || association.eventID != nil {
            try Self.validate(key: .init(calendarID: association.calendarID ?? "", eventID: association.eventID ?? ""))
        }
        return try dbQueue.write { db in
            if let existing = try RecordingMeetingAssociation.fetchOne(db, key: association.recordingID) {
                var comparable = association
                comparable.transcriptionID = existing.transcriptionID
                comparable.createdAt = existing.createdAt
                guard comparable == existing else { throw MeetingProjectRepositoryError.recordingAlreadyBound }
                return existing
            }
            var frozen = association
            // This boundary accepts native recording intent only. Binding a
            // Library row must pass through the atomic bind method below.
            frozen.transcriptionID = nil
            try frozen.insert(db)
            return frozen
        }
    }

    public func fetchRecordingAssociation(recordingID: UUID) throws -> RecordingMeetingAssociation? {
        try dbQueue.read { db in try RecordingMeetingAssociation.fetchOne(db, key: recordingID) }
    }

    @discardableResult
    public func bindRecording(recordingID: UUID, to transcriptionID: UUID) throws -> RecordingMeetingAssociation {
        try dbQueue.write { db in
            guard var association = try RecordingMeetingAssociation.fetchOne(db, key: recordingID) else {
                throw MeetingProjectRepositoryError.recordingAssociationMissing
            }
            guard let row = try Transcription.fetchOne(db, key: transcriptionID) else {
                throw MeetingProjectRepositoryError.transcriptionMissing
            }
            guard row.sourceType == .meeting, row.splitProvenance == nil else {
                throw MeetingProjectRepositoryError.invalidRecordingTranscription
            }
            if let bound = association.transcriptionID {
                guard bound == transcriptionID else { throw MeetingProjectRepositoryError.recordingAlreadyBound }
                // Repeated finalization must not undo a later user folder move.
                return association
            }
            association.transcriptionID = transcriptionID
            try association.update(db)
            try MeetingProjectRepository.assign(
                transcriptionIDs: [transcriptionID], to: association.projectID, in: db)
            return association
        }
    }

    private static func validate(key: MeetingPreparationKey) throws {
        guard !key.calendarID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !key.eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw MeetingProjectRepositoryError.invalidEventKey
        }
    }
}
