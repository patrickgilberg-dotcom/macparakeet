import Foundation
import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class LiveMeetingPreferencesViewModelTests: XCTestCase {
    private func fixture() -> (URL, LiveMeetingPreferencesStore, LiveMeetingPreferencesViewModel) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LiveMeetingPreferencesVMTests-\(UUID().uuidString)", isDirectory: true)
        let store = LiveMeetingPreferencesStore(directoryURL: directory, defaultIsLive: true)
        return (directory, store, LiveMeetingPreferencesViewModel(store: store))
    }

    func testLoadShowsSavedValuesWithoutManufacturingWritingExamples() async throws {
        let (directory, store, vm) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await vm.loadIfNeeded()
        XCTAssertTrue(vm.isLoaded)
        XCTAssertTrue(vm.automaticMinutesEnabled)
        XCTAssertTrue(vm.answerStyleEnabled)
        XCTAssertEqual(vm.answerStyleExamples, "")
        XCTAssertFalse(vm.hasUnsavedChanges)
        XCTAssertFalse(vm.canSave)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(vm.savedSkillRevision, snapshot.skillRevision)
    }

    func testEditingIsOnlyADraftUntilSaveCommitsAndUpdatesRevision() async throws {
        let (directory, store, vm) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await vm.loadIfNeeded()
        let original = try XCTUnwrap(vm.savedSkillRevision)
        vm.skillMarkdown = "# Custom synthetic skill"
        vm.automaticMinutesEnabled = false
        vm.answerStyleInstructions = "Use direct synthetic wording."
        XCTAssertTrue(vm.hasUnsavedChanges)
        XCTAssertTrue(vm.canSave)
        let beforeSave = try await store.snapshot()
        XCTAssertEqual(beforeSave.skillRevision, original)
        await vm.save()
        XCTAssertFalse(vm.hasUnsavedChanges)
        XCTAssertNil(vm.errorMessage)
        XCTAssertNotEqual(vm.savedSkillRevision, original)
        XCTAssertEqual(vm.history.count, 1)
        let saved = try await store.snapshot()
        XCTAssertEqual(saved.skillMarkdown, vm.skillMarkdown)
        XCTAssertFalse(saved.automaticMinutesEnabled)
    }

    func testConflictKeepsDraftAndSavedRevisionVisibleUntilExplicitReload() async throws {
        let (directory, store, vm) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await vm.loadIfNeeded()
        let original = try XCTUnwrap(vm.savedSkillRevision)
        _ = try await store.save(.init(skillMarkdown: "Newer external version"))
        vm.skillMarkdown = "Unsaved editor draft"
        await vm.save()
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(vm.skillMarkdown, "Unsaved editor draft")
        XCTAssertEqual(vm.savedSkillRevision, original)
        XCTAssertTrue(vm.hasUnsavedChanges)
        let external = try await store.snapshot()
        XCTAssertEqual(external.skillMarkdown, "Newer external version")
        await vm.reload()
        XCTAssertEqual(vm.skillMarkdown, "Newer external version")
        XCTAssertFalse(vm.hasUnsavedChanges)
    }

    func testRecoverUnreadableSettingsRequiresExplicitAction() async throws {
        let (directory, store, vm) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = try await store.load()
        let broken = Data("invalid settings".utf8)
        let current = directory.appendingPathComponent(LiveMeetingPreferencesStore.currentFileName)
        try broken.write(to: current)
        await vm.loadIfNeeded()
        XCTAssertFalse(vm.isLoaded)
        XCTAssertTrue(vm.canRecoverBackup)
        XCTAssertFalse(vm.canSave)
        XCTAssertEqual(try Data(contentsOf: current), broken)
        await vm.recoverBackup()
        XCTAssertTrue(vm.isLoaded)
        XCTAssertFalse(vm.canRecoverBackup)
        XCTAssertEqual(vm.skillMarkdown, initial.current.preferences.skillMarkdown)
        XCTAssertNotNil(vm.statusMessage)
    }

    func testRestoreAndStarterKeepHistoryAndRequireSavingNewDraftStyle() async throws {
        let (directory, store, vm) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await vm.loadIfNeeded()
        vm.skillMarkdown = "First saved skill"
        vm.answerStyleInstructions = "First saved style"
        await vm.save()
        let firstID = try XCTUnwrap(vm.savedState?.current.id)
        vm.skillMarkdown = "Second saved skill"
        await vm.save()
        await vm.restore(versionID: firstID)
        XCTAssertEqual(vm.skillMarkdown, "First saved skill")
        XCTAssertEqual(vm.answerStyleInstructions, "First saved style")
        vm.useStarterStyle()
        XCTAssertTrue(vm.hasUnsavedChanges)
        let beforeStarterSave = try await store.snapshot()
        XCTAssertEqual(beforeStarterSave.answerStyleInstructions, "First saved style")
        await vm.restoreDefaultSkill()
        XCTAssertEqual(vm.skillMarkdown, try LiveMeetingPreferences.defaultSkillMarkdown())
        XCTAssertEqual(vm.answerStyleInstructions, LiveMeetingPreferences.starterStyleInstructions)
        XCTAssertTrue(vm.hasUnsavedChanges)
        let afterDefaultDraft = try await store.snapshot()
        XCTAssertEqual(afterDefaultDraft.skillMarkdown, "First saved skill")
        XCTAssertEqual(afterDefaultDraft.answerStyleInstructions, "First saved style")
    }

    func testOversizeDraftShowsValidationAndCannotChangeSavedVersion() async throws {
        let (directory, store, vm) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await vm.loadIfNeeded()
        let initial = try await store.load()
        vm.answerStyleExamples = String(repeating: "x", count: LiveMeetingPreferences.maximumStyleExamplesBytes + 1)
        XCTAssertFalse(vm.canSave)
        XCTAssertNotNil(vm.validationMessage)
        await vm.save()
        let after = try await store.load()
        XCTAssertEqual(after, initial)
        XCTAssertTrue(vm.hasUnsavedChanges)
    }
}
