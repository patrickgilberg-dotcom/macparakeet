import Foundation
import MacParakeetCore

/// Discovers local company folders from explicit business attendee domains.
/// Calendar snapshots stay in memory; this lane never sends text to an LLM.
@MainActor
@Observable
public final class LiveMeetingCompanyDiscoveryViewModel {
    public private(set) var isDiscovering = false
    public private(set) var status: String?
    public private(set) var errorMessage: String?
    public private(set) var lastSweepEventCount = 0
    public private(set) var lastSweepCompanyCount = 0
    public private(set) var createdCompanyCount = 0
    public private(set) var lastCompletedAt: Date?

    @ObservationIgnored private let companyRepository: any MeetingCompanyRepositoryProtocol
    @ObservationIgnored private let eventsProvider: @Sendable () async throws -> [CalendarEvent]
    @ObservationIgnored private let internalDomainsProvider: @Sendable () async -> Set<String>
    @ObservationIgnored private let sourceIdentityProvider: @Sendable () async -> String?
    @ObservationIgnored private let onCompaniesChanged: @MainActor () async -> Void
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored nonisolated(unsafe) private var timerTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var activeTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    public init(
        companyRepository: any MeetingCompanyRepositoryProtocol,
        eventsProvider: @escaping @Sendable () async throws -> [CalendarEvent],
        internalDomainsProvider: @escaping @Sendable () async -> Set<String>,
        sourceIdentityProvider: @escaping @Sendable () async -> String?,
        onCompaniesChanged: @escaping @MainActor () async -> Void = {},
        pollInterval: Duration = .seconds(300), now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.companyRepository = companyRepository; self.eventsProvider = eventsProvider
        self.internalDomainsProvider = internalDomainsProvider; self.sourceIdentityProvider = sourceIdentityProvider
        self.onCompaniesChanged = onCompaniesChanged; self.pollInterval = pollInterval; self.now = now
    }

    deinit {
        timerTask?.cancel()
        activeTask?.cancel()
    }

    public func start() {
        guard timerTask == nil else { return }
        let interval = pollInterval
        timerTask = Task { @MainActor [weak self] in
            do {
                while !Task.isCancelled {
                    await self?.sweep()
                    try Task.checkCancellation()
                    try await Task.sleep(for: interval)
                }
            } catch {
                // Stopping the app-lifetime lane owns timer cancellation.
            }
        }
    }

    public func stop() {
        generation &+= 1
        timerTask?.cancel(); timerTask = nil
        activeTask?.cancel(); activeTask = nil
        isDiscovering = false
    }

    /// Refresh is local organization only. It does not start a recording,
    /// choose a project or generate company-wide meeting context.
    public func sweep() async {
        guard activeTask == nil, !Task.isCancelled else { return }
        generation &+= 1
        let token = generation
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == token { isDiscovering = false; activeTask = nil }
            }
            isDiscovering = true
            errorMessage = nil
            status = "Checking the next 30 days for company folders…"
            do {
                guard let identity = await sourceIdentityProvider() else {
                    status = "Connect Google Calendar to find company folders."
                    return
                }
                let internalDomains = await internalDomainsProvider()
                // An unknown account domain must not create the user's own
                // organization as a new customer company.
                guard !internalDomains.isEmpty else {
                    status = "Company discovery waits for the connected account."
                    return
                }
                let events = try await eventsProvider()
                try Task.checkCancellation()
                guard generation == token else { return }
                guard await sourceIdentityProvider() == identity else {
                    status = "Calendar selection changed. Company discovery will retry."
                    return
                }
                let start = now()
                let end = Calendar.current.date(byAdding: .day, value: 30, to: start) ?? start
                let eligible = events.filter {
                    $0.provider == .google && !$0.isAllDay && !$0.userDeclined
                        && $0.endTime > start && $0.startTime < end
                }
                let domains = Set(
                    eligible.flatMap {
                        MeetingCompanyDomainMatcher.discoverableDomains(event: $0, internalDomains: internalDomains)
                    }
                ).sorted()
                let repository = companyRepository
                let sourceIdentity = sourceIdentityProvider
                let isCurrent: @MainActor @Sendable () -> Bool = { [weak self] in self?.generation == token }
                let work = Task.detached(priority: .utility) { () async throws -> DiscoveryResult in
                    let previous = Set(try repository.fetchAll(includeArchived: true).map(\.id))
                    var found = Set<UUID>()
                    var created = Set<UUID>()
                    var ambiguous = 0
                    for domain in domains {
                        try Task.checkCancellation()
                        // Each committed domain is a separate local change.
                        // Account/calendar selection changes during one write
                        // must prevent every remaining stale-domain write.
                        guard await isCurrent() else { throw CancellationError() }
                        guard await sourceIdentity() == identity else { throw DiscoverySourceChanged() }
                        try Task.checkCancellation()
                        do {
                            let company = try repository.ensureCompany(forDomain: domain)
                            found.insert(company.id)
                            if !previous.contains(company.id) { created.insert(company.id) }
                        } catch MeetingCompanyRepositoryError.ambiguousCompanyDomain {
                            ambiguous += 1
                        }
                    }
                    return DiscoveryResult(found: found.count, created: created.count, ambiguous: ambiguous)
                }
                let result = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
                try Task.checkCancellation()
                guard generation == token else { return }
                guard await sourceIdentityProvider() == identity else {
                    status = "Calendar selection changed. Company discovery will retry."
                    return
                }
                lastSweepEventCount = eligible.count
                lastSweepCompanyCount = result.found
                createdCompanyCount = result.created
                lastCompletedAt = now()
                status =
                    "Checked \(eligible.count) upcoming meetings. \(result.found) company folders matched; \(result.created) added."
                if result.ambiguous > 0 {
                    errorMessage =
                        "\(result.ambiguous) attendee domains match multiple saved companies. Those choices remain manual."
                }
                await onCompaniesChanged()
            } catch is CancellationError {
                // A canceled or superseded sweep is not a completed scan.
            } catch is DiscoverySourceChanged {
                guard generation == token, !Task.isCancelled else { return }
                status = "Calendar selection changed. Company discovery will retry."
                await onCompaniesChanged()
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                status = "Company discovery will retry. Existing folders are preserved."
                errorMessage = "Company folders could not be refreshed. \(error.localizedDescription)"
                await onCompaniesChanged()
            }
        }
        activeTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private struct DiscoveryResult: Sendable {
        let found: Int
        let created: Int
        let ambiguous: Int
    }

    private struct DiscoverySourceChanged: Error {}
}
