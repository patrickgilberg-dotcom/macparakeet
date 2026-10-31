import Foundation

/// A local question/utterance anchor. Identity uses source timing and speaker ID,
/// not a display label, wall clock, or model inference. `isComplete` describes
/// source punctuation; it never promises that speech recognition heard every word.
public struct LiveMeetingQuestionAnchor: Sendable, Equatable, Identifiable {
    public let id: String
    public let text: String
    public let startMs: Int
    public let endMs: Int
    public let speakerID: String?
    public let isQuestion: Bool
    public let isComplete: Bool
    public let semanticText: String

    public init(
        id: String, text: String, startMs: Int, endMs: Int, speakerID: String?,
        isQuestion: Bool, isComplete: Bool, semanticText: String
    ) {
        self.id = id; self.text = text; self.startMs = startMs; self.endMs = endMs
        self.speakerID = speakerID; self.isQuestion = isQuestion; self.isComplete = isComplete
        self.semanticText = semanticText
    }
}

public struct LiveMeetingNowSnapshot: Sendable, Equatable {
    public let source: LiveMeetingFocusSource
    public let anchor: LiveMeetingQuestionAnchor?
    /// Long/pathological source is bounded explicitly. The complete transcript
    /// remains available through the ordinary current/general meeting context.
    public let sourceWasLimited: Bool
    fileprivate let observations: [NowObservedWord]
    fileprivate let observationStartMs: Int

    public init(
        source: LiveMeetingFocusSource, anchor: LiveMeetingQuestionAnchor? = nil,
        sourceWasLimited: Bool = false
    ) {
        self.source = source; self.anchor = anchor; self.sourceWasLimited = sourceWasLimited
        observations = []; observationStartMs = max(0, source.endMs - 180_000)
    }

    fileprivate init(
        source: LiveMeetingFocusSource, anchor: LiveMeetingQuestionAnchor?, sourceWasLimited: Bool,
        observations: [NowObservedWord], observationStartMs: Int
    ) {
        self.source = source; self.anchor = anchor; self.sourceWasLimited = sourceWasLimited
        self.observations = observations; self.observationStartMs = observationStartMs
    }
}

fileprivate struct NowObservedWord: Sendable, Equatable {
    let id: String
    let startMs: Int
    let endMs: Int
    let semanticText: String
    let speakerID: String?
}

/// Pure, local extraction for immediate answer focus. It deliberately performs
/// no network/model work and never changes durable source text.
public enum LiveMeetingNowTranscript {
    public static let windowMilliseconds = 30_000
    public static let anchorLookbackMilliseconds = 180_000
    public static let maximumSourceCharacters = 12_000
    private static let pauseMilliseconds = 2_500
    private static let omission = "[Beginning omitted from this focus; complete source remains in meeting context.]\n"
    private static let fillers: Set<String> = ["uh", "um", "umm", "hmm", "erm", "ah"]
    private static let minorWords: Set<String> = [
        "a", "an", "the", "and", "or", "to", "of", "for", "in", "on", "at", "it", "is", "are", "was", "were",
        "we", "i", "you", "they", "he", "she", "that", "this", "be", "been", "being",
    ]
    private static let correctionWords: Set<String> = [
        "actually", "correction", "instead", "retract", "cancel", "cancelled", "canceled", "not", "no", "never",
    ]
    // These cues only offer a refresh; they never establish approval or task
    // completion. The answer still has to interpret the complete source.
    private static let statusWords: Set<String> = ["approved", "denied", "completed"]
    private static let acknowledgements: Set<String> = [
        "thanks", "thank you", "thank you very much", "okay", "ok", "right", "got it", "understood",
        "all right", "alright", "makes sense", "sounds good",
    ]

