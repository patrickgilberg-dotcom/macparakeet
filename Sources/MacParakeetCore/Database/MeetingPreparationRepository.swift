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
    @discardableResult func updateRecordingOrganization(recordingID: UUID, companyID: UUID?, projectID: UUID?) throws
        -> RecordingMeetingAssociation
}

public extension MeetingPreparationRepositoryProtocol {
    @discardableResult
    func updateRecordingOrganization(recordingID: UUID, companyID: UUID?, projectID: UUID?) throws
        -> RecordingMeetingAssociation
    {
        throw MeetingCompanyRepositoryError.recordingOrganizationUnsupported
    }
}

public final class MeetingPreparationRepository: MeetingPreparationRepositoryProtocol, @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    public init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    @discardableResult
    public func save(_ preparation: MeetingPreparation) throws -> MeetingPreparation {
        try Self.validate(key: preparation.key)
        return try dbQueue.write { db in
            var value = preparation
            _ = try Self.organization(companyID: value.companyID, projectID: value.projectID, in: db)
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
            _ = try Self.organization(companyID: association.companyID, projectID: association.projectID, in: db)
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
            try MeetingCompanyRepository.assign(
                transcriptionIDs: [transcriptionID], to: association.companyID, in: db, allowArchived: true)
            try MeetingProjectRepository.assign(
                transcriptionIDs: [transcriptionID], to: association.projectID, in: db, allowArchived: true)
            return association
        }
    }

    /// Explicit organization edits preserve the frozen event title, authored
    /// context and timing. Bound folder memberships change in the same write.
    @discardableResult
    public func updateRecordingOrganization(recordingID: UUID, companyID: UUID?, projectID: UUID?) throws
        -> RecordingMeetingAssociation
    {
        try dbQueue.write { db in
            guard var association = try RecordingMeetingAssociation.fetchOne(db, key: recordingID) else {
                throw MeetingProjectRepositoryError.recordingAssociationMissing
            }
            let organization = try Self.organization(companyID: companyID, projectID: projectID, in: db)
            if let transcriptionID = association.transcriptionID {
                try MeetingCompanyRepository.assign(transcriptionIDs: [transcriptionID], to: companyID, in: db)
                try MeetingProjectRepository.assign(transcriptionIDs: [transcriptionID], to: projectID, in: db)
            }
            association.companyID = companyID
            association.projectID = projectID
            association.companyNameSnapshot = organization.0?.name
            association.projectNameSnapshot = organization.1?.name
            try association.update(db)
            return association
        }
    }

    private static func organization(companyID: UUID?, projectID: UUID?, in db: Database) throws
        -> (MeetingCompany?, MeetingProject?)
    {
        let company = try companyID.flatMap { try MeetingCompany.fetchOne(db, key: $0) }
        if companyID != nil, company == nil { throw MeetingCompanyRepositoryError.companyMissing }
        if let company, company.isArchived { throw MeetingCompanyRepositoryError.companyMissing }
        let project = try projectID.flatMap { try MeetingProject.fetchOne(db, key: $0) }
        if projectID != nil, project == nil { throw MeetingProjectRepositoryError.projectMissing }
        if let project, project.isArchived { throw MeetingProjectRepositoryError.projectMissing }
        if let project, project.companyID != companyID { throw MeetingCompanyRepositoryError.projectCompanyMismatch }
        return (company, project)
    }

    private static func validate(key: MeetingPreparationKey) throws {
        guard !key.calendarID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !key.eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw MeetingProjectRepositoryError.invalidEventKey
        }
    }
}
