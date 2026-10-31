import XCTest
@testable import MacParakeetCore

final class LiveMeetingNowTranscriptTests: XCTestCase {
    private func word(_ text: String, _ start: Int, _ end: Int, _ speaker: String? = "system") -> WordTimestamp {
        .init(word: text, startMs: start, endMs: end, confidence: 1, speakerId: speaker)
    }
    private func project(
        _ words: [WordTimestamp], at time: Int, rich: Bool = false,
        speakers: [SpeakerInfo] = []
    ) -> LiveMeetingNowSnapshot {
        LiveMeetingNowTranscript.project(words: words, speakers: speakers, elapsedMs: time, includeTimestamps: rich)
    }

    func testThirtySecondWindowRetainsTheCompleteIntersectingQuestion() {
        let words = [
            word("Previous.", 1_000, 2_000), word("Can", 40_000, 41_000), word("we", 49_000, 50_000),
            word("approve", 55_000, 56_000), word("this?", 69_000, 70_000),
        ]
        let result = project(words, at: 80_000)
        XCTAssertEqual(result.source.startMs, 40_000)
        XCTAssertEqual(result.source.endMs, 80_000)
        XCTAssertFalse(result.source.transcript.contains("Previous."))
        XCTAssertTrue(result.source.transcript.contains("Can"))
        XCTAssertEqual(result.anchor?.text, "Can we approve this?")
        XCTAssertEqual(result.anchor?.startMs, 40_000)
        XCTAssertTrue(result.anchor?.isQuestion == true)
        XCTAssertTrue(result.anchor?.isComplete == true)
    }

    func testLongQuestionCrossesPausesAndRenderingParagraphLimitsWithoutClipping() {
        let words = (0..<120).map { index in
            word(index == 119 ? "proceed?" : "detail\(index)", index * 600, index * 600 + 100)
        }
        let result = project(words, at: 80_000)
        XCTAssertEqual(result.anchor?.text, words.map(\.word).joined(separator: " "))
        XCTAssertTrue(result.source.transcript.contains("detail0"))
        XCTAssertTrue(result.source.transcript.contains("proceed?"))
        XCTAssertFalse(result.sourceWasLimited)
        XCTAssertTrue(result.anchor?.isComplete == true)
    }

    func testQuestionSentenceCanCrossLongPauseWithoutLosingItsStart() {
        let result = project(
            [
                word("Given", 0, 500), word("the", 1_000, 1_500), word("constraints", 20_000, 20_500),
                word("can", 40_000, 40_500), word("we", 41_000, 41_500), word("proceed?", 50_000, 50_500),
            ], at: 60_000)
        XCTAssertEqual(result.anchor?.text, "Given the constraints can we proceed?")
        XCTAssertEqual(result.source.startMs, 0)
    }

    func testQuestionAnchorSurvivesSilenceAndExpiresAfterLookback() {
        let words = [word("Can we proceed?", 10_000, 20_000)]
        let atAsk = project(words, at: 25_000)
        let silent = project(words, at: 100_000)
        XCTAssertEqual(atAsk.anchor?.id, silent.anchor?.id)
        XCTAssertEqual(silent.anchor?.text, "Can we proceed?")
        XCTAssertFalse(LiveMeetingNowTranscript.conversationMovedOn(from: atAsk, to: silent))
        let expired = project(words, at: 200_001)
        XCTAssertNil(expired.anchor)
        XCTAssertTrue(expired.source.transcript.isEmpty)
        XCTAssertFalse(LiveMeetingNowTranscript.conversationMovedOn(from: atAsk, to: expired))
    }

    func testActualSentenceAndPauseBoundariesAvoidAnUnboundedUnknownSpeakerTurn() {
        let result = project(
            [
                word("An old statement.", 0, 500, nil), word("Current unfinished turn", 50_000, 51_000, nil),
            ], at: 60_000)
        XCTAssertFalse(result.source.transcript.contains("old statement"))
        XCTAssertEqual(result.anchor?.text, "Current unfinished turn")
        XCTAssertNil(result.anchor?.speakerID)
        XCTAssertFalse(result.anchor?.isComplete ?? true)
        XCTAssertTrue(result.source.transcript.hasPrefix("Speaker:"))
    }

