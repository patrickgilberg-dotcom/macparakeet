import Foundation
import MacParakeetCore
import OSLog

public struct ChatDisplayMessage: Identifiable, Equatable {
    public let id: UUID
    public let role: ChatMessage.Role
    public var content: String
    public let modelPromptOverride: String?
    public var isStreaming: Bool

    public init(
        id: UUID = UUID(),
        role: ChatMessage.Role,
        content: String,
        modelPromptOverride: String? = nil,
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.modelPromptOverride = modelPromptOverride
        self.isStreaming = isStreaming
    }
}

@MainActor
@Observable
public final class TranscriptChatViewModel {
    private static let storageUnavailableMessage = "Chat storage is unavailable. Please relaunch."

    public var messages: [ChatDisplayMessage] = []
    public var inputText: String = ""
    public var isStreaming: Bool = false
    public var errorMessage: String?
    public private(set) var liveChatPersistenceError: String?
    public var onConversationsChanged: ((UUID, Bool) -> Void)?
    public var onModelChanged: (() -> Void)?
    /// Local-only account/meeting facts prepared before the call. Sent only on an explicit Ask.
    public var livePreparationContext: String = ""
    public private(set) var liveAnswerTiming: LiveAnswerTiming?
    public private(set) var usesDirectLiveAnswers = false
    public private(set) var liveMeetingMemoryProgress: LiveMeetingMemoryProgress?
    public private(set) var lastLiveMeetingMemory: LiveMeetingMemorySnapshot?
    public private(set) var liveMeetingMemoryLastUpdated: Date?
    public private(set) var liveMeetingMemoryBackgroundError: String?
    public private(set) var liveProjectContextStatus: String?
    public private(set) var lastLiveProjectContext: LiveProjectMeetingSnapshot?
    private var eventPreparationContext = ""
    private var projectSourceProvider: (@Sendable () async throws -> LiveProjectMeetingSource?)?
    private var projectMeetingMemory = LiveProjectMeetingMemory()
    @ObservationIgnored nonisolated(unsafe) private var projectPrefetchTask: Task<Void, Never>?
    private var lastAnswerProjectScopeKey: String?
    private var projectConfigurationGeneration: UInt64 = 0
    private var liveHistoryStartIndex = 0
    private var liveChatRecordingID: UUID?
    private var liveChatCheckpoint: (@Sendable (MeetingLiveChatSnapshot) async throws -> Void)?
    private var liveChatCheckpointRevision: UInt64 = 0
    private var liveChatCheckpointGeneration: UInt64 = 0
    private var liveChatCreatedAt = Date()
    private var latestLiveChatSnapshot: MeetingLiveChatSnapshot?
    @ObservationIgnored private var liveChatCheckpointTask: Task<Void, Error>?
    public var liveAnswerGlobalShortcutAvailable = false
    public var liveAnswerGlobalShortcutIncludesControl = false
    public var liveAnswerGlobalShortcutLabel: String {
        liveAnswerGlobalShortcutIncludesControl ? "⌃⌥⌘Space" : "⌥⌘Space"
    }
    public var liveTranscriptHasEarlierGap = false

    // Multi-conversation state
    public var conversations: [ChatConversation] = []
    public var currentConversation: ChatConversation?
    /// Live/unsaved chats keep their UUID when promoted to a stored conversation.
    private var unsavedConversationID = UUID()
    public var showConversationPicker: Bool = false

    // Model selection state
    public var currentModelName: String = ""
    public var currentProviderID: LLMProviderID?
    public var availableModels: [String] = []

    private var llmService: LLMServiceProtocol?
    private var llmClient: LLMClientProtocol?
    private var configStore: LLMConfigStoreProtocol?
    private var cliConfigStore: LocalCLIConfigStore?
    private var transcriptionRepo: TranscriptionRepositoryProtocol?
    private var conversationRepo: ChatConversationRepositoryProtocol?
    private var transcriptionId: UUID?
    private var transcriptText: String = ""
    /// Identifies which chat surface this VM instance is driving — meeting
    /// Ask or post-transcription transcript chat — so `llm_chat_used`
    /// telemetry can separate the two. Defaults to `.transcriptChat`;
    /// `MeetingRecordingPanelViewModel` flips it via
    /// `markAsMeetingAskSurface()` at construction.
    private var chatSource: TelemetryChatSource = .transcriptChat
    /// Optional provider closure that returns the user's typed meeting notes
    /// at chat-send time. Returning nil/empty omits the notes block from the
    /// chat system prompt, leaving chat behavior byte-identical to a chat
    /// without notes. The closure shape (vs. a stored snapshot) lets the live
    /// in-meeting Ask path read the freshest keystroke without reactive
    /// plumbing — see `MeetingRecordingPanelViewModel` for the wiring.
    ///
    /// `@MainActor`-isolated rather than `@Sendable` because the closure is
    /// invoked from `sendMessage()` on the MainActor before the streaming
    /// task is detached, and typical implementations read MainActor-isolated
    /// state (e.g. `MeetingNotesViewModel.notesText`).
    private var userNotesProvider: (@MainActor () -> String?)?
    private var prepareLiveTranscript: (@MainActor () async throws -> Void)?
    private var focusSourceProvider: (@MainActor () -> LiveMeetingFocusSource?)?
    private var directLiveSessionProvider: (@Sendable () async throws -> LiveAnswerStreamSession)?
    private var liveAnswerPreferencesProvider: (@Sendable () async throws -> LiveMeetingPreferences)?
    private var liveMeetingMemory = LiveMeetingMemory()
    // Mutated only on MainActor; deinit only cancels the Sendable task handles.
    @ObservationIgnored nonisolated(unsafe) private var summaryTimerTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var backgroundSummaryTask: Task<Void, Never>?
    private var summaryGeneration: UInt64 = 0
    private var summaryUpdatesEnabled = false
    private var summaryRefreshInterval: Duration = .seconds(180)
    private var lastBackgroundSource: String?
    private var lastBackgroundFocusSource: LiveMeetingFocusSource?
    private var lastBackgroundCacheKey: String?
    private var chatHistory: [ChatMessage] = []
    private var streamingTask: Task<Void, Never>?
    private var modelListTask: Task<Void, Never>?
    private var displayedModelRoute: LLMModelSelectionRoute?
    private var streamingAssistantID: UUID?
    private let logger = Logger(subsystem: "com.macparakeet.viewmodels", category: "TranscriptChatViewModel")

    public var canSendMessage: Bool {
        llmService != nil || directLiveSessionProvider != nil
    }

    /// Read saved preferences for each explicit Ask; never include writing samples in summaries.
    public func configureLiveAnswerPreferences(
        _ provider: @escaping @Sendable () async throws -> LiveMeetingPreferences
    ) {
        liveAnswerPreferencesProvider = provider
    }

