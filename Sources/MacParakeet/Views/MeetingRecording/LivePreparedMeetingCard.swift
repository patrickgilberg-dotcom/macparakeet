import MacParakeetCore
import SwiftUI

/// Quiet historical context: no notification, automatic question or overlay.
struct LivePreparedMeetingCard: View {
    let preparation: MeetingGeneratedPreparation
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    "Prepared from the latest meeting in \(preparation.projectName) and any saved notes. Ask can use this background; current speech takes priority."
                )
                .font(.caption).foregroundStyle(.secondary)
                Text(preparation.sourceStatus).font(.caption).foregroundStyle(.secondary)
                MeetingEvidenceBoardView(snapshot: preparation.board, compact: true)
                    .frame(maxHeight: 210)
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Image(systemName: "list.bullet.clipboard")
                Text("Prepared · \(preparation.projectName)")
                Spacer()
                Text("\(preparation.board.items.count) reminders")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}
