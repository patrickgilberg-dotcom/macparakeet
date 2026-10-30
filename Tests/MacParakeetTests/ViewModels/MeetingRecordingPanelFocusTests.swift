import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class MeetingRecordingPanelFocusTests: XCTestCase {
    func testFocusUsesNumericTimelineAndRespectsChangedDisplayPreference() throws {
        var mode = TranscriptAIContextMode.plainTranscript
        let panel = MeetingRecordingPanelViewModel(transcriptAIContextModeProvider: { mode })
        XCTAssertNil(panel.liveMeetingFocusSource)
        panel.elapsedSeconds = 300
        panel.updatePreviewLines([
            MeetingRecordingPreviewLine(
                id: "misleading-display-time", timestamp: "99:99", speakerLabel: "Display",
                text: "This display line must not determine the window.", source: .system)
        ])
        panel.updateLiveMeetingTimeline(
            MeetingTranscriptUpdate(
                words: [word("Old.", 10_000, 11_000), word("Fresh.", 200_000, 201_000)],
                speakers: [SpeakerInfo(id: "system", label: "Lee")]))
        let plain = try XCTUnwrap(panel.liveMeetingFocusSource)
        XCTAssertEqual(plain.transcript, "Lee: Fresh.")
        XCTAssertEqual(plain.startMs, 120_000)
        XCTAssertEqual(plain.endMs, 300_000)
        mode = .richTranscript
        let rich = try XCTUnwrap(panel.liveMeetingFocusSource)
        XCTAssertEqual(rich.transcript, "[3:20] Lee: Fresh.")
        XCTAssertEqual(rich.startMs, plain.startMs)
        XCTAssertEqual(rich.endMs, plain.endMs)
    }

    func testElapsedClockClearsAQuietWindowAndResetClearsTimeline() throws {
        let panel = MeetingRecordingPanelViewModel(transcriptAIContextModeProvider: { .plainTranscript })
        panel.updateLiveMeetingTimeline(MeetingTranscriptUpdate(words: [word("Speech.", 0, 1_000)], speakers: []))
        panel.elapsedSeconds = 180
        XCTAssertFalse(try XCTUnwrap(panel.liveMeetingFocusSource).transcript.isEmpty)
        panel.elapsedSeconds = 182
        XCTAssertTrue(try XCTUnwrap(panel.liveMeetingFocusSource).transcript.isEmpty)
        panel.reset()
        XCTAssertNil(panel.liveMeetingFocusSource)
    }

    func testExtremeElapsedClockSaturatesWithoutOverflow() throws {
        let panel = MeetingRecordingPanelViewModel()
        panel.updateLiveMeetingTimeline(MeetingTranscriptUpdate(words: [word("Speech.", 0, 1_000)], speakers: []))
        panel.elapsedSeconds = Int.max
        let source = try XCTUnwrap(panel.liveMeetingFocusSource)
        XCTAssertEqual(source.endMs, Int.max)
        XCTAssertEqual(source.startMs, Int.max - 180_000)
        XCTAssertTrue(source.transcript.isEmpty)
    }

    private func word(_ text: String, _ start: Int, _ end: Int) -> WordTimestamp {
        WordTimestamp(word: text, startMs: start, endMs: end, confidence: 1, speakerId: "system")
    }
}
