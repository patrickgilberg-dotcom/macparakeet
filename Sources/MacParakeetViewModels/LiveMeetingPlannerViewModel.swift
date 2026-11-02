import Foundation
import MacParakeetCore

/// Local project organization and explicitly selected event preparation.
/// Repositories run off the UI actor; this type never contacts a provider.
@MainActor
@Observable
public final class LiveMeetingPlannerViewModel {
    public private(set) var companies: [MeetingCompany] = []
    public private(set) var projects: [MeetingProject] = []
    public var selectedCompanyFilterID: UUID? {
        didSet {
            guard oldValue != selectedCompanyFilterID else { return }
            browsingSelectionRevision &+= 1
            selectedProjectFilterID = nil
            refreshProjectTranscriptionIDs()
        }
    }
    public var filteredProjects: [MeetingProject] {
        guard let selectedCompanyFilterID else { return projects }
        return projects.filter { $0.companyID == selectedCompanyFilterID }
    }
    public var selectedProjectFilterID: UUID? {
        didSet {
            if oldValue != selectedProjectFilterID {
                browsingSelectionRevision &+= 1
                refreshProjectTranscriptionIDs()
            }
        }
    }
    /// Nil means all projects; a selected empty folder is an empty set.
    public private(set) var filteredTranscriptionIDs: Set<UUID>?
    /// Complete folder contents, independent of the recent meeting page.
    public private(set) var projectTranscriptions: [Transcription] = []
    public var draftContext = ""
    public var draftCompanyID: UUID? {
        didSet {
            if oldValue != draftCompanyID { draftSelectionRevision &+= 1 }
            guard !isUpdatingDraftSelection else { return }
            if let id = draftProjectID, projects.first(where: { $0.id == id })?.companyID != draftCompanyID {
                draftProjectID = nil
            }
        }
    }
    public var draftProjectID: UUID? {
        didSet {
            if oldValue != draftProjectID { draftSelectionRevision &+= 1 }
            guard !isUpdatingDraftSelection, let id = draftProjectID,
                let project = projects.first(where: { $0.id == id })
            else { return }
            isUpdatingDraftSelection = true
            draftCompanyID = project.companyID
            isUpdatingDraftSelection = false
        }
    }
    public private(set) var draftCompanyName: String?
    public private(set) var draftProjectName: String?
    public private(set) var draftCompanyMatch: MeetingCompanyResolution?
    public var draftProjects: [MeetingProject] { projects.filter { $0.companyID == draftCompanyID } }
    public var draftCompanyExplanation: String? {
        if let savedDraft, savedDraft.companyID == draftCompanyID {
            return draftCompanyID == nil ? "Saved without a company." : "Saved company choice for this meeting."
        }
        guard let match = draftCompanyMatch else { return nil }
        guard draftCompanyID == match.company?.id else { return "Your company choice will be saved for this meeting." }
        return match.explanation
    }
    public private(set) var isDraftAvailable = false
    public private(set) var isLoadingProjects = false
    public private(set) var isLoadingProjectTranscriptions = false
    public private(set) var isCreatingProject = false
    public private(set) var isSavingCompany = false
    public private(set) var isLoadingDraft = false
    public private(set) var isSaving = false
    public private(set) var isAssigning = false
    public var errorMessage: String?
    /// Generated briefs have separate storage; authored draft fields remain local user input.
    public var automaticPrep: LiveMeetingPrepViewModel?
    public var companyOrganizer: LiveMeetingCompanyDiscoveryViewModel?
    public var internalCompanyDomains: Set<String> = []

    @ObservationIgnored private let companyRepository: (any MeetingCompanyRepositoryProtocol)?
    @ObservationIgnored private let projectRepository: any MeetingProjectRepositoryProtocol
    @ObservationIgnored private let preparationRepository: any MeetingPreparationRepositoryProtocol
    @ObservationIgnored private let transcriptionRepository: (any TranscriptionRepositoryProtocol)?
    @ObservationIgnored nonisolated(unsafe) private var projectTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var filterTask: Task<Void, Never>?
    private var assignmentTask: Task<Void, Never>?
    private var projectGeneration: UInt64 = 0
    private var filterGeneration: UInt64 = 0
    private var draftGeneration: UInt64 = 0
    private var assignmentGeneration: UInt64 = 0
    private var draftSelectionRevision: UInt64 = 0
    private var browsingSelectionRevision: UInt64 = 0
    private var draftKey: MeetingPreparationKey?
    private var savedDraft: MeetingPreparation?
    private var isUpdatingDraftSelection = false
    private var eventChoices: [MeetingPreparationKey: MeetingPreparation] = [:]
    private var loadedEventChoiceKeys: Set<MeetingPreparationKey> = []
    private var eventChoiceGeneration: UInt64 = 0
    private var eventChoiceRevisions: [MeetingPreparationKey: UInt64] = [:]

