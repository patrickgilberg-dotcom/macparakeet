import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class LiveMeetingOrganizationViewModelTests: XCTestCase {
    func testCompanySelectionLeavesProjectOptionalAndProjectChoiceStaysWithinCompany() async throws {
        let fixture = try Fixture()
        var saves: [(UUID?, UUID?)] = []
        let model = fixture.model { saves.append(($0, $1)) }
        await model.load()
        await model.selectCompany(fixture.first.id).value
        XCTAssertEqual(model.companyID, fixture.first.id)
        XCTAssertNil(model.projectID)
        XCTAssertEqual(model.availableProjects.map(\.id), [fixture.firstProject.id])
        await model.selectProject(fixture.firstProject.id).value
        XCTAssertEqual(model.projectID, fixture.firstProject.id)
        await model.selectCompany(fixture.second.id).value
        XCTAssertEqual(model.companyID, fixture.second.id)
        XCTAssertNil(model.projectID)
        XCTAssertEqual(model.availableProjects.map(\.id), [fixture.secondProject.id])
        XCTAssertEqual(saves.map { $0.0 }, [fixture.first.id, fixture.first.id, fixture.second.id])
        XCTAssertEqual(saves.map { $0.1 }, [nil, fixture.firstProject.id, nil])
        XCTAssertNil(model.errorMessage)
    }

    func testProjectSelectionAlignsCompanyAndLegacyProjectRemainsUnowned() async throws {
        let fixture = try Fixture()
        let legacy = MeetingProject(name: "Legacy")
        try fixture.projects.save(legacy)
        var savedCompany: UUID?
        var savedProject: UUID?
        let model = fixture.model {
            savedCompany = $0; savedProject = $1
        }
        await model.load()
        await model.selectProject(fixture.secondProject.id).value
        XCTAssertEqual(savedCompany, fixture.second.id)
        XCTAssertEqual(savedProject, fixture.secondProject.id)
        await model.selectProject(legacy.id).value
        XCTAssertNil(model.companyID)
        XCTAssertEqual(model.projectID, legacy.id)
        XCTAssertNil(savedCompany)
        XCTAssertEqual(savedProject, legacy.id)
    }

    func testSupersededQueuedSelectionDoesNotSaveBeforeLatestIntent() async throws {
        let fixture = try Fixture()
        var saves: [UUID?] = []
        let model = fixture.model { saves.append($1) }
        await model.load()
        let older = model.selectProject(fixture.firstProject.id)
        let latest = model.selectProject(fixture.secondProject.id)
        await older.value; await latest.value
        XCTAssertEqual(saves, [fixture.secondProject.id])
        XCTAssertEqual(model.companyID, fixture.second.id)
        XCTAssertEqual(model.projectID, fixture.secondProject.id)
        XCTAssertFalse(model.isSaving)
    }

    func testInFlightWriteFinishesBeforeLatestSelectionAndMiddleIntentIsSkipped() async throws {
        let fixture = try Fixture()
        var started = false
        var release: CheckedContinuation<Void, Never>?
        var saves: [UUID?] = []
        let model = fixture.model { _, projectID in
            if !started {
                started = true
                await withCheckedContinuation { release = $0 }
            }
            saves.append(projectID)
        }
        await model.load()
        let first = model.selectProject(fixture.firstProject.id)
        for _ in 0..<200 {
            if started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(started)
        let middle = model.selectCompany(nil)
        let latest = model.selectProject(fixture.secondProject.id)
        XCTAssertTrue(model.isSaving)
        release?.resume()
        await first.value; await middle.value; await latest.value
        await model.waitForPendingSave()
        XCTAssertEqual(saves, [fixture.firstProject.id, fixture.secondProject.id])
        XCTAssertEqual(model.companyID, fixture.second.id)
        XCTAssertEqual(model.projectID, fixture.secondProject.id)
        XCTAssertFalse(model.isSaving)
    }

    func testFailedWriteRestoresSavedChoiceAndReportsError() async throws {
        let fixture = try Fixture()
        let model = fixture.model(companyID: fixture.first.id, projectID: fixture.firstProject.id) { _, _ in
            throw TestError.saveFailed
        }
        await model.load()
        await model.selectCompany(fixture.second.id).value
        XCTAssertEqual(model.companyID, fixture.first.id)
        XCTAssertEqual(model.projectID, fixture.firstProject.id)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isSaving)
    }

    func testDeletedProjectIsRevalidatedBeforeSavingAndNeverRecreated() async throws {
        let fixture = try Fixture()
        var saveCount = 0
        let model = fixture.model { _, _ in saveCount += 1 }
        await model.load()
        _ = try fixture.projects.delete(id: fixture.firstProject.id)
        await model.selectProject(fixture.firstProject.id).value
        XCTAssertEqual(saveCount, 0)
        XCTAssertNil(model.projectID)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(try fixture.projects.fetch(id: fixture.firstProject.id))
    }

    func testCreateProjectUsesSelectedCompanyAndSavesThatChoice() async throws {
        let fixture = try Fixture()
        var saved: UUID?
        let model = fixture.model(companyID: fixture.first.id) { _, projectID in saved = projectID }
        await model.load()
        let created = await model.createProject(named: "  New workstream  ")
        XCTAssertTrue(created)
        let project = try XCTUnwrap(model.projects.first(where: { $0.name == "New workstream" }))
        XCTAssertEqual(project.companyID, fixture.first.id)
        XCTAssertEqual(model.projectID, project.id)
        XCTAssertEqual(saved, project.id)
        XCTAssertFalse(model.isCreatingProject)
    }

    func testPendingSaveWaiterFollowsChoiceQueuedWhileItWasAlreadyWaiting() async throws {
        let fixture = try Fixture()
        var firstStarted = false
        var secondStarted = false
        var firstRelease: CheckedContinuation<Void, Never>?
        var secondRelease: CheckedContinuation<Void, Never>?
        var saved: UUID?
        let model = fixture.model { _, projectID in
            if projectID == fixture.firstProject.id {
                firstStarted = true
                await withCheckedContinuation { firstRelease = $0 }
            } else {
                secondStarted = true
                await withCheckedContinuation { secondRelease = $0 }
            }
            saved = projectID
        }
        await model.load()
        let first = model.selectProject(fixture.firstProject.id)
        for _ in 0..<200 {
            if firstStarted { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(firstStarted)
        var waiterStarted = false
        var waiterFinished = false
        let waiter = Task { @MainActor in
            waiterStarted = true
            await model.waitForPendingSave()
            waiterFinished = true
        }
        for _ in 0..<200 {
            if waiterStarted { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(waiterStarted)
        let latest = model.selectProject(fixture.secondProject.id)
        firstRelease?.resume(); firstRelease = nil
        for _ in 0..<200 {
            if secondStarted { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(secondStarted)
        await first.value
        for _ in 0..<20 {
            if waiterFinished { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertFalse(waiterFinished, "A finalizer must wait for the choice queued after it started waiting.")
        secondRelease?.resume(); secondRelease = nil
        await first.value; await latest.value; await waiter.value
        XCTAssertTrue(waiterFinished)
        XCTAssertEqual(saved, fixture.secondProject.id)
        XCTAssertFalse(model.isSaving)
    }

    func testFinishingFreezesNewIntentsAndWaitsForAlreadyAdmittedProjectCreation() async throws {
        let fixture = try Fixture()
        let delayed = DelayedPlannerProjectRepository(base: fixture.projects, delayedName: "New workstream")
        var savedProjectID: UUID?
        let model = fixture.model(companyID: fixture.first.id, projectRepository: delayed) { _, projectID in
            savedProjectID = projectID
        }
        await model.load()
        let creation = Task { await model.createProject(named: "New workstream") }
        let blocked = await delayed.waitUntilSaveBlocked()
        XCTAssertTrue(blocked)
        model.beginFinishing()
        var finished = false
        let finalizer = Task { @MainActor in
            await model.finishEditing(); finished = true
        }

        await model.selectCompany(fixture.second.id).value
        await model.selectProject(fixture.secondProject.id).value
        let rejected = await model.createProject(named: "Too late")
        XCTAssertFalse(rejected)
        XCTAssertTrue(model.isFinishing)
        XCTAssertEqual(model.companyID, fixture.first.id)
        XCTAssertFalse(finished)
        delayed.releaseSave()
        let created = await creation.value
        await finalizer.value

        XCTAssertTrue(created)
        XCTAssertTrue(finished)
        let project = try XCTUnwrap(model.projects.first(where: { $0.name == "New workstream" }))
        XCTAssertEqual(project.companyID, fixture.first.id)
        XCTAssertEqual(savedProjectID, project.id)
        XCTAssertEqual(model.projectID, project.id)
        XCTAssertFalse(model.isCreatingProject)
        XCTAssertFalse(model.isSaving)
        XCTAssertNil(model.errorMessage)
    }

    private enum TestError: Error { case saveFailed }

    @MainActor
    private final class Fixture {
        let companies: MeetingCompanyRepository
        let projects: MeetingProjectRepository
        let first = MeetingCompany(name: "First")
        let second = MeetingCompany(name: "Second")
        let firstProject: MeetingProject
        let secondProject: MeetingProject

        init() throws {
            let database = try DatabaseManager()
            companies = MeetingCompanyRepository(dbQueue: database.dbQueue)
            projects = MeetingProjectRepository(dbQueue: database.dbQueue)
            firstProject = MeetingProject(name: "Delivery", companyID: first.id)
            secondProject = MeetingProject(name: "Rollout", companyID: second.id)
            try companies.save(first); try companies.save(second)
            try projects.save(firstProject); try projects.save(secondProject)
        }

        func model(
            companyID: UUID? = nil, projectID: UUID? = nil,
            projectRepository: (any MeetingProjectRepositoryProtocol)? = nil,
            onSave: @escaping @MainActor (UUID?, UUID?) async throws -> Void
        ) -> LiveMeetingOrganizationViewModel {
            LiveMeetingOrganizationViewModel(
                companyRepository: companies, projectRepository: projectRepository ?? projects,
                companyID: companyID, projectID: projectID, onSave: onSave)
        }
    }
}
