import Foundation
import XCTest
@testable import MacParakeetCore

final class LiveMeetingPreferencesTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LiveMeetingPreferencesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func store(isLive: Bool = true) -> LiveMeetingPreferencesStore {
        .init(directoryURL: directory, defaultIsLive: isLive)
    }

    private func preferences(_ skill: String, style: String = "Synthetic style", examples: String = "")
        -> LiveMeetingPreferences
    {
        .init(
            skillMarkdown: skill, automaticMinutesEnabled: false, answerStyleEnabled: true,
            answerStyleInstructions: style, answerStyleExamples: examples)
    }

    func testBundledSkillHasGenericRulesTemplateWithoutPrivateExampleAndLiveOnlyAutomaticDefault() throws {
        let live = try LiveMeetingPreferences.defaults(isLive: true)
        XCTAssertEqual(live.skillMarkdown.utf8.count, 18_565)
        XCTAssertEqual(live.skillRevision, "f02e71ef1e993f138038ba21f823bfcd9419744afed88b539f6be65b1a0bf4a3")
        XCTAssertFalse(live.skillMarkdown.contains("# Worked Example Using the Supplied Meeting"))
        XCTAssertTrue(live.skillMarkdown.contains("# Output Template"))
        XCTAssertTrue(live.skillMarkdown.contains("# Final Quality Standard"))
        XCTAssertTrue(live.skillMarkdown.hasSuffix("\n"), "Preserve the original file's final newline")
        XCTAssertTrue(live.automaticMinutesEnabled)
        XCTAssertFalse(try LiveMeetingPreferences.defaults(isLive: false).automaticMinutesEnabled)
        XCTAssertTrue(live.answerStyleEnabled)
        XCTAssertEqual(live.answerStyleExamples, "", "Never invent examples of the user's writing")
        XCTAssertEqual(live.answerStyleInstructions, LiveMeetingPreferences.starterStyleInstructions)
    }

    func testPrivateImportedDefaultSeedsAndRestoresExactBytesWithoutEditingTheImport() async throws {
        let imported = "  # Private synthetic meeting skill 🦜\n\nWorked example: synthetic illustration only.\n"
        let url = directory.appendingPathComponent(LiveMeetingPreferencesStore.importedDefaultFileName)
        let bytes = Data(imported.utf8)
        try bytes.write(to: url)
        let store = store()
        XCTAssertEqual(store.importedDefaultURL, url)
        let initial = try await store.load()
        XCTAssertEqual(initial.current.preferences.skillMarkdown, imported)
        let edited = try await store.save(preferences("Edited skill"), expectedVersionID: initial.current.id)
        let restored = try await store.restoreDefaultSkill(expectedVersionID: edited.current.id)
        XCTAssertEqual(restored.current.preferences.skillMarkdown, imported)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testInvalidExistingPrivateImportNeverFallsBackOrOverwritesSavedSettings() async throws {
        let url = directory.appendingPathComponent("injected-private-default.md")
        let store = LiveMeetingPreferencesStore(directoryURL: directory, importedDefaultURL: url)
        for invalid in [
            Data([0xff]), Data(), Data(repeating: 0x61, count: LiveMeetingPreferences.maximumSkillBytes + 1),
        ] {
            try invalid.write(to: url)
            do {
                _ = try await store.load(); XCTFail("Invalid private import silently fell back")
            } catch LiveMeetingPreferencesError.importedSeedUnavailable {}
            XCTAssertEqual(try Data(contentsOf: url), invalid)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(LiveMeetingPreferencesStore.currentFileName).path))
        }
        try Data("Valid private synthetic skill".utf8).write(to: url)
        let initial = try await store.load()
        try Data([0xff]).write(to: url)
        do {
            _ = try await store.restoreDefaultSkill(); XCTFail("Invalid restore silently fell back")
        } catch LiveMeetingPreferencesError.importedSeedUnavailable {}
        let after = try await store.load()
        XCTAssertEqual(after, initial)
        XCTAssertEqual(try Data(contentsOf: url), Data([0xff]))
    }

    func testDanglingPrivateImportSymlinkIsInvalidInsteadOfMissing() async throws {
        let url = directory.appendingPathComponent(LiveMeetingPreferencesStore.importedDefaultFileName)
        try FileManager.default.createSymbolicLink(
            at: url, withDestinationURL: directory.appendingPathComponent("missing-private-source.md"))
        let store = store()
        do {
            _ = try await store.load(); XCTFail("Dangling private import silently fell back")
        } catch LiveMeetingPreferencesError.importedSeedUnavailable {}
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: url.path),
            directory.appendingPathComponent("missing-private-source.md").path)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(LiveMeetingPreferencesStore.currentFileName).path))
    }

    func testSnapshotsReloadExactlyAndPreviouslyReadValuesStayImmutable() async throws {
        let firstStore = store()
        let initial = try await firstStore.load()
        let edited = preferences("  # Exact skill 🦜\n\nDo not trim.\n", examples: "Synthetic example.")
        let saved = try await firstStore.save(edited, expectedVersionID: initial.current.id)
        let reloaded = try await store().load()
        XCTAssertEqual(reloaded, saved)
        XCTAssertEqual(reloaded.current.preferences, edited)
        XCTAssertNotEqual(initial.current.preferences.skillMarkdown, edited.skillMarkdown)
        XCTAssertEqual(saved.history.map(\.id), [initial.current.id])
        let styleOnly = preferences(edited.skillMarkdown, style: "Another style")
        XCTAssertEqual(
            styleOnly.skillRevision, edited.skillRevision, "The skill revision identifies exact skill content")
    }

    func testHistoryIsBoundedAndRestoreCreatesNewCurrentVersion() async throws {
        let store = store()
        var state = try await store.load()
        for index in 0..<(LiveMeetingPreferencesStore.maximumHistoryCount + 3) {
            state = try await store.save(preferences("Skill \(index)"), expectedVersionID: state.current.id)
        }
        XCTAssertEqual(state.history.count, LiveMeetingPreferencesStore.maximumHistoryCount)
        let target = try XCTUnwrap(state.history.last)
        let beforeRestore = state.current
        let restored = try await store.restore(versionID: target.id, expectedVersionID: beforeRestore.id)
        XCTAssertEqual(restored.current.preferences, target.preferences)
        XCTAssertNotEqual(restored.current.id, target.id)
        XCTAssertEqual(restored.current.reason, .restored)
        XCTAssertEqual(restored.history.first, beforeRestore)
        XCTAssertEqual(restored.history.count, LiveMeetingPreferencesStore.maximumHistoryCount)
    }

    func testRestoringDefaultSkillPreservesOtherSettingsAndTheirHistory() async throws {
        let store = store()
        let initial = try await store.load()
        let edited = preferences("Custom skill", style: "Keep this instruction", examples: "Synthetic writing.")
        let saved = try await store.save(edited, expectedVersionID: initial.current.id)
        let restored = try await store.restoreDefaultSkill(expectedVersionID: saved.current.id)
        XCTAssertEqual(restored.current.preferences.skillMarkdown, initial.current.preferences.skillMarkdown)
        XCTAssertFalse(restored.current.preferences.automaticMinutesEnabled)
        XCTAssertEqual(restored.current.preferences.answerStyleInstructions, edited.answerStyleInstructions)
        XCTAssertEqual(restored.current.preferences.answerStyleExamples, edited.answerStyleExamples)
        XCTAssertEqual(restored.history.first?.id, saved.current.id)
    }

    func testExpectedVersionRejectsAnotherStoreChangesWithoutLosingCurrent() async throws {
        let first = store()
        let second = store()
        let loaded = try await first.load()
        let newer = try await second.save(preferences("Newer skill"), expectedVersionID: loaded.current.id)
        do {
            _ = try await first.save(preferences("Stale draft"), expectedVersionID: loaded.current.id)
            XCTFail("A stale editor overwrote a newer version")
        } catch LiveMeetingPreferencesError.conflict {}
        let after = try await first.load()
        XCTAssertEqual(after, newer)
    }

    func testConcurrentStoresAdmitOnlyOneSaveFromTheSameLoadedVersion() async throws {
        let first = store()
        let second = store()
        let loaded = try await first.load()
        let firstDraft = preferences("First concurrent draft")
        let secondDraft = preferences("Second concurrent draft")
        let results = await withTaskGroup(of: (Bool, LiveMeetingPreferencesError?).self) { group in
            group.addTask {
                do {
                    _ = try await first.save(firstDraft, expectedVersionID: loaded.current.id); return (true, nil)
                } catch { return (false, error as? LiveMeetingPreferencesError) }
            }
            group.addTask {
                do {
                    _ = try await second.save(secondDraft, expectedVersionID: loaded.current.id); return (true, nil)
                } catch { return (false, error as? LiveMeetingPreferencesError) }
            }
            var values: [(Bool, LiveMeetingPreferencesError?)] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.filter { $0.0 }.count, 1)
        let rejected = try XCTUnwrap(results.first { !$0.0 })
        XCTAssertTrue(rejected.1 == .busy || rejected.1 == .conflict)
        let saved = try await first.load()
        XCTAssertTrue([firstDraft, secondDraft].contains(saved.current.preferences))
        XCTAssertEqual(saved.history.count, 1)
    }

    func testInvalidInputsDoNotChangeSavedVersion() async throws {
        let store = store()
        let initial = try await store.load()
        let invalid = [
            preferences(" \n"),
            preferences(String(repeating: "x", count: LiveMeetingPreferences.maximumSkillBytes + 1)),
            preferences(
                "Skill", style: String(repeating: "x", count: LiveMeetingPreferences.maximumStyleInstructionsBytes + 1)),
            preferences(
                "Skill", examples: String(repeating: "x", count: LiveMeetingPreferences.maximumStyleExamplesBytes + 1)),
            preferences(
                "Skill",
                style: String(repeating: "x", count: LiveMeetingPreferences.maximumStyleInstructionsCharacters + 1)),
            preferences(
                "Skill",
                examples: String(repeating: "x", count: LiveMeetingPreferences.maximumStyleExamplesCharacters + 1)),
            preferences("Skill", style: ""),
        ]
        for value in invalid {
            do { _ = try await store.save(value); XCTFail("Invalid settings were saved") } catch {}
        }
        let after = try await store.load()
        XCTAssertEqual(after, initial)
        try LiveMeetingPreferences(
            skillMarkdown: "Skill", answerStyleEnabled: false, answerStyleInstructions: "", answerStyleExamples: ""
        ).validate()
    }

    func testCorruptCurrentIsNotOverwrittenAndExplicitRecoveryPreservesItsBytes() async throws {
        let store = store()
        let initial = try await store.load()
        let previous = try await store.save(preferences("Previous valid skill"), expectedVersionID: initial.current.id)
        _ = try await store.save(preferences("Current skill"), expectedVersionID: previous.current.id)
        let currentURL = directory.appendingPathComponent(LiveMeetingPreferencesStore.currentFileName)
        let broken = Data("{broken user-edited settings".utf8)
        try broken.write(to: currentURL)
        do {
            _ = try await store.snapshot(); XCTFail("Corruption silently defaulted")
        } catch LiveMeetingPreferencesError.corruptFile(let recoveryAvailable) {
            XCTAssertTrue(recoveryAvailable)
        }
        do { _ = try await store.save(preferences("Must not overwrite")); XCTFail("Corruption was overwritten") } catch
        {}
        XCTAssertEqual(try Data(contentsOf: currentURL), broken)
        let recovered = try await store.recoverFromBackup()
        XCTAssertEqual(recovered.current.preferences, previous.current.preferences)
        XCTAssertEqual(recovered.current.reason, .recovered)
        let preserved = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("unreadable-preferences-") }
        XCTAssertEqual(preserved.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(preserved.first)), broken)
    }

    func testMissingCurrentWithBackupRequiresExplicitRecoveryInsteadOfDefaults() async throws {
        let store = store()
        _ = try await store.load()
        let currentURL = directory.appendingPathComponent(LiveMeetingPreferencesStore.currentFileName)
        try FileManager.default.removeItem(at: currentURL)
        do {
            _ = try await store.load(); XCTFail("Missing current silently reset")
        } catch LiveMeetingPreferencesError.corruptFile(let recoveryAvailable) {
            XCTAssertTrue(recoveryAvailable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentURL.path))
        _ = try await store.recoverFromBackup()
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentURL.path))
    }

    func testUnsupportedSchemaCannotBeOverwrittenOrDowngradedByBackupRecovery() async throws {
        let store = store()
        _ = try await store.load()
        let currentURL = directory.appendingPathComponent(LiveMeetingPreferencesStore.currentFileName)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: currentURL)) as? [String: Any])
        object["schemaVersion"] = 2
        object.removeValue(forKey: "current")
        let future = try JSONSerialization.data(withJSONObject: object)
        try future.write(to: currentURL)
        do {
            _ = try await store.save(preferences("Older app")); XCTFail("Future schema overwritten")
        } catch LiveMeetingPreferencesError.unsupportedSchema {}
        do {
            _ = try await store.recoverFromBackup(); XCTFail("Future schema downgraded")
        } catch LiveMeetingPreferencesError.unsupportedSchema {}
        XCTAssertEqual(try Data(contentsOf: currentURL), future)
    }

    func testFailedBackupWriteLeavesCurrentVersionAndHistoryUntouched() async throws {
        let store = store()
        let initial = try await store.load()
        let currentURL = directory.appendingPathComponent(LiveMeetingPreferencesStore.currentFileName)
        let original = try Data(contentsOf: currentURL)
        let backup = directory.appendingPathComponent(LiveMeetingPreferencesStore.backupFileName)
        try FileManager.default.removeItem(at: backup)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
        do {
            _ = try await store.save(preferences("Cannot persist")); XCTFail("Save hid its I/O failure")
        } catch LiveMeetingPreferencesError.storageUnavailable {}
        XCTAssertEqual(try Data(contentsOf: currentURL), original)
        let after = try await store.load()
        XCTAssertEqual(after, initial)
    }

    func testIdenticalSaveDoesNotChurnVersionHistory() async throws {
        let store = store()
        let initial = try await store.load()
        let same = try await store.save(initial.current.preferences, expectedVersionID: initial.current.id)
        XCTAssertEqual(same, initial)
    }
}
