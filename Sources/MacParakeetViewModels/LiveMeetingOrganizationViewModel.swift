import Foundation
import MacParakeetCore

/// Editable organization for the current recording. Selection writes are ordered
/// so a slower earlier selection cannot replace a newer choice.
@MainActor
@Observable
public final class LiveMeetingOrganizationViewModel {
    public private(set) var companies: [MeetingCompany] = []
    public private(set) var projects: [MeetingProject] = []
    public private(set) var companyID: UUID?
    public private(set) var projectID: UUID?
    public private(set) var isLoading = false
    public private(set) var isSaving = false
    public private(set) var isCreatingProject = false
    public private(set) var isFinishing = false
    public private(set) var errorMessage: String?
    public var availableProjects: [MeetingProject] { projects.filter { $0.companyID == companyID } }

    @ObservationIgnored private let companyRepository: any MeetingCompanyRepositoryProtocol
    @ObservationIgnored private let projectRepository: any MeetingProjectRepositoryProtocol
    @ObservationIgnored private let onSave: @MainActor (UUID?, UUID?) async throws -> Void
    @ObservationIgnored nonisolated(unsafe) private var saveTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var creationTask: Task<Bool, Never>?
    private var selectionGeneration: UInt64 = 0
    private var loadGeneration: UInt64 = 0
    private var lastSavedCompanyID: UUID?
    private var lastSavedProjectID: UUID?

    public init(
        companyRepository: any MeetingCompanyRepositoryProtocol,
        projectRepository: any MeetingProjectRepositoryProtocol,
        companyID: UUID? = nil, projectID: UUID? = nil,
        onSave: @escaping @MainActor (UUID?, UUID?) async throws -> Void
    ) {
        self.companyRepository = companyRepository
        self.projectRepository = projectRepository
        self.companyID = companyID; self.projectID = projectID
        lastSavedCompanyID = companyID; lastSavedProjectID = projectID
        self.onSave = onSave
    }

    deinit { saveTask?.cancel(); creationTask?.cancel() }

    public func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        let companies = companyRepository
        let projects = projectRepository
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                (try companies.fetchAll(includeArchived: false), try projects.fetchAll(includeArchived: false))
            }.value
            try Task.checkCancellation()
            guard loadGeneration == generation else { return }
            self.companies = result.0; self.projects = result.1
            isLoading = false
        } catch {
            guard loadGeneration == generation else { return }
            isLoading = false
            if !(error is CancellationError) {
                errorMessage = "Meeting folders could not be loaded. \(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    public func selectCompany(_ id: UUID?) -> Task<Void, Never> {
        guard !isFinishing else { return Task {} }
        guard id == nil || companies.contains(where: { $0.id == id }) else {
            errorMessage = "That company is no longer available."
            return Task {}
        }
        guard companyID != id || errorMessage != nil else { return Task {} }
        companyID = id
        if let projectID, projects.first(where: { $0.id == projectID })?.companyID != id {
            self.projectID = nil
        }
        return enqueueSave()
    }

    @discardableResult
    public func selectProject(_ id: UUID?) -> Task<Void, Never> {
        guard !isFinishing else { return Task {} }
        var companyChanged = false
        if let id {
            guard let project = projects.first(where: { $0.id == id }) else {
                errorMessage = "That project is no longer available."
                return Task {}
            }
            companyChanged = companyID != project.companyID
            companyID = project.companyID
        }
        guard projectID != id || companyChanged || errorMessage != nil else { return Task {} }
        projectID = id
        return enqueueSave()
    }

    public func createProject(named name: String) async -> Bool {
        guard !isFinishing, !isCreatingProject, !Task.isCancelled else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorMessage = "Enter a project name."; return false }
        isCreatingProject = true
        errorMessage = nil
        let targetCompanyID = companyID
        let generation = selectionGeneration
        let repository = projectRepository
        let project = MeetingProject(name: trimmed, companyID: targetCompanyID, sortOrder: projects.count)
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            defer { self.isCreatingProject = false; self.creationTask = nil }
            do {
                try await Task.detached(priority: .userInitiated) { try repository.save(project) }.value
                await self.load()
                guard !Task.isCancelled else { return false }
                guard self.selectionGeneration == generation, self.companyID == targetCompanyID else { return true }
                // This creation was admitted before End. It may complete its
                // original selection after editing has been frozen, but cannot
                // replace a newer selection made while creation was pending.
                self.projectID = project.id
                await self.enqueueSave().value
                return self.errorMessage == nil
            } catch {
                self.errorMessage = "The project could not be created. \(error.localizedDescription)"
                return false
            }
        }
        creationTask = task
        return await task.value
    }

    /// Freezes new picker/create intents immediately, without delaying audio stop.
    public func beginFinishing() { isFinishing = true }

    /// Called after capture stops, before the Library row is bound. An already
    /// admitted project creation and its resulting selection finish in order.
    public func finishEditing() async {
        beginFinishing()
        _ = await creationTask?.value
        await waitForPendingSave()
    }

    /// Re-read the generation after awaiting: another choice may have queued
    /// behind the task this waiter initially observed.
    public func waitForPendingSave() async {
        while true {
            let generation = selectionGeneration
            await saveTask?.value
            if generation == selectionGeneration { return }
        }
    }

    private func enqueueSave() -> Task<Void, Never> {
        selectionGeneration &+= 1
        let generation = selectionGeneration
        let companyID = companyID
        let projectID = projectID
        let previous = saveTask
        let companies = companyRepository
        let projects = projectRepository
        isSaving = true
        errorMessage = nil
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.selectionGeneration == generation else { return }
            do {
                try Task.checkCancellation()
                try await Task.detached(priority: .userInitiated) {
                    if let companyID {
                        guard let company = try companies.fetch(id: companyID), !company.isArchived else {
                            throw OrganizationError.companyMissing
                        }
                    }
                    if let projectID {
                        guard let project = try projects.fetch(id: projectID), !project.isArchived else {
                            throw OrganizationError.projectMissing
                        }
                        guard project.companyID == companyID else { throw OrganizationError.projectCompanyMismatch }
                    }
                }.value
                try Task.checkCancellation()
                guard self.selectionGeneration == generation else { return }
                try await self.onSave(companyID, projectID)
                self.lastSavedCompanyID = companyID; self.lastSavedProjectID = projectID
                if self.selectionGeneration == generation { self.isSaving = false }
            } catch {
                guard self.selectionGeneration == generation else { return }
                self.companyID = self.lastSavedCompanyID; self.projectID = self.lastSavedProjectID
                self.isSaving = false
                self.errorMessage = "Meeting folders were not changed. \(error.localizedDescription)"
            }
        }
        saveTask = task
        return task
    }

    private enum OrganizationError: LocalizedError, Sendable {
        case companyMissing, projectMissing, projectCompanyMismatch
        var errorDescription: String? {
            switch self {
            case .companyMissing: "That company is no longer available."
            case .projectMissing: "That project is no longer available."
            case .projectCompanyMismatch: "Choose a project within the selected company."
            }
        }
    }
}
