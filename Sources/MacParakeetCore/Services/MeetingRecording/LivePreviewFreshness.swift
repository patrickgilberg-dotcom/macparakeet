import Foundation

/// Loss tracking is independent of the transient UI catching-up indicator.
/// Recovery means newer speech exists, never that missing words were reconstructed.
struct LivePreviewFreshness {
    private(set) var unresolvedFrontiers: [AudioSource: Int] = [:]
    private(set) var pendingIngressMarkers: [AudioSource: Int] = [:]
    private(set) var hasEarlierGap = false
    private var nextIngressRevision = 0

    var canAnswerLatestQuestion: Bool { unresolvedFrontiers.isEmpty && pendingIngressMarkers.isEmpty }

    mutating func recordLoss(source: AudioSource, nextEnqueueSequence: Int) {
        hasEarlierGap = true
        unresolvedFrontiers[source] = max(unresolvedFrontiers[source] ?? 0, nextEnqueueSequence)
    }

    mutating func recordIngressLoss(source: AudioSource) {
        hasEarlierGap = true
        nextIngressRevision += 1
        pendingIngressMarkers[source] = nextIngressRevision
    }

    mutating func acknowledgeIngressFrontier(source: AudioSource, revision: Int) {
        if pendingIngressMarkers[source] == revision { pendingIngressMarkers[source] = nil }
    }

    mutating func receive(source: AudioSource, enqueueSequence: Int, hasSpeech: Bool) {
        guard hasSpeech, pendingIngressMarkers[source] == nil,
            let frontier = unresolvedFrontiers[source], enqueueSequence >= frontier
        else { return }
        unresolvedFrontiers[source] = nil
    }
}
