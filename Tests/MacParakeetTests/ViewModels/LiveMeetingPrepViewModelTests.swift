import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class LiveMeetingPrepViewModelTests: XCTestCase {
    func testCompanyOnlyPreparationNeverChoosesAProjectOrCompanyWidePreviousMeeting() async throws {
        let fixture = try Fixture()
        let company = MeetingCompany(name: "Customer", attendeeDomains: ["customer.example"])
        try fixture.companies.save(company)
        let project = MeetingProject(name: "Unchosen", companyID: company.id)
        try fixture.projects.save(project)
        let row = Transcription(
            createdAt: fixture.now.addingTimeInterval(-300), fileName: "Other project",
            rawTranscript: "COMPANY_WIDE_CONTEXT_MUST_NOT_BE_SENT", status: .completed, sourceType: .meeting)
        try fixture.transcriptions.save(row)
        try fixture.projects.assign(transcriptionIDs: [row.id], to: project.id)
        let event = fixture.event()
        try fixture.preparations.save(
            .init(key: fixture.key(event), companyID: company.id, titleSnapshot: event.title))
        await fixture.model.poll(events: [event], now: fixture.now)
        XCTAssertNil(fixture.model.preparation(for: event))
        let calls = await fixture.provider.count
        XCTAssertEqual(calls, 0)
    }

    func testArchivingOnlyParentCompanyInvalidatesReadyPreparationWithoutNewInference() async throws {
        let fixture = try Fixture()
        var company = MeetingCompany(name: "Customer")
        try fixture.companies.save(company)
        var project = fixture.project
        project.companyID = company.id
        try fixture.projects.save(project)
        let event = fixture.event()
        try fixture.preparations.save(
            .init(key: fixture.key(event), companyID: company.id, projectID: project.id, titleSnapshot: event.title))
        try fixture.savePrevious(text: "Maya will send the report by Friday.")
        await fixture.model.poll(events: [event], now: fixture.now)
        XCTAssertNotNil(fixture.model.preparation(for: event))
        let initialCalls = await fixture.provider.count
        company.isArchived = true
        try fixture.companies.save(company)
        let restarted = fixture.makeModel()
        await restarted.load(for: event)
        XCTAssertNil(restarted.preparation(for: event))
        await fixture.model.poll(events: [event], now: fixture.now)
        XCTAssertNil(fixture.model.preparation(for: event))
        let afterCalls = await fixture.provider.count
        XCTAssertEqual(initialCalls, afterCalls)
        XCTAssertFalse(try XCTUnwrap(fixture.projects.fetch(id: project.id)).isArchived)
    }

    func testAutomaticWindowRequiresExplicitProjectChoiceAndIncludesSharedMeeting() async throws {
        let fixture = try Fixture()
        let selected = fixture.event(id: "selected", startsIn: 900)
        try fixture.saveSelection(for: selected)
        try fixture.savePrevious(text: "Maya will send the report by Friday.")
        let tooEarly = fixture.event(id: "early", startsIn: 901)
        try fixture.saveSelection(for: tooEarly)
        let unrelated = fixture.event(id: "not-selected", startsIn: 300)
        await fixture.model.poll(events: [tooEarly, unrelated, selected], now: fixture.now)
        XCTAssertNotNil(fixture.model.preparation(for: selected))
        XCTAssertNil(fixture.model.preparation(for: tooEarly))
        XCTAssertNil(fixture.model.preparation(for: unrelated))
        let calls = await fixture.provider.count
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(
            selected.isUserMeeting ?? true, "Explicit project selection also permits a shared calendar occurrence.")
    }

    func testAllDayDeclinedAndPastEventsDoNotGenerate() async throws {
        let fixture = try Fixture()
        var allDay = fixture.event(id: "day", startsIn: 10); allDay.isAllDay = true
        var declined = fixture.event(id: "declined", startsIn: 10); declined.userStatus = .declined
        let past = fixture.event(id: "past", startsIn: -1)
        for event in [allDay, declined, past] { try fixture.saveSelection(for: event) }
        try fixture.savePrevious(text: "Maya will send the report by Friday.")
        await fixture.model.poll(events: [allDay, declined, past], now: fixture.now)
        let calls = await fixture.provider.count
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(fixture.model.preparations.isEmpty)
    }

    func testBusyLiveAIDefersWithoutInferenceAndPreferenceCanDisable() async throws {
        let fixture = try Fixture()
        let event = fixture.event()
        try fixture.saveSelection(for: event)
        try fixture.savePrevious(text: "Maya will send the report by Friday.")
        fixture.model.start(eventsProvider: { [] }, isBusy: { true })
        await fixture.model.poll(events: [event], now: fixture.now)
        await fixture.model.refresh(for: event)
        fixture.model.stop()
        fixture.model.enabled = false
        await fixture.model.poll(events: [event], now: fixture.now)
        XCTAssertFalse(fixture.defaults.bool(forKey: LiveMeetingPrepViewModel.enabledPreferenceKey))
        let calls = await fixture.provider.count
        XCTAssertEqual(calls, 0)
    }

    func testIdleLiveAIAllowsBackToBackPreparationWhileCaptureContinues() async throws {
        let fixture = try Fixture()
        let nextMeeting = fixture.event(id: "next-meeting", startsIn: 900)
        try fixture.saveSelection(for: nextMeeting)
        try fixture.savePrevious(text: "Maya will send the report by Friday.")
        var liveAIIsBusy = true
        // The injected gate intentionally represents provider work, not the
        // ongoing audio capture: another meeting may start in fifteen minutes.
        fixture.model.start(eventsProvider: { [] }, isBusy: { liveAIIsBusy })
        defer { fixture.model.stop() }
        await fixture.model.poll(events: [nextMeeting], now: fixture.now)
        XCTAssertNil(fixture.model.preparation(for: nextMeeting))
        let deferredCalls = await fixture.provider.count
        XCTAssertEqual(deferredCalls, 0)

        liveAIIsBusy = false
        await fixture.model.poll(events: [nextMeeting], now: fixture.now)
        XCTAssertNotNil(fixture.model.preparation(for: nextMeeting))
        let completedCalls = await fixture.provider.count
        XCTAssertEqual(completedCalls, 1)
    }

    func testLatestProcessingMeetingDoesNotSubstituteOlderTranscriptAndRetainsNotes() async throws {
        let fixture = try Fixture()
        let event = fixture.event()
        try fixture.saveSelection(for: event)
        try fixture.savePrevious(text: "OLDER SECRET MUST NOT BE SENT", age: 300)
        let latest = try fixture.savePrevious(
            text: nil, notes: "Ask about the security review.", status: .processing, age: 100)
        await fixture.model.poll(events: [event], now: fixture.now)
        let prepared = try XCTUnwrap(fixture.model.preparation(for: event))
        XCTAssertEqual(prepared.board.documents.count, 1)
        XCTAssertEqual(prepared.board.documents[0].kind, .previousNotes)
        XCTAssertTrue(prepared.board.documents[0].id.hasPrefix(latest.id.uuidString))
        XCTAssertTrue(prepared.sourceStatus.contains("no older meeting was substituted"))
        let sent = await fixture.provider.requests.joined()
        XCTAssertFalse(sent.contains("OLDER SECRET"))
        XCTAssertTrue(sent.contains("Ask about the security review."))
    }

    func testFullNotesReachExtractionIncludingSuffixBeyondFirstChunk() async throws {
        let fixture = try Fixture()
        let event = fixture.event()
        try fixture.saveSelection(for: event, context: "Keep my own agenda unchanged.")
        let notes = String(repeating: "A personal detail. ", count: 900) + "SUFFIX REVIEW THE ACCESSIBILITY PLAN."
        let previous = try fixture.savePrevious(text: "We reviewed the project.", notes: notes)
        await fixture.model.poll(events: [event], now: fixture.now)
        let prepared = try XCTUnwrap(fixture.model.preparation(for: event))
        let sent = await fixture.provider.requests.joined()
        XCTAssertTrue(sent.contains("SUFFIX REVIEW THE ACCESSIBILITY PLAN."))
        XCTAssertEqual(prepared.board.documents.first(where: { $0.kind == .previousNotes })?.text, notes)
        XCTAssertEqual(try fixture.transcriptions.fetch(id: previous.id)?.userNotes, notes)
        XCTAssertEqual(
            try fixture.preparations.fetch(key: fixture.key(event))?.context, "Keep my own agenda unchanged.")
    }

    func testStablePreparationIsReusedWithoutAnotherInferenceAndSurvivesNewViewModel() async throws {
        let fixture = try Fixture()
        let event = fixture.event()
        try fixture.saveSelection(for: event)
        try fixture.savePrevious(text: "Maya will send the report by Friday.")
        await fixture.model.poll(events: [event], now: fixture.now)
        await fixture.model.poll(events: [event], now: fixture.now)
        let newModel = fixture.makeModel()
        await newModel.load(for: event)
        XCTAssertEqual(newModel.preparation(for: event), fixture.model.preparation(for: event))
        let calls = await fixture.provider.count
        XCTAssertEqual(calls, 1)
    }

    func testSourceNoteManualContextAndProviderChangesRejectCachedLivePreparation() async throws {
        let fixture = try Fixture()
        let event = fixture.event()
        try fixture.saveSelection(for: event)
        var previous = try fixture.savePrevious(
            text: "Maya will send the report by Friday.", notes: "Review the budget.")
        await fixture.model.poll(events: [event], now: fixture.now)
        let initial = await fixture.validated(for: event)
        XCTAssertNotNil(initial)
        previous.userNotes = "Review the corrected budget."; previous.updatedAt = fixture.now
        try fixture.transcriptions.save(previous)
        let changedNotes = await fixture.validated(for: event)
        XCTAssertNil(changedNotes)
        await fixture.model.poll(events: [event], now: fixture.now)
        var selection = try XCTUnwrap(fixture.preparations.fetch(key: fixture.key(event)))
        selection.context = "Changed meeting goals."; try fixture.preparations.save(selection)
        let changedManual = await fixture.validated(for: event)
        XCTAssertNil(changedManual)
        await fixture.model.poll(events: [event], now: fixture.now)
        await fixture.provider.changeAccount(to: "different-account")
        let changedAccount = await fixture.validated(for: event)
        XCTAssertNil(changedAccount)
    }

    func testNewerLatestMeetingInvalidatesPreparationInsteadOfKeepingOlderCarryover() async throws {
        let fixture = try Fixture()
        let event = fixture.event()
        try fixture.saveSelection(for: event)
        try fixture.savePrevious(text: "Maya will send the report by Friday.", age: 300)
        await fixture.model.poll(events: [event], now: fixture.now)
        try fixture.savePrevious(text: "A new latest meeting.", age: 100)
        let current = await fixture.validated(for: event)
        XCTAssertNil(current)
    }

    func testPreemptionCancelsAndAwaitsWithoutPublishingOrSavingPartialResult() async throws {
        let fixture = try Fixture()
        let event = fixture.event()
        try fixture.saveSelection(for: event)
        try fixture.savePrevious(text: "Maya will send the report by Friday.")
        await fixture.provider.setDelayed(true)
        let work = Task { await fixture.model.poll(events: [event], now: fixture.now) }
        for _ in 0..<200 {
            if await fixture.provider.count > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = await fixture.provider.count
        XCTAssertEqual(started, 1)
        await fixture.model.preempt()
        await work.value
        XCTAssertFalse(fixture.model.isPreparing)
        XCTAssertNil(fixture.model.preparation(for: event))
        let saved = try await fixture.store.load(key: fixture.key(event))
        XCTAssertNil(saved)
    }

    func testEditDuringGenerationCannotPublishStalePreparation() async throws {
        let fixture = try Fixture()
        let event = fixture.event()
        try fixture.saveSelection(for: event)
        var row = try fixture.savePrevious(text: "Maya will send the report by Friday.")
        await fixture.provider.setDelay(.milliseconds(75))
        let work = Task { await fixture.model.poll(events: [event], now: fixture.now) }
        for _ in 0..<200 {
            if await fixture.provider.count > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        row.rawTranscript = "The report is no longer needed."; row.updatedAt = fixture.now
        try fixture.transcriptions.save(row)
        await work.value
        XCTAssertNil(fixture.model.preparation(for: event))
        let saved = try await fixture.store.load(key: fixture.key(event))
        XCTAssertNil(saved)
    }

    func testOlderCacheLoadCannotEraseNewerGeneratedPreparationAfterNotesChange() async throws {
        let fixture = try Fixture()
        let event = fixture.event()
        try fixture.saveSelection(for: event)
        var row = try fixture.savePrevious(text: "Original project discussion.", notes: "Old personal note.")
        await fixture.model.poll(events: [event], now: fixture.now)
        await fixture.provider.delayValidation(after: 0, duration: .milliseconds(250))
        let oldLoad = Task { await fixture.model.load(for: event) }
        for _ in 0..<200 {
            if await fixture.provider.delayedValidationStarted { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        row.userNotes = "New personal note."; row.updatedAt = fixture.now
        try fixture.transcriptions.save(row)
        await fixture.model.poll(events: [event], now: fixture.now)
        let replacement = try XCTUnwrap(fixture.model.preparation(for: event))
        XCTAssertEqual(
            replacement.board.documents.first(where: { $0.kind == .previousNotes })?.text, "New personal note.")
        await oldLoad.value
        XCTAssertEqual(fixture.model.preparation(for: event), replacement)
    }

    func testDisableDuringCachedProviderValidationCannotPublishReadyStatus() async throws {
        let fixture = try Fixture()
        let event = fixture.event()
        try fixture.saveSelection(for: event)
        try fixture.savePrevious(text: "Original project discussion.")
        await fixture.model.poll(events: [event], now: fixture.now)
        // The second validation happens after loading the cached artifact.
        await fixture.provider.delayValidation(after: 1, duration: .seconds(1), ignoringCancellation: true)
        let work = Task { await fixture.model.poll(events: [event], now: fixture.now) }
        for _ in 0..<200 {
            if await fixture.provider.delayedValidationStarted { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = await fixture.provider.delayedValidationStarted
        XCTAssertTrue(started)
        fixture.model.enabled = false
        await work.value
        XCTAssertFalse(fixture.model.isPreparing)
        XCTAssertEqual(fixture.model.status, "Automatic preparation is off.")
    }

    @MainActor
    private final class Fixture {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let projects: MeetingProjectRepository
        let companies: MeetingCompanyRepository
        let preparations: MeetingPreparationRepository
        let transcriptions: TranscriptionRepository
        let project = MeetingProject(name: "Delivery")
        let provider = PrepProviderProbe()
        let store: MeetingGeneratedPreparationStore
        let defaults: UserDefaults
        let directory: URL
        lazy var model = makeModel()

        init() throws {
            let manager = try DatabaseManager()
            projects = MeetingProjectRepository(dbQueue: manager.dbQueue)
            companies = MeetingCompanyRepository(dbQueue: manager.dbQueue)
            preparations = MeetingPreparationRepository(dbQueue: manager.dbQueue)
            transcriptions = TranscriptionRepository(dbQueue: manager.dbQueue)
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            store = MeetingGeneratedPreparationStore(directoryURL: directory)
            defaults = UserDefaults(suiteName: "MeetingPrepTests." + UUID().uuidString)!
            defaults.set(true, forKey: LiveMeetingPrepViewModel.enabledPreferenceKey)
            try projects.save(project)
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        func makeModel() -> LiveMeetingPrepViewModel {
            let probe = provider
            return LiveMeetingPrepViewModel(
                projectRepository: projects, preparationRepository: preparations,
                companyRepository: companies,
                sessionProvider: { await probe.session() }, store: store, defaults: defaults)
        }

        func event(id: String = "selected", startsIn: TimeInterval = 600) -> CalendarEvent {
            CalendarEvent(
                id: "google/shared/" + id, title: "  Exact event name  ", startTime: now.addingTimeInterval(startsIn),
                endTime: now.addingTimeInterval(startsIn + 1800), calendarIdentifier: "shared",
                provider: .google, providerEventID: id, isUserMeeting: false)
        }

        func key(_ event: CalendarEvent) -> MeetingPreparationKey {
            .init(calendarID: event.preparationCalendarID!, eventID: event.preparationEventID!)
        }

        func saveSelection(for event: CalendarEvent, context: String = "My authored agenda.") throws {
            try preparations.save(
                .init(
                    key: key(event), context: context, projectID: project.id, titleSnapshot: event.title,
                    scheduledStartAt: event.startTime, scheduledEndAt: event.endTime))
        }

        @discardableResult
        func savePrevious(
            text: String?, notes: String? = nil, status: Transcription.TranscriptionStatus = .completed,
            age: TimeInterval = 300
        ) throws -> Transcription {
            let row = Transcription(
                createdAt: now.addingTimeInterval(-age), fileName: "Latest delivery meeting", rawTranscript: text,
                status: status, sourceType: .meeting, userNotes: notes, updatedAt: now.addingTimeInterval(-age))
            try transcriptions.save(row)
            try projects.assign(transcriptionIDs: [row.id], to: project.id)
            return row
        }

        func validated(for event: CalendarEvent) async -> MeetingGeneratedPreparation? {
            await model.validatedPreparation(key: key(event), projectID: project.id, before: now)
        }
    }
}

private actor PrepProviderProbe {
    private(set) var count = 0
    private(set) var requests: [String] = []
    private var account = "test-account"
    private var delay: Duration?
    private var validationCount = 0
    private var validationDelay: (call: Int, duration: Duration, ignoringCancellation: Bool)?
    private(set) var delayedValidationStarted = false

    func changeAccount(to value: String) { account = value }
    func setDelayed(_ value: Bool) { delay = value ? .seconds(60) : nil }
    func setDelay(_ value: Duration?) { delay = value }
    func delayValidation(after skippedCalls: Int, duration: Duration, ignoringCancellation: Bool = false) {
        validationDelay = (validationCount + skippedCalls + 1, duration, ignoringCancellation)
        delayedValidationStarted = false
    }

    func session() -> LiveAnswerStreamSession {
        let identity = account
        return LiveAnswerStreamSession(
            cacheKey: identity, validate: { try await self.validate(identity) },
            stream: { messages in
                AsyncThrowingStream { continuation in
                    let work = Task {
                        do {
                            let result = try await self.reply(messages)
                            continuation.yield(result); continuation.finish()
                        } catch { continuation.finish(throwing: error) }
                    }
                    continuation.onTermination = { @Sendable _ in work.cancel() }
                }
            })
    }

    private func validate(_ identity: String) async throws {
        validationCount += 1
        if let delayed = validationDelay, delayed.call == validationCount {
            delayedValidationStarted = true
            if delayed.ignoringCancellation {
                try? await Task.sleep(for: delayed.duration)
            } else {
                try await Task.sleep(for: delayed.duration)
            }
        }
        guard identity == account else { throw CancellationError() }
    }

    private func reply(_ messages: [ChatMessage]) async throws -> String {
        count += 1
        requests.append(contentsOf: messages.filter { $0.role == .user }.map(\.content))
        if let delay { try await Task.sleep(for: delay) }
        try Task.checkCancellation()
        return "{\"items\":[]}"
    }
}
