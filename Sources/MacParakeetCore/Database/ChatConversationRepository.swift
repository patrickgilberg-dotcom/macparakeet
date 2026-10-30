import Foundation
import GRDB

public protocol ChatConversationRepositoryProtocol: Sendable {
    func save(_ conversation: ChatConversation) throws
    func fetch(id: UUID) throws -> ChatConversation?
    func fetchAll(transcriptionId: UUID) throws -> [ChatConversation]
    func delete(id: UUID) throws -> Bool
    func deleteAll(transcriptionId: UUID) throws
    func deleteEmpty(transcriptionId: UUID) throws
    func updateMessages(id: UUID, messages: [ChatMessage]?) throws
    func updateTitle(id: UUID, title: String) throws
    func hasConversations(transcriptionId: UUID) throws -> Bool
    @discardableResult
    func insertRecoveredIfAbsent(_ conversation: ChatConversation) throws -> ChatConversation?
}

public extension ChatConversationRepositoryProtocol {
    /// Compatibility for injected repositories. Production overrides this in a
    /// single transaction, preserving an existing user's edits even when empty.
    func insertRecoveredIfAbsent(_ conversation: ChatConversation) throws -> ChatConversation? {
        if let existing = try fetch(id: conversation.id) {
            guard existing.transcriptionId == conversation.transcriptionId else {
                throw MeetingLiveChatPersistenceError.conversationMismatch
            }
            return existing
        }
        try save(conversation)
        return conversation
    }
}

public final class ChatConversationRepository: ChatConversationRepositoryProtocol {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func save(_ conversation: ChatConversation) throws {
        try dbQueue.write { db in
            try conversation.save(db)
        }
    }

    @discardableResult
    public func insertRecoveredIfAbsent(_ conversation: ChatConversation) throws -> ChatConversation? {
        try dbQueue.write { db -> ChatConversation? in
            let receipt = try RecoveredChatImportReceipt.fetchOne(db, key: conversation.id)
            if let receipt, receipt.transcriptionId != conversation.transcriptionId {
                throw MeetingLiveChatPersistenceError.conversationMismatch
            }
            if let existing = try ChatConversation.fetchOne(db, key: conversation.id) {
                guard existing.transcriptionId == conversation.transcriptionId else {
                    throw MeetingLiveChatPersistenceError.conversationMismatch
                }
                if receipt == nil {
                    try RecoveredChatImportReceipt(
                        id: conversation.id, transcriptionId: conversation.transcriptionId, createdAt: Date()
                    ).insert(db)
                }
                return existing
            }
            // Absence after a recorded import is an intentional deletion/clear,
            // not permission to resurrect old checkpoint contents on retry.
            if receipt != nil { return nil }
            try conversation.insert(db)
            try RecoveredChatImportReceipt(
                id: conversation.id, transcriptionId: conversation.transcriptionId, createdAt: Date()
            ).insert(db)
            return conversation
        }
    }

    public func fetch(id: UUID) throws -> ChatConversation? {
        try dbQueue.read { db in
            try ChatConversation.fetchOne(db, key: id)
        }
    }

    public func fetchAll(transcriptionId: UUID) throws -> [ChatConversation] {
        try dbQueue.read { db in
            try ChatConversation
                .filter(ChatConversation.Columns.transcriptionId == transcriptionId)
                .order(ChatConversation.Columns.updatedAt.desc)
                .fetchAll(db)
        }
    }

    public func delete(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            try ChatConversation.deleteOne(db, key: id)
        }
    }

    public func deleteAll(transcriptionId: UUID) throws {
        _ = try dbQueue.write { db in
            try ChatConversation
                .filter(ChatConversation.Columns.transcriptionId == transcriptionId)
                .deleteAll(db)
        }
    }

    public func deleteEmpty(transcriptionId: UUID) throws {
        _ = try dbQueue.write { db in
            try ChatConversation
                .filter(ChatConversation.Columns.transcriptionId == transcriptionId)
                .filter(ChatConversation.Columns.messages == nil)
                .deleteAll(db)
        }
    }

    public func updateMessages(id: UUID, messages: [ChatMessage]?) throws {
        try dbQueue.write { db in
            guard var conversation = try ChatConversation.fetchOne(db, key: id) else { return }
            conversation.messages = messages
            conversation.updatedAt = Date()
            try conversation.update(db)
        }
    }

    public func updateTitle(id: UUID, title: String) throws {
        try dbQueue.write { db in
            guard var conversation = try ChatConversation.fetchOne(db, key: id) else { return }
            conversation.title = title
            conversation.updatedAt = Date()
            try conversation.update(db)
        }
    }

    public func hasConversations(transcriptionId: UUID) throws -> Bool {
        try dbQueue.read { db in
            try
                !ChatConversation
                .filter(ChatConversation.Columns.transcriptionId == transcriptionId)
                .isEmpty(db)
        }
    }
}

private struct RecoveredChatImportReceipt: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "chat_recovery_imports"
    let id: UUID
    let transcriptionId: UUID
    let createdAt: Date
}