    public init(
        projectRepository: any MeetingProjectRepositoryProtocol,
        preparationRepository: any MeetingPreparationRepositoryProtocol,
        companyRepository: (any MeetingCompanyRepositoryProtocol)? = nil,
        transcriptionRepository: (any TranscriptionRepositoryProtocol)? = nil
    ) {
        self.projectRepository = projectRepository
        self.preparationRepository = preparationRepository
        self.companyRepository = companyRepository
        self.transcriptionRepository = transcriptionRepository
    }

    deinit {
        projectTask?.cancel()
        filterTask?.cancel()
    }

    @discardableResult
    public func refreshProjects() -> Task<Void, Never> {
        projectTask?.cancel()
        projectGeneration &+= 1
        let generation = projectGeneration
        isLoadingProjects = true
        let repository = projectRepository
        let companies = companyRepository
        let task = Task { @MainActor [weak self] in
            do {
                let values = try await Task.detached(priority: .userInitiated) {
                    (
                        try repository.fetchAll(includeArchived: false),
                        try companies?.fetchAll(includeArchived: false) ?? []
                    )
                }.value
                try Task.checkCancellation()
                guard let self, self.projectGeneration == generation else { return }
                self.projects = values.0
                self.companies = values.1
                self.isLoadingProjects = false
            } catch is CancellationError {
                // A newer refresh owns publication.
            } catch {
                guard let self, self.projectGeneration == generation else { return }
                self.errorMessage = "Projects could not be loaded. \(error.localizedDescription)"
                self.isLoadingProjects = false
            }
        }
        projectTask = task
        return task
    }

    @discardableResult
    public func refreshCompanies() -> Task<Void, Never> { refreshProjects() }

    public func projectLabel(_ project: MeetingProject, includingCompany: Bool = true) -> String {
        guard includingCompany else { return project.name }
        let companyName = project.companyID.flatMap { id in companies.first { $0.id == id }?.name }
        return "\(companyName ?? (project.companyID == nil ? "No company" : "Unavailable company")) / \(project.name)"
    }

    public func companyMatch(for event: CalendarEvent) -> MeetingCompanyResolution {
        MeetingCompanyDomainMatcher.resolve(
            event: event, companies: companies, preparation: Self.key(for: event).flatMap { eventChoices[$0] },
            internalDomains: internalCompanyDomains)
    }

    public func organizationCaption(for event: CalendarEvent) -> String {
        guard let key = Self.key(for: event), loadedEventChoiceKeys.contains(key) else {
            return "Checking company…"
        }
        let match = companyMatch(for: event)
        let project = Self.key(for: event).flatMap { eventChoices[$0]?.projectID }
            .flatMap { id in projects.first { $0.id == id } }
        if let company = match.company {
            return "Company: \(company.name) · Project: \(project?.name ?? "choose later")"
        }
        if let project { return "Project: \(project.name)" }
        return match.source == .ambiguous ? "Company: choose · multiple matches" : "Company: not selected"
    }

    /// Fetches only existing authored choices, not calendar contents, away from the UI actor.
    public func loadEventChoices(for events: [CalendarEvent]) async {
        eventChoiceGeneration &+= 1
        let generation = eventChoiceGeneration
        let keys = Set(events.compactMap(Self.key(for:)))
        let revisions = eventChoiceRevisions
        loadedEventChoiceKeys.subtract(keys)
        let repository = preparationRepository
        do {
            let choices = try await Task.detached(priority: .userInitiated) {
                var result: [MeetingPreparationKey: MeetingPreparation] = [:]
                for key in keys { if let value = try repository.fetch(key: key) { result[key] = value } }
                return result
            }.value
            try Task.checkCancellation()
            guard eventChoiceGeneration == generation else { return }
            eventChoices = eventChoices.filter { keys.contains($0.key) }
            for key in keys where eventChoiceRevisions[key] == revisions[key] { eventChoices[key] = choices[key] }
            loadedEventChoiceKeys = keys
        } catch is CancellationError {
            // A newer calendar view owns the choices.
        } catch {
            guard eventChoiceGeneration == generation else { return }
            errorMessage = "Saved meeting choices could not be loaded. \(error.localizedDescription)"
        }
    }

