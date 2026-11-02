import Foundation
import GRDB

public protocol MeetingCompanyRepositoryProtocol: Sendable {
    func save(_ company: MeetingCompany) throws
    func fetch(id: UUID) throws -> MeetingCompany?
    func fetchAll(includeArchived: Bool) throws -> [MeetingCompany]
    func ensureCompany(forDomain domain: String) throws -> MeetingCompany
    func assign(transcriptionIDs: Set<UUID>, to companyID: UUID?) throws
    func company(for transcriptionID: UUID) throws -> MeetingCompany?
    func companyIDs(for transcriptionIDs: Set<UUID>) throws -> [UUID: UUID]
    func transcriptionIDs(in companyID: UUID) throws -> Set<UUID>
}

public extension MeetingCompanyRepositoryProtocol {
    func fetchAll() throws -> [MeetingCompany] { try fetchAll(includeArchived: false) }
}

public final class MeetingCompanyRepository: MeetingCompanyRepositoryProtocol, @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    public init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    public func save(_ company: MeetingCompany) throws {
        var value = company
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty else { throw MeetingCompanyRepositoryError.emptyName }
        value.attendeeDomains = try MeetingCompanyDomainMatcher.normalizedDomains(value.attendeeDomains)
        try dbQueue.write { db in try value.save(db) }
    }

    public func fetch(id: UUID) throws -> MeetingCompany? {
        try dbQueue.read { db in try MeetingCompany.fetchOne(db, key: id) }
    }

    public func fetchAll(includeArchived: Bool) throws -> [MeetingCompany] {
        try dbQueue.read { db in
            var request = MeetingCompany.all()
            if !includeArchived { request = request.filter(MeetingCompany.Columns.isArchived == false) }
            return try request.order(
                MeetingCompany.Columns.name.collating(.nocase).asc, MeetingCompany.Columns.id.asc
            ).fetchAll(db)
        }
    }

    /// Discovery is idempotent across concurrent app/helper connections. A
    /// configured archived company is retained rather than recreated/revived.
    /// Company names inferred here remain honest editable domain labels.
    public func ensureCompany(forDomain domain: String) throws -> MeetingCompany {
        let normalized = try MeetingCompanyDomainMatcher.normalizedDomains([domain])[0]
        return try dbQueue.write { db in
            let all = try MeetingCompany.fetchAll(db)
            let matches = try all.filter {
                try MeetingCompanyDomainMatcher.normalizedDomains($0.attendeeDomains).contains(normalized)
            }
            guard matches.count <= 1 else { throw MeetingCompanyRepositoryError.ambiguousCompanyDomain }
            if let existing = matches.first { return existing }
            let usedNames = Set(all.map { $0.name.lowercased() })
            var label = normalized
            var suffix = 2
            while usedNames.contains(label.lowercased()) {
                label = "\(normalized) (\(suffix))"
                suffix += 1
            }
            let company = MeetingCompany(name: label, attendeeDomains: [normalized])
            try company.insert(db)
            return company
        }
    }

    public func assign(transcriptionIDs: Set<UUID>, to companyID: UUID?) throws {
        try dbQueue.write { db in try Self.assign(transcriptionIDs: transcriptionIDs, to: companyID, in: db) }
    }

    static func assign(
        transcriptionIDs: Set<UUID>, to companyID: UUID?, in db: Database, allowArchived: Bool = false
    ) throws {
        if let companyID {
            guard let company = try MeetingCompany.fetchOne(db, key: companyID), allowArchived || !company.isArchived
            else {
                throw MeetingCompanyRepositoryError.companyMissing
            }
        }
        for id in transcriptionIDs {
            guard try Transcription.fetchOne(db, key: id) != nil else {
                throw MeetingProjectRepositoryError.transcriptionMissing
            }
        }
        let assignedAt = Date()
        for id in transcriptionIDs {
            if let membership = try TranscriptionProjectMembership.fetchOne(db, key: id),
                let project = try MeetingProject.fetchOne(db, key: membership.projectID),
                project.companyID != companyID
            {
                _ = try TranscriptionProjectMembership.deleteOne(db, key: id)
            }
            if let companyID {
                try TranscriptionCompanyMembership(
                    transcriptionID: id, companyID: companyID, assignedAt: assignedAt
                ).save(db)
            } else {
                _ = try TranscriptionCompanyMembership.deleteOne(db, key: id)
            }
        }
    }

    public func company(for transcriptionID: UUID) throws -> MeetingCompany? {
        try dbQueue.read { db in
            guard let membership = try TranscriptionCompanyMembership.fetchOne(db, key: transcriptionID) else {
                return nil
            }
            return try MeetingCompany.fetchOne(db, key: membership.companyID)
        }
    }

    public func companyIDs(for transcriptionIDs: Set<UUID>) throws -> [UUID: UUID] {
        guard !transcriptionIDs.isEmpty else { return [:] }
        return try dbQueue.read { db in
            let placeholders = Array(repeating: "?", count: transcriptionIDs.count).joined(separator: ",")
            let rows = try TranscriptionCompanyMembership.fetchAll(
                db, sql: "SELECT * FROM transcription_company_memberships WHERE transcriptionID IN (\(placeholders))",
                arguments: StatementArguments(transcriptionIDs.map(\.databaseValue)))
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.transcriptionID, $0.companyID) })
        }
    }

    public func transcriptionIDs(in companyID: UUID) throws -> Set<UUID> {
        try dbQueue.read { db in
            let rows =
                try TranscriptionCompanyMembership
                .filter(TranscriptionCompanyMembership.Columns.companyID == companyID).fetchAll(db)
            return Set(rows.map(\.transcriptionID))
        }
    }
}
