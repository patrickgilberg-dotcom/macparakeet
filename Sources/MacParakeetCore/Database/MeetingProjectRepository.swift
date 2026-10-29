import Foundation
import GRDB

public protocol MeetingProjectRepositoryProtocol: Sendable {
    func save(_ project: MeetingProject) throws
    func fetch(id: UUID) throws -> MeetingProject?
    func fetchAll(includeArchived: Bool) throws -> [MeetingProject]
    func setArchived(id: UUID, isArchived: Bool) throws
    func delete(id: UUID) throws -> Bool
    func assign(transcriptionIDs: Set<UUID>, to projectID: UUID?) throws
    func project(for transcriptionID: UUID) throws -> MeetingProject?
    func projectIDs(for transcriptionIDs: Set<UUID>) throws -> [UUID: UUID]
    func transcriptionIDs(in projectID: UUID) throws -> Set<UUID>
    func latestPreviousMeeting(
        projectID: UUID, before: Date, excludingRecordingID: UUID?, excludingTranscriptionID: UUID?
    ) throws -> ProjectPreviousMeeting?
}

public extension MeetingProjectRepositoryProtocol {
    func fetchAll() throws -> [MeetingProject] { try fetchAll(includeArchived: false) }
    func latestPreviousMeeting(projectID: UUID, before: Date) throws -> ProjectPreviousMeeting? {
        try latestPreviousMeeting(
            projectID: projectID, before: before, excludingRecordingID: nil, excludingTranscriptionID: nil)
    }
}

public final class MeetingProjectRepository: MeetingProjectRepositoryProtocol, @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    public init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    public func save(_ project: MeetingProject) throws {
        var value = project
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty else { throw MeetingProjectRepositoryError.emptyName }
        try dbQueue.write { db in try value.save(db) }
    }

    public func fetch(id: UUID) throws -> MeetingProject? {
        try dbQueue.read { db in try MeetingProject.fetchOne(db, key: id) }
    }

    public func fetchAll(includeArchived: Bool) throws -> [MeetingProject] {
        try dbQueue.read { db in
            var request = MeetingProject.all()
            if !includeArchived { request = request.filter(MeetingProject.Columns.isArchived == false) }
            return try request.order(
                MeetingProject.Columns.sortOrder.asc, MeetingProject.Columns.name.collating(.nocase).asc,
                MeetingProject.Columns.id.asc
            ).fetchAll(db)
        }
    }

    public func setArchived(id: UUID, isArchived: Bool) throws {
        try dbQueue.write { db in
            guard var project = try MeetingProject.fetchOne(db, key: id) else {
                throw MeetingProjectRepositoryError.projectMissing
            }
            project.isArchived = isArchived
            project.updatedAt = Date()
            try project.update(db)
        }
    }

    /// Removing a folder unfiles its transcripts; no source row or file is deleted.
    public func delete(id: UUID) throws -> Bool {
        try dbQueue.write { db in try MeetingProject.deleteOne(db, key: id) }
    }

    public func assign(transcriptionIDs: Set<UUID>, to projectID: UUID?) throws {
        try dbQueue.write { db in
            try Self.assign(transcriptionIDs: transcriptionIDs, to: projectID, in: db)
        }
    }

    static func assign(transcriptionIDs: Set<UUID>, to projectID: UUID?, in db: Database) throws {
        if let projectID, try MeetingProject.fetchOne(db, key: projectID) == nil {
            throw MeetingProjectRepositoryError.projectMissing
        }
        // Validate the whole move before touching any membership.
        for id in transcriptionIDs {
            guard try Transcription.fetchOne(db, key: id) != nil else {
                throw MeetingProjectRepositoryError.transcriptionMissing
            }
        }
        let assignedAt = Date()
        for id in transcriptionIDs {
            if let projectID {
                try TranscriptionProjectMembership(
                    transcriptionID: id, projectID: projectID, assignedAt: assignedAt
                ).save(db)
            } else {
                _ = try TranscriptionProjectMembership.deleteOne(db, key: id)
            }
        }
    }

    public func project(for transcriptionID: UUID) throws -> MeetingProject? {
        try dbQueue.read { db in
            guard let membership = try TranscriptionProjectMembership.fetchOne(db, key: transcriptionID) else {
                return nil
            }
            return try MeetingProject.fetchOne(db, key: membership.projectID)
        }
    }

    public func projectIDs(for transcriptionIDs: Set<UUID>) throws -> [UUID: UUID] {
        guard !transcriptionIDs.isEmpty else { return [:] }
        return try dbQueue.read { db in
            let placeholders = Array(repeating: "?", count: transcriptionIDs.count).joined(separator: ",")
            let rows = try TranscriptionProjectMembership.fetchAll(
                db, sql: "SELECT * FROM transcription_project_memberships WHERE transcriptionID IN (\(placeholders))",
                arguments: StatementArguments(transcriptionIDs.map(\.databaseValue)))
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.transcriptionID, $0.projectID) })
        }
    }

    public func transcriptionIDs(in projectID: UUID) throws -> Set<UUID> {
        try dbQueue.read { db in
            let rows =
                try TranscriptionProjectMembership
                .filter(TranscriptionProjectMembership.Columns.projectID == projectID).fetchAll(db)
            return Set(rows.map(\.transcriptionID))
        }
    }

    public func latestPreviousMeeting(
        projectID: UUID, before: Date, excludingRecordingID: UUID? = nil, excludingTranscriptionID: UUID? = nil
    ) throws -> ProjectPreviousMeeting? {
        try dbQueue.read { db in
            var predicates = [
                "m.projectID = ?", "t.sourceType = 'meeting'", "t.createdAt < ?", "t.splitProvenance IS NULL",
            ]
            var values = [projectID.databaseValue, before.databaseValue]
            if let excludingTranscriptionID {
                predicates.append("t.id != ?")
                values.append(excludingTranscriptionID.databaseValue)
            }
            if let excludingRecordingID {
                predicates.append(
                    "NOT EXISTS (SELECT 1 FROM recording_meeting_associations r WHERE r.transcriptionID = t.id AND r.recordingID = ?)"
                )
                values.append(excludingRecordingID.databaseValue)
            }
            guard
                let row = try Transcription.fetchOne(
                    db,
                    sql: """
                        SELECT t.* FROM transcriptions t
                        JOIN transcription_project_memberships m ON m.transcriptionID = t.id
                        WHERE \(predicates.joined(separator: " AND "))
                        ORDER BY t.createdAt DESC, t.id DESC LIMIT 1
                        """,
                    arguments: StatementArguments(values)
                )
            else { return nil }

            var state: ProjectPreviousMeeting.State
            var text: String?
            var fingerprint: String?
            var revision = 0
            switch row.status {
            case .processing: state = .processing
            case .error: state = .failed
            case .cancelled: state = .cancelled
            case .completed:
                let projection = try SpeakerAttributionReadService.resolve(transcription: row, in: db)
                let candidate = TranscriptAIContextFormatter.format(projection: projection, mode: .richTranscript)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                state = candidate.isEmpty ? .empty : .ready
                text = candidate.isEmpty ? nil : candidate
                fingerprint = projection.attribution.fingerprint.rawValue
                revision = projection.correctionRevision
            }
            return ProjectPreviousMeeting(
                transcriptionID: row.id, title: row.effectiveDisplayTitle, createdAt: row.createdAt,
                updatedAt: row.updatedAt, state: state, effectiveTranscript: text, userNotes: row.userNotes,
                sourceHash: text.map { CardContentFingerprint.transcriptHash(for: $0) },
                sourceFingerprint: fingerprint, correctionRevision: revision)
        }
    }
}
