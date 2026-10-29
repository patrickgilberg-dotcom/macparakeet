import Foundation
import XCTest
@testable import MacParakeetCore

final class ConfiguredSavedAudioAutoPromptCompletionServiceTests: XCTestCase {
    func testUnconfiguredRouteSkipsLegacyPromptsCardsWarningsAndProgress() async throws {
        let delegate = ConfiguredCompletionProbe()
        let progress = ConfiguredCompletionProgressProbe()
        let service = ConfiguredSavedAudioAutoPromptCompletionService(delegate: delegate, isConfigured: { false })
        let result = try await service.completeAutoPrompts(
            for: Transcription(
                fileName: "Synthetic meeting", rawTranscript: "Synthetic source", status: .completed,
                sourceType: .meeting),
            onProgress: { progress.record($0) })
        XCTAssertEqual(result, SavedAudioAutoPromptCompletionResult())
        let calls = await delegate.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(progress.values.isEmpty)
    }

    func testConfiguredRoutePreservesDelegatedInputProgressOutcomesAndWarnings() async throws {
        let delegate = ConfiguredCompletionProbe()
        let progress = ConfiguredCompletionProgressProbe()
        let service = ConfiguredSavedAudioAutoPromptCompletionService(delegate: delegate, isConfigured: { true })
        let source = Transcription(
            fileName: "Synthetic child", rawTranscript: "Full synthetic source", status: .completed,
            sourceType: .meeting)
        let result = try await service.completeAutoPrompts(for: source, onProgress: { progress.record($0) })
        let calls = await delegate.calls
        XCTAssertEqual(calls, [source.id])
        XCTAssertEqual(result, ConfiguredCompletionProbe.expectedResult)
        XCTAssertEqual(progress.values, [.init(completedCount: 0, totalCount: 1, promptName: "Synthetic prompt")])
    }
}

private actor ConfiguredCompletionProbe: SavedAudioAutoPromptCompletionServicing {
    static let expectedResult = SavedAudioAutoPromptCompletionResult(
        outcomes: [.init(promptId: nil, promptName: "Synthetic prompt", status: .failed(message: "Synthetic failure"))],
        warnings: [.knowledgeCardFailed(message: "Synthetic card warning")])
    private(set) var calls: [UUID] = []

    func completeAutoPrompts(
        for transcription: Transcription,
        onProgress: (@Sendable (SavedAudioAutoPromptCompletionProgress) -> Void)?
    ) async throws -> SavedAudioAutoPromptCompletionResult {
        calls.append(transcription.id)
        onProgress?(.init(completedCount: 0, totalCount: 1, promptName: "Synthetic prompt"))
        return Self.expectedResult
    }
}

private final class ConfiguredCompletionProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SavedAudioAutoPromptCompletionProgress] = []
    var values: [SavedAudioAutoPromptCompletionProgress] { lock.withLock { recorded } }
    func record(_ value: SavedAudioAutoPromptCompletionProgress) { lock.withLock { recorded.append(value) } }
}
