import Foundation
import GRDB
import XCTest
@testable import MacParakeetCore

final class MeetingCompanyRepositoryTests: XCTestCase {
    private var manager: DatabaseManager!
    private var companies: MeetingCompanyRepository!
    private var projects: MeetingProjectRepository!
    private var preparations: MeetingPreparationRepository!
    private var transcriptions: TranscriptionRepository!
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        manager = try DatabaseManager()
        companies = MeetingCompanyRepository(dbQueue: manager.dbQueue)
        projects = MeetingProjectRepository(dbQueue: manager.dbQueue)
        preparations = MeetingPreparationRepository(dbQueue: manager.dbQueue)
        transcriptions = TranscriptionRepository(dbQueue: manager.dbQueue)
    }

    func testCompanyRulesNormalizeRoundTripAndCanBeCleared() throws {
        var company = MeetingCompany(
            name: "  Example  ", attendeeDomains: [" @EXAMPLE.COM ", "example.com", "subsidiary.test"],
            createdAt: instant, updatedAt: instant)
        try companies.save(company)
        XCTAssertEqual(try companies.fetch(id: company.id)?.name, "Example")
        XCTAssertEqual(try companies.fetch(id: company.id)?.attendeeDomains, ["example.com", "subsidiary.test"])
        company.attendeeDomains = []
        try companies.save(company)
        XCTAssertEqual(try companies.fetch(id: company.id)?.attendeeDomains, [])
        company.isArchived = true
        try companies.save(company)
        XCTAssertTrue(try companies.fetchAll().isEmpty)
        XCTAssertEqual(try companies.fetchAll(includeArchived: true).count, 1)
    }

    func testInvalidCompanyRuleDoesNotOverwriteExistingNameOrRules() throws {
        var company = try savedCompany("Original", domains: ["example.com"])
        company.name = "Uncommitted"
        company.attendeeDomains = ["*.example.com"]
        XCTAssertThrowsError(try companies.save(company)) { error in
            XCTAssertEqual(error as? MeetingCompanyRepositoryError, .invalidAttendeeDomain)
        }
        XCTAssertEqual(try companies.fetch(id: company.id)?.name, "Original")
        XCTAssertEqual(try companies.fetch(id: company.id)?.attendeeDomains, ["example.com"])
    }

    func testEnsureCompanyIsIdempotentAndUsesHonestDomainLabel() throws {
        let first = try companies.ensureCompany(forDomain: " @EXAMPLE.COM ")
        let second = try companies.ensureCompany(forDomain: "example.com")
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.name, "example.com")
        XCTAssertEqual(first.attendeeDomains, ["example.com"])
        XCTAssertEqual(try companies.fetchAll().count, 1)
    }

    func testEnsureCompanyReturnsArchivedRuleWithoutRecreatingOrRevivingIt() throws {
        var company = try savedCompany("Archived", domains: ["example.com"])
        company.isArchived = true
        try companies.save(company)
        let result = try companies.ensureCompany(forDomain: "EXAMPLE.COM")
        XCTAssertEqual(result.id, company.id)
        XCTAssertTrue(result.isArchived)
        XCTAssertTrue(try companies.fetchAll().isEmpty)
        XCTAssertEqual(try companies.fetchAll(includeArchived: true).count, 1)
    }

    func testEnsureCompanyDoesNotMergeNameCollisionIntoDifferentCompany() throws {
        let existing = try savedCompany("EXAMPLE.COM", domains: ["different.test"])
        _ = try savedCompany("example.com (2)", domains: ["another.test"])
        let result = try companies.ensureCompany(forDomain: "example.com")
        XCTAssertEqual(result.name, "example.com (3)")
        XCTAssertNotEqual(result.id, existing.id)
        XCTAssertEqual(try companies.fetch(id: existing.id)?.attendeeDomains, ["different.test"])
        XCTAssertEqual(try companies.ensureCompany(forDomain: "example.com").id, result.id)
    }

    func testDuplicateExistingDomainRulesRemainAmbiguousAndCreateNothing() throws {
        _ = try savedCompany("First", domains: ["example.com"])
        _ = try savedCompany("Second", domains: ["example.com"])
        XCTAssertThrowsError(try companies.ensureCompany(forDomain: "example.com")) { error in
            XCTAssertEqual(error as? MeetingCompanyRepositoryError, .ambiguousCompanyDomain)
        }
        XCTAssertEqual(try companies.fetchAll().count, 2)
    }

    func testConcurrentEnsureCallsCreateOneCompany() async throws {
        let repository = try XCTUnwrap(companies)
        let ids = try await withThrowingTaskGroup(of: UUID.self) { group in
            for _ in 0..<12 {
                group.addTask { try repository.ensureCompany(forDomain: "concurrent.test").id }
            }
            var ids = Set<UUID>()
            for try await id in group { ids.insert(id) }
            return ids
        }
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(try companies.fetchAll().count, 1)
    }

    func testProjectNamesAreUniquePerCompanyAndLegacyUnownedGroup() throws {
        let first = try savedCompany("First")
        let second = try savedCompany("Second")
        try projects.save(.init(name: "Renewals", companyID: first.id))
        try projects.save(.init(name: "Renewals", companyID: second.id))
        try projects.save(.init(name: "Renewals"))
        XCTAssertThrowsError(try projects.save(.init(name: "RENEWALS", companyID: first.id)))
        XCTAssertThrowsError(try projects.save(.init(name: "renewals")))
        XCTAssertEqual(try projects.fetchAll().count, 3)
    }

    func testCompanyAndProjectMembershipRemainConsistentWithoutChangingSource() throws {
        let first = try savedCompany("First")
        let second = try savedCompany("Second")
        let firstProject = try savedProject("First project", companyID: first.id)
        let secondProject = try savedProject("Second project", companyID: second.id)
        let legacy = try savedProject("Legacy", companyID: nil)
        let row = try savedMeeting()
        let before = try encoded(try XCTUnwrap(transcriptions.fetch(id: row.id)))
        try companies.assign(transcriptionIDs: [row.id], to: first.id)
        XCTAssertEqual(try companies.companyIDs(for: [row.id]), [row.id: first.id])
        XCTAssertEqual(try companies.transcriptionIDs(in: first.id), [row.id])
        try projects.assign(transcriptionIDs: [row.id], to: firstProject.id)
        try companies.assign(transcriptionIDs: [row.id], to: first.id)
        XCTAssertEqual(try projects.project(for: row.id)?.id, firstProject.id)
        try companies.assign(transcriptionIDs: [row.id], to: second.id)
        XCTAssertNil(try projects.project(for: row.id))
        XCTAssertEqual(try companies.company(for: row.id)?.id, second.id)
        try projects.assign(transcriptionIDs: [row.id], to: secondProject.id)
        try projects.assign(transcriptionIDs: [row.id], to: nil)
        XCTAssertNil(try projects.project(for: row.id))
        XCTAssertEqual(try companies.company(for: row.id)?.id, second.id, "Unfiling a project preserves company")
        try projects.assign(transcriptionIDs: [row.id], to: legacy.id)
        XCTAssertNil(try companies.company(for: row.id), "A legacy unowned project cannot retain an unrelated company")
        try companies.assign(transcriptionIDs: [row.id], to: nil)
        XCTAssertEqual(try projects.project(for: row.id)?.id, legacy.id)
        XCTAssertEqual(try encoded(try XCTUnwrap(transcriptions.fetch(id: row.id))), before)
    }

    func testCompanyBulkAssignmentValidatesEntireBatchBeforeChangingAnyMembership() throws {
        let first = try savedCompany("First")
        let second = try savedCompany("Second")
        let row = try savedMeeting()
        try companies.assign(transcriptionIDs: [row.id], to: first.id)
        XCTAssertThrowsError(try companies.assign(transcriptionIDs: [row.id, UUID()], to: second.id))
        XCTAssertEqual(try companies.company(for: row.id)?.id, first.id)
        XCTAssertThrowsError(try companies.assign(transcriptionIDs: [row.id], to: UUID()))
        XCTAssertEqual(try companies.company(for: row.id)?.id, first.id)
    }

    func testArchivedSelectionsFailButPreviouslyFrozenRecordingStillFinalizes() throws {
        var company = try savedCompany("Example")
        let project = try savedProject("Project", companyID: company.id)
        let recordingID = UUID()
        try preparations.saveRecordingAssociation(
            .init(
                recordingID: recordingID, companyID: company.id, projectID: project.id,
                titleSnapshot: "Exact", contextSnapshot: "Authored"))
        company.isArchived = true
        try companies.save(company)
        try projects.setArchived(id: project.id, isArchived: true)
        let row = try savedMeeting()
        XCTAssertThrowsError(try companies.assign(transcriptionIDs: [row.id], to: company.id))
        XCTAssertThrowsError(try projects.assign(transcriptionIDs: [row.id], to: project.id))
        XCTAssertThrowsError(try preparations.save(preparation(companyID: company.id, projectID: project.id)))
        XCTAssertThrowsError(
            try preparations.updateRecordingOrganization(
                recordingID: recordingID, companyID: company.id, projectID: project.id))
        try preparations.bindRecording(recordingID: recordingID, to: row.id)
        XCTAssertEqual(try companies.company(for: row.id)?.id, company.id)
        XCTAssertEqual(try projects.project(for: row.id)?.id, project.id)
    }

    func testDeletingProjectPreservesCompanyMembershipAndTranscript() throws {
        let company = try savedCompany("Example")
        let project = try savedProject("Project", companyID: company.id)
        let row = try savedMeeting()
        try projects.assign(transcriptionIDs: [row.id], to: project.id)
        XCTAssertTrue(try projects.delete(id: project.id))
        XCTAssertNil(try projects.project(for: row.id))
        XCTAssertEqual(try companies.company(for: row.id)?.id, company.id)
        XCTAssertEqual(try transcriptions.fetch(id: row.id)?.rawTranscript, row.rawTranscript)
    }

    func testMovingNonemptyProjectToAnotherCompanyIsRejected() throws {
        let first = try savedCompany("First")
        let second = try savedCompany("Second")
        var project = try savedProject("Project", companyID: first.id)
        let row = try savedMeeting()
        try projects.assign(transcriptionIDs: [row.id], to: project.id)
        project.companyID = second.id
        XCTAssertThrowsError(try projects.save(project)) { error in
            XCTAssertEqual(error as? MeetingCompanyRepositoryError, .projectCompanyChangeWithMeetings)
        }
        XCTAssertEqual(try projects.fetch(id: project.id)?.companyID, first.id)
        XCTAssertEqual(try companies.company(for: row.id)?.id, first.id)
        var empty = try savedProject("Empty", companyID: first.id)
        empty.companyID = second.id
        try projects.save(empty)
        XCTAssertEqual(try projects.fetch(id: empty.id)?.companyID, second.id)
    }

    func testProjectWithPreparationCannotChangeCompanyEvenBeforeRecording() throws {
        let first = try savedCompany("First")
        let second = try savedCompany("Second")
        var project = try savedProject("Project", companyID: first.id)
        try preparations.save(preparation(companyID: first.id, projectID: project.id))
        project.companyID = second.id
        XCTAssertThrowsError(try projects.save(project))
        XCTAssertEqual(try projects.fetch(id: project.id)?.companyID, first.id)
    }

    func testPreparationAndRecordingRejectMismatchedCompanyAndProject() throws {
        let first = try savedCompany("First")
        let second = try savedCompany("Second")
        let project = try savedProject("Project", companyID: first.id)
        let invalid = preparation(companyID: second.id, projectID: project.id)
        XCTAssertThrowsError(try preparations.save(invalid))
        XCTAssertNil(try preparations.fetch(key: invalid.key))
        XCTAssertThrowsError(
            try preparations.saveRecordingAssociation(
                .init(
                    recordingID: UUID(), companyID: second.id, projectID: project.id,
                    titleSnapshot: "Exact", contextSnapshot: "Authored")))
        XCTAssertThrowsError(try preparations.save(preparation(companyID: nil, projectID: project.id)))
    }

    func testCompanyOnlyRecordingBindsAndRepeatedFinalizationDoesNotUndoUserMove() throws {
        let first = try savedCompany("First")
        let second = try savedCompany("Second")
        let row = try savedMeeting()
        let recordingID = UUID()
        try preparations.saveRecordingAssociation(
            .init(recordingID: recordingID, companyID: first.id, titleSnapshot: "Exact", contextSnapshot: "Authored"))
        try preparations.bindRecording(recordingID: recordingID, to: row.id)
        XCTAssertEqual(try companies.company(for: row.id)?.id, first.id)
        XCTAssertNil(try projects.project(for: row.id))
        try companies.assign(transcriptionIDs: [row.id], to: second.id)
        try preparations.bindRecording(recordingID: recordingID, to: row.id)
        XCTAssertEqual(try companies.company(for: row.id)?.id, second.id)
    }

    func testExplicitRecordingOrganizationChangeUpdatesOnlyOrganizationAndMembership() throws {
        let first = try savedCompany("First")
        let second = try savedCompany("Second")
        let project = try savedProject("Project", companyID: second.id)
        let row = try savedMeeting()
        let recordingID = UUID()
        let association = RecordingMeetingAssociation(
            recordingID: recordingID, companyID: first.id, titleSnapshot: "  Exact — Event 🪴  ",
            contextSnapshot: "Authored context.", calendarID: "calendar", eventID: "event",
            scheduledStartAt: instant, scheduledEndAt: instant.addingTimeInterval(3_600),
            companyNameSnapshot: first.name, createdAt: instant)
        try preparations.saveRecordingAssociation(association)
        try preparations.bindRecording(recordingID: recordingID, to: row.id)
        let before = try encoded(try XCTUnwrap(transcriptions.fetch(id: row.id)))
        let updated = try preparations.updateRecordingOrganization(
            recordingID: recordingID, companyID: second.id, projectID: project.id)
        XCTAssertEqual(updated.companyID, second.id)
        XCTAssertEqual(updated.companyNameSnapshot, second.name)
        XCTAssertEqual(updated.projectID, project.id)
        XCTAssertEqual(updated.projectNameSnapshot, project.name)
        XCTAssertEqual(updated.titleSnapshot, association.titleSnapshot)
        XCTAssertEqual(updated.contextSnapshot, association.contextSnapshot)
        XCTAssertEqual(updated.scheduledStartAt, association.scheduledStartAt)
        XCTAssertEqual(updated.scheduledEndAt, association.scheduledEndAt)
        XCTAssertEqual(updated.createdAt, association.createdAt)
        XCTAssertEqual(try companies.company(for: row.id)?.id, second.id)
        XCTAssertEqual(try projects.project(for: row.id)?.id, project.id)
        XCTAssertEqual(try encoded(try XCTUnwrap(transcriptions.fetch(id: row.id))), before)
        XCTAssertThrowsError(
            try preparations.updateRecordingOrganization(
                recordingID: recordingID, companyID: first.id, projectID: project.id))
        XCTAssertEqual(try preparations.fetchRecordingAssociation(recordingID: recordingID)?.companyID, second.id)
        XCTAssertEqual(try companies.company(for: row.id)?.id, second.id)
    }

    func testExplicitOrganizationChangeBeforeBindingSetsFutureMembership() throws {
        let company = try savedCompany("Example")
        let recordingID = UUID()
        try preparations.saveRecordingAssociation(
            .init(recordingID: recordingID, titleSnapshot: "Exact", contextSnapshot: "Authored"))
        try preparations.updateRecordingOrganization(recordingID: recordingID, companyID: company.id, projectID: nil)
        let row = try savedMeeting()
        try preparations.bindRecording(recordingID: recordingID, to: row.id)
        XCTAssertEqual(try companies.company(for: row.id)?.id, company.id)
        let cleared = try preparations.updateRecordingOrganization(
            recordingID: recordingID, companyID: nil, projectID: nil)
        XCTAssertNil(cleared.companyID)
        XCTAssertNil(cleared.companyNameSnapshot)
        XCTAssertNil(try companies.company(for: row.id))
    }

    func testV53MigrationPreservesLegacyRowsWithoutAssigningCompany() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)
        let migrator = DatabaseManager.makeMigrator()
        try migrator.migrate(queue, upTo: "v0.52-evidence-first-meeting-minutes")
        let projectID = UUID()
        try queue.write { db in
            try db.execute(
                sql:
                    "INSERT INTO meeting_projects (id,name,sortOrder,isArchived,createdAt,updatedAt) VALUES (?,?,?,?,?,?)",
                arguments: [projectID, "Existing", 0, false, instant, instant])
        }
        let legacyPreparationID = UUID()
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meeting_preparations
                    (id,calendarID,eventID,context,titleSnapshot,createdAt,updatedAt)
                    VALUES (?,?,?,?,?,?,?)
                    """,
                arguments: [
                    legacyPreparationID, "calendar", "event", "Legacy authored agenda.", "Exact", instant, instant,
                ])
        }
        let sourceRepository = TranscriptionRepository(dbQueue: queue)
        let row = try savedMeeting(repository: sourceRepository)
        let legacyProjects = MeetingProjectRepository(dbQueue: queue)
        try legacyProjects.assign(transcriptionIDs: [row.id], to: nil)
        try queue.write { db in
            try TranscriptionProjectMembership(transcriptionID: row.id, projectID: projectID, assignedAt: instant)
                .insert(db)
        }
        let before = try encoded(try XCTUnwrap(sourceRepository.fetch(id: row.id)))
        try migrator.migrate(queue)
        XCTAssertNil(try legacyProjects.fetch(id: projectID)?.companyID)
        XCTAssertEqual(try legacyProjects.project(for: row.id)?.id, projectID)
        XCTAssertEqual(try encoded(try XCTUnwrap(sourceRepository.fetch(id: row.id))), before)
        let companyRepository = MeetingCompanyRepository(dbQueue: queue)
        XCTAssertTrue(try companyRepository.fetchAll(includeArchived: true).isEmpty)
        XCTAssertNil(try companyRepository.company(for: row.id))
        let migratedPreparation = try XCTUnwrap(
            MeetingPreparationRepository(dbQueue: queue).fetch(id: legacyPreparationID))
        XCTAssertNil(migratedPreparation.companyID)
        XCTAssertNil(migratedPreparation.companySelectionIsExplicit)
        XCTAssertEqual(migratedPreparation.context, "Legacy authored agenda.")
        XCTAssertEqual(try queue.read { db in try String.fetchOne(db, sql: "PRAGMA integrity_check") }, "ok")
    }

    func testLegacyJSONProjectPreparationAndAssociationDecodeWithNoCompany() throws {
        let project = MeetingProject(name: "Legacy", createdAt: instant, updatedAt: instant)
        let preparation = preparation(companyID: nil, projectID: project.id)
        let association = RecordingMeetingAssociation(
            recordingID: UUID(), projectID: project.id, titleSnapshot: "Exact", contextSnapshot: "Authored")
        XCTAssertNil(try decodeWithoutCompany(project, as: MeetingProject.self).companyID)
        let decodedPreparation = try decodeWithoutCompany(preparation, as: MeetingPreparation.self)
        XCTAssertNil(decodedPreparation.companyID)
        XCTAssertNil(decodedPreparation.companySelectionIsExplicit)
        let decoded = try decodeWithoutCompany(association, as: RecordingMeetingAssociation.self)
        XCTAssertNil(decoded.companyID)
        XCTAssertNil(decoded.companyNameSnapshot)
    }

    func testCorruptStoredCompanyRulesFailRatherThanInventingDefaults() throws {
        let company = try savedCompany("Existing", domains: ["example.com"])
        try manager.dbQueue.write { db in
            try db.execute(sql: "UPDATE meeting_companies SET attendeeDomains = ?", arguments: ["not-json"])
        }
        XCTAssertThrowsError(try companies.fetch(id: company.id))
        XCTAssertThrowsError(try companies.fetchAll())
        XCTAssertThrowsError(try companies.ensureCompany(forDomain: "other.test"))
    }

    func testNewNoCompanySelectionPersistsExplicitIntentWhileLegacyFlagCanRemainNil() throws {
        let explicit = try preparations.save(preparation(companyID: nil, projectID: nil))
        XCTAssertEqual(try preparations.fetch(id: explicit.id)?.companySelectionIsExplicit, true)
        var legacy = explicit
        legacy.companySelectionIsExplicit = nil
        try preparations.save(legacy)
        XCTAssertNil(try XCTUnwrap(preparations.fetch(id: explicit.id)).companySelectionIsExplicit)
        XCTAssertEqual(try preparations.fetch(id: explicit.id)?.context, explicit.context)
    }

    private func savedCompany(_ name: String, domains: [String] = []) throws -> MeetingCompany {
        let company = MeetingCompany(name: name, attendeeDomains: domains, createdAt: instant, updatedAt: instant)
        try companies.save(company)
        return company
    }

    private func savedProject(_ name: String, companyID: UUID?) throws -> MeetingProject {
        let project = MeetingProject(name: name, companyID: companyID, createdAt: instant, updatedAt: instant)
        try projects.save(project)
        return project
    }

    private func savedMeeting(repository: TranscriptionRepository? = nil) throws -> Transcription {
        var row = Transcription(
            createdAt: instant, fileName: "  Exact calendar title  ", filePath: "/synthetic/recording.m4a",
            rawTranscript: "Original transcript.", status: .completed, sourceType: .meeting, updatedAt: instant)
        row.userNotes = "Authored notes."
        try (repository ?? transcriptions!).save(row)
        return row
    }

    private func preparation(companyID: UUID?, projectID: UUID?) -> MeetingPreparation {
        MeetingPreparation(
            key: .init(calendarID: "calendar", eventID: "event"), context: "Authored preparation.",
            companyID: companyID, projectID: projectID, titleSnapshot: "Exact", createdAt: instant, updatedAt: instant)
    }

    private func encoded(_ row: Transcription) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(row)
    }

    private func decodeWithoutCompany<T: Codable>(_ value: T, as type: T.Type) throws -> T {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        object.removeValue(forKey: "companyID")
        object.removeValue(forKey: "companyNameSnapshot")
        object.removeValue(forKey: "companySelectionIsExplicit")
        return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }
}
