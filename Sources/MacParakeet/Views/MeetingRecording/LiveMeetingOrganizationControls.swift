import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

/// Compact organization controls shared by the real recording panel and native acceptance fixtures.
struct LiveMeetingOrganizationControls: View {
    @Bindable var viewModel: LiveMeetingOrganizationViewModel
    @State private var isAddingProject = false
    @State private var projectName = ""
    @State private var creationTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Company").font(.caption2).foregroundStyle(.secondary)
                    Picker("Company", selection: companySelection) {
                        Text("No company").tag(Optional<UUID>.none)
                        ForEach(viewModel.companies) { company in Text(company.name).tag(Optional(company.id)) }
                        if let id = viewModel.companyID, !viewModel.companies.contains(where: { $0.id == id }) {
                            Text("Saved company unavailable").tag(Optional(id))
                        }
                    }
                    .labelsHidden().accessibilityLabel("Recording company")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Project (optional)").font(.caption2).foregroundStyle(.secondary)
                    Picker("Project", selection: projectSelection) {
                        Text("Choose later").tag(Optional<UUID>.none)
                        ForEach(viewModel.availableProjects) { project in Text(project.name).tag(Optional(project.id)) }
                        if let id = viewModel.projectID, !viewModel.availableProjects.contains(where: { $0.id == id }) {
                            Text("Saved project unavailable").tag(Optional(id))
                        }
                    }
                    .labelsHidden().accessibilityLabel("Recording project")
                }
                Button {
                    isAddingProject.toggle()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .parakeetAction(.subtle)
                .accessibilityLabel("New project for this company")
                .help("Create a project within the selected company")
                if viewModel.isSaving { ProgressView().controlSize(.mini).accessibilityLabel("Saving meeting folders") }
            }
            .disabled(viewModel.isLoading || viewModel.isFinishing)
            if isAddingProject {
                HStack {
                    TextField("Project name", text: $projectName)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Live new project name")
                        .onSubmit { createProject() }
                    Button(viewModel.isCreatingProject ? "Creating…" : "Create") { createProject() }
                        .parakeetAction(.secondary)
                        .disabled(
                            viewModel.isCreatingProject
                                || projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .disabled(viewModel.isFinishing)
            }
            if let error = viewModel.errorMessage {
                Text(error).font(.caption).foregroundStyle(DesignSystem.Colors.errorRed).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .task { await viewModel.load() }
        .onDisappear { creationTask?.cancel() }
    }

    private var companySelection: Binding<UUID?> {
        Binding(get: { viewModel.companyID }, set: { viewModel.selectCompany($0) })
    }

    private var projectSelection: Binding<UUID?> {
        Binding(get: { viewModel.projectID }, set: { viewModel.selectProject($0) })
    }

    private func createProject() {
        guard creationTask == nil else { return }
        let name = projectName
        creationTask = Task { @MainActor in
            defer { creationTask = nil }
            if await viewModel.createProject(named: name) { projectName = ""; isAddingProject = false }
        }
    }
}
