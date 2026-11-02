import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class LiveMeetingPlannerViewModelTests: XCTestCase {
    func testPreparationKeepsExactCalendarTitleAndOccurrenceIdentity() async throws {
        let (planner, projects, preparations, _) = try makePlanner()
        let project = MeetingProject(name: "Project one")
        try projects.save(project)
        let original = event(title: "  Exact Calendar Title  ")
        await planner.loadDraft(for: original)
        planner.draftContext = "Review the latest proposal."
        planner.draftProjectID = project.id
        let savedValue = await planner.saveDraft(for: original)
        let saved = try XCTUnwrap(savedValue)
        XCTAssertEqual(saved.titleSnapshot, original.title)
        XCTAssertEqual(saved.key, .init(calendarID: "shared-calendar", eventID: "series_instance_1"))

        var rescheduled = original
        rescheduled.title = "Renamed in Google Calendar"
        rescheduled.startTime = original.startTime.addingTimeInterval(3600)
        await planner.loadDraft(for: rescheduled)
        XCTAssertEqual(planner.draftContext, "Review the latest proposal.")
        XCTAssertEqual(planner.draftProjectID, project.id)
        let updatedValue = await planner.saveDraft(for: rescheduled)
        let updated = try XCTUnwrap(updatedValue)
        XCTAssertEqual(updated.id, saved.id)
        XCTAssertEqual(try preparations.fetch(id: saved.id)?.titleSnapshot, rescheduled.title)

        await planner.loadDraft(for: event(eventID: "series_instance_2"))
        XCTAssertEqual(planner.draftContext, "")
        XCTAssertNil(planner.draftProjectID)
    }

    func testUnconnectedEventCannotSavePreparation() async throws {
        let (planner, _, _, _) = try makePlanner()
        let unconnected = CalendarEvent(
            id: "legacy", title: "Same title", startTime: Date(), endTime: Date().addingTimeInterval(1800))
        await planner.loadDraft(for: unconnected)
        XCTAssertFalse(planner.isDraftAvailable)
        XCTAssertNotNil(planner.errorMessage)
        let saved = await planner.saveDraft(for: unconnected)
        XCTAssertNil(saved)
    }

    func testSwitchingEventsCannotSavePreviousDraftAgainstNewEvent() async throws {
        let (planner, _, preparations, _) = try makePlanner()
        let first = event()
        let second = event(eventID: "series_instance_2")
        await planner.loadDraft(for: first)
        planner.draftContext = "First occurrence only."
        let wrongEventSave = await planner.saveDraft(for: second)
        XCTAssertNil(wrongEventSave)
        XCTAssertNil(try preparations.fetch(key: .init(calendarID: "shared-calendar", eventID: "series_instance_2")))
    }

    func testFailedSaveDoesNotReturnPreparationForRecording() async throws {
        let (planner, _, preparations, _) = try makePlanner()
        let upcoming = event()
        await planner.loadDraft(for: upcoming)
        planner.draftContext = "Do not lose this draft."
        planner.draftProjectID = UUID()
        let failed = await planner.saveDraft(for: upcoming)
        XCTAssertNil(failed)
        XCTAssertNotNil(planner.errorMessage)
        XCTAssertEqual(planner.draftContext, "Do not lose this draft.")
        XCTAssertFalse(planner.isSaving)
        XCTAssertNil(try preparations.fetch(key: .init(calendarID: "shared-calendar", eventID: "series_instance_1")))
    }

    func testFolderLoadsOldTranscriptsIndependentlyOfRecentPage() async throws {
        let (planner, projects, _, transcriptions) = try makePlanner()
        let project = MeetingProject(name: "Long-running project")
        try projects.save(project)
        let older = meeting(at: 10)
        let newer = meeting(at: 20)
        try transcriptions.save(older)
        try transcriptions.save(newer)
        try projects.assign(transcriptionIDs: [older.id, newer.id], to: project.id)
        // Both folder entries are beyond a normal recent-library page.
        for index in 0..<65 { try transcriptions.save(meeting(at: TimeInterval(100 + index))) }
        planner.selectedProjectFilterID = project.id
        await planner.refreshProjectTranscriptionIDs().value
        XCTAssertEqual(planner.filteredTranscriptionIDs, Set([older.id, newer.id]))
        XCTAssertEqual(planner.projectTranscriptions.map(\.id), [newer.id, older.id])
        XCTAssertFalse(planner.isLoadingProjectTranscriptions)

        planner.selectedProjectFilterID = nil
        XCTAssertNil(planner.filteredTranscriptionIDs)
        XCTAssertTrue(planner.projectTranscriptions.isEmpty)
    }

    func testNewerFolderSelectionOwnsResultsAndEmptyFolderIsNotAllMeetings() async throws {
        let (planner, projects, _, transcriptions) = try makePlanner()
        let first = MeetingProject(name: "First")
        let second = MeetingProject(name: "Empty")
        try projects.save(first)
        try projects.save(second)
        let row = meeting(at: 10)
        try transcriptions.save(row)
        try projects.assign(transcriptionIDs: [row.id], to: first.id)
        planner.selectedProjectFilterID = first.id
        let previousLoad = planner.refreshProjectTranscriptionIDs()
        planner.selectedProjectFilterID = second.id
        await planner.refreshProjectTranscriptionIDs().value
        await previousLoad.value
        XCTAssertEqual(planner.selectedProjectFilterID, second.id)
        XCTAssertEqual(planner.filteredTranscriptionIDs, Set<UUID>())
        XCTAssertTrue(planner.projectTranscriptions.isEmpty)
    }

    func testMoveOutRefreshesFolderWithoutChangingTranscript() async throws {
        let (planner, projects, _, transcriptions) = try makePlanner()
        let project = MeetingProject(name: "One")
        try projects.save(project)
        let row = meeting(at: 10)
        try transcriptions.save(row)
        try projects.assign(transcriptionIDs: [row.id], to: project.id)
        planner.selectedProjectFilterID = project.id
        await planner.refreshProjectTranscriptionIDs().value
        await planner.assign(transcriptionIDs: [row.id], to: nil).value
        XCTAssertTrue(planner.projectTranscriptions.isEmpty)
        XCTAssertEqual(planner.filteredTranscriptionIDs, Set<UUID>())
        XCTAssertEqual(try transcriptions.fetch(id: row.id)?.rawTranscript, row.rawTranscript)
        XCTAssertEqual(try transcriptions.fetch(id: row.id)?.updatedAt, row.updatedAt)
        XCTAssertFalse(planner.isAssigning)
    }

    func testCreateProjectValidatesNameAndSelectsOnlyRequestedSurface() async throws {
        let (planner, projects, _, _) = try makePlanner()
        await planner.createProject(named: "   ").value
        XCTAssertNotNil(planner.errorMessage)
        XCTAssertTrue(try projects.fetchAll().isEmpty)
        await planner.loadDraft(for: event())
        await planner.createProject(named: "  New project  ", selectForDraft: true).value
        let created = try XCTUnwrap(planner.projects.first)
        XCTAssertEqual(created.name, "New project")
        XCTAssertEqual(planner.draftProjectID, created.id)
        XCTAssertNil(planner.selectedProjectFilterID)
        XCTAssertFalse(planner.isCreatingProject)
    }

    func testAttendeeMatchChoosesCompanyWithoutInventingProjectOrSavingDraft() async throws {
        let (planner, companies, projects, preparations, _) = try makeCompanyPlanner()
        let company = MeetingCompany(name: "Customer", attendeeDomains: ["customer.example"])
        try companies.save(company)
        try projects.save(MeetingProject(name: "First project", companyID: company.id))
        var upcoming = event(title: "  Exact title ✨  ")
        upcoming.participants = [.init(email: "person@CUSTOMER.EXAMPLE")]

        await planner.loadDraft(for: upcoming)

        XCTAssertEqual(planner.draftCompanyID, company.id)
        XCTAssertNil(planner.draftProjectID)
        XCTAssertEqual(planner.draftProjects.map(\.name), ["First project"])
        XCTAssertEqual(planner.draftCompanyMatch?.source, .attendeeDomain)
        XCTAssertTrue(planner.draftCompanyExplanation?.contains("Customer") == true)
        XCTAssertNil(try preparations.fetch(key: .init(calendarID: "shared-calendar", eventID: "series_instance_1")))
    }

    func testDraftCompanyChangeClearsDifferentCompanyProject() async throws {
        let (planner, companies, projects, _, _) = try makeCompanyPlanner()
        let first = MeetingCompany(name: "First")
        let second = MeetingCompany(name: "Second")
        try companies.save(first); try companies.save(second)
        let project = MeetingProject(name: "Delivery", companyID: first.id)
        try projects.save(project)
        await planner.loadDraft(for: event())
        planner.draftProjectID = project.id
        XCTAssertEqual(planner.draftCompanyID, first.id)

        planner.draftCompanyID = second.id

        XCTAssertNil(planner.draftProjectID)
        XCTAssertTrue(planner.draftProjects.isEmpty)
    }

    func testSavedNoCompanyOverridesMatchingAttendeeInDraftAndUpcomingCaption() async throws {
        let (planner, companies, _, preparations, _) = try makeCompanyPlanner()
        try companies.save(MeetingCompany(name: "Customer", attendeeDomains: ["customer.example"]))
        let key = MeetingPreparationKey(calendarID: "shared-calendar", eventID: "series_instance_1")
        try preparations.save(.init(key: key, context: "Private authored context", titleSnapshot: "Saved title"))
        var upcoming = event()
        upcoming.participants = [.init(email: "person@customer.example")]
        await planner.refreshCompanies().value
        XCTAssertEqual(planner.organizationCaption(for: upcoming), "Checking company…")

        await planner.loadEventChoices(for: [upcoming])

        XCTAssertEqual(planner.companyMatch(for: upcoming).source, .manual)
        XCTAssertNil(planner.companyMatch(for: upcoming).company)
        XCTAssertEqual(planner.organizationCaption(for: upcoming), "Company: not selected")
        await planner.loadDraft(for: upcoming)
        XCTAssertNil(planner.draftCompanyID)
        XCTAssertNil(planner.draftProjectID)
        XCTAssertEqual(planner.draftContext, "Private authored context")
    }

    func testUpcomingCaptionKeepsExplicitCompanyAndProjectAgainstOtherDomain() async throws {
        let (planner, companies, projects, preparations, _) = try makeCompanyPlanner()
        let chosen = MeetingCompany(name: "Chosen")
        let inferred = MeetingCompany(name: "Inferred", attendeeDomains: ["customer.example"])
        try companies.save(chosen); try companies.save(inferred)
        let project = MeetingProject(name: "Delivery", companyID: chosen.id)
        try projects.save(project)
        let key = MeetingPreparationKey(calendarID: "shared-calendar", eventID: "series_instance_1")
        try preparations.save(.init(key: key, companyID: chosen.id, projectID: project.id, titleSnapshot: "Saved"))
        var upcoming = event()
        upcoming.participants = [.init(email: "person@customer.example")]
        await planner.refreshCompanies().value

        await planner.loadEventChoices(for: [upcoming])

        XCTAssertEqual(planner.organizationCaption(for: upcoming), "Company: Chosen · Project: Delivery")
    }

    func testCompanySaveAndProjectCreationRemainSeparateAndValidateDomains() async throws {
        let (planner, companies, projects, _, _) = try makeCompanyPlanner()
        let invalid = await planner.saveCompany(name: "Invalid", attendeeDomains: ["https://customer.example"])
        XCTAssertFalse(invalid)
        XCTAssertTrue(try companies.fetchAll().isEmpty)
        let saved = await planner.saveCompany(name: "  Customer  ", attendeeDomains: [" @CUSTOMER.EXAMPLE "])
        XCTAssertTrue(saved)
        let company = try XCTUnwrap(companies.fetchAll().first)
        XCTAssertEqual(company.name, "Customer")
        XCTAssertEqual(company.attendeeDomains, ["customer.example"])
        XCTAssertTrue(try projects.fetchAll().isEmpty)

        await planner.createProject(named: "Delivery", companyID: company.id, selectForBrowsing: true).value

        XCTAssertEqual(planner.selectedCompanyFilterID, company.id)
        XCTAssertEqual(try projects.fetchAll().first?.companyID, company.id)
        XCTAssertEqual(planner.filteredProjects.map(\.name), ["Delivery"])
    }

    func testCompanyBrowsingIncludesItsUnprojectedMeetingsAndMovePreservesSource() async throws {
        let (planner, companies, projects, _, transcriptions) = try makeCompanyPlanner()
        let first = MeetingCompany(name: "First")
        let second = MeetingCompany(name: "Second")
        try companies.save(first); try companies.save(second)
        let project = MeetingProject(name: "Delivery", companyID: first.id)
        try projects.save(project)
        let projected = meeting(at: 10), unprojected = meeting(at: 20)
        try transcriptions.save(projected); try transcriptions.save(unprojected)
        try projects.assign(transcriptionIDs: [projected.id], to: project.id)
        try companies.assign(transcriptionIDs: [unprojected.id], to: first.id)
        planner.selectedCompanyFilterID = first.id
        await planner.refreshProjectTranscriptionIDs().value
        XCTAssertEqual(planner.filteredTranscriptionIDs, [projected.id, unprojected.id])

        await planner.assignCompany(transcriptionIDs: [projected.id], to: second.id).value

        XCTAssertEqual(planner.filteredTranscriptionIDs, [unprojected.id])
        XCTAssertNil(try projects.project(for: projected.id))
        XCTAssertEqual(try companies.company(for: projected.id)?.id, second.id)
        XCTAssertEqual(try transcriptions.fetch(id: projected.id)?.rawTranscript, projected.rawTranscript)
        XCTAssertEqual(try transcriptions.fetch(id: projected.id)?.updatedAt, projected.updatedAt)
    }

    func testInternalOrganizerDoesNotBlockKnownCompanyTitleMatch() async throws {
        let (planner, companies, _, _, _) = try makeCompanyPlanner()
        let company = MeetingCompany(name: "Zephyr", attendeeDomains: ["zephyr.example"])
        try companies.save(company)
        planner.internalCompanyDomains = ["internal.example"]
        var upcoming = event(title: "Zephyr follow-up")
        upcoming.organizer = .init(email: "person@internal.example")

        await planner.loadDraft(for: upcoming)

        XCTAssertEqual(planner.draftCompanyID, company.id)
        XCTAssertEqual(planner.draftCompanyMatch?.source, .title)
        XCTAssertNil(planner.draftProjectID)
    }

    func testDomainEditorAcceptsCommaNewlineAndSpaceSeparatedEntries() {
        XCTAssertEqual(
            LiveMeetingPlannerViewModel.domainEntries(from: " first.example,\nsecond.example ; @third.example "),
            ["first.example", "second.example", "@third.example"])
    }

    func testCreatingProjectCannotRestoreCompanyAfterDraftSelectionChanges() async throws {
        let manager = try DatabaseManager()
        let companies = MeetingCompanyRepository(dbQueue: manager.dbQueue)
        let base = MeetingProjectRepository(dbQueue: manager.dbQueue)
        let delayed = DelayedPlannerProjectRepository(base: base, delayedName: "New workstream")
        let planner = LiveMeetingPlannerViewModel(
            projectRepository: delayed, preparationRepository: MeetingPreparationRepository(dbQueue: manager.dbQueue),
            companyRepository: companies)
        let first = MeetingCompany(name: "First"), second = MeetingCompany(name: "Second")
        try companies.save(first); try companies.save(second)
        await planner.loadDraft(for: event())
        planner.draftCompanyID = first.id

        let creation = planner.createProject(named: "New workstream", companyID: first.id, selectForDraft: true)
        let blocked = await delayed.waitUntilSaveBlocked()
        XCTAssertTrue(blocked)
        planner.draftCompanyID = second.id
        delayed.releaseSave()
        await creation.value

        XCTAssertEqual(planner.draftCompanyID, second.id)
        XCTAssertNil(planner.draftProjectID)
        XCTAssertEqual(try base.fetchAll().first?.companyID, first.id)
        XCTAssertFalse(planner.isCreatingProject)
    }

    func testCreatingProjectCannotReplaceNewerBrowsingIntentEvenWhenCompanyReturnsToOriginal() async throws {
        let manager = try DatabaseManager()
        let companies = MeetingCompanyRepository(dbQueue: manager.dbQueue)
        let base = MeetingProjectRepository(dbQueue: manager.dbQueue)
        let delayed = DelayedPlannerProjectRepository(base: base, delayedName: "New workstream")
        let planner = LiveMeetingPlannerViewModel(
            projectRepository: delayed, preparationRepository: MeetingPreparationRepository(dbQueue: manager.dbQueue),
            companyRepository: companies)
        let first = MeetingCompany(name: "First"), second = MeetingCompany(name: "Second")
        try companies.save(first); try companies.save(second)
        planner.selectedCompanyFilterID = first.id

        let creation = planner.createProject(named: "New workstream", companyID: first.id, selectForBrowsing: true)
        let blocked = await delayed.waitUntilSaveBlocked()
        XCTAssertTrue(blocked)
        planner.selectedCompanyFilterID = second.id
        planner.selectedCompanyFilterID = first.id
        delayed.releaseSave()
        await creation.value

        XCTAssertEqual(planner.selectedCompanyFilterID, first.id)
        XCTAssertNil(planner.selectedProjectFilterID)
        XCTAssertEqual(try base.fetchAll().count, 1)
    }

    func testGlobalProjectLabelsDistinguishSameNameAcrossCompaniesAndLegacyScope() async throws {
        let (planner, companies, projects, _, _) = try makeCompanyPlanner()
        let first = MeetingCompany(name: "First"), second = MeetingCompany(name: "Second")
        try companies.save(first); try companies.save(second)
        let firstProject = MeetingProject(name: "Delivery", companyID: first.id)
        let secondProject = MeetingProject(name: "Delivery", companyID: second.id)
        let legacy = MeetingProject(name: "Delivery")
        try projects.save(firstProject); try projects.save(secondProject); try projects.save(legacy)
        await planner.refreshProjects().value

        XCTAssertEqual(planner.projectLabel(firstProject), "First / Delivery")
        XCTAssertEqual(planner.projectLabel(secondProject), "Second / Delivery")
        XCTAssertEqual(planner.projectLabel(legacy), "No company / Delivery")
        XCTAssertEqual(planner.projectLabel(firstProject, includingCompany: false), "Delivery")
    }

    func testArchiveAndRestoreCompanyPreserveMeetingsProjectsAndAuthoredPreparation() async throws {
        let (planner, companies, projects, preparations, transcriptions) = try makeCompanyPlanner()
        let company = MeetingCompany(name: "Calendar service", attendeeDomains: ["calendar-service.example"])
        try companies.save(company)
        let project = MeetingProject(name: "Saved work", companyID: company.id)
        try projects.save(project)
        var row = meeting(at: 10)
        row.userNotes = "Keep these personal notes."
        try transcriptions.save(row)
        try projects.assign(transcriptionIDs: [row.id], to: project.id)
        let upcoming = event()
        let preparation = MeetingPreparation(
            key: .init(calendarID: "shared-calendar", eventID: "series_instance_1"),
            context: "Keep authored meeting context.", companyID: company.id, projectID: project.id,
            titleSnapshot: upcoming.title)
        let savedPreparation = try preparations.save(preparation)
        await planner.loadDraft(for: upcoming)
        planner.draftContext = "Keep this unsaved edit too."
        planner.selectedCompanyFilterID = company.id
        planner.selectedProjectFilterID = project.id
        await planner.refreshProjectTranscriptionIDs().value
        let persistedProject = try XCTUnwrap(projects.fetch(id: project.id))
        let persistedPreparation = try XCTUnwrap(preparations.fetch(id: savedPreparation.id))

        let archived = await planner.archiveCompany(id: company.id)

        XCTAssertTrue(archived)
        XCTAssertTrue(planner.companies.isEmpty)
        XCTAssertEqual(planner.archivedCompanies.map(\.id), [company.id])
        XCTAssertTrue(planner.projects.isEmpty, "Archived company projects stay out of new-selection lists.")
        XCTAssertNil(planner.selectedCompanyFilterID)
        XCTAssertNil(planner.selectedProjectFilterID)
        XCTAssertNil(planner.draftCompanyID)
        XCTAssertNil(planner.draftProjectID)
        XCTAssertEqual(planner.draftContext, "Keep this unsaved edit too.")
        XCTAssertEqual(try projects.fetch(id: project.id), persistedProject)
        XCTAssertEqual(try projects.project(for: row.id)?.id, project.id)
        XCTAssertEqual(try companies.company(for: row.id)?.id, company.id)
        XCTAssertEqual(try transcriptions.fetch(id: row.id)?.rawTranscript, row.rawTranscript)
        XCTAssertEqual(try transcriptions.fetch(id: row.id)?.userNotes, row.userNotes)
        XCTAssertEqual(try transcriptions.fetch(id: row.id)?.updatedAt, row.updatedAt)
        XCTAssertEqual(try preparations.fetch(id: savedPreparation.id), persistedPreparation)
        let rediscovered = try companies.ensureCompany(forDomain: "calendar-service.example")
        XCTAssertEqual(rediscovered.id, company.id)
        XCTAssertTrue(rediscovered.isArchived, "A sweep must not recreate or revive an archived company.")

        await planner.loadDraft(for: upcoming)
        XCTAssertNil(planner.draftCompanyID)
        XCTAssertNil(planner.draftProjectID)
        XCTAssertEqual(planner.draftContext, savedPreparation.context)
        XCTAssertEqual(planner.draftCompanyMatch?.source, .manual)
        let restored = await planner.restoreCompany(id: company.id)
        XCTAssertTrue(restored)
        XCTAssertEqual(planner.companies.map(\.id), [company.id])
        XCTAssertTrue(planner.archivedCompanies.isEmpty)
        XCTAssertEqual(planner.projects.map(\.id), [project.id])
        XCTAssertEqual(try companies.fetchAll(includeArchived: true).count, 1)
        XCTAssertEqual(try projects.project(for: row.id)?.id, project.id)
        XCTAssertFalse(planner.isUpdatingCompanyArchive)
        XCTAssertNil(planner.errorMessage)
    }

    func testArchivingMissingCompanyFailsWithoutChangingCurrentSelectionOrRecreatingRow() async throws {
        let (planner, companies, _, _, _) = try makeCompanyPlanner()
        let company = MeetingCompany(name: "Keep")
        try companies.save(company)
        await planner.refreshCompanies().value
        planner.selectedCompanyFilterID = company.id

        let archived = await planner.archiveCompany(id: UUID())

        XCTAssertFalse(archived)
        XCTAssertEqual(planner.selectedCompanyFilterID, company.id)
        XCTAssertEqual(planner.companies.map(\.id), [company.id])
        XCTAssertEqual(try companies.fetchAll(includeArchived: true).count, 1)
        XCTAssertEqual(try companies.fetch(id: company.id)?.isArchived, false)
        XCTAssertTrue(planner.archivedCompanies.isEmpty)
        XCTAssertNotNil(planner.errorMessage)
        XCTAssertFalse(planner.isUpdatingCompanyArchive)
    }

    private func makeCompanyPlanner() throws -> (
        LiveMeetingPlannerViewModel, MeetingCompanyRepository, MeetingProjectRepository,
        MeetingPreparationRepository, TranscriptionRepository
    ) {
        let manager = try DatabaseManager()
        let companies = MeetingCompanyRepository(dbQueue: manager.dbQueue)
        let projects = MeetingProjectRepository(dbQueue: manager.dbQueue)
        let preparations = MeetingPreparationRepository(dbQueue: manager.dbQueue)
        let transcriptions = TranscriptionRepository(dbQueue: manager.dbQueue)
        let planner = LiveMeetingPlannerViewModel(
            projectRepository: projects, preparationRepository: preparations,
            companyRepository: companies, transcriptionRepository: transcriptions)
        return (planner, companies, projects, preparations, transcriptions)
    }

    private func makePlanner() throws -> (
        LiveMeetingPlannerViewModel, MeetingProjectRepository, MeetingPreparationRepository, TranscriptionRepository
    ) {
        let manager = try DatabaseManager()
        let projects = MeetingProjectRepository(dbQueue: manager.dbQueue)
        let preparations = MeetingPreparationRepository(dbQueue: manager.dbQueue)
        let transcriptions = TranscriptionRepository(dbQueue: manager.dbQueue)
        let planner = LiveMeetingPlannerViewModel(
            projectRepository: projects, preparationRepository: preparations, transcriptionRepository: transcriptions)
        return (planner, projects, preparations, transcriptions)
    }

    private func event(title: String = "Project review", eventID: String = "series_instance_1") -> CalendarEvent {
        CalendarEvent(
            id: "google/shared-calendar/\(eventID)", title: title,
            startTime: Date(timeIntervalSince1970: 1000), endTime: Date(timeIntervalSince1970: 2800),
            calendarIdentifier: "shared-calendar", provider: .google, providerEventID: eventID)
    }

    private func meeting(at time: TimeInterval) -> Transcription {
        Transcription(
            createdAt: Date(timeIntervalSince1970: time), fileName: "Saved meeting \(time)",
            rawTranscript: "Saved words.", status: .completed, sourceType: .meeting,
            updatedAt: Date(timeIntervalSince1970: time))
    }
}