    @discardableResult
    public func refreshProjectTranscriptionIDs() -> Task<Void, Never> {
        filterTask?.cancel()
        filterGeneration &+= 1
        let generation = filterGeneration
        let projectID = selectedProjectFilterID
        let companyID = selectedCompanyFilterID
        guard projectID != nil || companyID != nil else {
            filteredTranscriptionIDs = nil
            projectTranscriptions = []
            isLoadingProjectTranscriptions = false
            let task = Task<Void, Never> {}
            filterTask = task
            return task
        }
        filteredTranscriptionIDs = []
        projectTranscriptions = []
        isLoadingProjectTranscriptions = true
        let repository = projectRepository
        let companies = companyRepository
        let transcriptions = transcriptionRepository
        let task = Task { @MainActor [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let ids: Set<UUID>
                    if let projectID {
                        ids = try repository.transcriptionIDs(in: projectID)
                    } else if let companyID {
                        ids = try companies?.transcriptionIDs(in: companyID) ?? []
                    } else {
                        ids = []
                    }
                    let rows = try ids.compactMap { try transcriptions?.fetch(id: $0) }.sorted {
                        if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                        return $0.id.uuidString < $1.id.uuidString
                    }
                    return (ids, rows)
                }.value
                try Task.checkCancellation()
                guard let self, self.filterGeneration == generation,
                    self.selectedProjectFilterID == projectID, self.selectedCompanyFilterID == companyID
                else { return }
                self.filteredTranscriptionIDs = result.0
                self.projectTranscriptions = result.1
                self.isLoadingProjectTranscriptions = false
            } catch is CancellationError {
                // A newer folder selection owns publication.
            } catch {
                guard let self, self.filterGeneration == generation else { return }
                self.errorMessage = "This project's transcripts could not be loaded. \(error.localizedDescription)"
                self.isLoadingProjectTranscriptions = false
            }
        }
        filterTask = task
        return task
    }

    public func loadDraft(for event: CalendarEvent) async {
        draftGeneration &+= 1
        let generation = draftGeneration
        isLoadingDraft = true
        isDraftAvailable = false
        draftContext = ""
        isUpdatingDraftSelection = true
        draftCompanyID = nil
        draftProjectID = nil
        isUpdatingDraftSelection = false
        draftCompanyName = nil
        draftProjectName = nil
        draftCompanyMatch = nil
        savedDraft = nil
        errorMessage = nil
        guard let key = Self.key(for: event) else {
            draftKey = nil
            errorMessage = MeetingProjectRepositoryError.invalidEventKey.localizedDescription
            isLoadingDraft = false
            return
        }
        draftKey = key
        let repository = preparationRepository
        let projects = projectRepository
        let companies = companyRepository
        let internalDomains = internalCompanyDomains
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let preparation = try repository.fetch(key: key)
                let availableProjects = try projects.fetchAll(includeArchived: false)
                let availableCompanies = try companies?.fetchAll(includeArchived: false) ?? []
                let match = MeetingCompanyDomainMatcher.resolve(
                    event: event, companies: availableCompanies, preparation: preparation,
                    internalDomains: internalDomains)
                let project = preparation?.projectID.flatMap { id in availableProjects.first { $0.id == id } }
                return (preparation, match, project, availableProjects, availableCompanies)
            }.value
            try Task.checkCancellation()
            guard generation == draftGeneration, draftKey == key else { return }
            savedDraft = result.0
            eventChoiceRevisions[key, default: 0] &+= 1
            eventChoices[key] = result.0
            loadedEventChoiceKeys.insert(key)
            draftContext = result.0?.context ?? ""
            self.projects = result.3
            self.companies = result.4
            isUpdatingDraftSelection = true
            draftCompanyID = result.1.company?.id ?? result.2?.companyID
            draftProjectID = result.2?.id
            isUpdatingDraftSelection = false
            draftCompanyName = result.1.company?.name
            draftProjectName = result.2?.name
            draftCompanyMatch = result.1
            isDraftAvailable = true
            isLoadingDraft = false
        } catch is CancellationError {
            if generation == draftGeneration { isLoadingDraft = false }
        } catch {
            guard generation == draftGeneration else { return }
            errorMessage = "Preparation could not be loaded. \(error.localizedDescription)"
            isLoadingDraft = false
        }
    }

    public func saveDraft(for event: CalendarEvent) async -> MeetingPreparation? {
        guard !isSaving, isDraftAvailable, let key = Self.key(for: event), key == draftKey else { return nil }
        let generation = draftGeneration
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        let value = MeetingPreparation(
            id: savedDraft?.id ?? UUID(), key: key, context: draftContext,
            companyID: draftCompanyID, projectID: draftProjectID,
            titleSnapshot: event.title, scheduledStartAt: event.startTime, scheduledEndAt: event.endTime,
            createdAt: savedDraft?.createdAt ?? Date(), updatedAt: Date())
        let repository = preparationRepository
        do {
            let saved = try await Task.detached(priority: .userInitiated) { try repository.save(value) }.value
            try Task.checkCancellation()
            guard generation == draftGeneration, draftKey == key else { return nil }
            savedDraft = saved
            eventChoiceRevisions[key, default: 0] &+= 1
            eventChoices[key] = saved
            loadedEventChoiceKeys.insert(key)
            return saved
        } catch is CancellationError {
            return nil
        } catch {
            if generation == draftGeneration {
                errorMessage = "Preparation could not be saved. \(error.localizedDescription)"
            }
            return nil
        }
    }

    @discardableResult
    public func createProject(
        named name: String, companyID: UUID? = nil,
        selectForDraft: Bool = false, selectForBrowsing: Bool = false
    ) -> Task<Void, Never> {
        guard !isCreatingProject else { return Task {} }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = MeetingProjectRepositoryError.emptyName.localizedDescription
            return Task {}
        }
        errorMessage = nil
        isCreatingProject = true
        let repository = projectRepository
        let project = MeetingProject(name: trimmedName, companyID: companyID, sortOrder: projects.count)
        let draftGeneration = draftGeneration
        let draftSelectionRevision = draftSelectionRevision
        let browsingSelectionRevision = browsingSelectionRevision
        return Task { @MainActor [weak self] in
            defer { self?.isCreatingProject = false }
            do {
                try await Task.detached(priority: .userInitiated) { try repository.save(project) }.value
                guard let self else { return }
                await self.refreshProjects().value
                if selectForDraft, self.draftGeneration == draftGeneration, self.isDraftAvailable,
                    self.draftSelectionRevision == draftSelectionRevision
                {
                    self.draftCompanyID = companyID
                    self.draftProjectID = project.id
                    self.draftProjectName = project.name
                }
                if selectForBrowsing, self.browsingSelectionRevision == browsingSelectionRevision {
                    self.selectedCompanyFilterID = companyID
                    self.selectedProjectFilterID = project.id
                }
            } catch { self?.errorMessage = "The project could not be created. \(error.localizedDescription)" }
        }
    }

    public func saveCompany(id: UUID? = nil, name: String, attendeeDomains: [String]) async -> Bool {
        guard !isSavingCompany, let repository = companyRepository else { return false }
        isSavingCompany = true
        errorMessage = nil
        defer { isSavingCompany = false }
        do {
            let saved = try await Task.detached(priority: .userInitiated) {
                var value: MeetingCompany
                if let id {
                    guard let current = try repository.fetch(id: id), !current.isArchived else {
                        throw MeetingCompanyRepositoryError.companyMissing
                    }
                    value = current
                } else {
                    value = MeetingCompany(name: name)
                }
                value.name = name
                value.attendeeDomains = attendeeDomains
                value.updatedAt = Date()
                try repository.save(value)
                return value
            }.value
            await refreshCompanies().value
            if id == nil { selectedCompanyFilterID = saved.id }
            return true
        } catch {
            errorMessage = "The company could not be saved. \(error.localizedDescription)"
            return false
        }
    }

    public nonisolated static func domainEntries(from text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;")))
            .filter { !$0.isEmpty }
    }

    @discardableResult
    public func assignCompany(transcriptionIDs: Set<UUID>, to companyID: UUID?) -> Task<Void, Never> {
        guard let repository = companyRepository else { return Task {} }
        return enqueueAssignment {
            try repository.assign(transcriptionIDs: transcriptionIDs, to: companyID)
        }
    }

    @discardableResult
    public func assign(transcriptionIDs: Set<UUID>, to projectID: UUID?) -> Task<Void, Never> {
        let repository = projectRepository
        return enqueueAssignment { try repository.assign(transcriptionIDs: transcriptionIDs, to: projectID) }
    }

    private func enqueueAssignment(_ operation: @escaping @Sendable () throws -> Void) -> Task<Void, Never> {
        assignmentGeneration &+= 1
        let generation = assignmentGeneration
        let previous = assignmentTask
        isAssigning = true
        errorMessage = nil
        let task = Task { @MainActor [weak self] in
            await previous?.value
            do {
                try await Task.detached(priority: .userInitiated) {
                    try operation()
                }.value
                guard let self else { return }
                await self.refreshProjectTranscriptionIDs().value
            } catch { self?.errorMessage = "The transcripts could not be moved. \(error.localizedDescription)" }
            if let self, self.assignmentGeneration == generation { self.isAssigning = false }
        }
        assignmentTask = task
        return task
    }

    private static func key(for event: CalendarEvent) -> MeetingPreparationKey? {
        guard let calendarID = event.preparationCalendarID, let eventID = event.preparationEventID else { return nil }
        return .init(calendarID: calendarID, eventID: eventID)
    }
}
