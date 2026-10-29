import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct LiveMeetingMinutesStatusView: View {
    let transcriptionID: UUID
    let onOpen: (UUID) -> Bool
    @State private var removedResult = false
    @Bindable private var model = LiveMeetingMinutesViewModel.shared

    var body: some View {
        if model.isConfigured {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "doc.text.magnifyingglass")
                    Text("Meeting Minutes").font(DesignSystem.Typography.body.weight(.semibold))
                    Spacer()
                    if let job = model.job(for: transcriptionID) {
                        controls(for: job)
                    } else {
                        Button("Generate minutes") {
                            Task { await model.generate(transcriptionID: transcriptionID) }
                        }
                        .parakeetAction(.secondary)
                        .disabled(model.captureIsActive)
                    }
                }
                if let job = model.job(for: transcriptionID) {
                    Text(status(for: job))
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(job.state == .failed ? Color.orange : Color.secondary)
                } else {
                    Text("Use your saved meeting skill to create four notes and source-backed action items.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = model.errorMessage {
                    Text(error).font(DesignSystem.Typography.caption).foregroundStyle(.orange)
                }
                if removedResult {
                    Text("These minutes were removed. They have not been recreated.")
                        .font(DesignSystem.Typography.caption).foregroundStyle(.secondary)
                }
                if let error = model.artifactErrors[transcriptionID] {
                    HStack {
                        Text(error).font(DesignSystem.Typography.caption).foregroundStyle(.orange)
                        Button("Retry file export") {
                            Task { await model.retryArtifactRefresh(transcriptionID: transcriptionID) }
                        }
                        .parakeetAction(.secondary)
                    }
                }
            }
            .padding(DesignSystem.Spacing.md)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .task(id: transcriptionID) {
                removedResult = false
                await model.refresh()
            }
        }
    }

    @ViewBuilder
    private func controls(for job: MeetingMinutesJob) -> some View {
        switch job.state {
        case .completed:
            if let resultID = job.resultID {
                Button("Open minutes") { removedResult = !onOpen(resultID) }.parakeetAction(.secondary)
            }
        case .failed:
            Button("Retry minutes") { Task { await model.retry(jobID: job.id) } }
                .parakeetAction(.secondary)
                .disabled(model.captureIsActive)
        case .pending, .running:
            if model.activeJobID == job.id { ProgressView().controlSize(.small) }
        }
    }

    private func status(for job: MeetingMinutesJob) -> String {
        switch job.state {
        case .pending:
            if model.captureIsActive { return "Queued. Minutes continue when recording finishes." }
            if !model.automaticMinutesEnabled { return "Automatic minutes are paused in Settings → AI." }
            return "Queued using your saved meeting skill."
        case .running:
            return
                "Reading the final transcript: \(job.coveredCharacters.formatted()) of \(job.totalCharacters.formatted()) characters reviewed."
        case .failed:
            return job.errorMessage
                ?? "Minutes did not finish. Your recording and transcript are saved. Retry when ready."
        case .completed:
            return "Saved from the final transcript. Skill revision \(job.skillRevision.prefix(8))."
        }
    }
}
