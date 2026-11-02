import XCTest
@testable import MacParakeetCore

final class LivePreviewFreshnessTests: XCTestCase {
    func testLossBeforeAskAndSilentFlushRemainUnresolved() {
        var freshness = LivePreviewFreshness()
        freshness.recordLoss(source: .system, nextEnqueueSequence: 3)
        freshness.receive(source: .system, enqueueSequence: 3, hasSpeech: false)
        XCTAssertFalse(freshness.canAnswerLatestQuestion)
        XCTAssertTrue(freshness.hasEarlierGap)
    }

    func testPreviouslyEnqueuedSuccessAndOtherSourceSpeechCannotClearLoss() {
        var freshness = LivePreviewFreshness()
        freshness.recordLoss(source: .system, nextEnqueueSequence: 3)
        freshness.receive(source: .system, enqueueSequence: 2, hasSpeech: true)
        freshness.receive(source: .microphone, enqueueSequence: 10, hasSpeech: true)
        XCTAssertFalse(freshness.canAnswerLatestQuestion)
        freshness.receive(source: .system, enqueueSequence: 3, hasSpeech: true)
        XCTAssertTrue(freshness.canAnswerLatestQuestion)
        XCTAssertTrue(freshness.hasEarlierGap, "Newer speech does not reconstruct lost words")
    }

    func testIngressLossMustDrainItsFrontierBeforeNewSpeechCanRecover() {
        var freshness = LivePreviewFreshness()
        freshness.recordIngressLoss(source: .microphone)
        let revision = freshness.pendingIngressMarkers[.microphone]!
        freshness.receive(source: .microphone, enqueueSequence: 4, hasSpeech: true)
        XCTAssertFalse(freshness.canAnswerLatestQuestion)
        freshness.recordLoss(source: .microphone, nextEnqueueSequence: 5)
        freshness.acknowledgeIngressFrontier(source: .microphone, revision: revision)
        freshness.receive(source: .microphone, enqueueSequence: 4, hasSpeech: true)
        XCTAssertFalse(freshness.canAnswerLatestQuestion)
        freshness.receive(source: .microphone, enqueueSequence: 5, hasSpeech: true)
        XCTAssertTrue(freshness.canAnswerLatestQuestion)
    }

    func testNewIngressLossDuringFrontierAcknowledgementStaysPending() {
        var freshness = LivePreviewFreshness()
        freshness.recordIngressLoss(source: .system)
        let oldRevision = freshness.pendingIngressMarkers[.system]!
        freshness.recordIngressLoss(source: .system)
        freshness.recordLoss(source: .system, nextEnqueueSequence: 2)
        freshness.acknowledgeIngressFrontier(source: .system, revision: oldRevision)
        freshness.receive(source: .system, enqueueSequence: 2, hasSpeech: true)
        XCTAssertFalse(freshness.canAnswerLatestQuestion)
    }

    func testNewSessionResetsLossAndEarlierGapWarning() {
        var freshness = LivePreviewFreshness()
        freshness.recordLoss(source: .system, nextEnqueueSequence: 2)
        freshness = LivePreviewFreshness()
        XCTAssertTrue(freshness.canAnswerLatestQuestion)
        XCTAssertFalse(freshness.hasEarlierGap)
    }
}
