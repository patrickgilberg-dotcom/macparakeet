import SwiftUI
import MacParakeetCore

/// This connection is independent of the optional API providers below it.
struct ChatGPTConnectionView: View {
    @State private var accounts: [ChatGPTAccount] = []
    @State private var active: ChatGPTAccount?
    @State private var models: [ChatGPTModel] = []
    @State private var selectedModel = ""
    @State private var status: String?
    @State private var isError = false
    @State private var busy = false
    @State private var credentialApprovalNeeded = false
    @State private var operation: Task<Void, Never>?
    @AppStorage("livePreparationContext", store: AppPaths.sharedAppDefaults()) private var preparation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live meeting answers")
                .font(.headline)
            Text("Connect your ChatGPT plan for direct, streaming answers in the meeting Ask tab.")
                .foregroundStyle(.secondary)
            if let active {
                HStack {
                    Image(
                        systemName: active.planUsageEnabled
                            ? "checkmark.circle.fill" : "person.crop.circle.badge.exclamationmark"
                    )
                    .foregroundStyle(active.planUsageEnabled ? .green : .orange)
                    VStack(alignment: .leading) {
                        Text(active.label)
                        Text(active.planUsageEnabled ? "Using ChatGPT plan" : "ChatGPT plan usage is disabled")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if accounts.count > 1 {
                    Picker(
                        "Account",
                        selection: Binding(
                            get: { active.id },
                            set: { id in
                                perform {
                                    try await ChatGPTAuth.shared.selectAccount(id: id); await reload()
                                }
                            })
                    ) {
                        ForEach(accounts) { account in
                            Text("\(account.label) · \(account.clientID.suffix(6))").tag(account.id)
                        }
                    }
                    .disabled(busy)
                }
                if !models.isEmpty {
                    Picker(
                        "Answer model",
                        selection: Binding(
                            get: { selectedModel },
                            set: { model in
                                guard !model.isEmpty, model != selectedModel else { return }
                                selectedModel = model
                                // Persist only an explicit Picker edit. Reloads
                                // update local state without writing preferences.
                                perform {
                                    let previous = try await ChatGPTLiveClient.shared.selection()
                                    guard previous.model != model else { return }
                                    try await ChatGPTLiveClient.shared.selectModel(ChatGPTModelSelection(model: model))
                                }
                            })
                    ) {
                        ForEach(models) { Text($0.displayName).tag($0.slug) }
                    }
                    .disabled(busy)
                }
            }
            HStack {
                if credentialApprovalNeeded {
                    Button("Unlock ChatGPT connection") {
                        perform {
                            try await ChatGPTAuth.shared.unlockCredentialAccess()
                            await reload()
                        }
                    }
                    .parakeetAction(.primary)
                    .disabled(busy)
                }
                Button("Continue with ChatGPT") {
                    perform {
                        _ = try await ChatGPTAuth.shared.signIn(
                            accountID: active?.id, requestPlanConsent: active?.planUsageEnabled == false)
                        await reload()
                        status = "Connected. Test the connection to verify a completed answer."
                    }
                }
                .parakeetAction(.primary)
                .disabled(busy || credentialApprovalNeeded)
                if active != nil {
                    Button("Test connection") {
                        perform {
                            let selection = try await ChatGPTLiveClient.shared.selection()
                            let trial = await ChatGPTLiveBenchmark.trial(
                                model: selection.model,
                                effort: selection.reasoningEffort, condition: "settings-connection-test")
                            guard trial.completed, !trial.output.isEmpty else {
                                throw ChatGPTAuthError(
                                    "inference_failed", trial.error ?? "The answer did not complete.")
                            }
                            let firstText = trial.firstTextMs.map { "\(Int($0)) ms" } ?? "not observed"
                            let firstSentence = trial.firstSentenceMs.map { "\(Int($0)) ms" } ?? "not observed"
                            status = "Answer completed. First text \(firstText); first sentence \(firstSentence)."
                        }
                    }
                    .parakeetAction(.secondary)
                    .disabled(busy || !(active?.planUsageEnabled ?? false))
                    Button("Disconnect") {
                        perform {
                            defer { Task { await reload() } }
                            try await ChatGPTAuth.shared.disconnect()
                            status = "Disconnected."
                        }
                    }
                    .parakeetAction(.secondary)
                    .disabled(busy)
                }
                if busy {
                    ProgressView().controlSize(.small)
                    Button("Cancel") {
                        operation?.cancel()
                        Task { await ChatGPTAuth.shared.cancelSignIn() }
                    }
                    .parakeetAction(.secondary)
                }
            }
            HStack {
                Link("Manage usage", destination: ChatGPTAuth.usageURL)
                if active != nil {
                    Button("Add account") {
                        perform {
                            _ = try await ChatGPTAuth.shared.signIn(); await reload()
                        }
                    }
                    .buttonStyle(.link).disabled(busy)
                    Button("Refresh models") { perform { await reload(refresh: true) } }
                        .buttonStyle(.link).disabled(busy)
                }
            }
            if let status {
                Text(status).font(.caption)
                    .foregroundStyle(isError ? Color.orange : Color.secondary)
                    .textSelection(.enabled)
            }
            DisclosureGroup("Prepare meeting context") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        "Add relevant account facts, goals, and constraints before the call. Saved on this Mac and sent only with your live questions."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $preparation).frame(minHeight: 90)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                }
            }
            Text("Live answers use this connection. The optional providers below serve other AI features.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        .task { await reload() }
    }

    @MainActor private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        status = nil
        isError = false
        operation = Task { @MainActor in
            defer { busy = false; operation = nil }
            do { try await work() } catch is CancellationError { status = "Cancelled." } catch {
                status = error.localizedDescription; isError = true
            }
        }
    }

    @MainActor private func reload(refresh: Bool = false) async {
        let credentialStatus = await ChatGPTAuth.shared.credentialStatus()
        credentialApprovalNeeded = credentialStatus.needsKeychainApproval
        if let error = credentialStatus.accessError { status = error; isError = true }
        accounts = await ChatGPTAuth.shared.accounts()
        active = await ChatGPTAuth.shared.activeAccount()
        guard active?.planUsageEnabled == true else { models = []; selectedModel = ""; return }
        do {
            models = try await ChatGPTLiveClient.shared.models(refresh: refresh)
            selectedModel = try await ChatGPTLiveClient.shared.selection().model
        } catch { status = error.localizedDescription; isError = true }
    }
}
