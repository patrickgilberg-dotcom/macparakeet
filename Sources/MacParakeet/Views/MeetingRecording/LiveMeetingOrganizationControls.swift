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
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    rowLabel("Company")
                    Menu {
                        Button("No company") { viewModel.selectCompany(nil) }
                        ForEach(viewModel.companies) { company in
                            Button(company.name) { viewModel.selectCompany(company.id) }
                        }
                    } label: {
                        selectionLabel(companyName)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .accessibilityLabel("Recording company")
                    .accessibilityValue(companyName)
                    .help(companyName)
                }
                HStack(spacing: 8) {
                    rowLabel("Project")
                    Menu {
                        Button("Choose later") { viewModel.selectProject(nil) }
                        ForEach(viewModel.availableProjects) { project in
                            Button(project.name) { viewModel.selectProject(project.id) }
                        }
                    } label: {
                        selectionLabel(selectedProjectName)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .accessibilityLabel("Recording project")
                    .accessibilityValue(selectedProjectName)
                    .help(selectedProjectName)
                    Button {
                        isAddingProject.toggle()
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .parakeetAction(.subtle)
                    .fixedSize()
                    .accessibilityLabel("New project for this company")
                    .help("Create a project within the selected company")
                    if viewModel.isSaving {
                        ProgressView().controlSize(.mini).accessibilityLabel("Saving meeting folders")
                    }
                }
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
        .frame(minWidth: 0, maxWidth: .infinity)
        .task { await viewModel.load() }
        .onDisappear { creationTask?.cancel() }
    }

    private var companyName: String {
        guard let id = viewModel.companyID else { return "No company" }
        return viewModel.companies.first(where: { $0.id == id })?.name ?? "Saved company unavailable"
    }

    private var selectedProjectName: String {
        guard let id = viewModel.projectID else { return "Choose later" }
        return viewModel.availableProjects.first(where: { $0.id == id })?.name ?? "Saved project unavailable"
    }

    private func rowLabel(_ value: String) -> some View {
        Text(value).font(.caption).foregroundStyle(.secondary)
            .frame(width: 52, alignment: .leading)
    }

    private func selectionLabel(_ value: String) -> some View {
        HStack(spacing: 6) {
            Text(value).lineLimit(1).truncationMode(.middle)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(DesignSystem.Colors.contentBackground, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
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