final class DelayedPlannerProjectRepository: MeetingProjectRepositoryProtocol, @unchecked Sendable {
    private let base: any MeetingProjectRepositoryProtocol
    private let delayedName: String
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    init(base: any MeetingProjectRepositoryProtocol, delayedName: String) {
        self.base = base; self.delayedName = delayedName
    }

    func waitUntilSaveBlocked() async -> Bool {
        await Task.detached { self.entered.wait(timeout: .now() + 2) == .success }.value
    }

    func releaseSave() { release.signal() }

    func save(_ project: MeetingProject) throws {
        if project.name == delayedName {
            entered.signal()
            guard release.wait(timeout: .now() + 5) == .success else { throw DelayError.timedOut }
        }
        try base.save(project)
    }

    func fetch(id: UUID) throws -> MeetingProject? { try base.fetch(id: id) }
    func fetchAll(includeArchived: Bool) throws -> [MeetingProject] {
        try base.fetchAll(includeArchived: includeArchived)
    }
    func setArchived(id: UUID, isArchived: Bool) throws { try base.setArchived(id: id, isArchived: isArchived) }
    func delete(id: UUID) throws -> Bool { try base.delete(id: id) }
    func assign(transcriptionIDs: Set<UUID>, to projectID: UUID?) throws {
        try base.assign(transcriptionIDs: transcriptionIDs, to: projectID)
    }
    func project(for transcriptionID: UUID) throws -> MeetingProject? { try base.project(for: transcriptionID) }
    func projectIDs(for transcriptionIDs: Set<UUID>) throws -> [UUID: UUID] {
        try base.projectIDs(for: transcriptionIDs)
    }
    func transcriptionIDs(in projectID: UUID) throws -> Set<UUID> { try base.transcriptionIDs(in: projectID) }
    func latestPreviousMeeting(
        projectID: UUID, before: Date, excludingRecordingID: UUID?, excludingTranscriptionID: UUID?
    ) throws -> ProjectPreviousMeeting? {
        try base.latestPreviousMeeting(
            projectID: projectID, before: before, excludingRecordingID: excludingRecordingID,
            excludingTranscriptionID: excludingTranscriptionID)
    }

    private enum DelayError: Error { case timedOut }
}
