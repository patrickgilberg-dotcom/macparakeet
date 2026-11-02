import CryptoKit
import Darwin
import Foundation

/// An immutable request snapshot. Consumers pin one value for each task; edits
/// made in Settings affect later tasks, not a request already in progress.
public struct LiveMeetingPreferences: Codable, Sendable, Equatable {
    public let skillMarkdown: String
    public let skillRevision: String
    public let automaticMinutesEnabled: Bool
    public let answerStyleEnabled: Bool
    public let answerStyleInstructions: String
    public let answerStyleExamples: String

    public static let maximumSkillBytes = 128 * 1_024
    public static let maximumStyleInstructionsBytes = 8 * 1_024
    public static let maximumStyleExamplesBytes = 16 * 1_024
    public static let maximumStyleInstructionsCharacters = 4_000
    public static let maximumStyleExamplesCharacters = 8_000
    public static let starterStyleInstructions = """
        Use concise, direct plain language. Lead with the useful answer and avoid filler.
        For action wording, prefer a clear verb and specific deliverable; name an owner only when the meeting supports it.
        Preserve uncertainty, conditions and exact facts. These are writing preferences, not evidence about the meeting.
        """

    public init(
        skillMarkdown: String,
        automaticMinutesEnabled: Bool = LiveAppIdentity.isLive,
        answerStyleEnabled: Bool = true,
        answerStyleInstructions: String = LiveMeetingPreferences.starterStyleInstructions,
        answerStyleExamples: String = ""
    ) {
        self.skillMarkdown = skillMarkdown
        self.skillRevision = Self.revision(for: skillMarkdown)
        self.automaticMinutesEnabled = automaticMinutesEnabled
        self.answerStyleEnabled = answerStyleEnabled
        self.answerStyleInstructions = answerStyleInstructions
        self.answerStyleExamples = answerStyleExamples
    }

    public static func defaults(isLive: Bool = LiveAppIdentity.isLive) throws -> Self {
        Self(skillMarkdown: try defaultSkillMarkdown(), automaticMinutesEnabled: isLive)
    }

    /// Shared generic rules/template only. The user's complete private skill
    /// is imported locally by the store, never shipped in the app resource.
    public static func defaultSkillMarkdown() throws -> String {
        guard let url = Bundle.module.url(forResource: "MeetingSkillDefault", withExtension: "md"),
            let data = try? Data(contentsOf: url), let value = String(data: data, encoding: .utf8)
        else { throw LiveMeetingPreferencesError.seedUnavailable }
        return value
    }

