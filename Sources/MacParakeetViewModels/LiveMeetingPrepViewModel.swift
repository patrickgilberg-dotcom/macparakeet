import Foundation
import MacParakeetCore

/// Builds preparation only for occurrences the user explicitly assigned to a
/// project. This polling lane is independent of calendar auto-recording and
/// can run during capture while live AI is idle. Ask and live background work
/// cancel and await it before claiming the provider.
@MainActor
@Observable
public final class LiveMeetingPrepViewModel {
    public static let enabledPreferenceKey = "liveAutomaticMeetingPreparationEnabled"
    public var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Self.enabledPreferenceKey)
            if !enabled {
                generation &+= 1
                schedulingGeneration &+= 1
                activeTask?.cancel()
                isPreparing = false
                status = "Automatic preparation is off."
            }
        }
    }
    public private(set) var isPreparing = false
    public private(set) var status: String?
    public private(set) var errorMessage: String?
    public private(set) var preparations: [MeetingPreparationKey: MeetingGeneratedPreparation] = [:]

    @ObservationIgnored private let projectRepository: any MeetingProjectRepositoryProtocol
    @ObservationIgnored private let preparationRepository: any MeetingPreparationRepositoryProtocol
    @ObservationIgnored private let sessionProvider: @Sendable () async throws -> LiveAnswerStreamSession
    @ObservationIgnored private let store: MeetingGeneratedPreparationStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let engine = MeetingBoardEngine()
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var eventsProvider: (@Sendable () async throws -> [CalendarEvent])?
    @ObservationIgnored private var isBusy: (@MainActor () -> Bool)?
    @ObservationIgnored nonisolated(unsafe) private var timerTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var activeTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var schedulingGeneration: UInt64 = 0
    private var cacheLoadRevisions: [MeetingPreparationKey: UInt64] = [:]

    private struct Inputs: Sendable {
        let manual: MeetingPreparation
        let source: LiveProjectMeetingSource
        let scopeKey: String
        let manualContextHash: String
        let documents: [MeetingEvidenceDocument]
        let status: String

        func matches(_ other: Inputs) -> Bool {
            manual.key == other.manual.key && manual.projectID == other.manual.projectID
                && manualContextHash == other.manualContextHash && scopeKey == other.scopeKey
        }
    }

    public init(
        projectRepository: any MeetingProjectRepositoryProtocol,
        preparationRepository: any MeetingPreparationRepositoryProtocol,
        sessionProvider: @escaping @Sendable () async throws -> LiveAnswerStreamSession,
        store: MeetingGeneratedPreparationStore = .shared,
        defaults: UserDefaults = AppPaths.sharedAppDefaults(),
        pollInterval: Duration = .seconds(60)
    ) {
        self.projectRepository = projectRepository; self.preparationRepository = preparationRepository
        self.sessionProvider = sessionProvider; self.store = store; self.defaults = defaults
        self.pollInterval = pollInterval
        enabled =
            defaults.object(forKey: Self.enabledPreferenceKey) == nil
            ? LiveAppIdentity.isLive : defaults.bool(forKey: Self.enabledPreferenceKey)
    }

    deinit {
        timerTask?.cancel()
        activeTask?.cancel()
    }

    public func start(
        eventsProvider: @escaping @Sendable () async throws -> [CalendarEvent],
        isBusy: @escaping @MainActor () -> Bool
    ) {
        self.eventsProvider = eventsProvider
        self.isBusy = isBusy
        guard timerTask == nil else { return }
        let interval = pollInterval
        timerTask = Task { @MainActor [weak self] in
            do {
                while !Task.isCancelled {
                    await self?.scheduledPoll()
                    try Task.checkCancellation()
                    try await Task.sleep(for: interval)
                }
            } catch is CancellationError {
                // Application teardown owns timer cancellation.
            } catch {
                // Sleep has no operational error besides cancellation.
            }
        }
    }

    public func stop() {
        generation &+= 1
        schedulingGeneration &+= 1
        timerTask?.cancel(); timerTask = nil
        activeTask?.cancel(); activeTask = nil
        isPreparing = false
    }

    /// Awaited by capture transitions, Ask, and live background work before
    /// they claim the provider. A cancelled request cannot publish, even if
    /// the remote stream finishes late.
    public func preempt() async {
        generation &+= 1
        schedulingGeneration &+= 1
        let previous = activeTask
        activeTask = nil
        previous?.cancel()
        await previous?.value
        isPreparing = false
    }

    /// Automatic scheduling has no inference for unselected shared events.
    /// A saved project choice is explicit interest, even on Ajay's calendar.
    public func poll(events: [CalendarEvent], now: Date = Date()) async {
        guard enabled, isBusy?() != true, activeTask == nil, !Task.isCancelled else { return }
        let batch = schedulingGeneration
        var visited = Set<MeetingPreparationKey>()
        let candidates = events.filter {
            Self.key(for: $0) != nil && !$0.isAllDay && !$0.userDeclined
                && $0.startTime >= now && $0.startTime <= now.addingTimeInterval(15 * 60)
                && $0.endTime > now
        }.sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            return $0.id < $1.id
        }
        for event in candidates {
            guard enabled, isBusy?() != true, !Task.isCancelled, schedulingGeneration == batch else { return }
            guard let key = Self.key(for: event), visited.insert(key).inserted else { continue }
            await run(for: event, now: now, automatic: true)
        }
    }

    public func refresh(for event: CalendarEvent) async {
        guard !Task.isCancelled, isBusy?() != true else {
            status = "Preparation waits for live AI work to finish."
            return
        }
        await run(for: event, now: Date(), automatic: false)
    }

    /// Cache inspection for the Prepare sheet; never starts generation.
    public func load(for event: CalendarEvent) async {
        guard let key = Self.key(for: event) else { return }
        let revision = beginCacheLoad(key: key)
        do {
            guard let inputs = try await readInputs(key: key, before: min(Date(), event.startTime)) else {
                publishLoaded(nil, key: key, revision: revision)
                return
            }
            let session = try await sessionProvider()
            try await session.validate()
            let cached = try await store.load(key: key)
            try Task.checkCancellation()
            try await session.validate()
            guard let latest = try await readInputs(key: key, before: min(Date(), event.startTime)),
                inputs.matches(latest), let cached,
                matches(cached, inputs: latest, session: session), cached.matches(event: event)
            else {
                publishLoaded(nil, key: key, revision: revision)
                return
            }
            try Task.checkCancellation()
            publishLoaded(cached, key: key, revision: revision)
        } catch is CancellationError {
            if !Task.isCancelled { publishLoaded(nil, key: key, revision: revision) }
        } catch {
            guard cacheLoadRevisions[key] == revision else { return }
            publishLoaded(nil, key: key, revision: revision)
            errorMessage = "Saved preparation is unavailable. \(error.localizedDescription)"
        }
    }

    public func preparation(for event: CalendarEvent) -> MeetingGeneratedPreparation? {
        guard let key = Self.key(for: event), let value = preparations[key], value.matches(event: event),
            !store.isPurged(value)
        else {
            return nil
        }
        return value
    }

    /// Reads current source identity and the pinned account without generating
    /// text. A late correction, newer meeting, note edit or project change
    /// prevents stale preparation from entering the live meeting.
    public func validatedPreparation(
        key: MeetingPreparationKey, projectID: UUID, before: Date, excludingRecordingID: UUID? = nil
    ) async -> MeetingGeneratedPreparation? {
        let revision = beginCacheLoad(key: key)
        do {
            guard
                let inputs = try await readInputs(
                    key: key, before: before, excludingRecordingID: excludingRecordingID),
                inputs.source.project.id == projectID
            else {
                publishLoaded(nil, key: key, revision: revision)
                return nil
            }
            let session = try await sessionProvider()
            try await session.validate()
            let cached = try await store.load(key: key)
            try Task.checkCancellation()
            try await session.validate()
            guard
                let latest = try await readInputs(
                    key: key, before: before, excludingRecordingID: excludingRecordingID), inputs.matches(latest),
                let cached, matches(cached, inputs: latest, session: session)
            else {
                publishLoaded(nil, key: key, revision: revision)
                return nil
            }
            try Task.checkCancellation()
            guard cacheLoadRevisions[key] == revision else { return nil }
            publishLoaded(cached, key: key, revision: revision)
            return cached
        } catch {
            publishLoaded(nil, key: key, revision: revision)
            return nil
        }
    }

    private func scheduledPoll() async {
        guard enabled, isBusy?() != true, activeTask == nil, let eventsProvider else { return }
        let batch = schedulingGeneration
        do {
            let events = try await eventsProvider()
            try Task.checkCancellation()
            guard enabled, isBusy?() != true, schedulingGeneration == batch else { return }
            await poll(events: events)
        } catch is CancellationError {
        } catch {
            errorMessage = "Calendar preparation will retry when the connection is available."
        }
    }

    private func run(for event: CalendarEvent, now: Date, automatic: Bool) async {
        guard activeTask == nil, let key = Self.key(for: event) else { return }
        generation &+= 1
        let token = generation
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == token {
                    activeTask = nil
                    isPreparing = false
                }
            }
            do {
                let cutoff = min(now, event.startTime)
                let inputSnapshot = try await readInputs(key: key, before: cutoff)
                try validate(token: token, automatic: automatic)
                guard let inputs = inputSnapshot else {
                    publishGenerated(nil, key: key)
                    return
                }
                try validate(token: token, automatic: automatic)
                let session = try await sessionProvider()
                try await session.validate()
                try validate(token: token, automatic: automatic)
                let saved = try? await store.load(key: key)
                try validate(token: token, automatic: automatic)
                if let cached = saved,
                    matches(cached, inputs: inputs, session: session), cached.matches(event: event)
                {
                    // Cache loading also revalidates repository state because
                    // provider preparation can suspend across a user edit.
                    try await session.validate()
                    let currentSnapshot = try await readInputs(key: key, before: cutoff)
                    try validate(token: token, automatic: automatic)
                    guard let latest = currentSnapshot, inputs.matches(latest) else {
                        publishGenerated(nil, key: key)
                        return
                    }
                    try validate(token: token, automatic: automatic)
                    publishGenerated(cached, key: key)
                    status = "Preparation ready from the latest project meeting."
                    errorMessage = nil
                    return
                }
                publishGenerated(nil, key: key)
                isPreparing = true
                status = "Preparing \(event.title)…"
                errorMessage = nil
                let board = try await engine.update(
                    scopeKey: inputs.scopeKey, documents: inputs.documents, session: session)
                try validate(token: token, automatic: automatic)
                try await session.validate()
                guard let latest = try await readInputs(key: key, before: cutoff), inputs.matches(latest) else {
                    status = "The previous meeting or your notes changed. Preparation will retry."
                    return
                }
                try validate(token: token, automatic: automatic)
                let result = MeetingGeneratedPreparation(
                    key: key, projectID: inputs.source.project.id, projectName: inputs.source.project.name,
                    sourceScopeKey: inputs.scopeKey, manualContextHash: inputs.manualContextHash,
                    eventTitle: event.title, startTime: event.startTime, board: board,
                    providerIdentityHash: MeetingGeneratedPreparation.hash(session.cacheKey),
                    sourceStatus: inputs.status)
                try await store.save(result)
                try validate(token: token, automatic: automatic)
                try await session.validate()
                guard let finalInputs = try await readInputs(key: key, before: cutoff), inputs.matches(finalInputs)
                else {
                    status = "The previous meeting or your notes changed. Preparation will retry."
                    return
                }
                try validate(token: token, automatic: automatic)
                publishGenerated(result, key: key)
                status = "Preparation ready from the latest project meeting."
            } catch is CancellationError {
                // Foreground capture/Ask or an explicit stop owns cancellation.
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                errorMessage = "Preparation could not be updated. \(error.localizedDescription)"
                status = "Preparation will retry before the meeting."
            }
        }
        activeTask = task
        await task.value
        // Disabling cancels but intentionally keeps the handle until its task
        // settles, preventing a new request from racing a late remote result.
        if generation == token || (!isPreparing && activeTask?.isCancelled == true) { activeTask = nil }
    }

    private func validate(token: UInt64, automatic: Bool) throws {
        try Task.checkCancellation()
        guard generation == token, (!automatic || enabled), isBusy?() != true else { throw CancellationError() }
    }

    private func matches(_ result: MeetingGeneratedPreparation, inputs: Inputs, session: LiveAnswerStreamSession)
        -> Bool
    {
        result.key == inputs.manual.key && result.projectID == inputs.source.project.id
            && result.sourceScopeKey == inputs.scopeKey && result.manualContextHash == inputs.manualContextHash
            && result.matchesProvider(session)
    }

    private func beginCacheLoad(key: MeetingPreparationKey) -> UInt64 {
        let revision = (cacheLoadRevisions[key] ?? 0) &+ 1
        cacheLoadRevisions[key] = revision
        return revision
    }

    private func publishLoaded(_ value: MeetingGeneratedPreparation?, key: MeetingPreparationKey, revision: UInt64) {
        guard cacheLoadRevisions[key] == revision else { return }
        cacheLoadRevisions[key] = revision &+ 1
        preparations[key] = value
    }

    private func publishGenerated(_ value: MeetingGeneratedPreparation?, key: MeetingPreparationKey) {
        _ = beginCacheLoad(key: key)
        preparations[key] = value
    }

    private func readInputs(
        key: MeetingPreparationKey, before: Date, excludingRecordingID: UUID? = nil
    ) async throws -> Inputs? {
        let preparations = preparationRepository
        let projects = projectRepository
        let inputs = try await Task.detached(priority: .utility) { () throws -> Inputs? in
            guard let manual = try preparations.fetch(key: key), let projectID = manual.projectID,
                let project = try projects.fetch(id: projectID), !project.isArchived
            else { return nil }
            let previous = try projects.latestPreviousMeeting(
                projectID: projectID, before: before, excludingRecordingID: excludingRecordingID,
                excludingTranscriptionID: nil)
            let source = LiveProjectMeetingSource(project: project, previous: previous)
            var documents: [MeetingEvidenceDocument] = []
            if let previous {
                let title = previous.title + " · " + ISO8601DateFormatter().string(from: previous.createdAt)
                if previous.state == .ready, let text = previous.effectiveTranscript,
                    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    documents.append(
                        .init(
                            id: previous.transcriptionID.uuidString + ":transcript", kind: .previousTranscript,
                            title: title, text: text))
                }
                if let text = previous.userNotes, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    documents.append(
                        .init(
                            id: previous.transcriptionID.uuidString + ":notes", kind: .previousNotes,
                            title: "Your notes · " + title, text: text))
                }
            }
            let status: String
            if previous == nil {
                status = "No previous meeting in this project yet."
            } else if previous?.state == .ready, documents.contains(where: { $0.kind == .previousTranscript }) {
                status = "Latest project meeting and available saved notes; carryover completion is unverified."
            } else {
                status =
                    "The latest project meeting has no ready transcript (\(previous?.state.rawValue ?? "empty")). Available personal notes are included; no older meeting was substituted."
            }
            return Inputs(
                manual: manual, source: source, scopeKey: source.scopeKey,
                manualContextHash: MeetingGeneratedPreparation.hash(manual.context), documents: documents,
                status: status)
        }.value
        try Task.checkCancellation()
        return inputs
    }

    private static func key(for event: CalendarEvent) -> MeetingPreparationKey? {
        guard let calendarID = event.preparationCalendarID, let eventID = event.preparationEventID else { return nil }
        return .init(calendarID: calendarID, eventID: eventID)
    }
}
