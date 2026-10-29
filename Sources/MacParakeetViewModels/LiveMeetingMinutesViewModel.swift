import Foundation
import MacParakeetCore

/// App-lifetime automation. Changing the selected meeting never cancels its minutes.
@MainActor
@Observable
public final class LiveMeetingMinutesViewModel {
    public static let shared = LiveMeetingMinutesViewModel()
    public private(set) var jobs: [MeetingMinutesJob] = []
    public private(set) var activeJobID: UUID?
    public private(set) var isConfigured = false
    public private(set) var automaticMinutesEnabled = true
    public private(set) var captureIsActive = false
    public private(set) var errorMessage: String?
    public private(set) var artifactErrors: [UUID: String] = [:]

    @ObservationIgnored private var repository: MeetingMinutesJobRepository?
    @ObservationIgnored private var engine: MeetingMinutesEngine?
    @ObservationIgnored private var preferencesProvider: (@Sendable () async throws -> LiveMeetingPreferences)?
    @ObservationIgnored private var sessionProvider: (@Sendable () async throws -> LiveAnswerStreamSession)?
    @ObservationIgnored private var activeCaptureProvider: (@MainActor () -> Bool)?
    @ObservationIgnored private var artifactRefresh: (@Sendable (UUID) async throws -> Void)?
    @ObservationIgnored private var onSaved: (@MainActor (UUID, UUID) -> Void)?
    @ObservationIgnored nonisolated(unsafe) private var pollingTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var generationTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var artifactTask: Task<Void, Never>?
    private var automaticStartDate = Date()
    private var isRefreshing = false
    private var configurationGeneration: UInt64 = 0
    private var explicitJobIDs: Set<UUID> = []
    private var reconciledArtifactIDs: Set<UUID> = []

    public init() {}

    deinit {
        pollingTask?.cancel()
        generationTask?.cancel()
        artifactTask?.cancel()
    }

    public func configure(
        repository: MeetingMinutesJobRepository, engine: MeetingMinutesEngine,
        preferencesProvider: @escaping @Sendable () async throws -> LiveMeetingPreferences,
        sessionProvider: @escaping @Sendable () async throws -> LiveAnswerStreamSession,
        activeCaptureProvider: @escaping @MainActor () -> Bool,
        automaticStartDate: Date,
        artifactRefresh: @escaping @Sendable (UUID) async throws -> Void,
        onSaved: @escaping @MainActor (UUID, UUID) -> Void
    ) {
        stop()
        self.repository = repository
        self.engine = engine
        self.preferencesProvider = preferencesProvider
        self.sessionProvider = sessionProvider
        self.activeCaptureProvider = activeCaptureProvider
        self.automaticStartDate = automaticStartDate
        self.artifactRefresh = artifactRefresh
        self.onSaved = onSaved
        isConfigured = true
    }

    /// Called once after environment wiring; pending work resumes without scanning old meetings.
    public func start(pollInterval: Duration = .seconds(5)) {
        guard pollingTask == nil, let repository else { return }
        let generation = configurationGeneration
        pollingTask = Task { @MainActor [weak self] in
            do {
                try await Task.detached(priority: .utility) { try repository.recoverInterruptedJobs() }.value
            } catch {
                self?.errorMessage = "Minutes recovery failed. \(error.localizedDescription)"
            }
            while !Task.isCancelled {
                guard let self, self.configurationGeneration == generation else { return }
                await self.refresh()
                do { try await Task.sleep(for: pollInterval) } catch { return }
            }
        }
    }

    public func stop() {
        configurationGeneration &+= 1
        pollingTask?.cancel()
        pollingTask = nil
        generationTask?.cancel()
        generationTask = nil
        artifactTask?.cancel()
        artifactTask = nil
        reconciledArtifactIDs = []
        activeJobID = nil
    }

    public func job(for transcriptionID: UUID) -> MeetingMinutesJob? {
        jobs.last { $0.transcriptionID == transcriptionID }
    }

    public func refresh() async {
        guard !isRefreshing, let repository, let preferencesProvider else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let generation = configurationGeneration
        do {
            let preferences = try await preferencesProvider()
            guard generation == configurationGeneration else { return }
            automaticMinutesEnabled = preferences.automaticMinutesEnabled
            captureIsActive = activeCaptureProvider?() ?? false
            if preferences.automaticMinutesEnabled {
                let cutoff = automaticStartDate
                let skill = MeetingMinutesSkillSnapshot(
                    markdown: preferences.skillMarkdown, revision: preferences.skillRevision)
                try await Task.detached(priority: .utility) {
                    for id in try repository.candidateIDs(createdAtOrAfter: cutoff) {
                        try Task.checkCancellation()
                        let source = try repository.captureSource(transcriptionID: id)
                        _ = try repository.enqueue(source: source, skill: skill)
                    }
                }.value
            }
            let loaded = try await Task.detached(priority: .utility) { try repository.allJobs() }.value
            guard generation == configurationGeneration else { return }
            jobs = loaded
            errorMessage = nil
            startArtifactReconciliationIfNeeded()
            startNextIfPossible()
        } catch {
            guard generation == configurationGeneration else { return }
            errorMessage = "Minutes are paused. \(error.localizedDescription)"
        }
    }

