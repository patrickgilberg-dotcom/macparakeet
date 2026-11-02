import Foundation

/// Recoverable successful history, independent of the not-yet-created Library
/// row. Partial assistant deltas are never represented as completed messages.
public struct MeetingLiveChatSnapshot: Codable, Sendable, Equatable {
    public let recordingID: UUID
    public let conversationID: UUID
    public let revision: UInt64
    public let messages: [ChatMessage]
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        recordingID: UUID, conversationID: UUID, revision: UInt64,
        messages: [ChatMessage], createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.recordingID = recordingID
        self.conversationID = conversationID
        self.revision = revision
        self.messages = messages
        // The containing lock uses ISO8601 whole seconds. Normalize at capture
        // so rereading that lock preserves equality for same-revision retries.
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
        self.updatedAt = Date(timeIntervalSince1970: updatedAt.timeIntervalSince1970.rounded(.down))
    }

    public var isValid: Bool {
        revision > 0 && createdAt.timeIntervalSince1970.isFinite && updatedAt.timeIntervalSince1970.isFinite
            && messages.allSatisfy { $0.role != .system && !$0.content.isEmpty }
    }

    public func conversation(transcriptionID: UUID) -> ChatConversation {
        ChatConversation(
            id: conversationID, transcriptionId: transcriptionID,
            title: String((messages.first { $0.role == .user }?.content ?? "Meeting chat").prefix(50)),
            messages: messages.isEmpty ? nil : messages, createdAt: createdAt, updatedAt: updatedAt)
    }
}

public enum MeetingLiveChatPersistenceError: Error, LocalizedError, Sendable {
    case storageUnavailable
    case recordingChanged
    case outdatedSnapshot
    case invalidSnapshot
    case conversationMismatch

    public var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            return "Live chat could not be saved with this recording. Retry saving before closing the app."
        case .recordingChanged:
            return "The recording changed before its live chat could be saved."
        case .outdatedSnapshot:
            return "A newer version of this live chat is already saved."
        case .invalidSnapshot:
            return "The recording's live chat could not be read safely."
        case .conversationMismatch:
            return "This recovered chat is already linked to a different meeting."
        }
    }
}