    /// The stream-only overload keeps injected local test providers simple.
    public func configureDirectLiveAnswers(
        prepareTranscript: @escaping @MainActor () async throws -> Void,
        stream: @escaping @Sendable ([ChatMessage]) -> AsyncThrowingStream<String, Error>,
        focusSourceProvider: (@MainActor () -> LiveMeetingFocusSource?)? = nil,
        summaryRefreshInterval: Duration = .seconds(180)
    ) {
        configureDirectLiveAnswers(
            prepareTranscript: prepareTranscript,
            sessionProvider: { LiveAnswerStreamSession(cacheKey: "injected-live-provider", stream: stream) },
            focusSourceProvider: focusSourceProvider,
            summaryRefreshInterval: summaryRefreshInterval)
    }

    /// One identity is pinned across each summary update and its eventual answer.
    public func configureDirectLiveAnswers(
        prepareTranscript: @escaping @MainActor () async throws -> Void,
        sessionProvider: @escaping @Sendable () async throws -> LiveAnswerStreamSession,
        focusSourceProvider: (@MainActor () -> LiveMeetingFocusSource?)? = nil,
        summaryRefreshInterval: Duration = .seconds(180)
    ) {
        cancelStreaming()
        stopLiveMeetingMemory()
        usesDirectLiveAnswers = true
        self.prepareLiveTranscript = prepareTranscript
        self.focusSourceProvider = focusSourceProvider
        directLiveSessionProvider = sessionProvider
        liveMeetingMemory = LiveMeetingMemory()
        lastLiveMeetingMemory = nil
        liveMeetingMemoryLastUpdated = nil
        liveMeetingMemoryBackgroundError = nil
        lastBackgroundSource = nil
        lastBackgroundFocusSource = nil
        lastBackgroundCacheKey = nil
        self.summaryRefreshInterval = summaryRefreshInterval
        resumeLiveMeetingMemory()
    }

    public func configureLiveProjectContext(
        eventPreparation: String,
        sourceProvider: (@Sendable () async throws -> LiveProjectMeetingSource?)? = nil
    ) {
        cancelStreaming()
        projectConfigurationGeneration &+= 1
        let generation = projectConfigurationGeneration
        let previousPrefetch = projectPrefetchTask
        previousPrefetch?.cancel()
        liveHistoryStartIndex = chatHistory.count
        lastAnswerProjectScopeKey = nil
        eventPreparationContext = eventPreparation
        projectSourceProvider = sourceProvider
        lastLiveProjectContext = nil
        liveProjectContextStatus = nil
        guard let sourceProvider, let sessionProvider = directLiveSessionProvider else { return }
        let memory = projectMeetingMemory
        projectPrefetchTask = Task { @MainActor [weak self] in
            do {
                await previousPrefetch?.value
                try Task.checkCancellation()
                guard let source = try await sourceProvider() else { return }
                try Task.checkCancellation()
                guard self?.projectConfigurationGeneration == generation else { return }
                self?.liveProjectContextStatus = "Preparing the latest project meeting…"
                let session = try await sessionProvider()
                try await memory.prefetch(source: source, session: session)
                try Task.checkCancellation()
                guard self?.projectConfigurationGeneration == generation else { return }
                self?.liveProjectContextStatus = "Project context checked."
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, self?.projectConfigurationGeneration == generation else { return }
                self?.liveProjectContextStatus = "Previous meeting context will retry when you ask."
            }
        }
    }

