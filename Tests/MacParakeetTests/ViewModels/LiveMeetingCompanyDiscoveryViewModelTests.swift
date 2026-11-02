import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class LiveMeetingCompanyDiscoveryViewModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    func testSweepFindsAllDistinctBusinessDomainsAcrossIncludedSharedEventsWithoutProjects() async throws {
        let manager = try DatabaseManager()
        let companies = MeetingCompanyRepository(dbQueue: manager.dbQueue)
        let existing = MeetingCompany(name: "Beta", attendeeDomains: ["beta.example"])
        try companies.save(existing)
        var resource = event("room", domain: "rooms.example")
        resource.participants[0].kind = .room
        var declined = event("declined", domain: "declined.example")
        declined.userStatus = .declined
        var allDay = event("all-day", domain: "all-day.example")
        allDay.isAllDay = true
        let probe = CompanyDiscoveryProbe(events: [
            event("primary", domain: "alpha.example"), event("shared", domain: "beta.example"),
            event("duplicate", domain: "ALPHA.EXAMPLE"), event("personal", domain: "gmail.com"),
            event("own-team", domain: "internal.example"), event("future", domain: "late.example", days: 31),
            event("unknown-title", title: "Unknown Company Review"), resource, declined, allDay,
        ])
        let model = makeModel(companies, probe: probe)
        await model.sweep()
        let values = try companies.fetchAll(includeArchived: true)
        XCTAssertEqual(Set(values.map(\.name)), ["alpha.example", "Beta"])
        XCTAssertEqual(model.lastSweepCompanyCount, 2)
        XCTAssertEqual(model.createdCompanyCount, 1)
        XCTAssertEqual(model.lastCompletedAt, now)
        XCTAssertNil(model.errorMessage)
        let projects = MeetingProjectRepository(dbQueue: manager.dbQueue)
        XCTAssertTrue(try projects.fetchAll().isEmpty, "Company discovery never fabricates projects.")
        let preparations = MeetingPreparationRepository(dbQueue: manager.dbQueue)
        XCTAssertNil(try preparations.fetch(key: .init(calendarID: "shared", eventID: "shared")))
    }

    func testRepeatedSweepIsIdempotentAndPreservesEditedCompanyName() async throws {
        let manager = try DatabaseManager()
        let companies = MeetingCompanyRepository(dbQueue: manager.dbQueue)
        let probe = CompanyDiscoveryProbe(events: [event("client", domain: "client.example")])
        let model = makeModel(companies, probe: probe)
        await model.sweep()
        var company = try XCTUnwrap(companies.fetchAll().first)
        XCTAssertEqual(company.name, "client.example", "Unknown names remain honest editable domain labels.")
        company.name = "My Client"
        try companies.save(company)
        await model.sweep()
        XCTAssertEqual(try companies.fetchAll().map(\.id), [company.id])
        XCTAssertEqual(try companies.fetchAll().map(\.name), ["My Client"])
        XCTAssertEqual(model.createdCompanyCount, 0)
        XCTAssertEqual(model.lastSweepCompanyCount, 1)
    }

    func testArchivedConfiguredCompanyIsNotRecreatedOrUnarchived() async throws {
        let manager = try DatabaseManager()
        let companies = MeetingCompanyRepository(dbQueue: manager.dbQueue)
        let archived = MeetingCompany(
            name: "Archived", attendeeDomains: ["client.example"], isArchived: true, createdAt: now, updatedAt: now)
        try companies.save(archived)
        let model = makeModel(
            companies, probe: CompanyDiscoveryProbe(events: [event("client", domain: "client.example")]))
        await model.sweep()
        XCTAssertEqual(try companies.fetchAll(includeArchived: true), [archived])
        XCTAssertTrue(try companies.fetchAll().isEmpty)
        XCTAssertEqual(model.createdCompanyCount, 0)
    }

    func testAmbiguousExistingDomainLeavesBothCompaniesAndNoNewGuess() async throws {
        let manager = try DatabaseManager()
        let companies = MeetingCompanyRepository(dbQueue: manager.dbQueue)
        for name in ["One", "Two"] {
            try companies.save(MeetingCompany(name: name, attendeeDomains: ["client.example"]))
        }
        let model = makeModel(
            companies, probe: CompanyDiscoveryProbe(events: [event("client", domain: "client.example")]))
        await model.sweep()
        XCTAssertEqual(try companies.fetchAll().count, 2)
        XCTAssertEqual(model.createdCompanyCount, 0)
        XCTAssertEqual(model.lastSweepCompanyCount, 0)
        XCTAssertTrue(model.errorMessage?.contains("multiple saved companies") ?? false)
    }

    func testAccountOrCalendarSelectionChangeDiscardsFetchedSnapshotBeforeCreation() async throws {
        let manager = try DatabaseManager()
        let companies = MeetingCompanyRepository(dbQueue: manager.dbQueue)
        let probe = CompanyDiscoveryProbe(events: [event("client", domain: "client.example")])
        await probe.changeIdentityDuringRead()
        let model = makeModel(companies, probe: probe)
        await model.sweep()
        XCTAssertTrue(try companies.fetchAll().isEmpty)
        XCTAssertNil(model.lastCompletedAt)
        XCTAssertFalse(model.isDiscovering)
    }

    func testAccountChangeBetweenDomainWritesRetainsOnlyTheAlreadyCommittedCompany() async throws {
        let manager = try DatabaseManager()
        let companies = MeetingCompanyRepository(dbQueue: manager.dbQueue)
        let firstCommitted = expectation(description: "First company committed before the selection changed")
        let gated = CompanyDiscoveryWriteGate(repository: companies, firstCommitted: firstCommitted)
        let probe = CompanyDiscoveryProbe(events: [
            event("first", domain: "alpha.example"), event("second", domain: "beta.example"),
        ])
        let model = makeModel(gated, probe: probe)
        let work = Task { await model.sweep() }
        await fulfillment(of: [firstCommitted], timeout: 3)
        await probe.replaceIdentity()
        gated.release()
        await work.value
        XCTAssertEqual(gated.attemptedDomains, ["alpha.example"])
        XCTAssertEqual(try companies.fetchAll().flatMap(\.attendeeDomains), ["alpha.example"])
        XCTAssertNil(model.lastCompletedAt, "A partial scan never claims completion for the changed account.")
        XCTAssertTrue(model.status?.contains("selection changed") ?? false)
        XCTAssertFalse(model.isDiscovering)
    }

    func testStopBetweenDomainWritesPreventsTheRemainingDomainCreation() async throws {
        let manager = try DatabaseManager()
        let companies = MeetingCompanyRepository(dbQueue: manager.dbQueue)
        let firstCommitted = expectation(description: "First company committed before stopping discovery")
        let gated = CompanyDiscoveryWriteGate(repository: companies, firstCommitted: firstCommitted)
        let probe = CompanyDiscoveryProbe(events: [
            event("first", domain: "alpha.example"), event("second", domain: "beta.example"),
        ])
        let model = makeModel(gated, probe: probe)
        let work = Task { await model.sweep() }
        await fulfillment(of: [firstCommitted], timeout: 3)
        model.stop()
        gated.release()
        await work.value
        XCTAssertEqual(gated.attemptedDomains, ["alpha.example"])
        XCTAssertEqual(try companies.fetchAll().flatMap(\.attendeeDomains), ["alpha.example"])
        XCTAssertNil(model.lastCompletedAt)
        XCTAssertFalse(model.isDiscovering)
    }

    func testUnavailableAccountDomainAndFailedFetchCannotCreateFoldersOrClaimCompletion() async throws {
        let manager = try DatabaseManager()
        let companies = MeetingCompanyRepository(dbQueue: manager.dbQueue)
        let probe = CompanyDiscoveryProbe(events: [event("client", domain: "client.example")])
        let clock = now
        let noAccountDomain = LiveMeetingCompanyDiscoveryViewModel(
            companyRepository: companies, eventsProvider: { try await probe.fetch() },
            internalDomainsProvider: { [] }, sourceIdentityProvider: { "account" }, now: { clock })
        await noAccountDomain.sweep()
        let noReadCount = await probe.fetchCount
        XCTAssertEqual(noReadCount, 0)
        XCTAssertNil(noAccountDomain.lastCompletedAt)
        await probe.failReads()
        let failed = makeModel(companies, probe: probe)
        await failed.sweep()
        XCTAssertNotNil(failed.errorMessage)
        XCTAssertNil(failed.lastCompletedAt)
        XCTAssertTrue(try companies.fetchAll().isEmpty)
    }

    func testStopCancelsInFlightDiscoveryWithoutCreatingOrPublishingCompletion() async throws {
        let manager = try DatabaseManager()
        let companies = MeetingCompanyRepository(dbQueue: manager.dbQueue)
        let probe = CompanyDiscoveryProbe(events: [event("client", domain: "client.example")])
        await probe.delayReads()
        let model = makeModel(companies, probe: probe)
        let work = Task { await model.sweep() }
        for _ in 0..<200 {
            if await probe.fetchCount > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        model.stop()
        await work.value
        XCTAssertFalse(model.isDiscovering)
        XCTAssertNil(model.lastCompletedAt)
        XCTAssertTrue(try companies.fetchAll().isEmpty)
    }

    private func makeModel(
        _ companies: any MeetingCompanyRepositoryProtocol, probe: CompanyDiscoveryProbe
    ) -> LiveMeetingCompanyDiscoveryViewModel {
        let clock = now
        return LiveMeetingCompanyDiscoveryViewModel(
            companyRepository: companies, eventsProvider: { try await probe.fetch() },
            internalDomainsProvider: { ["internal.example"] }, sourceIdentityProvider: { await probe.identity },
            now: { clock })
    }

    private func event(
        _ id: String, domain: String? = nil, title: String = "Review", days: TimeInterval = 1
    ) -> CalendarEvent {
        CalendarEvent(
            id: id, title: title, startTime: now.addingTimeInterval(days * 86_400),
            endTime: now.addingTimeInterval(days * 86_400 + 1800),
            participants: domain.map { [.init(email: "person@" + $0)] } ?? [],
            calendarIdentifier: "shared", provider: .google, providerEventID: id, isUserMeeting: false)
    }

}

