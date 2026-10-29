import CryptoKit
import Foundation
import GRDB

public struct MeetingMinutesSkillSnapshot: Codable, Sendable, Equatable {
    public let markdown: String
    public let revision: String
    public init(markdown: String, revision: String) { self.markdown = markdown; self.revision = revision }
}

public struct MeetingMinutesSourceSnapshot: Codable, Sendable, Equatable {
    public let transcriptionID: UUID
    public let transcript: String
    /// Exact formatted evidence text, including available speaker/time labels.
    public let sourceHash: String
    /// Existing result-page word hash. This deliberately differs from sourceHash.
    public let canonicalTranscriptHash: String
    public let correctionRevision: Int
    public let attributionFingerprint: String
    public let title: String

    public init(
        transcriptionID: UUID, transcript: String, sourceHash: String,
        canonicalTranscriptHash: String, correctionRevision: Int,
        attributionFingerprint: String, title: String
    ) {
        self.transcriptionID = transcriptionID; self.transcript = transcript; self.sourceHash = sourceHash
        self.canonicalTranscriptHash = canonicalTranscriptHash; self.correctionRevision = correctionRevision
        self.attributionFingerprint = attributionFingerprint; self.title = title
    }

    func matches(_ other: Self) -> Bool {
        transcriptionID == other.transcriptionID && sourceHash == other.sourceHash
            && canonicalTranscriptHash == other.canonicalTranscriptHash
            && correctionRevision == other.correctionRevision && attributionFingerprint == other.attributionFingerprint
    }
}

public enum MeetingMinutesJobState: String, Codable, Sendable { case pending, running, failed, completed }

/// Lightweight status; listing jobs never reads their private source/skill bodies.
public struct MeetingMinutesJob: Codable, FetchableRecord, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let transcriptionID: UUID
    public let state: MeetingMinutesJobState
    public let skillRevision: String
    public let sourceHash: String
    public let coveredCharacters: Int
    public let totalCharacters: Int
    public let resultID: UUID?
    public let errorMessage: String?
    public let createdAt: Date
    public let updatedAt: Date
}

public enum MeetingMinutesError: Error, LocalizedError, Sendable, Equatable {
    case sourceUnavailable
    case sourceChanged
    case invalidSkill
    case skillTooLarge
    case jobUnavailable
    case jobBusy
    case providerChanged
    case invalidResponse
    case invalidEvidence
    case incompleteCoverage
    case interrupted
    case providerFailed

    public var errorDescription: String? {
        switch self {
        case .sourceUnavailable: return "Minutes need a saved, completed meeting with a usable transcript."
        case .sourceChanged: return "The meeting transcript changed. Retry to use the current source."
        case .invalidSkill: return "The meeting skill is empty or its saved revision could not be verified."
        case .skillTooLarge:
            return "The meeting skill is too large for bounded minutes requests. Shorten its instructions and retry."
        case .jobUnavailable: return "This minutes job is no longer available."
        case .jobBusy: return "This minutes job is already running or completed."
        case .providerChanged:
            return "The ChatGPT account or model changed. Retry minutes to restart with the current selection."
        case .invalidResponse:
            return "Minutes did not finish in the required four-note format. Retry to generate a valid draft."
        case .invalidEvidence:
            return "An action's quotation could not be verified against the meeting. No new minutes were saved."
        case .incompleteCoverage: return "The whole meeting has not been processed. No final minutes were saved."
        case .interrupted: return "Minutes were interrupted. Retry to continue from completed checkpoints."
        case .providerFailed: return "ChatGPT could not complete minutes. Retry when the connection is available."
        }
    }
}

enum MeetingMinutesIdentity {
    static let policy = "evidence-first-minutes-v1"
    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func key(source: MeetingMinutesSourceSnapshot, skill: MeetingMinutesSkillSnapshot) -> String {
        hash(
            [
                policy, source.transcriptionID.uuidString, source.sourceHash,
                source.canonicalTranscriptHash, String(source.correctionRevision), source.attributionFingerprint,
                skill.revision,
            ].map { "\($0.utf8.count):\($0)" }.joined())
    }
}

struct MeetingMinutesChunkReceipt: Codable, Sendable, Equatable {
    let start: Int
    let end: Int
    let requestStart: Int
}

struct MeetingMinutesCandidate: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case confirmed, conditional, proposed, excluded }
    var kind: Kind
    let headline: String
    let description: String
    let owner: String?
    let recipient: String?
    let dueDate: String?
    let trigger: String?
    let ownerCertainty: String
    var why: String
    let doNotOverstate: String
    let quoteStart: Int
    let quoteEnd: Int
    var reviewed: Bool
}

struct MeetingMinutesProgress: Codable, Sendable, Equatable {
    var chunks: [MeetingMinutesChunkReceipt] = []
    var meetingMap = ""
    var candidates: [MeetingMinutesCandidate] = []
    var coveredCharacters: Int { chunks.last?.end ?? 0 }
}

struct MeetingMinutesWork: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "meeting_minutes_jobs"
    let id: UUID
    let transcriptionID: UUID
    let identityKey: String
    var state: MeetingMinutesJobState
    let skillRevision: String
    let sourceHash: String
    var coveredCharacters: Int
    let totalCharacters: Int
    var resultID: UUID?
    var errorMessage: String?
    let createdAt: Date
    var updatedAt: Date
    let sourceJSON: String
    let skillJSON: String
    var progressJSON: String
    var attemptID: UUID?
    var providerIdentity: String?
    var providerSnapshot: String?
    var modelSnapshot: String?
    var allowsProviderRebind: Bool

    var source: MeetingMinutesSourceSnapshot { get throws { try Self.decode(sourceJSON) } }
    var skill: MeetingMinutesSkillSnapshot { get throws { try Self.decode(skillJSON) } }
    var progress: MeetingMinutesProgress { get throws { try Self.decode(progressJSON) } }
    var summary: MeetingMinutesJob {
        MeetingMinutesJob(
            id: id, transcriptionID: transcriptionID, state: state, skillRevision: skillRevision,
            sourceHash: sourceHash, coveredCharacters: coveredCharacters, totalCharacters: totalCharacters,
            resultID: resultID, errorMessage: errorMessage, createdAt: createdAt, updatedAt: updatedAt)
    }
    static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    static func decode<T: Decodable>(_ text: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(text.utf8))
    }
}
