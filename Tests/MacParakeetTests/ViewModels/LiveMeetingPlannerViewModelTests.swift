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
