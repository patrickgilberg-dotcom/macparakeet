import Foundation

/// Projects a live focus window from audio-relative word times. Display text
/// preferences never determine which speech belongs to the three-minute window.
public enum LiveMeetingFocusTranscript {
    public static let windowMilliseconds = 180_000

    public static func project(
        words: [WordTimestamp], speakers: [SpeakerInfo], elapsedMs: Int,
        includeTimestamps: Bool
    ) -> LiveMeetingFocusSource {
        // The transcript barrier may publish fresh words before the next elapsed
        // time poll. Silence, however, must advance the window without new words.
        let latestWordEnd = words.lazy.filter(validTiming).map(\.endMs).max() ?? 0
        let end = max(max(0, elapsedMs), latestWordEnd)
        let start = max(0, end - windowMilliseconds)
        let selected = words.filter {
            validTiming($0) && $0.endMs >= start && $0.startMs <= end
        }
        let labels = Dictionary(speakers.map { ($0.id, $0.label) }, uniquingKeysWith: { _, latest in latest })
        let transcript: String = TranscriptParagraphBuilder.build(from: selected).map { paragraph -> String in
            let speakerID = paragraph.speakerId ?? ""
            let savedLabel = labels[speakerID]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let label = savedLabel.isEmpty ? AudioSource(rawValue: speakerID)?.displayLabel ?? "Speaker" : savedLabel
            let prefix: String
            if includeTimestamps {
                let seconds = paragraph.startMs / 1_000
                prefix = "[\(seconds / 60):\(String(format: "%02d", seconds % 60))] "
            } else {
                prefix = ""
            }
            return "\(prefix)\(label): \(paragraph.text)"
        }.joined(separator: "\n")
        return LiveMeetingFocusSource(transcript: transcript, startMs: start, endMs: end)
    }

    private static func validTiming(_ word: WordTimestamp) -> Bool {
        !word.word.isEmpty && word.startMs >= 0 && word.endMs >= word.startMs
    }
}