    public func validate() throws {
        guard !skillMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LiveMeetingPreferencesError.emptySkill
        }
        try Self.checkSize(skillMarkdown, field: "Meeting skill", maximum: Self.maximumSkillBytes)
        try Self.checkSize(
            answerStyleInstructions, field: "Style instructions", maximum: Self.maximumStyleInstructionsBytes)
        try Self.checkSize(answerStyleExamples, field: "Writing examples", maximum: Self.maximumStyleExamplesBytes)
        guard answerStyleInstructions.count <= Self.maximumStyleInstructionsCharacters else {
            throw LiveMeetingPreferencesError.characterLimit(
                field: "Style instructions", maximumCharacters: Self.maximumStyleInstructionsCharacters)
        }
        guard answerStyleExamples.count <= Self.maximumStyleExamplesCharacters else {
            throw LiveMeetingPreferencesError.characterLimit(
                field: "Writing examples", maximumCharacters: Self.maximumStyleExamplesCharacters)
        }
        guard skillRevision == Self.revision(for: skillMarkdown) else {
            throw LiveMeetingPreferencesError.corruptFile(recoveryAvailable: false)
        }
        if answerStyleEnabled,
            answerStyleInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            answerStyleExamples.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw LiveMeetingPreferencesError.emptyStyle
        }
    }

    private static func revision(for markdown: String) -> String {
        SHA256.hash(data: Data(markdown.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func checkSize(_ value: String, field: String, maximum: Int) throws {
        guard value.utf8.count <= maximum else {
            throw LiveMeetingPreferencesError.sizeLimit(field: field, maximumBytes: maximum)
        }
    }
}

public struct LiveMeetingPreferencesVersion: Codable, Sendable, Equatable, Identifiable {
    public enum Reason: String, Codable, Sendable {
        case initial, edited, restored, defaultSkill, recovered
    }

    public let id: UUID
    public let savedAt: Date
    public let reason: Reason
    public let preferences: LiveMeetingPreferences

    public init(id: UUID = UUID(), savedAt: Date = Date(), reason: Reason, preferences: LiveMeetingPreferences) {
        self.id = id
        self.savedAt = savedAt
        self.reason = reason
        self.preferences = preferences
    }
}

public struct LiveMeetingPreferencesState: Sendable, Equatable {
    public let current: LiveMeetingPreferencesVersion
    /// Newest previous version first. Restoring creates a new current version.
    public let history: [LiveMeetingPreferencesVersion]

    public init(current: LiveMeetingPreferencesVersion, history: [LiveMeetingPreferencesVersion]) {
        self.current = current
        self.history = history
    }
}

public enum LiveMeetingPreferencesError: Error, LocalizedError, Sendable, Equatable {
    case emptySkill
    case emptyStyle
    case sizeLimit(field: String, maximumBytes: Int)
    case characterLimit(field: String, maximumCharacters: Int)
    case seedUnavailable
    case importedSeedUnavailable
    case storageUnavailable
    case busy
    case conflict
    case versionMissing
    case corruptFile(recoveryAvailable: Bool)
    case unsupportedSchema
    case backupUnavailable

    public var errorDescription: String? {
        switch self {
        case .emptySkill: "The meeting skill cannot be empty."
        case .emptyStyle: "Add style instructions or a writing example, or turn personal answer style off."
        case .sizeLimit(let field, let maximum):
            "\(field) exceeds its \(maximum / 1_024) KB limit. Shorten it before saving."
        case .characterLimit(let field, let maximum):
            "\(field) exceeds its \(maximum.formatted()) character limit. Shorten it before saving."
        case .seedUnavailable: "The bundled default meeting skill is unavailable. Reinstall MacParakeet Live."
        case .importedSeedUnavailable:
            "The private imported default skill could not be read safely. It has been preserved; repair that file before restoring the default."
        case .storageUnavailable:
            "The settings could not be read or saved. Your saved settings were not intentionally removed."
        case .busy: "Another settings operation is in progress. Try again."
        case .conflict: "Saved settings changed elsewhere. Reload the saved version before saving your draft."
        case .versionMissing: "That previous version is no longer available. Reload the version history."
        case .corruptFile(let available):
            available
                ? "The current settings file is unreadable. Recover the previous saved file to continue; the unreadable file will be preserved."
                : "The saved settings file is unreadable and no valid backup is available. It has been preserved for recovery."
        case .unsupportedSchema: "These settings were saved by a newer app version. Update the app before editing them."
        case .backupUnavailable: "No valid previous settings file is available to recover."
        }
    }
}

/// One isolated, versioned local domain. No UserDefaults, Keychain, network or
/// account access. A corrupt current file is never silently reset to defaults.
public actor LiveMeetingPreferencesStore {
    public static let shared = LiveMeetingPreferencesStore()
    public static let maximumHistoryCount = 12
    public static let maximumStoreBytes = 4 * 1_024 * 1_024
    public static let currentFileName = "preferences-v1.json"
    public static let backupFileName = "preferences-v1.previous.json"
    public static let importedDefaultFileName = "imported-default-skill.md"

    private struct Envelope: Codable {
        let schemaVersion: Int
        let current: LiveMeetingPreferencesVersion
        let history: [LiveMeetingPreferencesVersion]

        var state: LiveMeetingPreferencesState { .init(current: current, history: history) }
    }

    private struct SchemaHeader: Decodable { let schemaVersion: Int }

    private let directoryURL: URL
    private let defaultIsLive: Bool
    private let fileManager: FileManager
    public nonisolated let importedDefaultURL: URL

    public init(
        directoryURL: URL = URL(fileURLWithPath: AppPaths.appSupportDir, isDirectory: true)
            .appendingPathComponent("meeting-preferences", isDirectory: true),
        defaultIsLive: Bool = LiveAppIdentity.isLive,
        importedDefaultURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.defaultIsLive = defaultIsLive
        self.importedDefaultURL =
            importedDefaultURL ?? directoryURL.appendingPathComponent(Self.importedDefaultFileName)
        self.fileManager = fileManager
    }

    public func snapshot() throws -> LiveMeetingPreferences { try load().current.preferences }

    public func load() throws -> LiveMeetingPreferencesState {
        try withStoreLock { try loadEnvelope().state }
    }

    public func defaultSkillMarkdown() throws -> String {
        try withStoreLock { try readDefaultSkillMarkdown() }
    }

    @discardableResult
    public func save(_ preferences: LiveMeetingPreferences, expectedVersionID: UUID? = nil) throws
        -> LiveMeetingPreferencesState
    {
        try preferences.validate()
        return try withStoreLock {
            let envelope = try loadEnvelope()
            return try save(preferences, from: envelope, expected: expectedVersionID, reason: .edited)
        }
    }

    @discardableResult
    public func restore(versionID: UUID, expectedVersionID: UUID? = nil) throws -> LiveMeetingPreferencesState {
        try withStoreLock {
            let envelope = try loadEnvelope()
            guard let version = ([envelope.current] + envelope.history).first(where: { $0.id == versionID }) else {
                throw LiveMeetingPreferencesError.versionMissing
            }
            return try save(version.preferences, from: envelope, expected: expectedVersionID, reason: .restored)
        }
    }

    @discardableResult
    public func restoreDefaultSkill(expectedVersionID: UUID? = nil) throws -> LiveMeetingPreferencesState {
        try withStoreLock {
            let envelope = try loadEnvelope()
            let previous = envelope.current.preferences
            let restored = LiveMeetingPreferences(
                skillMarkdown: try readDefaultSkillMarkdown(),
                automaticMinutesEnabled: previous.automaticMinutesEnabled,
                answerStyleEnabled: previous.answerStyleEnabled,
                answerStyleInstructions: previous.answerStyleInstructions,
                answerStyleExamples: previous.answerStyleExamples)
            return try save(restored, from: envelope, expected: expectedVersionID, reason: .defaultSkill)
        }
    }

    @discardableResult
    public func recoverFromBackup() throws -> LiveMeetingPreferencesState {
        try withStoreLock {
            let currentURL = directoryURL.appendingPathComponent(Self.currentFileName)
            if fileManager.fileExists(atPath: currentURL.path) {
                do { return try readEnvelope(at: currentURL).state } catch LiveMeetingPreferencesError.corruptFile {
                    // Explicit recovery only; retain the unreadable original.
                }
            }
            guard let backup = try? readEnvelope(at: directoryURL.appendingPathComponent(Self.backupFileName)) else {
                throw LiveMeetingPreferencesError.backupUnavailable
            }
            let preservedURL = directoryURL.appendingPathComponent("unreadable-preferences-\(UUID().uuidString).json")
            let existed = fileManager.fileExists(atPath: currentURL.path)
            if existed {
                do { try fileManager.moveItem(at: currentURL, to: preservedURL) } catch {
                    throw LiveMeetingPreferencesError.storageUnavailable
                }
            }
            let recovered = Envelope(
                schemaVersion: 1,
                current: .init(reason: .recovered, preferences: backup.current.preferences),
                history: Array(([backup.current] + backup.history).prefix(Self.maximumHistoryCount)))
            do {
                try write(recovered, to: currentURL)
            } catch {
                if existed, !fileManager.fileExists(atPath: currentURL.path) {
                    try? fileManager.moveItem(at: preservedURL, to: currentURL)
                }
                throw error
            }
            return recovered.state
        }
    }

    private func save(
        _ preferences: LiveMeetingPreferences, from envelope: Envelope, expected: UUID?,
        reason: LiveMeetingPreferencesVersion.Reason
    ) throws -> LiveMeetingPreferencesState {
        if let expected, expected != envelope.current.id { throw LiveMeetingPreferencesError.conflict }
        try preferences.validate()
        guard preferences != envelope.current.preferences else { return envelope.state }
        let updated = Envelope(
            schemaVersion: 1, current: .init(reason: reason, preferences: preferences),
            history: Array(([envelope.current] + envelope.history).prefix(Self.maximumHistoryCount)))
        // If either atomic write fails, the old current or valid backup remains.
        try write(envelope, to: directoryURL.appendingPathComponent(Self.backupFileName))
        try write(updated, to: directoryURL.appendingPathComponent(Self.currentFileName))
        return updated.state
    }

    private func loadEnvelope() throws -> Envelope {
        let currentURL = directoryURL.appendingPathComponent(Self.currentFileName)
        guard fileManager.fileExists(atPath: currentURL.path) else {
            if fileManager.fileExists(atPath: directoryURL.appendingPathComponent(Self.backupFileName).path) {
                throw LiveMeetingPreferencesError.corruptFile(recoveryAvailable: validBackupExists())
            }
            let envelope = Envelope(
                schemaVersion: 1,
                current: .init(
                    reason: .initial,
                    preferences: .init(
                        skillMarkdown: try readDefaultSkillMarkdown(), automaticMinutesEnabled: defaultIsLive)),
                history: [])
            try write(envelope, to: directoryURL.appendingPathComponent(Self.backupFileName))
            try write(envelope, to: currentURL)
            return envelope
        }
        do { return try readEnvelope(at: currentURL) } catch LiveMeetingPreferencesError.corruptFile {
            throw LiveMeetingPreferencesError.corruptFile(recoveryAvailable: validBackupExists())
        }
    }

    private func validBackupExists() -> Bool {
        (try? readEnvelope(at: directoryURL.appendingPathComponent(Self.backupFileName))) != nil
    }

    private func readDefaultSkillMarkdown() throws -> String {
        var entry = stat()
        if lstat(importedDefaultURL.path, &entry) != 0 {
            guard errno == ENOENT else { throw LiveMeetingPreferencesError.importedSeedUnavailable }
            return try LiveMeetingPreferences.defaultSkillMarkdown()
        }
        let data: Data
        do {
            let attributes = try fileManager.attributesOfItem(atPath: importedDefaultURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                let size = attributes[.size] as? NSNumber,
                size.intValue <= LiveMeetingPreferences.maximumSkillBytes
            else { throw LiveMeetingPreferencesError.importedSeedUnavailable }
            data = try Data(contentsOf: importedDefaultURL)
        } catch { throw LiveMeetingPreferencesError.importedSeedUnavailable }
        guard let value = String(data: data, encoding: .utf8) else {
            throw LiveMeetingPreferencesError.importedSeedUnavailable
        }
        do { try LiveMeetingPreferences(skillMarkdown: value).validate() } catch {
            throw LiveMeetingPreferencesError.importedSeedUnavailable
        }
        return value
    }

    private func readEnvelope(at url: URL) throws -> Envelope {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try fileManager.attributesOfItem(atPath: url.path) } catch {
            throw LiveMeetingPreferencesError.storageUnavailable
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumStoreBytes
        else { throw LiveMeetingPreferencesError.corruptFile(recoveryAvailable: false) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw LiveMeetingPreferencesError.storageUnavailable }
        let envelope: Envelope
        let schema: Int
        do { schema = try JSONDecoder().decode(SchemaHeader.self, from: data).schemaVersion } catch {
            throw LiveMeetingPreferencesError.corruptFile(recoveryAvailable: false)
        }
        guard schema == 1 else { throw LiveMeetingPreferencesError.unsupportedSchema }
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) } catch {
            throw LiveMeetingPreferencesError.corruptFile(recoveryAvailable: false)
        }
        guard envelope.history.count <= Self.maximumHistoryCount else {
            throw LiveMeetingPreferencesError.corruptFile(recoveryAvailable: false)
        }
        let versions = [envelope.current] + envelope.history
        guard Set(versions.map(\.id)).count == versions.count else {
            throw LiveMeetingPreferencesError.corruptFile(recoveryAvailable: false)
        }
        for version in versions {
            guard version.savedAt.timeIntervalSince1970.isFinite else {
                throw LiveMeetingPreferencesError.corruptFile(recoveryAvailable: false)
            }
            do { try version.preferences.validate() } catch {
                throw LiveMeetingPreferencesError.corruptFile(recoveryAvailable: false)
            }
        }
        return envelope
    }

    private func write(_ envelope: Envelope, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        guard data.count <= Self.maximumStoreBytes else { throw LiveMeetingPreferencesError.storageUnavailable }
        do { try data.write(to: url, options: .atomic) } catch { throw LiveMeetingPreferencesError.storageUnavailable }
    }

    private func withStoreLock<T>(_ body: () throws -> T) throws -> T {
        do {
            try fileManager.createDirectory(
                at: directoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { throw LiveMeetingPreferencesError.storageUnavailable }
        let descriptor = open(
            directoryURL.appendingPathComponent("preferences.lock").path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw LiveMeetingPreferencesError.storageUnavailable }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw LiveMeetingPreferencesError.storageUnavailable
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw LiveMeetingPreferencesError.busy }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
