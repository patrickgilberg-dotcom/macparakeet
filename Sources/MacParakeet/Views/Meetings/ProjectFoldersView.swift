import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

/// Project membership is local. Browsing a folder does not depend on the recent meeting page.
struct ProjectFoldersView: View {
    @Bindable var planner: LiveMeetingPlannerViewModel
    let onOpen: (Transcription) -> Void

    @State private var newProjectName = ""
    @State private var isAddingProject = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Label("Project Folders", systemImage: "folder")
                    .font(DesignSystem.Typography.sectionTitle)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    isAddingProject.toggle()
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .parakeetAction(.subtle)
            }

            VStack(alignment: .leading, spacing: 12) {
                if isAddingProject { newFolderForm }
                folderButtons

                if planner.isLoadingProjects {
                    ProgressView("Loading projects…").controlSize(.small)
                } else if planner.projects.isEmpty {
                    Text(
                        "Create a project folder, then choose it when preparing a meeting or move a saved transcript into it."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if planner.selectedProjectFilterID != nil { folderContents }

                if let message = planner.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(DesignSystem.Colors.errorRed)
                        .textSelection(.enabled)
                }
            }
            .padding(DesignSystem.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(DesignSystem.Colors.surface)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(DesignSystem.Colors.border.opacity(0.65), lineWidth: 0.6)
                    }
            }
        }
        .task {
            await planner.refreshProjects().value
            await planner.refreshProjectTranscriptionIDs().value
        }
    }

    private var newFolderForm: some View {
        HStack {
            TextField("Project name", text: $newProjectName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { createProject() }
            Button(planner.isCreatingProject ? "Creating…" : "Create") { createProject() }
                .parakeetAction(.secondary)
                .disabled(
                    planner.isCreatingProject || newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var folderButtons: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), alignment: .leading)], alignment: .leading, spacing: 8) {
            folderButton(name: "All Meetings", id: nil, icon: "square.stack")
            ForEach(planner.projects) { project in
                folderButton(name: project.name, id: project.id, icon: "folder.fill")
            }
        }
    }

    private func folderButton(name: String, id: UUID?, icon: String) -> some View {
        Button {
            planner.selectedProjectFilterID = id
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(name).lineLimit(1)
                Spacer(minLength: 0)
                if planner.selectedProjectFilterID == id {
                    Image(systemName: "checkmark").font(.caption.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
        }
        .parakeetAction(planner.selectedProjectFilterID == id ? .primary : .secondary)
        .help(name)
        .accessibilityValue(planner.selectedProjectFilterID == id ? "Selected" : "")
    }

    @ViewBuilder
    private var folderContents: some View {
        Divider()
        if planner.isLoadingProjectTranscriptions {
            ProgressView("Loading transcripts…").controlSize(.small)
        } else if planner.projectTranscriptions.isEmpty {
            Text(
                "This folder is empty. Choose this project when preparing a meeting, or use Move to Project on a saved transcript."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            Text("\(planner.projectTranscriptions.count) saved transcripts")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(planner.projectTranscriptions) { transcription in
                        MeetingRowCard(transcription: transcription, onTap: { onOpen(transcription) }) {
                            Button("Open") { onOpen(transcription) }
                                .parakeetAction(.secondary)
                            Menu("Move to Project") {
                                Button("No Project") { planner.assign(transcriptionIDs: [transcription.id], to: nil) }
                                ForEach(planner.projects) { project in
                                    Button(project.name) {
                                        planner.assign(transcriptionIDs: [transcription.id], to: project.id)
                                    }
                                }
                            }
                            .disabled(planner.isAssigning)
                        }
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 360)
        }
    }

    private func createProject() {
        guard !planner.isCreatingProject,
            !newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        let name = newProjectName
        Task { @MainActor in
            await planner.createProject(named: name, selectForBrowsing: true).value
            if planner.errorMessage == nil {
                newProjectName = ""
                isAddingProject = false
            }
        }
    }
}
