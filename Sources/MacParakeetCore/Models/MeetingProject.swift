import Foundation
import GRDB

/// A virtual Library folder. Membership never moves transcript or audio files.
public struct MeetingProject: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var sortOrder: Int
    public var isArchived: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), name: String, sortOrder: Int = 0, isArchived: Bool = false,
        createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id; self.name = name; self.sortOrder = sortOrder; self.isArchived = isArchived
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

extension MeetingProject: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "meeting_projects"
    public enum Columns: String, ColumnExpression {
        case id, name, sortOrder, isArchived, createdAt, updatedAt
    }
}

struct TranscriptionProjectMembership: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "transcription_project_memberships"
    var transcriptionID: UUID
    var projectID: UUID
    var assignedAt: Date
    enum Columns: String, ColumnExpression { case transcriptionID, projectID, assignedAt }
}

/// The newest eligible row is selected before its readiness is evaluated.
/// A pending/failed latest meeting must never silently become an older one.
public struct ProjectPreviousMeeting: Sendable, Equatable {
    public enum State: String, Sendable { case ready, processing, failed, cancelled, empty }
    public let transcriptionID: UUID
    public let title: String
    public let createdAt: Date
    public let updatedAt: Date
    public let state: State
    public let effectiveTranscript: String?
    public let userNotes: String?
    /// SHA-256 of the exact effective transcript projection returned above.
    public let sourceHash: String?
    public let sourceFingerprint: String?
    public let correctionRevision: Int

    public init(
        transcriptionID: UUID, title: String, createdAt: Date, updatedAt: Date,
        state: State, effectiveTranscript: String? = nil, userNotes: String? = nil,
        sourceHash: String? = nil, sourceFingerprint: String? = nil, correctionRevision: Int = 0
    ) {
        self.transcriptionID = transcriptionID; self.title = title; self.createdAt = createdAt
        self.updatedAt = updatedAt; self.state = state; self.effectiveTranscript = effectiveTranscript
        self.userNotes = userNotes; self.sourceHash = sourceHash
        self.sourceFingerprint = sourceFingerprint; self.correctionRevision = correctionRevision
    }
}

public enum MeetingProjectRepositoryError: Error, LocalizedError, Sendable, Equatable {
    case emptyName
    case projectMissing
    case transcriptionMissing
    case invalidEventKey
    case preparationIdentityChanged
    case recordingAssociationMissing
    case recordingAlreadyBound
    case invalidRecordingTranscription

    public var errorDescription: String? {
        switch self {
        case .emptyName: return "Enter a project name."
        case .projectMissing: return "That project is no longer available."
        case .transcriptionMissing: return "A selected transcript is no longer available."
        case .invalidEventKey: return "Choose a specific connected Google Calendar event."
        case .preparationIdentityChanged: return "This preparation belongs to a different calendar event."
        case .recordingAssociationMissing: return "The recording's project context is unavailable."
        case .recordingAlreadyBound: return "This recording already has a different saved association."
        case .invalidRecordingTranscription: return "Only a meeting recording can receive this association."
        }
    }
}
