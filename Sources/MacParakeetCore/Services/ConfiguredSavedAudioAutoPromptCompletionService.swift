import Foundation

/// App-level opt-in gate for legacy analysis-provider completion. Direct
/// ChatGPT-plan minutes have their own job path and do not configure this route.
public struct ConfiguredSavedAudioAutoPromptCompletionService: SavedAudioAutoPromptCompletionServicing {
    private let delegate: any SavedAudioAutoPromptCompletionServicing
    private let isConfigured: @Sendable () -> Bool

    public init(
        delegate: any SavedAudioAutoPromptCompletionServicing,
        isConfigured: @escaping @Sendable () -> Bool
    ) {
        self.delegate = delegate
        self.isConfigured = isConfigured
    }

    @discardableResult
    public func completeAutoPrompts(
        for transcription: Transcription,
        onProgress: (@Sendable (SavedAudioAutoPromptCompletionProgress) -> Void)?
    ) async throws -> SavedAudioAutoPromptCompletionResult {
        try Task.checkCancellation()
        guard isConfigured() else { return SavedAudioAutoPromptCompletionResult() }
        return try await delegate.completeAutoPrompts(for: transcription, onProgress: onProgress)
    }
}