    func testPlainRichAndLabelChangesHaveSameSemanticAnchorAndDoNotMarkStale() {
        let words = [word("Can we proceed?", 50_000, 51_000)]
        let plain = project(words, at: 60_000, speakers: [.init(id: "system", label: "Maya")])
        let rich = project(words, at: 65_000, rich: true, speakers: [.init(id: "system", label: "Lee")])
        XCTAssertEqual(plain.anchor?.id, rich.anchor?.id)
        XCTAssertEqual(plain.anchor?.semanticText, rich.anchor?.semanticText)
        XCTAssertTrue(plain.source.transcript.contains("Maya:"))
        XCTAssertTrue(rich.source.transcript.contains("[0:50] Lee:"))
        XCTAssertFalse(LiveMeetingNowTranscript.conversationMovedOn(from: plain, to: rich))
    }

    func testFreshBarrierWordEndAdvancesBeyondStaleElapsedPollAndInvalidTimingIsExcluded() {
        let result = project(
            [
                word("bad", -20, -1), word("backwards", 90_000, 80_000), word("", 0, 999_000),
                word("Fresh question?", 300_000, 301_234),
            ], at: 300_000)
        XCTAssertEqual(result.source.endMs, 301_234)
        XCTAssertEqual(result.anchor?.text, "Fresh question?")
        XCTAssertFalse(result.source.transcript.contains("backwards"))
    }

    func testPathologicalQuestionIsBoundedAndExplicitlyIncomplete() {
        let text = String(repeating: "a", count: 15_000) + "?"
        let result = project([word(text, 0, 10_000)], at: 20_000)
        XCTAssertLessThanOrEqual(result.source.transcript.count, 12_000)
        XCTAssertLessThanOrEqual(result.anchor?.text.count ?? 99_999, 12_000)
        XCTAssertTrue(result.sourceWasLimited)
        XCTAssertTrue(result.source.transcript.contains("Beginning omitted"))
        XCTAssertFalse(result.anchor?.isComplete ?? true)
    }

    func testCompletedNewQuestionOffersUpdateWithOnlyOneNewWord() {
        let first = [word("Can we proceed?", 0, 1_000)]
        let before = project(first, at: 2_000)
        let after = project(first + [word("Why?", 3_000, 3_500)], at: 4_000)
        XCTAssertTrue(LiveMeetingNowTranscript.conversationMovedOn(from: before, to: after))
    }

    func testCompleteQuestionRemainsAnchorThroughBriefAcknowledgementsAndFillers() {
        let first = [word("Can we proceed?", 0, 1_000)]
        let baseline = project(first, at: 2_000)
        let after = project(
            first + [
                word("Thanks.", 40_000, 41_000), word("Okay.", 42_000, 43_000), word("Um.", 44_000, 45_000),
            ], at: 50_000)
        XCTAssertEqual(after.anchor?.text, "Can we proceed?")
        XCTAssertEqual(after.anchor?.id, baseline.anchor?.id)
        XCTAssertTrue(after.source.transcript.contains("Thanks."))
        XCTAssertTrue(after.source.transcript.contains("Okay."))
        XCTAssertFalse(LiveMeetingNowTranscript.conversationMovedOn(from: baseline, to: after))
    }

    func testAcknowledgementDoesNotHideAnInterveningSubstantiveTopicOrNewQuestion() {
        let first = [word("Can we proceed?", 0, 1_000)]
        let topic = "Different delivery dates require security review customer approval."
        let moved = project(
            first + [
                word(topic, 40_000, 42_000), word("Thanks.", 43_000, 44_000),
            ], at: 50_000)
        XCTAssertEqual(moved.anchor?.text, topic)
        XCTAssertTrue(LiveMeetingNowTranscript.conversationMovedOn(from: project(first, at: 2_000), to: moved))
        let newQuestion = project(
            first + [
                word("What changed?", 40_000, 41_000), word("Thanks.", 42_000, 43_000),
            ], at: 50_000)
        XCTAssertEqual(newQuestion.anchor?.text, "What changed?")
        XCTAssertTrue(newQuestion.anchor?.isQuestion == true)
    }

    func testStandaloneStatusChangesOfferUpdateWithoutInferringTheirTruth() {
        let first = [word("Can we proceed?", 0, 1_000)]
        let baseline = project(first, at: 2_000)
        for status in ["Approved.", "Denied.", "Completed."] {
            let current = project(first + [word(status, 3_000, 3_500)], at: 4_000)
            XCTAssertTrue(LiveMeetingNowTranscript.conversationMovedOn(from: baseline, to: current), status)
            XCTAssertEqual(current.anchor?.text, status)
        }
    }

