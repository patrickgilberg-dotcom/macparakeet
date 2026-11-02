import Foundation

public enum MeetingMinutesArtifactRefreshError: LocalizedError {
    case folderUnavailable
    public var errorDescription: String? {
        "The meeting’s portable files are unavailable. The saved minutes remain in the app."
    }
}

/// Refresh derived portable files without repeating completed model requests.
public struct MeetingMinutesArtifactRefresher: Sendable {
    private let transcriptionRepository: TranscriptionRepositoryProtocol
    private let promptResultRepository: PromptResultRepositoryProtocol
    private let speakerAttributionReader: SpeakerAttributionReading
    private let artifactStore: MeetingArtifactStoring

    public init(
        transcriptionRepository: TranscriptionRepositoryProtocol,
        promptResultRepository: PromptResultRepositoryProtocol,
        speakerAttributionReader: SpeakerAttributionReading,
        artifactStore: MeetingArtifactStoring
    ) {
        self.transcriptionRepository = transcriptionRepository
        self.promptResultRepository = promptResultRepository
        self.speakerAttributionReader = speakerAttributionReader
        self.artifactStore = artifactStore
    }

    public func refresh(transcriptionID: UUID) async throws {
        try await Task.detached(priority: .utility) {
            guard let initial = try transcriptionRepository.fetch(id: transcriptionID),
                let folder = MeetingArtifactStore.sessionFolderURL(for: initial)
            else { return }
            let lease = try MeetingMediaMutationLease.acquire(roots: [folder.deletingLastPathComponent()])
            defer { lease.release() }
            guard let current = try transcriptionRepository.fetch(id: transcriptionID),
                MeetingArtifactStore.sessionFolderURL(for: current)?.standardizedFileURL == folder.standardizedFileURL
            else { return }
            guard FileManager.default.fileExists(atPath: folder.path) else {
                throw MeetingMinutesArtifactRefreshError.folderUnavailable
            }
            let projection = try speakerAttributionReader.resolve(transcription: current)
            let results = try promptResultRepository.fetchAll(transcriptionId: transcriptionID)
            _ = try await artifactStore.materialize(projection: projection, promptResults: results)
        }.value
    }
}
