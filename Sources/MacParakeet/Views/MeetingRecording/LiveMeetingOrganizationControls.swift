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
        LiveMeetingOrganizationSurface {
            LiveMeetingOrganizationRows(
                companies: viewModel.companies, projects: viewModel.availableProjects,
                companyName: companyName, projectName: selectedProjectName, isSaving: viewModel.isSaving,
                onCompany: { viewModel.selectCompany($0) }, onProject: { viewModel.selectProject($0) },
                onCreateProject: { isAddingProject.toggle() }
            )
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

    private func createProject() {
        guard creationTask == nil else { return }
        let name = projectName
        creationTask = Task { @MainActor in
            defer { creationTask = nil }
            if await viewModel.createProject(named: name) { projectName = ""; isAddingProject = false }
        }
    }
}

/// Keeps the startup and ready controls in one equally sized section. Only the
/// values and enabled state change when the recording's organization loads.
struct LiveMeetingOrganizationSlot: View {
    let viewModel: LiveMeetingOrganizationViewModel?

    var body: some View {
        if let viewModel {
            LiveMeetingOrganizationControls(viewModel: viewModel)
        } else {
            LiveMeetingOrganizationSurface {
                LiveMeetingOrganizationRows(
                    companies: [], projects: [], companyName: "Preparing folders…", projectName: "Choose later",
                    isSaving: false, onCompany: { _ in }, onProject: { _ in }, onCreateProject: {}
                )
                .disabled(true)
            }
        }
    }
}

private struct LiveMeetingOrganizationSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(minWidth: 0, maxWidth: .infinity)
    }
}

private struct LiveMeetingOrganizationRows: View {
    let companies: [MeetingCompany]
    let projects: [MeetingProject]
    let companyName: String
    let projectName: String
    let isSaving: Bool
    let onCompany: (UUID?) -> Void
    let onProject: (UUID?) -> Void
    let onCreateProject: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                rowLabel("Company")
                Menu {
                    Button("No company") { onCompany(nil) }
                    ForEach(companies) { company in
                        Button(company.name) { onCompany(company.id) }
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
                    Button("Choose later") { onProject(nil) }
                    ForEach(projects) { project in
                        Button(project.name) { onProject(project.id) }
                    }
                } label: {
                    selectionLabel(projectName)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(minWidth: 0, maxWidth: .infinity)
                .accessibilityLabel("Recording project")
                .accessibilityValue(projectName)
                .help(projectName)
                Button {
                    onCreateProject()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .parakeetAction(.subtle)
                .fixedSize()
                .accessibilityLabel("New project for this company")
                .help("Create a project within the selected company")
                if isSaving {
                    ProgressView().controlSize(.mini).accessibilityLabel("Saving meeting folders")
                }
            }
        }
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

}
