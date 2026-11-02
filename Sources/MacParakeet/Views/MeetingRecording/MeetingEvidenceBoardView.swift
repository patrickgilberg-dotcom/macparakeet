import Foundation
import MacParakeetCore
import SwiftUI

/// A captured board and its original quotations. Disclosure always uses the
/// captured source, so a later transcript correction cannot send a quote to
/// a different live line or make a historical note look like current speech.
struct MeetingEvidenceBoardView: View {
    let snapshot: MeetingBoardSnapshot
    var compact = false

    @State private var selectedQuote: MeetingBoardQuoteSelection?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: compact ? 12 : 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Decisions & follow-ups").font(.headline)
                    Text("Snapshot at \(snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !snapshot.coverageDescription.isEmpty {
                        DisclosureGroup("Sources and coverage") {
                            Text(snapshot.coverageDescription)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if snapshot.items.isEmpty && snapshot.resolvedItems.isEmpty {
                    Label("No decisions or follow-ups found in this snapshot.", systemImage: "checklist")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    currentGroup("Actions", kind: .action, icon: "checklist")
                    currentGroup("Decisions", kind: .decision, icon: "checkmark.seal")
                    currentGroup("Questions", kind: .question, icon: "questionmark.bubble")
                    currentGroup("Notes", kind: .note, icon: "note.text")
                    let carryover = snapshot.items.filter(isHistorical)
                    if !carryover.isEmpty {
                        group(
                            "Carryover from the latest project meeting", items: carryover,
                            icon: "clock.arrow.circlepath")
                        Text(
                            "Previous meeting items are historical. Their completion is unverified unless current evidence updates it."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if !snapshot.resolvedItems.isEmpty {
                        group("Resolved", items: snapshot.resolvedItems, icon: "checkmark.circle")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $selectedQuote) { selection in
            MeetingBoardQuoteSheet(selection: selection)
        }
    }

    @ViewBuilder
    private func currentGroup(_ title: String, kind: MeetingBoardItem.Kind, icon: String) -> some View {
        let items = snapshot.items.filter { $0.kind == kind && !isHistorical($0) }
        if !items.isEmpty { group(title, items: items, icon: icon) }
    }

    private func group(_ title: String, items: [MeetingBoardItem], icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            ForEach(items) { item in itemRow(item) }
        }
    }

    private func itemRow(_ item: MeetingBoardItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(item.text)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text(
                item.isResolved
                    ? "Resolved · originally \(commitmentLabel(item.commitment).lowercased())"
                    : commitmentLabel(item.commitment)
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            let details = [
                item.owner.map { "Owner: \($0)" }, item.deadline.map { "Due: \($0)" },
            ].compactMap { $0 }.joined(separator: " · ")
            if !details.isEmpty {
                Text(details)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(provenanceLabel(item))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if hasNoteEvidence(item) {
                Text("Your typed notes do not establish spoken commitments.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(item.evidence.enumerated()), id: \.offset) { index, quote in
                quoteButton(quote, item: item, index: index)
            }
            if let resolution = item.resolutionEvidence {
                quoteButton(resolution, item: item, index: item.evidence.count, isResolution: true)
            }
            if let reopening = item.reopeningEvidence {
                quoteButton(reopening, item: item, index: item.evidence.count + 1, isReopening: true)
            }
        }
        .padding(compact ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain)
    }

    private func quoteButton(
        _ quote: MeetingEvidenceQuote, item: MeetingBoardItem, index: Int, isResolution: Bool = false,
        isReopening: Bool = false
    ) -> some View {
        let document = snapshot.document(for: quote)
        let isAvailable = snapshot.resolvedQuote(quote) != nil
        return Button {
            selectedQuote = MeetingBoardQuoteSelection(
                document: document, quote: quote.quote, generatedAt: snapshot.generatedAt,
                itemText: item.text, provenance: provenanceLabel(item), isVerified: isAvailable,
                isResolved: item.isResolved, isResolutionQuote: isResolution)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Label(
                    isAvailable
                        ? (isReopening
                            ? "Reopening quotation"
                            : (isResolution ? "Resolution quotation" : documentLabel(document?.kind)))
                        : "Source unavailable",
                    systemImage: isAvailable ? "quote.bubble" : "exclamationmark.circle"
                )
                .font(.caption.weight(.medium))
                Text("“\(quote.quote)”")
                    .font(.caption)
                    .lineLimit(compact ? 2 : 3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .parakeetAction(.subtle)
        .help(
            isAvailable
                ? "Open the exact quotation and surrounding captured source" : "This quotation cannot be verified"
        )
        .accessibilityLabel(isAvailable ? "Open source quotation: \(quote.quote)" : "Source quotation unavailable")
        .accessibilityIdentifier("meeting-board-quote-\(item.id)-\(index)")
    }

    private func isHistorical(_ item: MeetingBoardItem) -> Bool {
        item.evidence.contains { quote in snapshot.document(for: quote)?.kind.isHistorical == true }
    }

    private func hasNoteEvidence(_ item: MeetingBoardItem) -> Bool {
        item.evidence.contains { quote in snapshot.document(for: quote)?.kind.isNotes == true }
    }

    private func provenanceLabel(_ item: MeetingBoardItem) -> String {
        guard item.evidence.contains(where: { snapshot.document(for: $0) != nil }) else { return "Source unavailable" }
        return item.provenanceLabel(in: snapshot.documents)
    }

    private func commitmentLabel(_ commitment: MeetingBoardItem.Commitment) -> String {
        switch commitment {
        case .confirmed: return "Confirmed"
        case .proposed: return "Proposed"
        case .conditional: return "Conditional"
        case .unresolved: return "Unresolved"
        case .noted: return "Noted"
        }
    }

    private func documentLabel(_ kind: MeetingEvidenceDocument.Kind?) -> String {
        switch kind {
        case .currentTranscript: return "Current transcript quotation"
        case .currentNotes: return "Your current note"
        case .previousTranscript: return "Previous meeting quotation"
        case .previousNotes: return "Your previous meeting note"
        case nil: return "Source unavailable"
        }
    }
}

private struct MeetingBoardQuoteSelection: Identifiable {
    let id = UUID()
    let document: MeetingEvidenceDocument?
    let quote: String
    let generatedAt: Date
    let itemText: String
    let provenance: String
    let isVerified: Bool
    let isResolved: Bool
    let isResolutionQuote: Bool

    var exactRange: Range<String.Index>? {
        guard isVerified, let document, !quote.isEmpty,
            let range = document.text.range(of: quote, options: [.literal]),
            Data(document.text[range].utf8) == Data(quote.utf8)
        else { return nil }
        return range
    }
}

private struct MeetingBoardQuoteSheet: View {
    let selection: MeetingBoardQuoteSelection

    @Environment(\.dismiss) private var dismiss
    @State private var showsFullSource = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(selection.isResolutionQuote ? "Resolution quotation" : "Source quotation")
                .font(.title3.weight(.semibold))
            Text(selection.itemText)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("Snapshot captured \(selection.generatedAt.formatted(date: .abbreviated, time: .standard))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let document = selection.document, let range = selection.exactRange {
                sourceDetails(document)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        excerpt(document: document, range: range)
                            .font(.body)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("meeting-board-verified-excerpt")
                        DisclosureGroup(
                            document.kind.isNotes ? "Full captured notes" : "Full captured transcript",
                            isExpanded: $showsFullSource
                        ) {
                            if showsFullSource {
                                Text(document.text)
                                    .font(.callout)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 8)
                            }
                        }
                        .font(.caption)
                    }
                    .padding(.trailing, 8)
                }
            } else {
                Label(
                    "The exact quotation is unavailable in this captured source.", systemImage: "exclamationmark.circle"
                )
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                Text("Refresh the board to check the available sources.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .parakeetAction(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 620, height: 520)
    }

    private func sourceDetails(_ document: MeetingEvidenceDocument) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if !document.title.isEmpty {
                Text(document.title)
                    .font(.subheadline.weight(.semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(sourceKindLabel(document.kind))
                .font(.caption.weight(.semibold))
            Text(selection.provenance).font(.caption).foregroundStyle(.secondary)
            if document.kind.isNotes {
                Text("This is your typed note, not a spoken transcript or proof of an accepted assignment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if document.kind.isHistorical && !selection.isResolved {
                Text(
                    "Historical source from the latest project meeting. Completion has not been independently verified."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if selection.isResolved && !selection.isResolutionQuote {
                Text("This quotation records the original item. Its later update has a separate resolution quotation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sourceKindLabel(_ kind: MeetingEvidenceDocument.Kind) -> String {
        switch kind {
        case .currentTranscript: return "Current meeting transcript"
        case .currentNotes: return "Your current meeting notes"
        case .previousTranscript: return "Latest previous project meeting transcript"
        case .previousNotes: return "Your notes from the latest previous project meeting"
        }
    }

    private func excerpt(document: MeetingEvidenceDocument, range: Range<String.Index>) -> Text {
        let source = document.text
        let start = source.index(range.lowerBound, offsetBy: -360, limitedBy: source.startIndex) ?? source.startIndex
        let end = source.index(range.upperBound, offsetBy: 360, limitedBy: source.endIndex) ?? source.endIndex
        let before = (start > source.startIndex ? "…" : "") + String(source[start..<range.lowerBound])
        let after = String(source[range.upperBound..<end]) + (end < source.endIndex ? "…" : "")
        return Text(before) + Text(String(source[range])).bold() + Text(after)
    }
}
