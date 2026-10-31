import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

/// Edits local preparation for this explicit Google event occurrence only.
struct MeetingPreparationSheet: View {
    let event: CalendarEvent
    @Bindable var planner: LiveMeetingPlannerViewModel
    let onRecord: (MeetingPreparation) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var actionTask: Task<Void, Never>?
    @State private var newProjectName = ""
    @State private var isAddingProject = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(event.title)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Text(event.startTime.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Project", selection: $planner.draftProjectID) {
                        Text("No project").tag(Optional<UUID>.none)
                        ForEach(planner.projects) { project in
                            Text(project.name).tag(Optional(project.id))
                        }
                        if let id = planner.draftProjectID, !planner.projects.contains(where: { $0.id == id }) {
                            Text(planner.draftProjectName ?? "Saved project").tag(Optional(id))
                        }
                    }
                    .disabled(planner.isLoadingDraft || planner.isLoadingProjects || planner.isSaving)
                    if isAddingProject {
                        HStack {
                            TextField("Project name", text: $newProjectName)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { createProject() }
                            Button("Create") { createProject() }
                                .parakeetAction(.secondary)
                                .disabled(
                                    newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        || planner.isCreatingProject)
                        }
                        .disabled(planner.isSaving)
                    } else {
                        Button("New Project Folder…") { isAddingProject = true }
                            .parakeetAction(.subtle)
                            .disabled(!planner.isDraftAvailable || planner.isSaving)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Context for this meeting").font(.headline)
                        Text(
                            "Add goals, background, or questions. This preparation is used by live meeting AI for this event."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Text("If you choose a project, live AI can also use its latest previous meeting.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $planner.draftContext)
                            .font(.body)
                            .frame(minHeight: 150)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                            .disabled(planner.isLoadingDraft || planner.isSaving || !planner.isDraftAvailable)
                    }
                    if planner.isLoadingDraft {
                        ProgressView("Loading preparation…").controlSize(.small)
                    }
                    if let error = planner.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let automaticPrep = planner.automaticPrep {
                        MeetingAutomaticPrepSection(
                            event: event, prep: automaticPrep,
                            projectID: planner.draftProjectID,
                            contextHash: MeetingGeneratedPreparation.hash(planner.draftContext),
                            canPrepare: planner.isDraftAvailable && planner.draftProjectID != nil && !planner.isSaving,
                            onPrepare: { prepareNow() })
                    }
                }
            }
            HStack {
                Button("Cancel") {
                    actionTask?.cancel()
                    dismiss()
                }
                .parakeetAction(.secondary)
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save(record: false) }
                    .parakeetAction(.secondary)
                    .disabled(planner.isSaving || planner.isCreatingProject || !planner.isDraftAvailable)
                Button("Save and Record") { save(record: true) }
                    .parakeetAction(.primary)
                    .disabled(planner.isSaving || planner.isCreatingProject || !planner.isDraftAvailable)
            }
        }
        .padding(22)
        .frame(width: 560, height: 650)
        .task(id: event.id) {
            await planner.loadDraft(for: event)
            guard !Task.isCancelled else { return }
            await planner.refreshProjects().value
            await planner.automaticPrep?.load(for: event)
        }
        .onDisappear { actionTask?.cancel() }
    }

    private func prepareNow() {
        guard actionTask == nil else { return }
        actionTask = Task { @MainActor in
            defer { actionTask = nil }
            guard await planner.saveDraft(for: event) != nil, !Task.isCancelled else { return }
            await planner.automaticPrep?.refresh(for: event)
        }
    }

    private func save(record: Bool) {
        guard actionTask == nil else { return }
        actionTask = Task { @MainActor in
            defer { actionTask = nil }
            guard let saved = await planner.saveDraft(for: event), !Task.isCancelled else { return }
            if record { onRecord(saved) }
            dismiss()
        }
    }

    private func createProject() {
        guard !planner.isCreatingProject,
            !newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        let name = newProjectName
        Task { @MainActor in
            await planner.createProject(named: name, selectForDraft: true).value
            if planner.errorMessage == nil {
                newProjectName = ""
                isAddingProject = false
            }
        }
    }
}

private struct MeetingAutomaticPrepSection: View {
    let event: CalendarEvent
    @Bindable var prep: LiveMeetingPrepViewModel
    let projectID: UUID?
    let contextHash: String
    let canPrepare: Bool
    let onPrepare: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Prepare automatically 15 minutes before", isOn: $prep.enabled)
                .font(.callout)
            Text(
                "For meetings saved to a project, ChatGPT checks only that project's latest meeting and all your saved notes. This Mac must be awake and Live running. Your live answers and summaries get priority."
            )
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Prepare now") { onPrepare() }
                    .parakeetAction(.secondary)
                    .disabled(!canPrepare || prep.isPreparing)
                if prep.isPreparing { ProgressView().controlSize(.small) }
            }
            if let error = prep.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary)
            } else if let status = prep.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if let value = prep.preparation(for: event), value.projectID == projectID,
                value.manualContextHash == contextHash
            {
                Text(value.sourceStatus).font(.caption).foregroundStyle(.secondary)
                MeetingEvidenceBoardView(snapshot: value.board, compact: true)
                    .frame(height: 220)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }
}