    func testPartialTokensAndPunctuationCaseChangesDoNotOfferUpdate() {
        let before = project([word("Can we proceed?", 0, 1_000)], at: 2_000)
        let appended = project(
            [
                word("Can we proceed?", 0, 1_000), word("I", 3_000, 3_200), word("think", 3_300, 3_600),
            ], at: 4_000)
        XCTAssertFalse(LiveMeetingNowTranscript.conversationMovedOn(from: before, to: appended))
        let punctuation = project([word("CAN WE PROCEED.", 0, 1_000)], at: 4_000)
        XCTAssertFalse(LiveMeetingNowTranscript.conversationMovedOn(from: before, to: punctuation))
        XCTAssertFalse(LiveMeetingNowTranscript.conversationMovedOn(from: before, to: before))
    }

    func testIncompleteTrailingTokenGrowthDoesNotOfferUpdateButNumbersRemainMeaningful() {
        let before = project([word("The budg", 0, 1_000)], at: 2_000)
        let completedToken = project([word("The budget", 0, 1_000)], at: 3_000)
        XCTAssertFalse(LiveMeetingNowTranscript.conversationMovedOn(from: before, to: completedToken))
        let oldAmount = project([word("The cap is 38", 0, 1_000)], at: 2_000)
        let changedAmount = project([word("The cap is 38000", 0, 1_000)], at: 3_000)
        XCTAssertTrue(LiveMeetingNowTranscript.conversationMovedOn(from: oldAmount, to: changedAmount))
        let completedQuestion = project([word("The budget approved?", 0, 1_000)], at: 3_000)
        XCTAssertTrue(LiveMeetingNowTranscript.conversationMovedOn(from: before, to: completedQuestion))
    }

    func testChangedWordOrSpeakerAttributionOffersUpdate() {
        let before = project([word("Approval is pending.", 10_000, 11_000, "A")], at: 12_000)
        let correction = project([word("Approval is declined.", 10_000, 11_000, "A")], at: 12_000)
        XCTAssertTrue(LiveMeetingNowTranscript.conversationMovedOn(from: before, to: correction))
        let reassigned = project([word("Approval is pending.", 10_000, 11_000, "B")], at: 12_000)
        XCTAssertTrue(LiveMeetingNowTranscript.conversationMovedOn(from: before, to: reassigned))
    }

    func testExplicitCorrectionAndSubstantiveDiscussionOfferUpdate() {
        let first = [word("Can we proceed?", 0, 1_000)]
        let before = project(first, at: 2_000)
        let correction = project(first + [word("Actually no", 3_000, 3_500)], at: 4_000)
        XCTAssertTrue(LiveMeetingNowTranscript.conversationMovedOn(from: before, to: correction))
        let eight = ["Different", "delivery", "dates", "require", "security", "review", "customer", "approval"]
        let substantive = project(
            first
                + eight.enumerated().map {
                    word($0.element, 3_000 + $0.offset * 100, 3_050 + $0.offset * 100)
                }, at: 5_000)
        XCTAssertTrue(LiveMeetingNowTranscript.conversationMovedOn(from: before, to: substantive))
    }

    func testSilenceAgingObservationsWithEqualWordStartsDoesNotOfferUpdate() {
        let words = [word("Earlier", 0, 1_000), word("Later", 0, 10_000)]
        let before = project(words, at: 180_000)
        let after = project(words, at: 185_000)
        XCTAssertFalse(LiveMeetingNowTranscript.conversationMovedOn(from: before, to: after))
    }

    func testRemovingRecognizedNegationIsMeaningfulCorrection() {
        let words = [word("Approval", 0, 100), word("not", 200, 300), word("granted.", 400, 500)]
        let before = project(words, at: 1_000)
        let after = project([words[0], words[2]], at: 1_000)
        XCTAssertTrue(LiveMeetingNowTranscript.conversationMovedOn(from: before, to: after))
    }

    func testAbbreviationInsideQuestionDoesNotLoseTheLeadingCondition() {
        let words = [
            word("Given", 0, 100), word("the U.S.", 1_000, 1_100), word("review", 30_000, 30_100),
            word("can we proceed?", 50_000, 51_000),
        ]
        let result = project(words, at: 60_000)
        XCTAssertEqual(result.anchor?.text, "Given the U.S. review can we proceed?")
    }
}
