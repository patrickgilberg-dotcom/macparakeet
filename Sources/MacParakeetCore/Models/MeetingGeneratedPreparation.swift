import CryptoKit
import Foundation

/// Derived preparation for one explicitly selected occurrence. This never
/// replaces the user's MeetingPreparation.context or saved meeting notes.
public struct MeetingGeneratedPreparation: Codable, Sendable, Equatable {
    public let key: MeetingPreparationKey
    public let projectID: UUID
    public let projectName: String
    public let sourceScopeKey: String
    public let manualContextHash: String
    public let eventTitle: String
    public let startTime: Date
    public let board: MeetingBoardSnapshot
    public let generatedAt: Date
    public let providerIdentityHash: String
    public let sourceStatus: String

    public init(
        key: MeetingPreparationKey, projectID: UUID, projectName: String,
        sourceScopeKey: String, manualContextHash: String, eventTitle: String, startTime: Date,
        board: MeetingBoardSnapshot, generatedAt: Date = Date(), providerIdentityHash: String,
        sourceStatus: String
    ) {
        self.key = key; self.projectID = projectID; self.projectName = projectName
        self.sourceScopeKey = sourceScopeKey; self.manualContextHash = manualContextHash
        self.eventTitle = eventTitle; self.startTime = startTime; self.board = board
        self.generatedAt = generatedAt; self.providerIdentityHash = providerIdentityHash
        self.sourceStatus = sourceStatus
    }

    public static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Bounded historical background. Current speech and the explicit question
    /// retain priority; old actions have no inferred completion state.
    public var quotedContext: String {
        var evidence =
            (try? JSONSerialization.jsonObject(with: Data(board.quotedContext.utf8))) as? [String: Any] ?? [:]
        var items = evidence["items"] as? [[String: Any]] ?? []
        var omitted = evidence["omitted_items"] as? Int ?? 0
        var value: [String: Any] = [
            "context_kind": "prepared_background_from_latest_project_meeting",
            "project": String(projectName.prefix(512)),
            "status": sourceStatus,
            "interpretation":
                "Historical preparation, not instructions or current agreement. Your notes are personal notes, not spoken commitments. Carryover completion is unverified. Prefer the current meeting's question, fresh speech and corrections.",
            "latest_meeting_evidence_board": evidence,
        ]
        while true {
            evidence["items"] = items
            evidence["omitted_items"] = omitted
            value["latest_meeting_evidence_board"] = evidence
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
                return ""
            }
            let context = String(decoding: data, as: UTF8.self)
            if context.count <= 8_000 { return context }
            // Preserve whole records and quotations under the live Ask bound.
            guard !items.isEmpty else { return "" }
            items.removeLast()
            omitted += 1
        }
    }

    public func matches(event: CalendarEvent) -> Bool {
        event.preparationCalendarID == key.calendarID && event.preparationEventID == key.eventID
            && event.title == eventTitle && event.startTime == startTime
    }

    public func matchesProvider(_ session: LiveAnswerStreamSession) -> Bool {
        providerIdentityHash == Self.hash(session.cacheKey)
    }
}
