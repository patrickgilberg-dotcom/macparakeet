import Foundation
import MacParakeetCore
import Observation

@MainActor
@Observable
public final class LiveMeetingPreferencesViewModel {
    public var skillMarkdown = ""
    public var automaticMinutesEnabled = false
    public var answerStyleEnabled = true
    public var answerStyleInstructions = ""
    public var answerStyleExamples = ""
    public private(set) var savedState: LiveMeetingPreferencesState?
    public private(set) var isBusy = false
    public private(set) var errorMessage: String?
    public private(set) var statusMessage: String?
    public private(set) var canRecoverBackup = false

    @ObservationIgnored private let store: LiveMeetingPreferencesStore

    public init(store: LiveMeetingPreferencesStore = .shared) { self.store = store }

    public var isLoaded: Bool { savedState != nil }
    public var history: [LiveMeetingPreferencesVersion] { savedState?.history ?? [] }
    public var savedSkillRevision: String? { savedState?.current.preferences.skillRevision }
    public var hasUnsavedChanges: Bool {
        guard let savedState else { return false }
        return draft != savedState.current.preferences
    }
    public var validationMessage: String? {
        guard isLoaded else { return nil }
        do { try draft.validate(); return nil } catch { return error.localizedDescription }
    }
    public var canSave: Bool { isLoaded && !isBusy && hasUnsavedChanges && validationMessage == nil }

    public func loadIfNeeded() async {
        guard savedState == nil, !isBusy else { return }
        await reload()
    }

    public func reload() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do { apply(try await store.load()); statusMessage = nil } catch { record(error) }
    }

    public func save() async {
        guard canSave, let expected = savedState?.current.id else { return }
        let requested = draft
        isBusy = true
        defer { isBusy = false }
        do {
            let saved = try await store.save(requested, expectedVersionID: expected)
            apply(saved)
            statusMessage = "Saved. New tasks use this version."
        } catch { record(error) }
    }

    public func restoreDefaultSkill() async {
        guard !isBusy, isLoaded else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            skillMarkdown = try await store.defaultSkillMarkdown()
            errorMessage = nil
            statusMessage = "Default skill loaded into your draft. Save to use it. Other draft settings were kept."
        } catch { record(error) }
    }

    public func restore(versionID: UUID) async {
        guard !isBusy, let expected = savedState?.current.id else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            apply(try await store.restore(versionID: versionID, expectedVersionID: expected))
            statusMessage = "Previous settings restored as a new saved version."
        } catch { record(error) }
    }

    public func recoverBackup() async {
        guard !isBusy, canRecoverBackup else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            apply(try await store.recoverFromBackup())
            statusMessage = "Previous saved file recovered. The unreadable file was preserved on this Mac."
        } catch { record(error) }
    }

    public func useStarterStyle() {
        guard !isBusy, isLoaded else { return }
        answerStyleInstructions = LiveMeetingPreferences.starterStyleInstructions
        answerStyleExamples = ""
        statusMessage = "Editable starter loaded. Save to use it."
    }

    private var draft: LiveMeetingPreferences {
        .init(
            skillMarkdown: skillMarkdown, automaticMinutesEnabled: automaticMinutesEnabled,
            answerStyleEnabled: answerStyleEnabled, answerStyleInstructions: answerStyleInstructions,
            answerStyleExamples: answerStyleExamples)
    }

    private func apply(_ state: LiveMeetingPreferencesState) {
        savedState = state
        let preferences = state.current.preferences
        skillMarkdown = preferences.skillMarkdown
        automaticMinutesEnabled = preferences.automaticMinutesEnabled
        answerStyleEnabled = preferences.answerStyleEnabled
        answerStyleInstructions = preferences.answerStyleInstructions
        answerStyleExamples = preferences.answerStyleExamples
        errorMessage = nil
        canRecoverBackup = false
    }

    private func record(_ error: Error) {
        errorMessage = error.localizedDescription
        statusMessage = nil
        if case LiveMeetingPreferencesError.corruptFile(let available) = error {
            canRecoverBackup = available
        } else {
            canRecoverBackup = false
        }
    }
}
