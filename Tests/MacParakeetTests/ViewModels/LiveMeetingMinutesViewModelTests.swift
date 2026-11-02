import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

private actor MinutesSessionAttempts {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor MinutesArtifactAttempts {
    private(set) var ids: [UUID] = []
    func record(_ id: UUID) { ids.append(id) }
}

@MainActor
final class LiveMeetingMinutesViewModelTests: XCTestCase {
    private let cutoff = Date(timeIntervalSince1970: 1_700_000_000)

    func testAutomaticScanCoversNewCompletedMeetingsWithoutBackfillingOldLibrary() async throws {
        let database = try DatabaseManager()
        let transcriptions = TranscriptionRepository(dbQueue: database.dbQueue)
        let old = fixture(createdAt: cutoff.addingTimeInterval(-60))
        let new = fixture(createdAt: cutoff.addingTimeInterval(60))
        var incomplete = fixture(createdAt: cutoff.addingTimeInterval(60))
        incomplete.status = .processing
        try transcriptions.save(old)
        try transcriptions.save(new)
        try transcriptions.save(incomplete)
        let repository = MeetingMinutesJobRepository(dbQueue: database.dbQueue)
        let model = configured(repository: repository, captureActive: { true })
        defer { model.stop() }
        await model.refresh()
        XCTAssertNil(try repository.job(for: old.id))
        XCTAssertNil(try repository.job(for: incomplete.id))
        XCTAssertEqual(try repository.job(for: new.id)?.state, .pending)
        XCTAssertTrue(model.captureIsActive)
        XCTAssertNil(model.activeJobID)
        XCTAssertEqual(try transcriptions.fetch(id: new.id)?.cleanTranscript, new.cleanTranscript)
        await model.refresh()
        XCTAssertEqual(try repository.allJobs().count, 1, "Polling cannot duplicate meeting work")
    }

    func testDisabledAutomationDoesNotQueueButExplicitOlderMeetingRequestDoes() async throws {
        let database = try DatabaseManager()
        let transcriptions = TranscriptionRepository(dbQueue: database.dbQueue)
        let meeting = fixture(createdAt: cutoff.addingTimeInterval(-60))
        try transcriptions.save(meeting)
        let repository = MeetingMinutesJobRepository(dbQueue: database.dbQueue)
        let preferences = LiveMeetingPreferences(skillMarkdown: "Evidence-first skill", automaticMinutesEnabled: false)
        let model = configured(repository: repository, preferences: { preferences }, captureActive: { true })
        defer { model.stop() }
        await model.refresh()
        XCTAssertTrue(try repository.allJobs().isEmpty)
        await model.generate(transcriptionID: meeting.id)
        XCTAssertEqual(try repository.job(for: meeting.id)?.state, .pending)
        XCTAssertFalse(model.automaticMinutesEnabled)
        XCTAssertNil(model.activeJobID, "An explicit request still waits for recording to finish")
    }

    func testUnavailablePreferencesPauseBeforeAnyCloudDispatch() async throws {
        let database = try DatabaseManager()
        let transcriptions = TranscriptionRepository(dbQueue: database.dbQueue)
        try transcriptions.save(fixture(createdAt: cutoff.addingTimeInterval(60)))
        let repository = MeetingMinutesJobRepository(dbQueue: database.dbQueue)
        let attempts = MinutesSessionAttempts()
        let model = configured(
            repository: repository,
            preferences: { throw LiveMeetingPreferencesError.corruptFile(recoveryAvailable: true) },
            captureActive: { false },
            sessionProvider: {
                await attempts.record()
                throw ChatGPTLiveError.disconnected
            })
        defer { model.stop() }
        await model.refresh()
        XCTAssertTrue(try repository.allJobs().isEmpty)
        XCTAssertNotNil(model.errorMessage)
        let count = await attempts.count
        XCTAssertEqual(count, 0)
    }

    func testConnectionFailureBecomesDurableAndPollingNeverReplaysIt() async throws {
        let database = try DatabaseManager()
        let transcriptions = TranscriptionRepository(dbQueue: database.dbQueue)
        let meeting = fixture(createdAt: cutoff.addingTimeInterval(60))
        try transcriptions.save(meeting)
        let repository = MeetingMinutesJobRepository(dbQueue: database.dbQueue)
        let attempts = MinutesSessionAttempts()
        let model = configured(
            repository: repository, captureActive: { false },
            sessionProvider: {
                await attempts.record()
                throw ChatGPTLiveError.disconnected
            })
        defer { model.stop() }
        await model.refresh()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while try repository.job(for: meeting.id)?.state != .failed, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(try repository.job(for: meeting.id)?.state, .failed)
        for _ in 0..<3 { await model.refresh() }
        let count = await attempts.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try transcriptions.fetch(id: meeting.id)?.status, .completed)
    }

    func testRetryAfterSourceEditPresentsNewJobInsteadOfOldFailure() async throws {
        let database = try DatabaseManager()
        let transcriptions = TranscriptionRepository(dbQueue: database.dbQueue)
        var meeting = fixture(createdAt: cutoff.addingTimeInterval(60))
        try transcriptions.save(meeting)
        let repository = MeetingMinutesJobRepository(dbQueue: database.dbQueue)
        let preferences = LiveMeetingPreferences(skillMarkdown: "Evidence-first skill")
        let old = try repository.enqueue(
            source: repository.captureSource(transcriptionID: meeting.id),
            skill: .init(markdown: preferences.skillMarkdown, revision: preferences.skillRevision))
        try repository.failPendingJob(jobID: old.id, message: "Synthetic failure")
        meeting.cleanTranscript = "We corrected the test scope. No deadline was agreed."
        try transcriptions.save(meeting)
        let model = configured(repository: repository, captureActive: { true })
        defer { model.stop() }
        await model.retry(jobID: old.id)
        let latest = try XCTUnwrap(model.job(for: meeting.id))
        XCTAssertNotEqual(latest.id, old.id)
        XCTAssertEqual(latest.state, .pending)
        XCTAssertEqual(try repository.fetch(id: old.id)?.state, .failed)
        XCTAssertEqual(try repository.jobsFor(transcriptionID: meeting.id).count, 2)
    }

    func testRestartRepairsCompletedMinutesFilesWithoutAnyInferenceReplay() async throws {
        let database = try DatabaseManager()
        let transcriptions = TranscriptionRepository(dbQueue: database.dbQueue)
        let meeting = fixture(createdAt: cutoff.addingTimeInterval(60))
        try transcriptions.save(meeting)
        let repository = MeetingMinutesJobRepository(dbQueue: database.dbQueue)
        let preferences = LiveMeetingPreferences(skillMarkdown: "Evidence-first skill", automaticMinutesEnabled: false)
        let source = try repository.captureSource(transcriptionID: meeting.id)
        let job = try repository.enqueue(
            source: source, skill: .init(markdown: preferences.skillMarkdown, revision: preferences.skillRevision))
        let claimed = try repository.claim(
            jobID: job.id, providerIdentity: "synthetic", provider: "fixture", model: "fixture")
        let attemptID = try XCTUnwrap(claimed.attemptID)
        var progress = MeetingMinutesProgress()
        progress.chunks = [.init(start: 0, end: source.transcript.count, requestStart: 0)]
        progress.meetingMap = "Synthetic saved result."
        try repository.checkpoint(jobID: job.id, attemptID: attemptID, progress: progress)
        let saved = try repository.complete(jobID: job.id, attemptID: attemptID, markdown: "Synthetic saved minutes.")
        let exports = MinutesArtifactAttempts()
        let provider = MinutesSessionAttempts()
        for index in 1...2 {
            let model = configured(
                repository: repository, preferences: { preferences }, captureActive: { false },
                sessionProvider: {
                    await provider.record(); throw ChatGPTLiveError.disconnected
                },
                artifactRefresh: { await exports.record($0) })
            await model.refresh()
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while await exports.ids.count < index, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            model.stop()
        }
        let calls = await provider.count
        let exported = await exports.ids
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(exported, [meeting.id, meeting.id])
        XCTAssertEqual(try repository.result(jobID: job.id)?.id, saved.id)
        XCTAssertEqual(try PromptResultRepository(dbQueue: database.dbQueue).count(transcriptionId: meeting.id), 1)
    }

    private func fixture(createdAt: Date) -> Transcription {
        Transcription(
            createdAt: createdAt, fileName: "Synthetic minutes fixture", rawTranscript: "We discussed the test.",
            cleanTranscript: "We discussed the test.", status: .completed, sourceType: .meeting)
    }

    private func configured(
        repository: MeetingMinutesJobRepository,
        preferences: @escaping @Sendable () async throws -> LiveMeetingPreferences = {
            LiveMeetingPreferences(skillMarkdown: "Evidence-first skill")
        },
        captureActive: @escaping @MainActor () -> Bool,
        sessionProvider: @escaping @Sendable () async throws -> LiveAnswerStreamSession = {
            throw ChatGPTLiveError.disconnected
        },
        artifactRefresh: @escaping @Sendable (UUID) async throws -> Void = { _ in }
    ) -> LiveMeetingMinutesViewModel {
        let model = LiveMeetingMinutesViewModel()
        model.configure(
            repository: repository, engine: MeetingMinutesEngine(repository: repository),
            preferencesProvider: preferences, sessionProvider: sessionProvider,
            activeCaptureProvider: captureActive, automaticStartDate: cutoff,
            artifactRefresh: artifactRefresh, onSaved: { _, _ in })
        return model
    }
}