    /// The explicit completion callback closes the first-activation boundary for an older active recording.
    public func meetingCompleted(transcriptionID: UUID) async {
        guard let preferencesProvider else { return }
        do {
            let preferences = try await preferencesProvider()
            guard preferences.automaticMinutesEnabled else { return }
            try await enqueue(transcriptionID: transcriptionID, preferences: preferences)
            await refresh()
        } catch { errorMessage = "Minutes could not be queued. \(error.localizedDescription)" }
    }

    /// Explicitly generating an older meeting is a separate user action from automatic future meetings.
    public func generate(transcriptionID: UUID) async {
        guard let preferencesProvider else { return }
        do {
            let preferences = try await preferencesProvider()
            let job = try await enqueue(transcriptionID: transcriptionID, preferences: preferences)
            explicitJobIDs.insert(job.id)
            await refresh()
        } catch { errorMessage = "Minutes could not be queued. \(error.localizedDescription)" }
    }

    @discardableResult
    private func enqueue(transcriptionID: UUID, preferences: LiveMeetingPreferences) async throws -> MeetingMinutesJob {
        guard let repository else { throw LiveMeetingPreferencesError.storageUnavailable }
        let skill = MeetingMinutesSkillSnapshot(
            markdown: preferences.skillMarkdown, revision: preferences.skillRevision)
        return try await Task.detached(priority: .utility) {
            let source = try repository.captureSource(transcriptionID: transcriptionID)
            return try repository.enqueue(source: source, skill: skill)
        }.value
    }

    public func retry(jobID: UUID) async {
        guard let repository, let preferencesProvider else { return }
        do {
            let preferences = try await preferencesProvider()
            let skill = MeetingMinutesSkillSnapshot(
                markdown: preferences.skillMarkdown, revision: preferences.skillRevision)
            let newJob = try await Task.detached(priority: .utility) {
                guard let old = try repository.fetch(id: jobID) else {
                    throw LiveMeetingPreferencesError.storageUnavailable
                }
                let source = try repository.captureSource(transcriptionID: old.transcriptionID)
                return try repository.retry(jobID: jobID, source: source, skill: skill)
            }.value
            explicitJobIDs.insert(newJob.id)
            await refresh()
        } catch { errorMessage = "Minutes could not be retried. \(error.localizedDescription)" }
    }

    public func retryArtifactRefresh(transcriptionID: UUID) async {
        guard let artifactRefresh else { return }
        reconciledArtifactIDs.insert(transcriptionID)
        do {
            try await artifactRefresh(transcriptionID)
            artifactErrors[transcriptionID] = nil
        } catch {
            artifactErrors[transcriptionID] =
                "Minutes are saved in the app; file export needs retry. \(error.localizedDescription)"
        }
    }

    /// A completed job is also a durable receipt for repairing files after an app interruption.
    /// Reconcile once per launch even if the app quit between result commit and file materialization.
    private func startArtifactReconciliationIfNeeded() {
        guard artifactTask == nil, !captureIsActive else { return }
        let ids = Set(jobs.filter { $0.state == .completed }.map(\.transcriptionID))
            .subtracting(reconciledArtifactIDs)
        guard !ids.isEmpty else { return }
        let generation = configurationGeneration
        artifactTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if configurationGeneration == generation { artifactTask = nil } }
            for id in ids {
                guard !Task.isCancelled, configurationGeneration == generation,
                    !(activeCaptureProvider?() ?? true)
                else { return }
                await retryArtifactRefresh(transcriptionID: id)
            }
        }
    }

    private func shouldYield(jobID: UUID) async -> Bool {
        guard !Task.isCancelled, !(activeCaptureProvider?() ?? true), let preferencesProvider else { return true }
        if explicitJobIDs.contains(jobID) { return false }
        return (try? await preferencesProvider().automaticMinutesEnabled) != true
    }

    private func startNextIfPossible() {
        guard generationTask == nil, !captureIsActive,
            let job = jobs.first(where: {
                $0.state == .pending && (automaticMinutesEnabled || explicitJobIDs.contains($0.id))
            }), let engine,
            let sessionProvider, let repository
        else { return }
        activeJobID = job.id
        let generation = configurationGeneration
        generationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if configurationGeneration == generation {
                    activeJobID = nil
                    generationTask = nil
                }
            }
            do {
                let session: LiveAnswerStreamSession
                do { session = try await sessionProvider() } catch {
                    try await Task.detached(priority: .utility) {
                        try repository.failPendingJob(jobID: job.id, message: error.localizedDescription)
                    }.value
                    throw error
                }
                let saved = try await engine.run(
                    jobID: job.id, session: session,
                    shouldYield: { [weak self] in
                        guard let self else { return true }
                        return await self.shouldYield(jobID: job.id)
                    }, modelSnapshot: session.modelName)
                try Task.checkCancellation()
                guard configurationGeneration == generation else { return }
                if let saved {
                    onSaved?(saved.transcriptionId, saved.id)
                    await retryArtifactRefresh(transcriptionID: saved.transcriptionId)
                }
            } catch is CancellationError {
                // The engine leaves interrupted work visible and retryable; never replay an uncertain request.
            } catch {
                errorMessage = "Minutes need attention. \(error.localizedDescription)"
            }
            if let loaded = try? await Task.detached(priority: .utility, operation: { try repository.allJobs() }).value,
                configurationGeneration == generation
            {
                jobs = loaded
            }
        }
    }
}
