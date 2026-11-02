import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

struct LiveMeetingPreferencesView: View {
    @State private var viewModel = LiveMeetingPreferencesViewModel()
    @State private var showsPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Meeting skill & personal answer style")
                .font(.headline)
            Text("Saved on this Mac. Each task uses a fixed snapshot of your saved settings.")
                .font(.caption).foregroundStyle(.secondary)

            if viewModel.isLoaded {
                skillEditor
                Divider()
                styleEditor
                saveControls
                versionHistory
            } else if viewModel.isBusy {
                ProgressView("Loading saved settings…")
            }

            if let error = viewModel.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                HStack {
                    Button("Reload saved settings") { Task { await viewModel.reload() } }
                        .parakeetAction(.secondary).disabled(viewModel.isBusy)
                    if viewModel.canRecoverBackup {
                        Button("Recover previous saved file") { Task { await viewModel.recoverBackup() } }
                            .parakeetAction(.secondary).disabled(viewModel.isBusy)
                    }
                }
            }
            if let status = viewModel.statusMessage {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await viewModel.loadIfNeeded() }
    }

    private var skillEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Create minutes automatically after final transcription", isOn: $viewModel.automaticMinutesEnabled)
            Text(
                "When enabled, the completed transcript and this skill are sent through your connected ChatGPT plan to create minutes. Audio stays on this Mac."
            )
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Meeting skill (SKILL.md)").font(.subheadline.weight(.semibold))
                Spacer()
                Picker("Skill display", selection: $showsPreview) {
                    Text("Edit").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented).frame(width: 170)
            }
            Text(
                "Uses your private imported skill when available, otherwise the bundled evidence-first rules and template. Any worked example illustrates format and is never evidence about another meeting."
            )
            .font(.caption).foregroundStyle(.secondary)
            if showsPreview {
                ScrollView { MarkdownContentView(viewModel.skillMarkdown).padding(10) }
                    .frame(height: 300)
            } else {
                markdownEditor($viewModel.skillMarkdown, height: 300)
                    .accessibilityLabel("Meeting skill markdown")
            }
            HStack {
                byteCount(viewModel.skillMarkdown, maximum: LiveMeetingPreferences.maximumSkillBytes)
                Spacer()
                Button("Restore default skill") { Task { await viewModel.restoreDefaultSkill() } }
                    .parakeetAction(.secondary).disabled(viewModel.isBusy)
            }
        }
        .disabled(viewModel.isBusy)
    }

    private var styleEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Use my personal answer style for Ask", isOn: $viewModel.answerStyleEnabled)
            Text(
                "Enabled instructions and examples are sent only with Ask questions. They guide wording; meeting facts, evidence and uncertainty always take priority. This does not access your ChatGPT history or memory."
            )
            .font(.caption).foregroundStyle(.secondary)
            Text("Style instructions").font(.subheadline.weight(.semibold))
            Text("Editable starter: concise, direct plain language and clear action wording.")
                .font(.caption).foregroundStyle(.secondary)
            markdownEditor($viewModel.answerStyleInstructions, height: 95)
                .accessibilityLabel("Personal answer style instructions")
            byteCount(
                viewModel.answerStyleInstructions, maximum: LiveMeetingPreferences.maximumStyleInstructionsBytes)
            Text("Maximum \(LiveMeetingPreferences.maximumStyleInstructionsCharacters.formatted()) characters.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Your writing examples (optional)").font(.subheadline.weight(.semibold))
            Text(
                "Paste examples you want to emulate. They guide tone and format, not meeting facts. No examples are prefilled."
            )
            .font(.caption).foregroundStyle(.secondary)
            markdownEditor($viewModel.answerStyleExamples, height: 110)
                .accessibilityLabel("Personal writing examples")
            HStack {
                byteCount(viewModel.answerStyleExamples, maximum: LiveMeetingPreferences.maximumStyleExamplesBytes)
                Spacer()
                Button("Use editable starter") { viewModel.useStarterStyle() }
                    .parakeetAction(.secondary)
            }
            Text("Maximum \(LiveMeetingPreferences.maximumStyleExamplesCharacters.formatted()) characters.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(viewModel.isBusy)
    }

    private var saveControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Save meeting settings") { Task { await viewModel.save() } }
                    .parakeetAction(.primary).disabled(!viewModel.canSave)
                Button("Reload saved version") { Task { await viewModel.reload() } }
                    .parakeetAction(.secondary).disabled(viewModel.isBusy)
                if viewModel.isBusy { ProgressView().controlSize(.small) }
            }
            if let revision = viewModel.savedSkillRevision {
                Text("Saved skill revision: \(revision.prefix(12))")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Text(
                viewModel.hasUnsavedChanges ? "Unsaved draft. Save to use these changes." : "Showing the saved version."
            )
            .font(.caption).foregroundStyle(.secondary)
            if let message = viewModel.validationMessage {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var versionHistory: some View {
        DisclosureGroup("Previous saved versions (\(viewModel.history.count))") {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    "Restore brings back that version’s skill, automatic-minutes switch and answer style as a new saved version. Up to 12 previous versions are kept."
                )
                .font(.caption).foregroundStyle(.secondary)
                if viewModel.history.isEmpty {
                    Text("Previous versions appear after you save a change.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(viewModel.history) { version in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(version.savedAt, format: .dateTime.year().month().day().hour().minute().second())
                            Text("Skill \(version.preferences.skillRevision.prefix(12))")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore this version") { Task { await viewModel.restore(versionID: version.id) } }
                            .parakeetAction(.secondary).disabled(viewModel.isBusy)
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    private func markdownEditor(_ binding: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: binding)
            .font(.system(size: 12, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: height)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }

    private func byteCount(_ value: String, maximum: Int) -> some View {
        Text("\(value.utf8.count.formatted()) / \(maximum.formatted()) bytes")
            .font(.caption).foregroundStyle(value.utf8.count > maximum ? .orange : .secondary)
    }
}
