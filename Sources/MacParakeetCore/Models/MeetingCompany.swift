import Foundation
import GRDB

/// A local company grouping. Domain-derived names are editable labels, not
/// claims that the app has identified an official legal company name.
public struct MeetingCompany: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var attendeeDomains: [String]
    public var isArchived: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), name: String, attendeeDomains: [String] = [], isArchived: Bool = false,
        createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id; self.name = name; self.attendeeDomains = attendeeDomains; self.isArchived = isArchived
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

extension MeetingCompany: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "meeting_companies"
    public enum Columns: String, ColumnExpression { case id, name, attendeeDomains, isArchived, createdAt, updatedAt }
}

struct TranscriptionCompanyMembership: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "transcription_company_memberships"
    var transcriptionID: UUID
    var companyID: UUID
    var assignedAt: Date
    enum Columns: String, ColumnExpression { case transcriptionID, companyID, assignedAt }
}

public enum MeetingCompanyRepositoryError: Error, LocalizedError, Sendable, Equatable {
    case emptyName
    case companyMissing
    case invalidAttendeeDomain
    case ambiguousCompanyDomain
    case projectCompanyMismatch
    case projectCompanyChangeWithMeetings
    case recordingOrganizationUnsupported

    public var errorDescription: String? {
        switch self {
        case .emptyName: return "Enter a company name."
        case .companyMissing: return "That company is no longer available."
        case .invalidAttendeeDomain:
            return "Enter up to 100 email domains such as company.com, without an address, URL or wildcard."
        case .ambiguousCompanyDomain: return "This domain belongs to more than one saved company. Choose a company."
        case .projectCompanyMismatch: return "Choose a project belonging to the selected company."
        case .projectCompanyChangeWithMeetings:
            return
                "This project already has saved meetings or preparation. Create a project under the other company instead."
        case .recordingOrganizationUnsupported:
            return "This recording does not support changing its company and project."
        }
    }
}