private actor CompanyDiscoveryProbe {
    var identity = "account-and-calendar-selection"
    private(set) var fetchCount = 0
    private let events: [CalendarEvent]
    private var changesIdentity = false
    private var fails = false
    private var delay = false

    init(events: [CalendarEvent]) { self.events = events }
    func changeIdentityDuringRead() { changesIdentity = true }
    func replaceIdentity() { identity = "changed-account-or-exclusions" }
    func failReads() { fails = true }
    func delayReads() { delay = true }

    func fetch() async throws -> [CalendarEvent] {
        fetchCount += 1
        if delay { try await Task.sleep(for: .seconds(30)) }
        if fails { throw CocoaError(.fileReadUnknown) }
        if changesIdentity { identity = "changed-account-or-exclusions" }
        return events
    }
}

/// The synchronous repository boundary deliberately holds after its first
/// committed transaction. The async test can then change authorization before
/// the discovery loop attempts another independently committed company.
private final class CompanyDiscoveryWriteGate: MeetingCompanyRepositoryProtocol, @unchecked Sendable {
    private let repository: MeetingCompanyRepository
    private let firstCommitted: XCTestExpectation
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var domains: [String] = []
    var attemptedDomains: [String] { lock.withLock { domains } }

    init(repository: MeetingCompanyRepository, firstCommitted: XCTestExpectation) {
        self.repository = repository; self.firstCommitted = firstCommitted
    }

