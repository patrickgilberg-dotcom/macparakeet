import Foundation
import MacParakeetCore

/// Local project organization and explicitly selected event preparation.
/// Repositories run off the UI actor; this type never contacts a provider.
@MainActor
@Observable
public final class LiveMeetingPlannerViewModel {
    public private(set) var projects: [MeetingProject] = []
    public var selectedProjectFilterID: UUID? {
        didSet {
            if oldValue != selectedProjectFilterID { refreshProjectTranscriptionIDs() }
        }
    }
    /// Nil means all projects; a selected empty folder is an empty set.
    public private(set) var filteredTranscriptionIDs: Set<UUID>?
    /// Complete folder contents, independent of the recent meeting page.
    public private(set) var projectTranscriptions: [Transcription] = []
    public var draftContext = ""
    public var draftProjectID: UUID?
    public private(set) var draftProjectName: String?
    public private(set) var isDraftAvailable = false
    public private(set) var isLoadingProjects = false
    public private(set) var isLoadingProjectTranscriptions = false
    public private(set) var isCreatingProject = false
    public private(set) var isLoadingDraft = false
    public private(set) var isSaving = false
    public private(set) var isAssigning = false
    public var errorMessage: String?

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
    private var draftKey: MeetingPreparationKey?
    private var savedDraft: MeetingPreparation?

    public init(
        projectRepository: any MeetingProjectRepositoryProtocol,
        preparationRepository: any MeetingPreparationRepositoryProtocol,
        transcriptionRepository: (any TranscriptionRepositoryProtocol)? = nil
    ) {
        self.projectRepository = projectRepository
        self.preparationRepository = preparationRepository
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
        let task = Task { @MainActor [weak self] in
            do {
                let values = try await Task.detached(priority: .userInitiated) {
                    try repository.fetchAll(includeArchived: false)
                }.value
                try Task.checkCancellation()
                guard let self, self.projectGeneration == generation else { return }
                self.projects = values
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
    public func refreshProjectTranscriptionIDs() -> Task<Void, Never> {
        filterTask?.cancel()
        filterGeneration &+= 1
        let generation = filterGeneration
        guard let projectID = selectedProjectFilterID else {
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
        let transcriptions = transcriptionRepository
        let task = Task { @MainActor [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let ids = try repository.transcriptionIDs(in: projectID)
                    let rows = try ids.compactMap { try transcriptions?.fetch(id: $0) }.sorted {
                        if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                        return $0.id.uuidString < $1.id.uuidString
                    }
                    return (ids, rows)
                }.value
                try Task.checkCancellation()
                guard let self, self.filterGeneration == generation,
                    self.selectedProjectFilterID == projectID
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
        draftProjectID = nil
        draftProjectName = nil
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
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let preparation = try repository.fetch(key: key)
                let project = try preparation?.projectID.flatMap { try projects.fetch(id: $0) }
                return (preparation, project)
            }.value
            try Task.checkCancellation()
            guard generation == draftGeneration, draftKey == key else { return }
            savedDraft = result.0
            draftContext = result.0?.context ?? ""
            draftProjectID = result.0?.projectID
            draftProjectName = result.1?.name
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
            id: savedDraft?.id ?? UUID(), key: key, context: draftContext, projectID: draftProjectID,
            titleSnapshot: event.title, scheduledStartAt: event.startTime, scheduledEndAt: event.endTime,
            createdAt: savedDraft?.createdAt ?? Date(), updatedAt: Date())
        let repository = preparationRepository
        do {
            let saved = try await Task.detached(priority: .userInitiated) { try repository.save(value) }.value
            try Task.checkCancellation()
            guard generation == draftGeneration, draftKey == key else { return nil }
            savedDraft = saved
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
        named name: String, selectForDraft: Bool = false, selectForBrowsing: Bool = false
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
        let project = MeetingProject(name: trimmedName, sortOrder: projects.count)
        let draftGeneration = draftGeneration
        let selectedFilterID = selectedProjectFilterID
        return Task { @MainActor [weak self] in
            defer { self?.isCreatingProject = false }
            do {
                try await Task.detached(priority: .userInitiated) { try repository.save(project) }.value
                guard let self else { return }
                await self.refreshProjects().value
                if selectForDraft, self.draftGeneration == draftGeneration, self.isDraftAvailable {
                    self.draftProjectID = project.id
                    self.draftProjectName = project.name
                }
                if selectForBrowsing, self.selectedProjectFilterID == selectedFilterID {
                    self.selectedProjectFilterID = project.id
                }
            } catch { self?.errorMessage = "The project could not be created. \(error.localizedDescription)" }
        }
    }

    @discardableResult
    public func assign(transcriptionIDs: Set<UUID>, to projectID: UUID?) -> Task<Void, Never> {
        assignmentGeneration &+= 1
        let generation = assignmentGeneration
        let previous = assignmentTask
        let repository = projectRepository
        isAssigning = true
        errorMessage = nil
        let task = Task { @MainActor [weak self] in
            await previous?.value
            do {
                try await Task.detached(priority: .userInitiated) {
                    try repository.assign(transcriptionIDs: transcriptionIDs, to: projectID)
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