    public static func project(
        words: [WordTimestamp], speakers: [SpeakerInfo], elapsedMs: Int,
        includeTimestamps: Bool
    ) -> LiveMeetingNowSnapshot {
        var valid = words.filter { !$0.word.isEmpty && $0.startMs >= 0 && $0.endMs >= $0.startMs }
        // Production input is ordered. Keep that path linear; only repair an
        // explicitly out-of-order caller, retaining input order for equal times.
        if zip(valid, valid.dropFirst()).contains(where: { pair in pair.0.startMs > pair.1.startMs }) {
            valid = valid.enumerated().sorted {
                $0.element.startMs == $1.element.startMs
                    ? $0.offset < $1.offset : $0.element.startMs < $1.element.startMs
            }.map(\.element)
        }
        let end = max(max(0, elapsedMs), valid.map(\.endMs).max() ?? 0)
        let cutoff = max(0, end - windowMilliseconds)
        let lookback = max(0, end - anchorLookbackMilliseconds)
        let sentences = spans(valid, splitAtPause: false)
        let turns = spans(valid, splitAtPause: true)
        let utterances = spans(valid, splitAtPause: true, splitAtSentence: false)
        let meaningfulTurns = turns.filter { range in
            valid[range.upperBound - 1].endMs >= lookback && !semantic(valid[range]).isEmpty
        }
        // A short acknowledgement should not hide the question being answered.
        // Look past acknowledgements, while retaining any intervening new topic.
        let latestTurn =
            meaningfulTurns.last(where: { !acknowledgements.contains(semantic(valid[$0])) })
            ?? meaningfulTurns.last
        // A completed question can cross a real pause, 30 seconds, or rendering
        // paragraph limits. Use its sentence range rather than the paragraph.
        let lastQuestion = sentences.last { range in
            valid[range.upperBound - 1].endMs >= lookback && question(valid[range])
        }
        let legacyAnchor: Range<Int>?
        if let lastQuestion,
            latestTurn == nil || lastQuestion.upperBound >= latestTurn!.upperBound
        {
            legacyAnchor = lastQuestion
        } else {
            legacyAnchor = latestTurn
        }
        let lexical = questionOpeningFallback(
            words: valid, turns: sentences.filter { valid[$0.upperBound - 1].endMs >= lookback }, lookback: lookback)
        let selectedAnchor = lexical.anchor ?? legacyAnchor
        // ASR can insert a question mark or period inside one uninterrupted
        // question. Keep the complete acoustic utterance as exact source even
        // when its sentence punctuation suggests a shorter question.
        let anchorRange = selectedAnchor.map { range -> Range<Int> in
            guard question(valid[range]) || !endsSentence(valid[range.upperBound - 1].word),
                let utterance = utterances.first(where: { $0.contains(range.upperBound - 1) })
            else { return range }
            var start = min(range.lowerBound, utterance.lowerBound)
            if let boundary = lexical.boundary { start = max(start, min(boundary, range.lowerBound)) }
            // This lexical cue is deliberately modest, not semantic turn
            // detection. A genuine Q1? Who/What/Can...Q2? keeps Q2 priority.
            // If capitalization was itself an ASR error, the full raw acoustic
            // utterance below still contains the recoverable opening.
            for (previous, next) in zip(sentences, sentences.dropFirst())
            where next.lowerBound > start && next.lowerBound <= range.lowerBound {
                if question(valid[previous]), startsNewQuestion(valid[next.lowerBound].word) {
                    start = next.lowerBound
                }
            }
            return start..<range.upperBound
        }
        var first = valid.firstIndex { $0.endMs >= cutoff && $0.startMs <= end }
        if let firstIndex = first,
            let intersecting = utterances.first(where: { $0.contains(firstIndex) })
        {
            first = intersecting.lowerBound
        }
        if let anchorRange {
            let acousticStart =
                utterances.first(where: { $0.contains(anchorRange.upperBound - 1) })?.lowerBound
                ?? anchorRange.lowerBound
            let retainedStart = min(anchorRange.lowerBound, acousticStart)
            first = min(first ?? retainedStart, retainedStart)
        }
        if let retainedStart = lexical.retainedStart {
            first = min(first ?? retainedStart, retainedStart)
        }
        let selected = first.map { Array(valid[$0...]) } ?? []
        let labels = Dictionary(speakers.map { ($0.id, $0.label) }, uniquingKeysWith: { _, latest in latest })
        let rendered = render(selected, labels: labels, includeTimestamps: includeTimestamps)
        let limited = rendered.count > maximumSourceCharacters
        let bounded = bound(rendered)
        let anchor = anchorRange.map { range -> LiveMeetingQuestionAnchor in
            let rangeWords = valid[range]
            let firstWord = rangeWords.first!
            let lastWord = rangeWords.last!
            let raw: String = rangeWords.map(\.word).joined(separator: " ")
            let clipped = raw.count > maximumSourceCharacters
            return .init(
                id: identity(speakerID: firstWord.speakerId, startMs: firstWord.startMs),
                text: bound(raw), startMs: firstWord.startMs, endMs: lastWord.endMs,
                speakerID: firstWord.speakerId,
                isQuestion: question(rangeWords)
                    || (lexical.anchor.map { range.lowerBound <= $0.lowerBound && range.upperBound >= $0.upperBound }
                        ?? false),
                isComplete: !clipped && endsSentence(lastWord.word), semanticText: normalize(bound(raw)))
        }
        var occurrences: [String: Int] = [:]
        var observations: [NowObservedWord] = []
        for word in valid {
            let base = identity(speakerID: word.speakerId, startMs: word.startMs)
            let occurrence = occurrences[base, default: 0]; occurrences[base] = occurrence + 1
            guard word.endMs >= lookback, word.startMs <= end else { continue }
            observations.append(
                .init(
                    id: "\(base):\(occurrence)", startMs: word.startMs, endMs: word.endMs,
                    semanticText: normalize(word.word), speakerID: word.speakerId))
        }
        return .init(
            source: .init(transcript: bounded, startMs: selected.first?.startMs ?? cutoff, endMs: end),
            anchor: anchor,
            sourceWasLimited: limited || (anchor?.isComplete == false && anchor?.text.hasPrefix(omission) == true),
            observations: observations, observationStartMs: lookback)
    }