    func release() { gate.signal() }
    func ensureCompany(forDomain domain: String) throws -> MeetingCompany {
        let isFirst = lock.withLock {
            domains.append(domain)
            return domains.count == 1
        }
        let company = try repository.ensureCompany(forDomain: domain)
        if isFirst {
            firstCommitted.fulfill()
            _ = gate.wait(timeout: .now() + 3)
        }
        return company
    }
    func save(_ company: MeetingCompany) throws { try repository.save(company) }
    func fetch(id: UUID) throws -> MeetingCompany? { try repository.fetch(id: id) }
    func fetchAll(includeArchived: Bool) throws -> [MeetingCompany] {
        try repository.fetchAll(includeArchived: includeArchived)
    }
    func assign(transcriptionIDs: Set<UUID>, to companyID: UUID?) throws {
        try repository.assign(transcriptionIDs: transcriptionIDs, to: companyID)
    }
    func company(for transcriptionID: UUID) throws -> MeetingCompany? { try repository.company(for: transcriptionID) }
    func companyIDs(for transcriptionIDs: Set<UUID>) throws -> [UUID: UUID] {
        try repository.companyIDs(for: transcriptionIDs)
    }
    func transcriptionIDs(in companyID: UUID) throws -> Set<UUID> { try repository.transcriptionIDs(in: companyID) }
}
