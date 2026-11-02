import Darwin
import Foundation

public enum MeetingGeneratedPreparationStoreError: Error, LocalizedError, Sendable {
    case invalidFile
    case tooLarge
    case busy
    case sourceDeleted

    public var errorDescription: String? {
        switch self {
        case .invalidFile: return "The saved preparation could not be read. Generate it again."
        case .tooLarge: return "This preparation is too large to save safely. The original meeting is preserved."
        case .busy: return "Saved preparation is being updated. Try again when that update finishes."
        case .sourceDeleted: return "This preparation belongs to a deleted meeting and cannot be saved again."
        }
    }
}

/// One private derived artifact per explicitly prepared occurrence. No calendar
/// inventory, audio, or user-authored fields are written here. Full source
/// deletion removes matching derived copies and durably rejects late writes.
public actor MeetingGeneratedPreparationStore {
    public static let shared = MeetingGeneratedPreparationStore()
    private static let maximumBytes = 16 * 1_024 * 1_024
    private let directoryURL: URL
    private let removeArtifact: @Sendable (URL) throws -> Void
    private static let deletedSourcesFileName = ".deleted-sources.json"
    private static let purgedSources = PurgedMeetingPreparationSources()

    private static var defaultDirectoryURL: URL {
        URL(fileURLWithPath: AppPaths.appSupportDir, isDirectory: true)
            .appendingPathComponent("generated-meeting-preparation", isDirectory: true)
    }

    private struct Envelope: Codable {
        let schemaVersion: Int
        let preparation: MeetingGeneratedPreparation
    }

    private struct DeletedSources: Codable {
        let ids: Set<UUID>
        let pending: Set<UUID>
    }

    public init(
        directoryURL: URL = URL(fileURLWithPath: AppPaths.appSupportDir, isDirectory: true)
            .appendingPathComponent("generated-meeting-preparation", isDirectory: true)
    ) {
        self.directoryURL = directoryURL
        removeArtifact = { try FileManager.default.removeItem(at: $0) }
    }

    init(directoryURL: URL, removeArtifact: @escaping @Sendable (URL) throws -> Void) {
        self.directoryURL = directoryURL; self.removeArtifact = removeArtifact
    }

    /// Synchronous compatibility hook for the existing app, CLI and bulk
    /// deletion boundary. It completes in order, without launching a Task.
    public static func purgeDeletedSources(_ transcriptionIDs: Set<UUID>, directoryURL: URL? = nil) throws {
        _ = try purge(
            transcriptionIDs: transcriptionIDs, directoryURL: directoryURL ?? defaultDirectoryURL,
            removeArtifact: { try FileManager.default.removeItem(at: $0) })
    }

    /// Pins durable cleanup intent before the legacy synchronous deletion can
    /// remove its source. Ordinary failure/no-op restores the previous intent;
    /// successful deletion keeps it even if a derived-file removal fails.
    public static func withSourceDeletion(
        _ transcriptionIDs: Set<UUID>, directoryURL: URL? = nil, operation: () throws -> Bool
    ) throws -> Bool {
        let directory = directoryURL ?? defaultDirectoryURL
        return try withStoreLock(directory) {
            let original = try deletedSources(in: directory)
            let deleted = DeletedSources(
                ids: original.ids.union(transcriptionIDs), pending: original.pending.union(transcriptionIDs))
            try writeDeletedSources(deleted, in: directory)
            let didDelete: Bool
            do {
                didDelete = try operation()
            } catch {
                // A rollback failure stays conservative: no deleted source
                // content can be republished from uncertain cleanup intent.
                try? writeDeletedSources(original, in: directory)
                throw error
            }
            guard didDelete else {
                try writeDeletedSources(original, in: directory)
                return false
            }
            purgedSources.mark(deleted.ids, in: directory)
            _ = try removeDeletedArtifacts(
                in: directory, deleted: deleted.pending, removeArtifact: { try FileManager.default.removeItem(at: $0) })
            try writeDeletedSources(.init(ids: deleted.ids, pending: []), in: directory)
            return true
        }
    }

    @discardableResult
    public func purge(transcriptionIDs: Set<UUID>) throws -> Set<MeetingPreparationKey> {
        try Self.purge(transcriptionIDs: transcriptionIDs, directoryURL: directoryURL, removeArtifact: removeArtifact)
    }

    /// No I/O on the UI actor. The ordered deletion hook invalidates loaded
    /// briefs immediately; subsequent disk operations also merge durable intent.
    public nonisolated func isPurged(_ preparation: MeetingGeneratedPreparation) -> Bool {
        !Self.sourceIDs(preparation).isDisjoint(with: Self.purgedSources.ids(in: directoryURL))
    }

    public func load(key: MeetingPreparationKey) throws -> MeetingGeneratedPreparation? {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return nil }
        return try Self.withStoreLock(directoryURL) {
            let deleted = try Self.deletedSources(in: directoryURL)
            try Self.retryPendingCleanup(deleted, in: directoryURL, removeArtifact: removeArtifact)
            let url = fileURL(for: key)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let envelope = try Self.readEnvelope(at: url)
            guard envelope.preparation.key == key else { throw MeetingGeneratedPreparationStoreError.invalidFile }
            guard Self.sourceIDs(envelope.preparation).isDisjoint(with: deleted.ids) else { return nil }
            try Task.checkCancellation()
            return envelope.preparation
        }
    }

    public func save(_ preparation: MeetingGeneratedPreparation) throws {
        try Task.checkCancellation()
        try Self.withStoreLock(directoryURL) {
            let deleted = try Self.deletedSources(in: directoryURL)
            try Self.retryPendingCleanup(deleted, in: directoryURL, removeArtifact: removeArtifact)
            guard Self.sourceIDs(preparation).isDisjoint(with: deleted.ids) else {
                throw MeetingGeneratedPreparationStoreError.sourceDeleted
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Envelope(schemaVersion: 1, preparation: preparation))
            guard data.count <= Self.maximumBytes else { throw MeetingGeneratedPreparationStoreError.tooLarge }
            try Task.checkCancellation()
            let url = fileURL(for: preparation.key)
            try Self.writePrivate(data, to: url)
        }
    }

    private static func purge(
        transcriptionIDs: Set<UUID>, directoryURL: URL, removeArtifact: (URL) throws -> Void
    ) throws -> Set<MeetingPreparationKey> {
        guard !transcriptionIDs.isEmpty else { return [] }
        return try withStoreLock(directoryURL) {
            let original = try deletedSources(in: directoryURL)
            let deleted = DeletedSources(
                ids: original.ids.union(transcriptionIDs), pending: original.pending.union(transcriptionIDs))
            // Intent is durable before unlinking. A failed removal is retried
            // on every subsequent load/save/purge and can never become reusable.
            try writeDeletedSources(deleted, in: directoryURL)
            purgedSources.mark(deleted.ids, in: directoryURL)
            let removed = try removeDeletedArtifacts(
                in: directoryURL, deleted: deleted.pending, removeArtifact: removeArtifact)
            try writeDeletedSources(.init(ids: deleted.ids, pending: []), in: directoryURL)
            return removed
        }
    }

    private static func sourceIDs(_ preparation: MeetingGeneratedPreparation) -> Set<UUID> {
        Set(
            preparation.board.documents.compactMap { document in
                let parts = document.id.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[1] == "transcript" || parts[1] == "notes" else { return nil }
                return UUID(uuidString: String(parts[0]))
            })
    }

    private static func deletedSources(in directoryURL: URL) throws -> DeletedSources {
        let url = directoryURL.appendingPathComponent(deletedSourcesFileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .init(ids: purgedSources.ids(in: directoryURL), pending: [])
        }
        let data = try boundedData(at: url)
        guard let stored = try? JSONDecoder().decode(DeletedSources.self, from: data) else {
            throw MeetingGeneratedPreparationStoreError.invalidFile
        }
        purgedSources.mark(stored.ids, in: directoryURL)
        return .init(ids: stored.ids.union(purgedSources.ids(in: directoryURL)), pending: stored.pending)
    }

    private static func writeDeletedSources(_ deleted: DeletedSources, in directoryURL: URL) throws {
        let data = try JSONEncoder().encode(deleted)
        guard data.count <= maximumBytes else { throw MeetingGeneratedPreparationStoreError.tooLarge }
        try writePrivate(data, to: directoryURL.appendingPathComponent(deletedSourcesFileName))
    }

    private static func retryPendingCleanup(
        _ deleted: DeletedSources, in directoryURL: URL, removeArtifact: (URL) throws -> Void
    ) throws {
        guard !deleted.pending.isEmpty else { return }
        _ = try removeDeletedArtifacts(in: directoryURL, deleted: deleted.pending, removeArtifact: removeArtifact)
        // Completed cleanup keeps only small source IDs. Ordinary prep loads
        // must not reread every historical source artifact on every poll.
        try writeDeletedSources(.init(ids: deleted.ids, pending: []), in: directoryURL)
    }

    private static func removeDeletedArtifacts(
        in directoryURL: URL, deleted: Set<UUID>, removeArtifact: (URL) throws -> Void
    ) throws -> Set<MeetingPreparationKey> {
        guard !deleted.isEmpty else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        var removed = Set<MeetingPreparationKey>()
        for file in files where isArtifactURL(file) {
            // Invalid/unrelated local artifacts have no established source
            // ownership and are preserved rather than deleted speculatively.
            guard let envelope = try? readEnvelope(at: file),
                !sourceIDs(envelope.preparation).isDisjoint(with: deleted)
            else { continue }
            try removeArtifact(file)
            removed.insert(envelope.preparation.key)
        }
        return removed
    }

    private static func isArtifactURL(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent
        return url.pathExtension == "json" && name.count == 64
            && name.allSatisfy { "0123456789abcdef".contains($0) }
    }

    private static func readEnvelope(at url: URL) throws -> Envelope {
        let data = try boundedData(at: url)
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.schemaVersion == 1 else {
            throw MeetingGeneratedPreparationStoreError.invalidFile
        }
        return envelope
    }

    private static func boundedData(at url: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            let size = attributes[.size] as? NSNumber, size.intValue <= maximumBytes
        else { throw MeetingGeneratedPreparationStoreError.tooLarge }
        return try Data(contentsOf: url)
    }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func withStoreLock<T>(_ directoryURL: URL, _ body: () throws -> T) throws -> T {
        let manager = FileManager.default
        try manager.createDirectory(
            at: directoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        let descriptor = open(
            directoryURL.appendingPathComponent(".preparation.lock").path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw MeetingGeneratedPreparationStoreError.busy }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
            flock(descriptor, LOCK_EX | LOCK_NB) == 0
        else { throw MeetingGeneratedPreparationStoreError.busy }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func fileURL(for key: MeetingPreparationKey) -> URL {
        // Length prefixes prevent ambiguous identities or provider IDs being
        // interpreted as paths. Names do not disclose event or account titles.
        let identity = "\(key.calendarID.utf8.count):\(key.calendarID)\(key.eventID.utf8.count):\(key.eventID)"
        return directoryURL.appendingPathComponent(MeetingGeneratedPreparation.hash(identity) + ".json")
    }
}

private final class PurgedMeetingPreparationSources: @unchecked Sendable {
    private let lock = NSLock()
    private var byDirectory: [String: Set<UUID>] = [:]

    func ids(in directoryURL: URL) -> Set<UUID> {
        lock.withLock { byDirectory[directoryURL.standardizedFileURL.path] ?? [] }
    }

    func mark(_ ids: Set<UUID>, in directoryURL: URL) {
        lock.withLock { byDirectory[directoryURL.standardizedFileURL.path, default: []].formUnion(ids) }
    }
}