    public func resumeLiveMeetingMemory() {
        guard usesDirectLiveAnswers, directLiveSessionProvider != nil else { return }
        summaryUpdatesEnabled = true
        guard summaryTimerTask == nil else { return }
        let interval = summaryRefreshInterval
        summaryTimerTask = Task { @MainActor [weak self] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: interval)
                    try Task.checkCancellation()
                    guard let self, self.summaryUpdatesEnabled else { return }
                    self.beginBackgroundSummaryUpdate()
                }
            } catch is CancellationError {
                // Recording pause/stop owns timer cancellation.
            } catch {
                // Sleep has no other operational failure mode.
            }
        }
    }

    /// Capture pause, stop and panel teardown must explicitly end periodic work.
    public func stopLiveMeetingMemory() {
        summaryUpdatesEnabled = false
        summaryGeneration &+= 1
        summaryTimerTask?.cancel()
        summaryTimerTask = nil
        backgroundSummaryTask?.cancel()
        backgroundSummaryTask = nil
        projectPrefetchTask?.cancel()
        liveMeetingMemoryProgress = nil
    }

    private static let previewGapWarning =
        "[Earlier live-preview audio was missed; missing words were not reconstructed. The full recording is preserved for final transcription.]"

    private func meetingTranscriptSnapshot() -> String {
        guard liveTranscriptHasEarlierGap else { return transcriptText }
        let warning = Self.previewGapWarning
        return transcriptText.hasPrefix(warning) ? transcriptText : warning + "\n" + transcriptText
    }

    private func beginBackgroundSummaryUpdate() {
        guard summaryUpdatesEnabled, !isStreaming, backgroundSummaryTask == nil,
            let provider = directLiveSessionProvider
        else { return }
        guard !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let source = meetingTranscriptSnapshot()
        let focusSource = focusSourceProvider?()
        summaryGeneration &+= 1
        let generation = summaryGeneration
        let snapshotAt = Date()
        let memory = liveMeetingMemory
        backgroundSummaryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if summaryGeneration == generation {
                    backgroundSummaryTask = nil
                    liveMeetingMemoryProgress = nil
                }
            }
            do {
                let session = try await provider()
                try Task.checkCancellation()
                guard summaryUpdatesEnabled, summaryGeneration == generation, !isStreaming else { return }
                if source == lastBackgroundSource, focusSource == lastBackgroundFocusSource,
                    session.cacheKey == lastBackgroundCacheKey
                {
                    return
                }
                if lastBackgroundCacheKey != session.cacheKey { liveMeetingMemoryLastUpdated = nil }
                _ = try await memory.update(
                    transcript: source, cacheKey: session.cacheKey, focusSource: focusSource,
                    summarize: { messages in
                        var result = ""
                        for try await text in session.stream(messages: messages) {
                            try Task.checkCancellation()
                            result += text
                        }
                        try Task.checkCancellation()
                        return result
                    },
                    progress: { [weak self] progress in
                        guard let self else { return }
                        await self.publishBackgroundMemoryProgress(progress, generation: generation)
                    })
                try Task.checkCancellation()
                try await session.validate()
                guard summaryUpdatesEnabled, summaryGeneration == generation, !isStreaming else { return }
                // A live correction invalidates this old snapshot; never label it current.
                guard meetingTranscriptSnapshot().hasPrefix(source) else {
                    liveMeetingMemoryLastUpdated = nil
                    return
                }
                lastBackgroundSource = source
                lastBackgroundFocusSource = focusSource
                lastBackgroundCacheKey = session.cacheKey
                liveMeetingMemoryLastUpdated = snapshotAt
                liveMeetingMemoryBackgroundError = nil
                AudioCaptureDiagnostics.appendAsync("live_meeting_memory outcome=updated source_chars=\(source.count)")
            } catch is CancellationError {
                // Explicit Ask, pause and stop preempt background work.
            } catch LiveMeetingMemoryError.backgroundDeferred {
                // The foreground request owns the context builder.
            } catch {
                guard summaryUpdatesEnabled, summaryGeneration == generation else { return }
                liveMeetingMemoryBackgroundError =
                    "Your question retries required earlier context. The next summary update retries recent focus."
                AudioCaptureDiagnostics.appendAsync("live_meeting_memory outcome=failed")
            }
        }
    }

    private func publishBackgroundMemoryProgress(_ progress: LiveMeetingMemoryProgress, generation: UInt64) {
        guard summaryUpdatesEnabled, summaryGeneration == generation, !isStreaming else { return }
        liveMeetingMemoryProgress = progress
    }

    private func publishForegroundMemoryProgress(_ progress: LiveMeetingMemoryProgress, assistantID: UUID) {
        guard streamingAssistantID == assistantID else { return }
        liveMeetingMemoryProgress = progress
    }

    private func preemptBackgroundSummary() async {
        summaryGeneration &+= 1
        let generation = summaryGeneration
        let previous = backgroundSummaryTask
        let previousProject = projectPrefetchTask
        projectPrefetchTask = nil
        backgroundSummaryTask = nil
        liveMeetingMemoryProgress = nil
        previous?.cancel()
        previousProject?.cancel()
        await previous?.value
        await previousProject?.value
        if summaryGeneration == generation { liveMeetingMemoryProgress = nil }
    }

    public func helpMeAnswer(requestedAt: ContinuousClock.Instant = ContinuousClock.now) {
        guard canSendMessage else { return }
        cancelStreaming()
        inputText = "Help me answer this"
        sendMessage(
            richPrompt:
                "Help me answer the latest question the other person asked. Give me a concise, natural reply I can say aloud now.",
            requestedAt: requestedAt)
    }

    public var modelDisplayName: String {
        if usesDirectLiveAnswers { return "ChatGPT plan" }
        guard !currentModelName.isEmpty else { return "" }
        // Strip provider prefix for OpenRouter models (e.g. "anthropic/claude-sonnet-4.6" -> "claude-sonnet-4.6")
        if currentProviderID == .openrouter, let slashIndex = currentModelName.firstIndex(of: "/") {
            return String(currentModelName[currentModelName.index(after: slashIndex)...])
        }
        return currentModelName
    }

    public init() {}

    deinit {
        projectPrefetchTask?.cancel()
        summaryTimerTask?.cancel()
        backgroundSummaryTask?.cancel()
    }

    public func configure(
        llmService: LLMServiceProtocol?,
        transcriptText: String,
        transcriptionRepo: TranscriptionRepositoryProtocol? = nil,
        configStore: LLMConfigStoreProtocol? = nil,
        llmClient: LLMClientProtocol? = nil,
        conversationRepo: ChatConversationRepositoryProtocol? = nil,
        cliConfigStore: LocalCLIConfigStore = LocalCLIConfigStore()
    ) {
        self.llmService = llmService
        self.llmClient = llmClient
        self.transcriptText = transcriptText
        self.transcriptionRepo = transcriptionRepo
        self.configStore = configStore
        self.conversationRepo = conversationRepo
        self.cliConfigStore = cliConfigStore
        refreshModelInfo()
    }

    public func refreshModelInfo() {
        modelListTask?.cancel()
        let loadedRoute: LLMModelSelectionRoute?
        do {
            loadedRoute = try configStore?.loadRouteMetadata(for: .analysis)
        } catch {
            // A brief competing writer must not permanently disable the picker.
            // The conditional write still revalidates this retained snapshot.
            return
        }
        displayedModelRoute = nil
        guard let configStore, let route = loadedRoute else {
            currentModelName = ""
            currentProviderID = nil
            availableModels = []
            return
        }
        displayedModelRoute = route
        let config = route.config
        currentProviderID = config.id
        if config.id == .localCLI {
            let displayName =
                cliConfigStore
                .flatMap { $0.load() }
                .map { LocalCLITemplate.displayName(for: $0.commandTemplate) }
                ?? "Custom CLI"
            currentModelName = displayName
            availableModels = [displayName]
            return
        }

        currentModelName = config.modelName
        availableModels = LLMModelAvailability.pickerModels(for: config, discoveredModels: [])
        // Discovery needs credentials, but picker identity and writes never do.
        let discoveryConfig = try? configStore.loadConfig(for: .analysis)
        if let discoveryConfig,
            LLMModelSelectionRoute(config: discoveryConfig, isOverride: route.isOverride) == route
        {
            refreshAvailableModels(for: discoveryConfig)
        }
    }

    public var canSelectModel: Bool {
        !usesDirectLiveAnswers && configStore != nil && currentProviderID != nil
            && currentProviderID != .localCLI && currentProviderID != .appleIntelligence
            && !isStreaming
    }

    public func selectModel(_ modelName: String) {
        guard let configStore, canSelectModel else { return }
        do {
            guard let displayedModelRoute,
                try configStore.updateModelName(modelName, for: .analysis, expected: displayedModelRoute)
            else {
                refreshModelInfo()
                return
            }
            refreshModelInfo()
            onModelChanged?()
        } catch {
            refreshModelInfo()
        }
    }

    private func refreshAvailableModels(for config: LLMProviderConfig) {
        modelListTask = LLMModelAvailability.refreshPickerModelsTask(
            for: config,
            llmClient: llmClient,
            configStore: configStore,
            task: .analysis
        ) { [weak self] models in
            self?.availableModels = models
        }
    }

    /// Updates the LLM service reference (e.g., when provider config changes).
    /// Passes `nil` to disable chat when LLM is unconfigured.
    public func updateLLMService(_ service: LLMServiceProtocol?) {
        cancelStreaming()
        self.llmService = service
        refreshModelInfo()
    }

    /// - Parameter richPrompt: Optional expanded prompt sent to the LLM in place of
    ///   the visible `inputText`. Used by pills where the label is short ("Tell me
    ///   more") but the actual prompt deserves to be more comprehensive. The
    ///   user-visible bubble and persisted history both show `inputText`.
    public func sendMessage(richPrompt: String? = nil, requestedAt: ContinuousClock.Instant = ContinuousClock.now) {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming, canSendMessage else { return }
        let llmQuestion: String
        if let rich = richPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !rich.isEmpty {
            llmQuestion = rich
        } else {
            llmQuestion = text
        }

        // Live in-memory mode: no transcriptionId + no conversationRepo means we are
        // chatting against a not-yet-finalized transcript (e.g. an in-flight meeting).
        // Skip persistence; promote to a real ChatConversation later via
        // bindPersistedConversation(transcriptionId:transcriptionRepo:conversationRepo:).
        let isLiveInMemoryMode = (transcriptionId == nil && conversationRepo == nil)

        // Lazy conversation creation on first message (skipped in live in-memory mode)
        if currentConversation == nil && !isLiveInMemoryMode {
            guard let transcriptionId else {
                errorMessage = "Chat is unavailable until a transcript is loaded."
                return
            }
            guard let conversationRepo else {
                logger.error("Missing conversationRepo in sendMessage")
                errorMessage = Self.storageUnavailableMessage
                return
            }
            let title = String(text.prefix(50))
            let conversation = ChatConversation(
                id: unsavedConversationID, transcriptionId: transcriptionId, title: title)
            do {
                try conversationRepo.save(conversation)
                currentConversation = conversation
                conversations.insert(conversation, at: 0)
            } catch {
                logger.error("Failed to save new conversation error=\(error.localizedDescription, privacy: .public)")
                errorMessage = "Failed to create conversation"
                return
            }
        }

        inputText = ""
        errorMessage = nil

        let modelPromptOverride = llmQuestion == text ? nil : llmQuestion
        let userMessage = ChatDisplayMessage(role: .user, content: text, modelPromptOverride: modelPromptOverride)
        messages.append(userMessage)

        // Capture history BEFORE appending user message — buildChatMessages() adds question separately
        let historyForRequest = chatHistory
        chatHistory.append(ChatMessage(role: .user, content: text, modelPromptOverride: modelPromptOverride))
        persistChatMessages()

        startStreamingAssistant(question: llmQuestion, historyForRequest: historyForRequest, requestedAt: requestedAt)
    }

    /// Tail-only regenerate: drops the last completed assistant turn and re-issues
    /// the most recent user prompt against the same prior history. Mid-history
    /// regeneration would force a branching/forking model into a surface that's
    /// purposefully linear; we deliberately don't support it.
    public func regenerateLastResponse() {
        guard !isStreaming, canSendMessage else { return }
        guard let last = messages.last,
            last.role == .assistant,
            !last.isStreaming
        else { return }
        guard chatHistory.last?.role == .assistant else { return }

        // Pop the assistant turn from both the visible thread and persisted
        // history; commit the removal so a crash/restart wouldn't replay the
        // stale answer.
        messages.removeLast()
        chatHistory.removeLast()
        persistChatMessages()
        errorMessage = nil

        guard let trailingUser = chatHistory.last,
            trailingUser.role == .user,
            let visibleUser = messages.last,
            visibleUser.role == .user
        else { return }
        let userPrompt = trailingUser.modelPromptOverride ?? visibleUser.modelPromptOverride ?? trailingUser.content
        let historyForRequest = Array(chatHistory.dropLast())

        startStreamingAssistant(question: userPrompt, historyForRequest: historyForRequest)
    }

    /// Shared streaming kernel for both first-send and regenerate. Appends a
    /// streaming-state assistant turn, then runs the LLM stream with the same
    /// detach/cancel/error semantics in both code paths.
    private func startStreamingAssistant(
        question: String, historyForRequest: [ChatMessage],
        requestedAt: ContinuousClock.Instant = ContinuousClock.now
    ) {
        guard canSendMessage else { return }
        let llmService = llmService
        let directLiveSessionProvider = directLiveSessionProvider
        let prepareLiveTranscript = prepareLiveTranscript
        let requestStarted = requestedAt
        let projectGeneration = projectConfigurationGeneration
        let capturedProjectSourceProvider = projectSourceProvider
        let capturedEventPreparation = eventPreparationContext
        let capturedPreferencesProvider = liveAnswerPreferencesProvider
        if directLiveSessionProvider != nil { liveAnswerTiming = LiveAnswerTiming() }

        let assistantID = UUID()
        let assistantMessage = ChatDisplayMessage(id: assistantID, role: .assistant, content: "", isStreaming: true)
        messages.append(assistantMessage)
        isStreaming = true
        streamingAssistantID = assistantID

        // Saved transcript chat retains its established send-time snapshot.
        // Direct Live Ask re-reads only after its explicit freshness barrier.
        let capturedTranscript = transcriptText
        let capturedNotes = userNotesProvider?()

        // Capture context so the task can persist independently if detached (e.g. user clicks New Chat)
        let capturedConversationId = currentConversation?.id
        let requestConversationID = capturedConversationId ?? unsavedConversationID
        let capturedHistory = chatHistory
        let repo = conversationRepo
        let checkpointGeneration = liveChatCheckpointGeneration
        let admissionCheckpoint = enqueueLiveChatCheckpoint(chatHistory)

        streamingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var accumulated = ""
            var preparedMeetingMemory: LiveMeetingMemorySnapshot?
            var preparedProjectContext: LiveProjectMeetingSnapshot?
            var terminalCheckpointAttempted = false
            var coalescer = StreamingTextCoalescer(interval: .milliseconds(33))
            do {
                if let admissionCheckpoint {
                    do { try await admissionCheckpoint.value } catch {
                        liveChatPersistenceError =
                            "Your question could not be saved. No AI request was sent. Retry saving before trying again."
                        throw MeetingLiveChatPersistenceError.storageUnavailable
                    }
                    try Task.checkCancellation()
                    guard checkpointGeneration == liveChatCheckpointGeneration,
                        streamingAssistantID == assistantID
                    else { throw CancellationError() }
                    liveChatPersistenceError = nil
                }
                var liveSession: LiveAnswerStreamSession?
                if let directLiveSessionProvider {
                    await preemptBackgroundSummary()
                    try Task.checkCancellation()
                    guard projectConfigurationGeneration == projectGeneration else { return }
                    liveSession = try await directLiveSessionProvider()
                    try Task.checkCancellation()
                    guard streamingAssistantID == assistantID else { return }
                    if let previousKey = lastBackgroundCacheKey, previousKey != liveSession?.cacheKey {
                        liveMeetingMemoryLastUpdated = nil
                        lastBackgroundSource = nil
                        lastBackgroundFocusSource = nil
                        lastBackgroundCacheKey = nil
                    }
                    try Task.checkCancellation()
                    guard streamingAssistantID == assistantID else { return }
                    try await prepareLiveTranscript?()
                    try Task.checkCancellation()
                    guard streamingAssistantID == assistantID else { return }
                    liveAnswerTiming?.transcriptReadyMs = LiveAnswerTiming.milliseconds(
                        requestStarted.duration(to: .now))
                    liveAnswerTiming?.outcome = "streaming"
                }
                // Read after the audio barrier, so the pending end of the question is included.
                let transcript = directLiveSessionProvider == nil ? capturedTranscript : meetingTranscriptSnapshot()
                let focusSource = directLiveSessionProvider == nil ? nil : focusSourceProvider?()
                let userNotes = directLiveSessionProvider == nil ? capturedNotes : userNotesProvider?()
                let stream: AsyncThrowingStream<String, Error>
                if let session = liveSession {
                    let answerPreferences = try await capturedPreferencesProvider?()
                    try Task.checkCancellation()
                    let memory = liveMeetingMemory
                    let memorySnapshot = try await memory.prepare(
                        transcript: transcript, question: question, cacheKey: session.cacheKey,
                        focusSource: focusSource,
                        summarize: { messages in
                            var result = ""
                            for try await text in session.stream(messages: messages) {
                                try Task.checkCancellation()
                                result += text
                            }
                            try Task.checkCancellation()
                            return result
                        },
                        progress: { [weak self] progress in
                            guard let self else { return }
                            await self.publishForegroundMemoryProgress(progress, assistantID: assistantID)
                        })
                    try Task.checkCancellation()
                    guard streamingAssistantID == assistantID else { return }
                    try await session.validate()
                    guard streamingAssistantID == assistantID else { return }
                    liveMeetingMemoryProgress = nil
                    preparedMeetingMemory = memorySnapshot
                    liveAnswerTiming?.contextReadyMs = LiveAnswerTiming.milliseconds(
                        requestStarted.duration(to: .now))
                    if let sourceProvider = capturedProjectSourceProvider, let source = try await sourceProvider() {
                        try Task.checkCancellation()
                        guard projectConfigurationGeneration == projectGeneration else { return }
                        preparedProjectContext = try await projectMeetingMemory.prepare(
                            source: source, question: question, session: session)
                        try Task.checkCancellation()
                        let currentSource = try await sourceProvider()
                        guard currentSource?.scopeKey == preparedProjectContext?.scopeKey else {
                            throw LiveProjectContextChanged()
                        }
                    }
                    try Task.checkCancellation()
                    guard streamingAssistantID == assistantID,
                        projectConfigurationGeneration == projectGeneration
                    else { return }
                    liveAnswerTiming?.contextReadyMs = LiveAnswerTiming.milliseconds(requestStarted.duration(to: .now))
                    let projectScope = preparedProjectContext?.scopeKey
                    if projectScope != lastAnswerProjectScopeKey { liveHistoryStartIndex = historyForRequest.count }
                    let scopedHistory = Array(historyForRequest.dropFirst(liveHistoryStartIndex))
                    var contextMessages = LiveAnswerContext.messages(
                        question: question, context: memorySnapshot, notes: userNotes,
                        preparation: livePreparationContext, history: scopedHistory,
                        eventPreparation: capturedEventPreparation,
                        previousMeeting: preparedProjectContext?.quotedContext ?? "",
                        sourceLimitations: liveTranscriptHasEarlierGap ? Self.previewGapWarning : "")
                    if let answerPreferences {
                        contextMessages = LiveAnswerStyleContext.applying(
                            to: contextMessages, enabled: answerPreferences.answerStyleEnabled,
                            preferences: answerPreferences.answerStyleInstructions,
                            examples: answerPreferences.answerStyleExamples)
                    }
                    liveAnswerTiming?.requestStartedMs = LiveAnswerTiming.milliseconds(
                        requestStarted.duration(to: .now))
                    stream = session.stream(messages: contextMessages)
                } else if let llmService {
                    stream = llmService.chatStream(
                        question: question, transcript: transcript, userNotes: userNotes,
                        history: historyForRequest, source: chatSource, conversationID: requestConversationID
                    )
                } else {
                    return
                }
                for try await token in stream {
                    try Task.checkCancellation()
                    accumulated += token
                    if directLiveSessionProvider != nil, streamingAssistantID == assistantID {
                        let elapsed = LiveAnswerTiming.milliseconds(requestStarted.duration(to: .now))
                        if liveAnswerTiming?.firstTextMs == nil,
                            LiveAnswerTiming.containsMeaningfulText(accumulated)
                        {
                            liveAnswerTiming?.firstTextMs = elapsed
                        }
                        if liveAnswerTiming?.firstSentenceMs == nil, LiveAnswerTiming.containsSentence(accumulated) {
                            liveAnswerTiming?.firstSentenceMs = elapsed
                        }
                    }
                    // Keep every token in the authoritative response, but bound
                    // message-list/Markdown invalidation just as generated results do.
                    if coalescer.append(token, at: .now) != nil,
                        streamingAssistantID == assistantID,
                        let idx = messages.firstIndex(where: { $0.id == assistantID })
                    {
                        messages[idx].content = accumulated
                    }
                }

                if let liveSession { try await liveSession.validate() }
                if directLiveSessionProvider != nil {
                    try Task.checkCancellation()
                    guard projectConfigurationGeneration == projectGeneration else { throw CancellationError() }
                }
                if let preparedProjectContext, let sourceProvider = capturedProjectSourceProvider {
                    let currentSource = try await sourceProvider()
                    guard currentSource?.scopeKey == preparedProjectContext.scopeKey else {
                        throw LiveProjectContextChanged()
                    }
                }
                // Explicit cancellation (Stop button) — discard partial response
                guard !Task.isCancelled else {
                    if streamingAssistantID == assistantID {
                        removeStreamingAssistantMessage()
                        isStreaming = false
                    }
                    return
                }

                let assistantMsg = ChatMessage(role: .assistant, content: accumulated)

                if streamingAssistantID == assistantID {
                    if let checkpoint = enqueueLiveChatCheckpoint(chatHistory + [assistantMsg]) {
                        terminalCheckpointAttempted = true
                        do {
                            try await checkpoint.value
                            liveChatPersistenceError = nil
                        } catch {
                            // Cloud completion is still real. Keep the full
                            // answer in memory and expose local-save failure;
                            // Retry Saving must not repeat model inference.
                            liveChatPersistenceError =
                                "Answer completed, but its chat could not be saved. Keep the app open and retry saving."
                        }
                        try Task.checkCancellation()
                        guard checkpointGeneration == liveChatCheckpointGeneration,
                            streamingAssistantID == assistantID
                        else { throw CancellationError() }
                        if let liveSession { try await liveSession.validate() }
                        if let preparedProjectContext, let sourceProvider = capturedProjectSourceProvider {
                            let currentSource = try await sourceProvider()
                            guard currentSource?.scopeKey == preparedProjectContext.scopeKey,
                                projectGeneration == projectConfigurationGeneration
                            else { throw LiveProjectContextChanged() }
                        }
                    }
                    // Publish the complete response before marking it finished.
                    // Cancellation/failure still discard partial replies; detached
                    // conversations persist the full accumulated text below.
                    if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                        if messages[idx].content != accumulated {
                            messages[idx].content = accumulated
                        }
                        messages[idx].isStreaming = false
                    }
                    chatHistory.append(assistantMsg)
                    persistChatMessages()
                    streamingAssistantID = nil
                    isStreaming = false
                    if directLiveSessionProvider != nil {
                        lastLiveMeetingMemory = preparedMeetingMemory
                        lastLiveProjectContext = preparedProjectContext
                        lastAnswerProjectScopeKey = preparedProjectContext?.scopeKey
                        liveProjectContextStatus = preparedProjectContext?.statusLabel
                        liveMeetingMemoryProgress = nil
                        liveAnswerTiming?.completionMs = LiveAnswerTiming.milliseconds(
                            requestStarted.duration(to: .now))
                        liveAnswerTiming?.outcome = "completed"
                        recordLiveTiming()
                    }
                } else if let convId = capturedConversationId, !accumulated.isEmpty {
                    // Detached — user switched away. Persist directly to repo.
                    // Only write if the conversation hasn't been modified since detach,
                    // otherwise we'd overwrite newer messages (e.g. user navigated back and sent more).
                    let currentMessages = conversations.first(where: { $0.id == convId })?.messages
                    if currentMessages == nil || currentMessages == capturedHistory {
                        var updatedHistory = capturedHistory
                        updatedHistory.append(assistantMsg)
                        try? repo?.updateMessages(id: convId, messages: updatedHistory)
                        if let idx = conversations.firstIndex(where: { $0.id == convId }) {
                            conversations[idx].messages = updatedHistory
                            conversations[idx].updatedAt = Date()
                        }
                    }
                }
            } catch is CancellationError {
                if terminalCheckpointAttempted { await rollbackLiveChatCheckpoint(generation: checkpointGeneration) }
                // Cancellation is expected (Stop button, provider change) — don't surface as error
                if streamingAssistantID == assistantID {
                    removeStreamingAssistantMessage()
                    isStreaming = false
                    liveMeetingMemoryProgress = nil
                    liveAnswerTiming?.outcome = "cancelled"
                    recordLiveTiming()
                }
            } catch {
                if terminalCheckpointAttempted { await rollbackLiveChatCheckpoint(generation: checkpointGeneration) }
                if streamingAssistantID == assistantID {
                    if directLiveSessionProvider != nil, !accumulated.isEmpty,
                        let idx = messages.firstIndex(where: { $0.id == assistantID })
                    {
                        messages[idx].content = accumulated + "\n\n[Incomplete response]"
                        messages[idx].isStreaming = false
                        streamingAssistantID = nil
                    } else {
                        removeStreamingAssistantMessage()
                    }
                    isStreaming = false
                    errorMessage = error.localizedDescription
                    liveMeetingMemoryProgress = nil
                    liveAnswerTiming?.outcome = "failed"
                    recordLiveTiming()
                }
            }
        }
    }

    public func cancelStreaming() {
        streamingTask?.cancel()
        // A provider-completed assistant can still be awaiting its local save.
        // Queue cancellation's successful-history rollback synchronously, before
        // End can flush/stop/promote and before the canceled owner resumes.
        if latestLiveChatSnapshot?.messages != chatHistory {
            enqueueLiveChatCheckpoint(chatHistory)
        }
        streamingTask = nil
        isStreaming = false
        liveMeetingMemoryProgress = nil
        removeStreamingAssistantMessage()
        if liveAnswerTiming?.outcome == "streaming" || liveAnswerTiming?.outcome == "preparing" {
            liveAnswerTiming?.outcome = "cancelled"
            recordLiveTiming()
        }
    }

    /// The caller binds one recording before accepting live questions. The
    /// callback must write through an off-main serialized recording owner.
    public func configureLiveChatCheckpoint(
        recordingID: UUID,
        checkpoint: @escaping @Sendable (MeetingLiveChatSnapshot) async throws -> Void
    ) {
        liveChatCheckpointGeneration &+= 1
        liveChatCheckpointTask?.cancel()
        liveChatCheckpointTask = nil
        liveChatRecordingID = recordingID
        liveChatCheckpoint = checkpoint
        liveChatCheckpointRevision = 0
        latestLiveChatSnapshot = nil
        liveChatCreatedAt = Date()
        liveChatPersistenceError = nil
    }

    /// Retries only local saving, never provider inference. End must still stop
    /// audio on failure and retain the awaiting-transcription lock for retry.
    public func flushLiveChatCheckpoint() async throws {
        guard latestLiveChatSnapshot != nil else { return }
        let generation = liveChatCheckpointGeneration
        while let snapshot = latestLiveChatSnapshot, let checkpoint = liveChatCheckpoint {
            do {
                if let task = liveChatCheckpointTask {
                    do { try await task.value } catch {
                        if latestLiveChatSnapshot?.revision != snapshot.revision { continue }
                        try await checkpoint(snapshot)
                    }
                } else {
                    try await checkpoint(snapshot)
                }
                guard generation == liveChatCheckpointGeneration else {
                    throw MeetingLiveChatPersistenceError.recordingChanged
                }
                if latestLiveChatSnapshot?.revision != snapshot.revision { continue }
                liveChatPersistenceError = nil
                return
            } catch {
                guard generation == liveChatCheckpointGeneration else {
                    throw MeetingLiveChatPersistenceError.recordingChanged
                }
                liveChatPersistenceError = MeetingLiveChatPersistenceError.storageUnavailable.localizedDescription
                throw MeetingLiveChatPersistenceError.storageUnavailable
            }
        }
    }

    @discardableResult
    private func enqueueLiveChatCheckpoint(_ history: [ChatMessage]) -> Task<Void, Error>? {
        guard let recordingID = liveChatRecordingID, let checkpoint = liveChatCheckpoint else { return nil }
        liveChatCheckpointRevision &+= 1
        let snapshot = MeetingLiveChatSnapshot(
            recordingID: recordingID, conversationID: unsavedConversationID,
            revision: liveChatCheckpointRevision, messages: history, createdAt: liveChatCreatedAt)
        latestLiveChatSnapshot = snapshot
        let previous = liveChatCheckpointTask
        let task = Task {
            // A failed earlier write must not prevent saving a newer complete
            // snapshot. Revision checks also reject out-of-order late writers.
            _ = try? await previous?.value
            try Task.checkCancellation()
            try await checkpoint(snapshot)
        }
        liveChatCheckpointTask = task
        return task
    }

    private func rollbackLiveChatCheckpoint(generation: UInt64) async {
        guard generation == liveChatCheckpointGeneration,
            latestLiveChatSnapshot?.messages != chatHistory
        else { return }
        do { try await enqueueLiveChatCheckpoint(chatHistory)?.value } catch {
            liveChatPersistenceError = MeetingLiveChatPersistenceError.storageUnavailable.localizedDescription
        }
    }

    private func recordLiveTiming() {
        guard let timing = liveAnswerTiming else { return }
        func value(_ milliseconds: Double?) -> String {
            milliseconds.map { String(format: "%.1f", $0) } ?? "none"
        }
        AudioCaptureDiagnostics.appendAsync(
            "live_answer_timing request=\(timing.requestID.uuidString) outcome=\(timing.outcome) transcript_ready_ms=\(value(timing.transcriptReadyMs)) context_ready_ms=\(value(timing.contextReadyMs)) hotkey_to_request_ms=\(value(timing.requestStartedMs)) request_to_first_text_ms=\(value(timing.requestToFirstTextMs)) first_text_ms=\(value(timing.firstTextMs)) first_sentence_ms=\(value(timing.firstSentenceMs)) completion_ms=\(value(timing.completionMs))"
        )
    }

    public func updateTranscript(_ text: String) {
        transcriptText = text
        clearHistory()
    }

    /// Updates the transcript text without clearing chat history. Use during a live
    /// recording where the rolling transcript grows across many ticks; each new send
    /// should run against the latest text without losing prior turns.
    public func updateTranscriptText(_ text: String) {
        transcriptText = text
    }

    /// Wire a closure that returns the user's typed meeting notes at chat-send
    /// time. Pass `nil` to clear. Empty / whitespace-only return values are
    /// treated as "no notes" by the LLM service — chat behaves identically to
    /// a chat without notes when the closure has nothing to give.
    ///
    /// Two shapes of caller:
    /// - **Saved transcription detail page**: bind a closure that returns the
    ///   loaded `Transcription.userNotes`. It is effectively static for the
    ///   page's lifetime, but the closure pattern keeps the API uniform.
    /// - **Live in-meeting Ask**: bind a closure that reads the live
    ///   notepad's `notesText` at call time so chat sees every keystroke up
    ///   to the moment the user hits Send.
    public func bindUserNotesProvider(_ provider: (@MainActor () -> String?)?) {
        self.userNotesProvider = provider
    }

    /// Marks this VM as driving the live in-meeting Ask surface so
    /// `llm_chat_used` telemetry attributes the chat to `meeting_ask` rather
    /// than the default `transcript_chat`. Callable once at construction —
    /// `MeetingRecordingPanelViewModel.init()` flips this immediately and
    /// the VM keeps the meeting-Ask attribution for its entire lifetime,
    /// including post-meeting "Continue chat" persistence.
    public func markAsMeetingAskSurface() {
        // Contract: call once at construction, before any chat activity. A later
        // call would silently reclassify subsequent `llm_chat_used` telemetry.
        // Debug-only assert so misuse surfaces in tests/dev without ever crashing
        // a user's session over a telemetry-attribution slip.
        assert(
            chatSource == .transcriptChat && messages.isEmpty && chatHistory.isEmpty,
            "markAsMeetingAskSurface() must be called once at construction, before any messages are sent"
        )
        self.chatSource = .meetingAsk
    }

    /// Promotes an in-memory live chat (no transcriptionId, no conversationRepo)
    /// into a persisted `ChatConversation` linked to a finalized transcription.
    /// Call this once after `sendMessage()` was used in live in-memory mode and the
    /// recording has been transcribed and saved. Existing in-memory `chatHistory` is
    /// flushed to the new conversation in one repo write.
    @discardableResult
    public func bindPersistedConversation(
        transcriptionId: UUID,
        transcriptionRepo: TranscriptionRepositoryProtocol,
        conversationRepo: ChatConversationRepositoryProtocol
    ) -> Bool {
        self.transcriptionId = transcriptionId
        self.transcriptionRepo = transcriptionRepo
        self.conversationRepo = conversationRepo

        // Nothing to persist, or already bound to a conversation.
        guard !chatHistory.isEmpty, currentConversation == nil else {
            return true
        }

        let firstUser = chatHistory.first(where: { $0.role == .user })?.content ?? "Meeting chat"
        let title = String(firstUser.prefix(50))
        let conversation = ChatConversation(
            id: unsavedConversationID, transcriptionId: transcriptionId,
            title: title, messages: chatHistory)

        do {
            let stored = try conversationRepo.insertRecoveredIfAbsent(conversation)
            currentConversation = stored
            if let stored {
                conversations.insert(stored, at: 0)
                chatHistory = stored.messages ?? []
                messages = chatHistory.map {
                    ChatDisplayMessage(role: $0.role, content: $0.content, modelPromptOverride: $0.modelPromptOverride)
                }
            } else {
                chatHistory.removeAll()
                messages.removeAll()
            }
            liveChatCheckpointGeneration &+= 1
            liveChatCheckpoint = nil
            liveChatRecordingID = nil
            liveChatCheckpointTask = nil
            latestLiveChatSnapshot = nil
            liveChatPersistenceError = nil
            notifyConversationsChanged()
            return true
        } catch {
            logger.error("Failed to promote live chat error=\(error.localizedDescription, privacy: .public)")
            errorMessage = "Failed to save chat history."
            liveChatPersistenceError =
                "Chat could not be linked to the saved meeting. Its recovery checkpoint was kept; retry saving."
            return false
        }
    }

    public func loadTranscript(_ text: String, transcriptionId: UUID?) {
        cancelStreaming()
        self.transcriptText = text
        self.transcriptionId = transcriptionId
        self.streamingAssistantID = nil
        unsavedConversationID = UUID()

        guard let transcriptionId else {
            messages.removeAll()
            chatHistory.removeAll()
            conversations.removeAll()
            currentConversation = nil
            errorMessage = nil
            inputText = ""
            return
        }

        guard let conversationRepo else {
            logger.error("Missing conversationRepo in loadTranscript")
            messages.removeAll()
            chatHistory.removeAll()
            conversations.removeAll()
            currentConversation = nil
            errorMessage = Self.storageUnavailableMessage
            inputText = ""
            return
        }

        // Load conversations from repo
        do {
            try conversationRepo.deleteEmpty(transcriptionId: transcriptionId)
            conversations = try conversationRepo.fetchAll(transcriptionId: transcriptionId)
        } catch {
            logger.error("Failed to load conversations error=\(error.localizedDescription, privacy: .public)")
            conversations = []
        }

        if let mostRecent = conversations.first {
            loadConversationMessages(mostRecent)
        } else {
            messages.removeAll()
            chatHistory.removeAll()
            currentConversation = nil
        }

        errorMessage = nil
        inputText = ""

        notifyConversationsChanged()
    }

    // MARK: - Multi-Conversation

    public func newChat() {
        detachCurrentStreaming()
        discardEmptyCurrentConversation()

        messages.removeAll()
        chatHistory.removeAll()
        lastLiveMeetingMemory = nil
        lastLiveProjectContext = nil
        lastAnswerProjectScopeKey = nil
        liveHistoryStartIndex = 0
        errorMessage = nil
        inputText = ""
        currentConversation = nil
        unsavedConversationID = UUID()

        Telemetry.send(.chatConversationCreated)
        notifyConversationsChanged()
    }

    public func switchConversation(_ conversation: ChatConversation) {
        detachCurrentStreaming()
        discardEmptyCurrentConversation()

        loadConversationMessages(conversation)
        errorMessage = nil
        inputText = ""
    }

    public func deleteConversation(_ conversation: ChatConversation) {
        if currentConversation?.id == conversation.id {
            cancelStreaming()
        }

        guard let conversationRepo else {
            logger.error("Missing conversationRepo in deleteConversation")
            errorMessage = Self.storageUnavailableMessage
            return
        }

        do {
            _ = try conversationRepo.delete(id: conversation.id)
        } catch {
            logger.error("Failed to delete conversation error=\(error.localizedDescription, privacy: .public)")
            errorMessage = "Failed to delete conversation."
            return
        }

        conversations.removeAll { $0.id == conversation.id }

        if currentConversation?.id == conversation.id {
            if let next = conversations.first {
                loadConversationMessages(next)
            } else {
                messages.removeAll()
                chatHistory.removeAll()
                currentConversation = nil
                unsavedConversationID = UUID()
            }
            errorMessage = nil
            inputText = ""
        }

        notifyConversationsChanged()
    }

    /// Clears all conversations for the current transcript (used when retranscribing).
    public func clearHistory() {
        cancelStreaming()
        lastLiveMeetingMemory = nil
        lastLiveProjectContext = nil
        lastAnswerProjectScopeKey = nil
        liveHistoryStartIndex = 0

        // Delete all conversations for this transcript
        if let transcriptionId {
            guard let conversationRepo else {
                logger.error("Missing conversationRepo in clearHistory")
                errorMessage = Self.storageUnavailableMessage
                return
            }

            do {
                try conversationRepo.deleteAll(transcriptionId: transcriptionId)
            } catch {
                logger.error("Failed to clear conversations error=\(error.localizedDescription, privacy: .public)")
                errorMessage = "Failed to clear chat history."
                return
            }

            conversations.removeAll()
        }

        messages.removeAll()
        chatHistory.removeAll()
        errorMessage = nil
        inputText = ""
        currentConversation = nil
        unsavedConversationID = UUID()
        enqueueLiveChatCheckpoint([])

        notifyConversationsChanged()
    }

    // MARK: - Private

    /// Disowns the current streaming task without cancelling.
    /// The task continues in the background and persists to DB when done.
    private func detachCurrentStreaming() {
        // A live answer belongs to this visible question. Releasing it also
        // prevents the periodic worker competing with an invisible live stream.
        if usesDirectLiveAnswers {
            cancelStreaming()
            return
        }
        streamingTask = nil
        isStreaming = false
        removeStreamingAssistantMessage()
    }

    private func loadConversationMessages(_ conversation: ChatConversation) {
        lastLiveMeetingMemory = nil
        lastLiveProjectContext = nil
        lastAnswerProjectScopeKey = nil
        liveHistoryStartIndex = conversation.messages?.count ?? 0
        currentConversation = conversation
        if let chatMessages = conversation.messages, !chatMessages.isEmpty {
            messages = chatMessages.map { msg in
                ChatDisplayMessage(role: msg.role, content: msg.content, modelPromptOverride: msg.modelPromptOverride)
            }
            chatHistory = chatMessages
        } else {
            messages.removeAll()
            chatHistory.removeAll()
        }
    }

    private func discardEmptyCurrentConversation() {
        guard let current = currentConversation,
            current.messages == nil || current.messages?.isEmpty == true
        else { return }

        guard let conversationRepo else {
            logger.error("Missing conversationRepo in discardEmptyCurrentConversation")
            errorMessage = Self.storageUnavailableMessage
            return
        }

        do {
            _ = try conversationRepo.delete(id: current.id)
        } catch {
            logger.error("Failed to discard empty conversation error=\(error.localizedDescription, privacy: .public)")
            return
        }

        conversations.removeAll { $0.id == current.id }
    }

    private func persistChatMessages() {
        guard let currentConversation else { return }
        guard let conversationRepo else {
            logger.error("Missing conversationRepo in persistChatMessages")
            return
        }
        let toSave = chatHistory.isEmpty ? nil : chatHistory
        do {
            try conversationRepo.updateMessages(id: currentConversation.id, messages: toSave)
            // Update the local copy
            self.currentConversation?.messages = toSave
            if let idx = conversations.firstIndex(where: { $0.id == currentConversation.id }) {
                conversations[idx].messages = toSave
                conversations[idx].updatedAt = Date()
                // Move to front so most-recently-updated stays first
                if idx != 0 {
                    let updated = conversations.remove(at: idx)
                    conversations.insert(updated, at: 0)
                }
            }
        } catch {
            logger.error("Failed to persist chat messages error=\(error.localizedDescription, privacy: .public)")
        }
        notifyConversationsChanged()
    }

    private func notifyConversationsChanged() {
        guard let transcriptionId else { return }
        let hasConvs = !conversations.isEmpty
        onConversationsChanged?(transcriptionId, hasConvs)
    }

    private func removeStreamingAssistantMessage() {
        guard let streamingAssistantID else { return }
        if let idx = messages.firstIndex(where: { $0.id == streamingAssistantID }) {
            messages.remove(at: idx)
        }
        self.streamingAssistantID = nil
    }
}

private struct LiveProjectContextChanged: LocalizedError {
    var errorDescription: String? {
        "The latest project meeting changed while preparing this answer. Ask again to use its current context."
    }
}
