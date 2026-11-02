import Foundation
import GRDB

/// Explicit Google event/instance identity. Titles and scheduled time are not keys.
public struct MeetingPreparationKey: Codable, Sendable, Equatable, Hashable {
    public let calendarID: String
    public let eventID: String
    public init(calendarID: String, eventID: String) {
        self.calendarID = calendarID; self.eventID = eventID
    }
}

/// User-authored preparation, not a mirror of calendar events or attendees.
public struct MeetingPreparation: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var calendarID: String
    public var eventID: String
    public var context: String
    public var companyID: UUID?
    /// Nil decodes legacy drafts created before a company choice existed.
    /// True includes an explicitly saved No company selection.
    public var companySelectionIsExplicit: Bool?
    public var projectID: UUID?
    public var titleSnapshot: String
    public var scheduledStartAt: Date?
    public var scheduledEndAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var key: MeetingPreparationKey { .init(calendarID: calendarID, eventID: eventID) }

    public init(
        id: UUID = UUID(), key: MeetingPreparationKey, context: String = "", companyID: UUID? = nil,
        companySelectionIsExplicit: Bool? = true,
        projectID: UUID? = nil,
        titleSnapshot: String, scheduledStartAt: Date? = nil, scheduledEndAt: Date? = nil,
        createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id; calendarID = key.calendarID; eventID = key.eventID
        self.companyID = companyID
        self.companySelectionIsExplicit = companySelectionIsExplicit
        self.context = context; self.projectID = projectID; self.titleSnapshot = titleSnapshot
        self.scheduledStartAt = scheduledStartAt; self.scheduledEndAt = scheduledEndAt
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

extension MeetingPreparation: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "meeting_preparations"
    public enum Columns: String, ColumnExpression {
        case id, calendarID, eventID, context, companyID, companySelectionIsExplicit, projectID, titleSnapshot
        case scheduledStartAt, scheduledEndAt, createdAt, updatedAt
    }
}

/// Frozen intent captured against the native recording UUID before its Library
/// row exists. Final transcription writes never replace these separate columns.
public struct RecordingMeetingAssociation: Codable, Sendable, Equatable {
    public var recordingID: UUID
    public var transcriptionID: UUID?
    public var preparationID: UUID?
    public var companyID: UUID?
    public var projectID: UUID?
    public var titleSnapshot: String
    public var contextSnapshot: String
    public var calendarID: String?
    public var eventID: String?
    public var scheduledStartAt: Date?
    public var scheduledEndAt: Date?
    public var projectNameSnapshot: String?
    public var companyNameSnapshot: String?
    public var createdAt: Date

    public init(
        recordingID: UUID, preparationID: UUID? = nil, companyID: UUID? = nil, projectID: UUID? = nil,
        titleSnapshot: String, contextSnapshot: String, calendarID: String? = nil, eventID: String? = nil,
        scheduledStartAt: Date? = nil, scheduledEndAt: Date? = nil, projectNameSnapshot: String? = nil,
        companyNameSnapshot: String? = nil,
        createdAt: Date = Date()
    ) {
        self.recordingID = recordingID; transcriptionID = nil
        self.companyID = companyID; self.companyNameSnapshot = companyNameSnapshot
        self.preparationID = preparationID; self.projectID = projectID
        self.titleSnapshot = titleSnapshot; self.contextSnapshot = contextSnapshot
        self.calendarID = calendarID; self.eventID = eventID
        self.scheduledStartAt = scheduledStartAt; self.scheduledEndAt = scheduledEndAt
        self.projectNameSnapshot = projectNameSnapshot; self.createdAt = createdAt
    }
}

extension RecordingMeetingAssociation: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "recording_meeting_associations"
    public enum Columns: String, ColumnExpression {
        case recordingID, transcriptionID, preparationID, companyID, projectID, titleSnapshot, contextSnapshot
        case calendarID, eventID, scheduledStartAt, scheduledEndAt, projectNameSnapshot, companyNameSnapshot, createdAt
    }
}
