import XCTest
@testable import MacParakeetCore

final class LiveMeetingFocusTranscriptTests: XCTestCase {
    private func word(_ text: String, _ start: Int, _ end: Int, speaker: String = "microphone") -> WordTimestamp {
        WordTimestamp(word: text, startMs: start, endMs: end, confidence: 1, speakerId: speaker)
    }

    func testWindowAt179180And181SecondsUsesNumericWordBoundaries() {
        let words = [word("Opening.", 0, 100), word("Boundary.", 900, 1_000), word("Retained.", 1_001, 1_100)]
        for elapsed in [179_000, 180_000] {
            let source = project(words, elapsed: elapsed)
            XCTAssertEqual(source.startMs, 0)
            XCTAssertEqual(source.endMs, elapsed)
            XCTAssertTrue(source.transcript.contains("Opening."))
        }
        let advanced = project(words, elapsed: 181_000)
        XCTAssertEqual(advanced.startMs, 1_000)
        XCTAssertFalse(advanced.transcript.contains("Opening."))
        XCTAssertTrue(advanced.transcript.contains("Boundary."), "Keep a word ending exactly at the boundary")
        XCTAssertTrue(advanced.transcript.contains("Retained."))
    }

    func testWordStraddlingWindowIsKeptEvenWhenItBeganBeforeWindow() {
        let source = project(
            [
                word("Outside.", 170_000, 179_999), word("Straddles.", 179_999, 180_001),
                word("Inside.", 180_001, 180_100),
            ], elapsed: 360_000)
        XCTAssertEqual(source.startMs, 180_000)
        XCTAssertFalse(source.transcript.contains("Outside."))
        XCTAssertTrue(source.transcript.contains("Straddles."))
        XCTAssertTrue(source.transcript.contains("Inside."))
    }

    func testSilenceAgesOldWordsOutWithoutAnyTranscriptChange() {
        let words = [word("Last words.", 99_000, 100_000)]
        XCTAssertFalse(project(words, elapsed: 280_000).transcript.isEmpty)
        let silent = project(words, elapsed: 281_000)
        XCTAssertEqual(silent.startMs, 101_000)
        XCTAssertEqual(silent.endMs, 281_000)
        XCTAssertTrue(silent.transcript.isEmpty)
    }

    func testFreshBarrierWordsAdvancePastStaleElapsedPoll() {
        let source = project([word("Fresh question?", 300_000, 301_234)], elapsed: 300_000)
        XCTAssertEqual(source.endMs, 301_234)
        XCTAssertEqual(source.startMs, 121_234)
        XCTAssertTrue(source.transcript.contains("Fresh question?"))
    }

    func testPlainAndRichModesChooseIdenticalSpeechAndSpeakerLabels() {
        let words = [word("Old.", 10_000, 11_000), word("Recent.", 200_000, 201_000)]
        let speakers = [SpeakerInfo(id: "microphone", label: "Maya")]
        let plain = LiveMeetingFocusTranscript.project(
            words: words, speakers: speakers, elapsedMs: 300_000, includeTimestamps: false)
        let rich = LiveMeetingFocusTranscript.project(
            words: words, speakers: speakers, elapsedMs: 300_000, includeTimestamps: true)
        XCTAssertEqual(plain.startMs, rich.startMs)
        XCTAssertEqual(plain.endMs, rich.endMs)
        XCTAssertEqual(plain.transcript, "Maya: Recent.")
        XCTAssertEqual(rich.transcript, "[3:20] Maya: Recent.")
    }

    func testInvalidTimingAndNegativeElapsedDoNotInventFutureSpeech() {
        let source = project(
            [word("Negative.", -20, -1), word("Backwards.", 90_000, 80_000), word("", 200_000, 300_000)],
            elapsed: -100)
        XCTAssertEqual(source.startMs, 0)
        XCTAssertEqual(source.endMs, 0)
        XCTAssertTrue(source.transcript.isEmpty)
    }

    func testFocusProjectionDoesNotTruncateDenseThreeMinuteSpeech() {
        let words = (0..<5_000).map { word("token\($0)", 180_000 + $0, 180_001 + $0) }
        let source = project(words, elapsed: 300_000)
        XCTAssertGreaterThan(source.transcript.count, 16_000)
        XCTAssertTrue(source.transcript.contains("token0"))
        XCTAssertTrue(source.transcript.contains("token4999"))
    }

    private func project(_ words: [WordTimestamp], elapsed: Int) -> LiveMeetingFocusSource {
        LiveMeetingFocusTranscript.project(words: words, speakers: [], elapsedMs: elapsed, includeTimestamps: false)
    }
}
