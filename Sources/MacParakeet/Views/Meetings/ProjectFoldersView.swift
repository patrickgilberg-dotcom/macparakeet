import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

/// Company and project folders organize local membership without moving source files.
struct ProjectFoldersView: View {
    @Bindable var planner: LiveMeetingPlannerViewModel
    let onOpen: (Transcription) -> Void

    @State private var newProjectName = ""
    @State private var newProjectCompanyID: UUID?
    @State private var isAddingProject = false
    @State private var companyEditor: CompanyEditorTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Label("Companies & Projects", systemImage: "folder")
                    .font(DesignSystem.Typography.sectionTitle)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("New Company") { companyEditor = .init(company: nil) }
                    .parakeetAction(.subtle)
                Button("New Project") {
                    newProjectCompanyID = planner.selectedCompanyFilterID
                    isAddingProject.toggle()
                }
                .parakeetAction(.subtle)
            }
            VStack(alignment: .leading, spacing: 12) {
                if isAddingProject { newProjectForm }
                HStack {
                    Picker("Company", selection: $planner.selectedCompanyFilterID) {
                        Text("All companies").tag(Optional<UUID>.none)
                        ForEach(planner.companies) { company in Text(company.name).tag(Optional(company.id)) }
                    }
                    .accessibilityLabel("Browse company")
                    Picker("Project", selection: $planner.selectedProjectFilterID) {
                        Text("All projects").tag(Optional<UUID>.none)
                        ForEach(planner.filteredProjects) { project in
                            Text(
                                planner.projectLabel(project, includingCompany: planner.selectedCompanyFilterID == nil)
                            )
                            .tag(Optional(project.id))
                        }
                    }
                    .accessibilityLabel("Browse project")
                }
                if let company = planner.companies.first(where: { $0.id == planner.selectedCompanyFilterID }) {
                    HStack {
                        Text(company.attendeeDomains.map { "@" + $0 }.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Spacer()
                        Button("Edit Company") { companyEditor = .init(company: company) }
                            .parakeetAction(.subtle)
                    }
                }
                if let organizer = planner.companyOrganizer {
                    HStack(alignment: .firstTextBaseline) {
                        if organizer.isDiscovering { ProgressView().controlSize(.small) }
                        Text(
                            organizer.errorMessage ?? organizer.status ?? "Companies are found from upcoming meetings."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Find Companies") { Task { await organizer.sweep() } }
                            .parakeetAction(.subtle)
                            .disabled(organizer.isDiscovering)
                    }
                }
                Text(
                    "Company matches are automatic. Choose a project when you start recording, during the meeting, or afterward."
                )
                .font(.caption).foregroundStyle(.secondary)
                if planner.isLoadingProjects { ProgressView("Loading folders…").controlSize(.small) }
                if planner.selectedCompanyFilterID != nil || planner.selectedProjectFilterID != nil { folderContents }
                if let message = planner.errorMessage {
                    Text(message).font(.caption).foregroundStyle(DesignSystem.Colors.errorRed).textSelection(.enabled)
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
        .sheet(item: $companyEditor) { target in CompanyEditor(company: target.company, planner: planner) }
    }

    private var newProjectForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Company for new project", selection: $newProjectCompanyID) {
                Text("No company").tag(Optional<UUID>.none)
                ForEach(planner.companies) { company in Text(company.name).tag(Optional(company.id)) }
            }
            HStack {
                TextField("Project name", text: $newProjectName)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("New project name")
                    .onSubmit { createProject() }
                Button(planner.isCreatingProject ? "Creating…" : "Create Project") { createProject() }
                    .parakeetAction(.secondary)
                    .disabled(
                        planner.isCreatingProject
                            || newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .disabled(planner.isCreatingProject)
    }

    @ViewBuilder
    private var folderContents: some View {
        Divider()
        if planner.isLoadingProjectTranscriptions {
            ProgressView("Loading meetings…").controlSize(.small)
        } else if planner.projectTranscriptions.isEmpty {
            Text(
                "No saved meetings here yet. Company-matched recordings are filed automatically; projects are optional."
            )
            .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("\(planner.projectTranscriptions.count) saved meetings").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(planner.projectTranscriptions) { transcription in
                        MeetingRowCard(transcription: transcription, onTap: { onOpen(transcription) }) {
                            Button("Open") { onOpen(transcription) }.parakeetAction(.secondary)
                            Menu("Move to Company") {
                                Button("No Company") {
                                    planner.assignCompany(transcriptionIDs: [transcription.id], to: nil)
                                }
                                ForEach(planner.companies) { company in
                                    Button(company.name) {
                                        planner.assignCompany(transcriptionIDs: [transcription.id], to: company.id)
                                    }
                                }
                            }
                            .disabled(planner.isAssigning)
                            Menu("Move to Project") {
                                Button("No Project") { planner.assign(transcriptionIDs: [transcription.id], to: nil) }
                                ForEach(planner.projects) { project in
                                    Button(planner.projectLabel(project)) {
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
        guard !planner.isCreatingProject, !newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let name = newProjectName
        let companyID = newProjectCompanyID
        Task { @MainActor in
            await planner.createProject(named: name, companyID: companyID, selectForBrowsing: true).value
            if planner.errorMessage == nil { newProjectName = ""; isAddingProject = false }
        }
    }
}

private struct CompanyEditorTarget: Identifiable {
    let id = UUID()
    let company: MeetingCompany?
}

private struct CompanyEditor: View {
    let company: MeetingCompany?
    @Bindable var planner: LiveMeetingPlannerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var domains: String
    @State private var saveTask: Task<Void, Never>?

    init(company: MeetingCompany?, planner: LiveMeetingPlannerViewModel) {
        self.company = company; self.planner = planner
        _name = State(initialValue: company?.name ?? "")
        _domains = State(initialValue: company?.attendeeDomains.joined(separator: ", ") ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(company == nil ? "New Company" : "Edit Company").font(.title3.weight(.semibold))
            TextField("Company name", text: $name).textFieldStyle(.roundedBorder).accessibilityLabel("Company name")
            VStack(alignment: .leading, spacing: 5) {
                Text("Attendee email domains").font(.caption.weight(.medium))
                TextField("customer.com, partner.com", text: $domains)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Company attendee email domains")
                Text(
                    "Matching attendee addresses organize upcoming meetings under this company. Separate domains with commas. Projects stay your choice."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            if let message = planner.errorMessage {
                Text(message).font(.caption).foregroundStyle(DesignSystem.Colors.errorRed).textSelection(.enabled)
            }
            HStack {
                Button("Cancel") { dismiss() }.parakeetAction(.secondary).keyboardShortcut(.cancelAction)
                    .disabled(planner.isSavingCompany)
                Spacer()
                Button(planner.isSavingCompany ? "Saving…" : "Save Company") { save() }
                    .parakeetAction(.primary).keyboardShortcut(.defaultAction)
                    .disabled(planner.isSavingCompany || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22).frame(width: 460).interactiveDismissDisabled(planner.isSavingCompany)
        .onAppear { planner.errorMessage = nil }.onDisappear { saveTask?.cancel() }
    }

    private func save() {
        guard saveTask == nil else { return }
        let entries = LiveMeetingPlannerViewModel.domainEntries(from: domains)
        saveTask = Task { @MainActor in
            defer { saveTask = nil }
            if await planner.saveCompany(id: company?.id, name: name, attendeeDomains: entries) { dismiss() }
        }
    }
}