    /// A cue to offer an explicit update, never permission to regenerate on its
    /// own. No amount of clock-only aging or silence makes an answer stale.
    public static func conversationMovedOn(
        from baseline: LiveMeetingNowSnapshot, to current: LiveMeetingNowSnapshot
    ) -> Bool {
        if baseline.observations.isEmpty || current.observations.isEmpty {
            return fallbackMovedOn(from: baseline, to: current)
        }
        let oldText: String = baseline.observations.filter { !$0.semanticText.isEmpty }.map {
            "\($0.speakerID ?? ""):\($0.semanticText)"
        }.joined(separator: " ")
        let newText: String = current.observations.filter { !$0.semanticText.isEmpty }.map {
            "\($0.speakerID ?? ""):\($0.semanticText)"
        }.joined(separator: " ")
        guard oldText != newText else { return false }
        let old = Dictionary(baseline.observations.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let new = Dictionary(current.observations.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var added: [String] = []
        var corrected = false
        for word in current.observations {
            guard !word.semanticText.isEmpty else { continue }
            if let previous = old[word.id] {
                if previous.semanticText != word.semanticText {
                    let growsIncompleteTail =
                        baseline.anchor?.isComplete != true && current.anchor?.isComplete != true
                        && previous.id == baseline.observations.last?.id && word.id == current.observations.last?.id
                        && word.semanticText.hasPrefix(previous.semanticText)
                        && !previous.semanticText.contains(where: \.isNumber)
                        && !word.semanticText.contains(where: \.isNumber)
                        && !previous.semanticText.split(separator: " ").contains(where: {
                            correctionWords.contains(String($0))
                        })
                    if growsIncompleteTail {
                        added += word.semanticText.dropFirst(previous.semanticText.count).split(separator: " ").map(
                            String.init)
                    } else {
                        corrected = true
                    }
                }
            } else {
                added += word.semanticText.split(separator: " ").map(String.init)
            }
        }
        for word in baseline.observations
        where word.endMs >= current.observationStartMs && word.startMs <= current.source.endMs {
            if new[word.id] == nil, !word.semanticText.isEmpty { corrected = true }
        }
        guard corrected || !added.isEmpty else { return false }
        if corrected { return true }
        if let anchor = current.anchor, anchor.isQuestion, anchor.isComplete,
            anchor.semanticText != baseline.anchor?.semanticText
        {
            return true
        }
        if added.contains(where: correctionWords.contains) || added.contains(where: statusWords.contains) {
            return true
        }
        return added.filter { !minorWords.contains($0) }.count >= 8
    }

    private static func fallbackMovedOn(
        from baseline: LiveMeetingNowSnapshot, to current: LiveMeetingNowSnapshot
    ) -> Bool {
        let before = baseline.anchor?.semanticText ?? normalize(baseline.source.transcript)
        let after = current.anchor?.semanticText ?? normalize(current.source.transcript)
        guard !after.isEmpty, before != after else { return false }
        if let anchor = current.anchor, anchor.isComplete, anchor.isQuestion { return true }
        if let old = baseline.anchor, let new = current.anchor, old.id == new.id, !after.hasPrefix(before) {
            return true
        }
        let appended = after.hasPrefix(before) ? String(after.dropFirst(before.count)) : after
        let tokens = appended.split(separator: " ").map(String.init)
        return tokens.contains(where: correctionWords.contains) || tokens.contains(where: statusWords.contains)
            || tokens.filter { !minorWords.contains($0) }.count >= 8
    }

    private static func identity(speakerID: String?, startMs: Int) -> String {
        let id = speakerID ?? ""
        return "\(id.utf8.count):\(id):\(startMs)"
    }

    private static func spans(
        _ words: [WordTimestamp], splitAtPause: Bool, splitAtSentence: Bool = true
    ) -> [Range<Int>] {
        guard !words.isEmpty else { return [] }
        var output: [Range<Int>] = []
        var start = 0
        for index in words.indices {
            if index > start,
                words[index].speakerId != words[index - 1].speakerId
                    || (splitAtPause && words[index].startMs - words[index - 1].endMs >= pauseMilliseconds)
            {
                output.append(start..<index); start = index
            }
            if splitAtSentence, endsSentence(words[index].word) {
                output.append(start..<(index + 1)); start = index + 1
            }
        }
        if start < words.count { output.append(start..<words.count) }
        return output
    }

    /// Local recovery for ASR that inserts periods/pauses and omits the final
    /// question mark. It is an English lexical cue, not semantic turn detection.
    /// A later explicit question/topic/status still takes priority. Raw source
    /// can retain the earlier opening when a status boundary is ambiguous.
    private static func questionOpeningFallback(
        words: [WordTimestamp], turns: [Range<Int>], lookback: Int
    ) -> (anchor: Range<Int>?, retainedStart: Int?, boundary: Int?) {
        var active: Range<Int>?
        var retainedStart: Int?
        var boundary: Int?
        var speaker: String?
        for range in turns {
            let first = words[range.lowerBound]
            let text = semantic(words[range])
            let tokens = text.split(separator: " ").map(String.init)
            guard !tokens.isEmpty, !acknowledgements.contains(text) else { continue }
            if let start = retainedStart, words[start].speakerId != first.speakerId {
                active = nil; retainedStart = nil; boundary = range.lowerBound
            }
            if first.startMs >= lookback, directQuestionOpening(tokens) {
                if retainedStart != nil { boundary = range.lowerBound }
                active = range; retainedStart = range.lowerBound; speaker = first.speakerId
                continue
            }
            let continuation: Set<String> = [
                "and", "but", "while", "whether", "so", "before", "after", "as", "also", "which", "that", "to",
                "without", "if", "when", "where", "how", "who", "what", "because", "since",
            ]
            let explicitQuestion =
                active != nil && question(words[range])
                && ((tokens.count <= 4
                    && (tokens.count == 1 || !continuation.contains(tokens[0]) || startsNewQuestion(first.word)))
                    || ["given", "under"].contains(tokens[0]))
            if explicitQuestion {
                active = range; boundary = range.lowerBound
                retainedStart = retainedStart ?? range.lowerBound; speaker = first.speakerId
                continue
            }
            let explicitTopic = [
                "here is a different question", "here is another question", "new question", "different question",
                "another question", "separate question", "moving on", "switching topics", "next topic", "different ",
            ].contains(where: text.hasPrefix)
            let status =
                statusWords.contains(tokens[0])
                || (tokens.contains(where: statusWords.contains)
                    && tokens.contains(where: {
                        ["is", "are", "was", "were", "has", "have", "been", "now"].contains($0)
                    })
                    && endsSentence(words[range.upperBound - 1].word))
            if explicitTopic {
                active = nil; retainedStart = nil; boundary = range.lowerBound
                continue
            }
            if status {
                active = nil; boundary = range.lowerBound
                continue
            }
            let declarativeStarts: Set<String> = ["i", "we", "they", "you", "he", "she", "the", "our", "this", "it"]
            let standaloneStatement =
                tokens.count >= 8 && !continuation.contains(tokens[0])
                && declarativeStarts.contains(tokens[0]) && endsSentence(words[range.upperBound - 1].word)
            if standaloneStatement {
                active = nil; retainedStart = nil; boundary = range.lowerBound
                continue
            }
            if let prior = active, first.speakerId == speaker {
                active = prior.lowerBound..<range.upperBound
            }
        }
        return (active, retainedStart, boundary)
    }

    private static func directQuestionOpening(_ tokens: [String]) -> Bool {
        guard let first = tokens.first, tokens.count >= 2 else { return false }
        if ["can", "could", "would", "should", "will", "do", "does", "did", "is", "are", "was", "were", "has", "have"]
            .contains(first)
        {
            return true
        }
        if ["who", "whom", "whose"].contains(first) { return true }
        if ["what", "how", "when", "where", "why", "which"].contains(first) {
            return [
                "is", "are", "was", "were", "can", "could", "would", "should", "will", "do", "does", "did", "has",
                "have",
            ].contains(tokens[1])
        }
        if first == "please" { return true }
        if ["help", "tell", "show", "walk"].contains(first), ["me", "us"].contains(tokens[1]) { return true }
        return first == "explain"
    }

    private static func startsNewQuestion(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“‘([{"))
        guard text.first?.isUppercase == true, let first = normalize(text).split(separator: " ").first else {
            return false
        }
        return [
            "who", "what", "when", "where", "why", "how", "can", "could", "would", "should", "will", "do", "does",
            "did", "is", "are", "was", "were", "has", "have",
        ].contains(String(first))
    }

    private static func question(_ words: ArraySlice<WordTimestamp>) -> Bool {
        words.contains { $0.word.contains("?") || $0.word.contains("？") }
    }

    private static func semantic(_ words: ArraySlice<WordTimestamp>) -> String {
        normalize(words.map(\.word).joined(separator: " "))
    }

    private static func normalize(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { !fillers.contains($0) }.joined(separator: " ")
    }

    private static func endsSentence(_ value: String) -> Bool {
        let word = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]}"))
        guard let last = word.last else { return false }
        if last == "?" || last == "？" || last == "!" || last == "！" || last == "。" { return true }
        guard last == "." else { return false }
        let lower = word.lowercased()
        if ["mr.", "mrs.", "ms.", "dr.", "prof.", "jr.", "sr.", "st.", "vs.", "etc."].contains(lower) { return false }
        if word.dropLast().contains(".") { return false }
        if word.dropLast().count == 1, word.first?.isUppercase == true { return false }
        return true
    }

    private static func bound(_ text: String) -> String {
        guard text.count > maximumSourceCharacters else { return text }
        return omission + String(text.suffix(maximumSourceCharacters - omission.count))
    }

    private static func render(
        _ words: [WordTimestamp], labels: [String: String], includeTimestamps: Bool
    ) -> String {
        spans(words, splitAtPause: true).map { range -> String in
            let selected = words[range]
            let first = selected.first!
            let speaker = first.speakerId ?? ""
            let label = labels[speaker]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = label?.isEmpty == false ? label! : AudioSource(rawValue: speaker)?.displayLabel ?? "Speaker"
            let timestamp: String
            if includeTimestamps {
                let seconds = first.startMs / 1_000
                timestamp = "[\(seconds / 60):\(String(format: "%02d", seconds % 60))] "
            } else {
                timestamp = ""
            }
            return "\(timestamp)\(name): \(selected.map(\.word).joined(separator: " "))"
        }.joined(separator: "\n")
    }
}
