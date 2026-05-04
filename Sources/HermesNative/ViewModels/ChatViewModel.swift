import Foundation
import Combine

/// Core chat ViewModel — manages conversation state and interacts with the gateway.
@MainActor
final class ChatViewModel: ObservableObject {

    // MARK: - App Formatting Prompt
    // Injected as ephemeral system prompt so the model uses mermaid diagrams
    // and rich markdown — matching the app's native rendering capabilities.

    static let appFormattingPrompt = """
    ## Response Formatting (HermesNative App)

    You are running inside a native app that renders rich markdown and Mermaid diagrams. Use these capabilities:

    - **Mermaid diagrams** for architecture, data flows, protocol sequences, call chains, state machines, component relationships, or any "how does X connect to Y" question. Use the appropriate type: flowchart, sequenceDiagram, graph, stateDiagram-v2, classDiagram. Wrap in ```mermaid blocks. One concept per diagram.
    - **Markdown headings** (##, ###) to structure longer responses
    - **Bold** for key terms, *italic* for emphasis
    - **Code blocks** with language tags (```python, ```swift, ```bash)
    - **Ordered/unordered lists** for steps and enumerations
    - **Blockquotes** for important callouts

    Prefer diagram-first: when a visual explanation is possible, lead with the Mermaid diagram, then explain in prose.
    """
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isStreaming: Bool = false
    @Published var isSessionReady: Bool = false
    @Published var currentModel: String = ""
    @Published var pendingApproval: ApprovalPayload?
    @Published var activeToolCalls: [String: ToolCallRecord] = [:] // tool_id → record
    @Published var error: String?
    @Published var avatarState: AvatarState = .idle
    @Published var sessionTitle: String = "New Chat"
    @Published private(set) var createGeneration: Int = 0

    private struct SessionRuntimeState {
        var messages: [ChatMessage] = []
        var isStreaming: Bool = false
        var isSessionReady: Bool = false
        var pendingApproval: ApprovalPayload?
        var activeToolCalls: [String: ToolCallRecord] = [:]
        var error: String?
        var avatarState: AvatarState = .idle
        var sessionTitle: String = "New Chat"
        var streamingMessageID: UUID?
    }

    private var gatewayClient: GatewayClient?
    private var sessionID: String?
    private var stableSessionByGatewayID: [String: String] = [:]
    private var gatewayIDByStableSession: [String: String] = [:]
    private var sessionStates: [String: SessionRuntimeState] = [:]
    private var streamingMessageID: UUID?
    private var cancellables = Set<AnyCancellable>()
    private var isCreatingSession = false  // Guard against double-trigger
    private var isStopping = false
    weak var personaManager: PersonaManager?

    // MARK: - Setup

    func setGatewayClient(_ client: GatewayClient) {
        // ContentView can wire the same app-level client repeatedly during
        // connect/session-create flows. Avoid stacking duplicate Combine
        // subscriptions, because every gateway event would otherwise be applied
        // N times and parallel sessions quickly corrupt local chat state.
        guard gatewayClient !== client else { return }

        cancellables.removeAll()
        gatewayClient = client

        // Subscribe to gateway events. Events are multiplexed over one app-level
        // WebSocket, so only apply events whose session_id matches this chat's
        // current session. Legacy/global events may have no session_id.
        client.eventStream
            .receive(on: RunLoop.main)
            .sink { [weak self] event, eventSessionID in
                self?.handleEvent(event, eventSessionID: eventSessionID)
            }
            .store(in: &cancellables)

        // Observe connection state
        client.$connectionState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                switch state {
                case .connected:
                    self?.error = nil
                case .reconnecting:
                    self?.error = nil  // Clear errors — reconnect in progress
                    self?.isStreaming = false
                    self?.avatarState = .thinking
                case .error(let msg):
                    self?.error = msg
                    self?.isSessionReady = false
                    self?.isStreaming = false
                    self?.avatarState = .error
                default:
                    break
                }
            }
            .store(in: &cancellables)

        // Observe session info
        client.$sessionInfo
            .receive(on: RunLoop.main)
            .sink { [weak self] info in
                if let info = info {
                    self?.currentModel = info.model
                }
            }
            .store(in: &cancellables)

        // Handle reconnection. Session creation is explicit from the Sessions UI;
        // reconnect should not implicitly create an invisible chat that races with
        // the New Session button and leaves the list empty on compact iOS.
        client.onReconnected = { [weak self] in
            guard let self else { return }
            // Sync persona
            if let pm = self.personaManager, let client = self.gatewayClient {
                await pm.syncFromGateway(client)
            }
            // If GatewayClient already resumed the session, use that session ID
            if let resumedID = self.gatewayClient?.activeSessionID, self.sessionID != resumedID {
                self.sessionID = resumedID
                self.createGeneration += 1
                self.isSessionReady = true
                self.error = nil
            }
        }
    }

    /// The session ID currently active in this chat view.
    var currentSessionID: String? { sessionID }

    private func displaySessionID(for runtimeID: String) -> String {
        stableSessionByGatewayID[runtimeID] ?? runtimeID
    }

    private func runtimeSessionID(for displayID: String) -> String {
        gatewayIDByStableSession[displayID] ?? displayID
    }

    /// Bind the stable database ID shown by the session list to the runtime
    /// gateway ID carried by live events. A newly-created session starts out
    /// keyed only by its short runtime ID, then `session.title` later resolves
    /// to a database ID. Without moving that cached runtime state, clicking
    /// away from a live turn and back via the database ID restores an empty
    /// history and makes the running session look like it disappeared.
    func bindRuntimeSession(displayID: String, runtimeID: String) {
        guard !displayID.isEmpty, !runtimeID.isEmpty else { return }
        stableSessionByGatewayID[runtimeID] = displayID
        gatewayIDByStableSession[displayID] = runtimeID

        if displayID != runtimeID, let runtimeState = sessionStates.removeValue(forKey: runtimeID) {
            if var displayState = sessionStates[displayID] {
                // Preserve any locally visible state that is newer/richer than
                // disk history, but prefer the live runtime stream fields.
                displayState.messages = runtimeState.messages
                displayState.isStreaming = runtimeState.isStreaming
                displayState.streamingMessageID = runtimeState.streamingMessageID
                displayState.pendingApproval = runtimeState.pendingApproval
                displayState.activeToolCalls = runtimeState.activeToolCalls
                displayState.avatarState = runtimeState.avatarState
                displayState.error = runtimeState.error
                sessionStates[displayID] = displayState
            } else {
                sessionStates[displayID] = runtimeState
            }
        }

        if sessionID == runtimeID {
            snapshotCurrentSessionState()
            if !messages.isEmpty {
                ChatHistoryStore.shared.saveMessages(messages, forSession: displayID)
            }
        }
    }

    private func snapshotCurrentSessionState() {
        guard let sessionID else { return }
        let displayID = displaySessionID(for: sessionID)
        sessionStates[displayID] = SessionRuntimeState(
            messages: messages,
            isStreaming: isStreaming,
            isSessionReady: isSessionReady,
            pendingApproval: pendingApproval,
            activeToolCalls: activeToolCalls,
            error: error,
            avatarState: avatarState,
            sessionTitle: sessionTitle,
            streamingMessageID: streamingMessageID
        )
    }

    private func restoreSessionState(displayID: String, runtimeID: String? = nil) -> Bool {
        guard let state = sessionStates[displayID] else { return false }
        sessionID = runtimeID ?? runtimeSessionID(for: displayID)
        messages = state.messages
        isStreaming = state.isStreaming
        isSessionReady = state.isSessionReady
        pendingApproval = state.pendingApproval
        activeToolCalls = state.activeToolCalls
        error = state.error
        avatarState = state.avatarState
        sessionTitle = state.sessionTitle
        streamingMessageID = state.streamingMessageID
        return true
    }

    private func mutateSessionState(for eventSessionID: String, _ mutation: (inout SessionRuntimeState) -> Void) {
        let displayID = displaySessionID(for: eventSessionID)
        var state = sessionStates[displayID] ?? SessionRuntimeState()
        mutation(&state)
        sessionStates[displayID] = state
        if sessionID == eventSessionID || displaySessionID(for: sessionID ?? "") == displayID {
            _ = restoreSessionState(displayID: displayID, runtimeID: eventSessionID)
        }
    }

    /// Create a new session on the gateway.
    func createSession() async {
        guard let client = gatewayClient else {
            self.error = "No gateway client"
            return
        }
        NSLog("[HermesNative] ChatViewModel createSession invoked state=\(client.connectionState)")
        guard !isCreatingSession else {
            NSLog("[HermesNative] ChatViewModel createSession ignored: already creating")
            return
        }
        isCreatingSession = true
        do {
            let sid = try await client.createSession()
            NSLog("[HermesNative] ChatViewModel createSession succeeded sid=\(sid)")
            snapshotCurrentSessionState()
            self.sessionID = sid
            self.createGeneration += 1
            self.isSessionReady = true
            self.messages = []
            self.activeToolCalls = [:]
            self.pendingApproval = nil
            self.streamingMessageID = nil
            self.isStreaming = false
            self.avatarState = .idle
            self.error = nil
            snapshotCurrentSessionState()

            await applyEphemeralPrompt(for: sid, using: client)
        } catch {
            self.error = "Session create failed: \(error.localizedDescription)"
        }
        isCreatingSession = false
    }

    /// Resume an existing session by key, replacing the currently visible chat state.
    /// Existing live state for the previously selected session is snapshotted first,
    /// so switching away from an active reasoning/tool turn does not discard it.
    func resumeSession(key: String) async {
        snapshotCurrentSessionState()

        guard let client = gatewayClient else {
            self.error = "No gateway client"
            return
        }
        guard case .connected = client.connectionState else {
            self.error = "Not connected to gateway"
            return
        }

        let cachedBeforeResume = sessionStates[key]

        do {
            let result = try await client.resumeSession(key: key)
            stableSessionByGatewayID[result.sessionID] = key
            gatewayIDByStableSession[key] = result.sessionID

            let parsedMessages = Self.parseHistoryMessages(result.messages)
            if !parsedMessages.isEmpty {
                if var liveState = sessionStates[key], liveState.isStreaming {
                    // The gateway history returned by session.resume is a persisted
                    // snapshot and can lag behind the currently running turn. Do not
                    // replace an in-memory live stream with non-streaming history when
                    // the user clicks away and back mid-tool-use; that is the exact
                    // path that made the live session appear to disappear.
                    if liveState.messages.isEmpty {
                        liveState.messages = parsedMessages
                    }
                    liveState.isSessionReady = true
                    sessionStates[key] = liveState
                } else {
                    sessionStates[key] = SessionRuntimeState(
                        messages: parsedMessages,
                        isStreaming: false,
                        isSessionReady: true,
                        sessionTitle: cachedBeforeResume?.sessionTitle ?? sessionTitle
                    )
                }
            } else if cachedBeforeResume == nil, let cachedMessages = ChatHistoryStore.shared.loadMessages(forSession: key) {
                sessionStates[key] = SessionRuntimeState(
                    messages: cachedMessages,
                    isStreaming: false,
                    isSessionReady: true
                )
            }

            if !restoreSessionState(displayID: key, runtimeID: result.sessionID) {
                self.sessionID = result.sessionID
                self.isSessionReady = true
                self.messages = []
                self.activeToolCalls = [:]
                self.pendingApproval = nil
                self.isStreaming = false
                self.streamingMessageID = nil
                self.avatarState = .idle
                self.error = nil
                snapshotCurrentSessionState()
            }

            await applyEphemeralPrompt(for: result.sessionID, using: client)
        } catch {
            self.error = "Session resume failed: \(error.localizedDescription)"
        }
    }

    private func applyEphemeralPrompt(for sessionID: String, using client: GatewayClient) async {
        var prompt = Self.appFormattingPrompt
        if let personaManager,
           !personaManager.usesAgentDefault,
           let personaSuffix = personaManager.activePersona.systemPromptSuffix,
           !personaSuffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "\n\n" + personaSuffix
        }
        try? await client.setEphemeralPrompt(sessionID: sessionID, prompt: prompt)
    }

    /// Load history for the current session (for reconnects where resume isn't used).
    func loadSessionHistory() async {
        guard let client = gatewayClient, let sid = sessionID else { return }
        do {
            let historyMessages = try await client.sessionHistory(sessionID: sid)
            let parsed = Self.parseHistoryMessages(historyMessages)
            if !parsed.isEmpty {
                self.messages = parsed
            }
        } catch {
            // Non-critical — show what we have
        }
    }

    /// Parse gateway history messages into ChatMessage array.
    /// Gateway format: {"role": "user"|"assistant"|"tool", "text": "...", "name": "...", "context": "..."}
    private static func parseHistoryMessages(_ rawMessages: [[String: AnyCodable]]) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        var currentToolCalls: [ToolCallRecord] = []

        for raw in rawMessages {
            guard let roleStr = raw["role"]?.stringValue else { continue }

            switch roleStr {
            case "user":
                let text = raw["text"]?.stringValue ?? ""
                guard !text.isEmpty else { continue }
                messages.append(ChatMessage(role: .user, content: text))

            case "assistant":
                // Flush any pending tool calls before this assistant message
                if !currentToolCalls.isEmpty {
                    if let lastIdx = messages.lastIndex(where: { $0.role == .assistant }) {
                        messages[lastIdx].toolCalls = currentToolCalls
                    }
                    currentToolCalls = []
                }

                let text = raw["text"]?.stringValue ?? ""
                guard !text.isEmpty else { continue }
                messages.append(ChatMessage(role: .assistant, content: text, status: "complete"))

            case "tool":
                let name = raw["name"]?.stringValue ?? "tool"
                let context = raw["context"]?.stringValue
                let toolID = "hist_\(messages.count)"
                currentToolCalls.append(ToolCallRecord(
                    id: toolID,
                    name: name,
                    context: context,
                    summary: context,
                    isComplete: true
                ))

            default:
                break
            }
        }

        // Flush remaining tool calls
        if !currentToolCalls.isEmpty {
            if let lastIdx = messages.lastIndex(where: { $0.role == .assistant }) {
                messages[lastIdx].toolCalls = currentToolCalls
            }
        }

        return messages
    }

    // MARK: - User Input

    /// Send the current input text as a prompt.
    func submitPrompt() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let client = gatewayClient, let sid = sessionID else { return }

        inputText = ""
        isStreaming = true

        // Add user message to conversation
        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)

        // Auto-title from first user message
        if messages.filter({ $0.role == .user }).count == 1 {
            sessionTitle = String(text.prefix(60))
        }

        // Persist user message immediately
        saveHistory()
        snapshotCurrentSessionState()

        // Prepare streaming assistant message
        let assistantMessage = ChatMessage(
            role: .assistant,
            content: "",
            isStreaming: true
        )
        streamingMessageID = assistantMessage.id
        messages.append(assistantMessage)
        snapshotCurrentSessionState()

        do {
            try await client.submitPrompt(sessionID: sid, text: text)
        } catch {
            self.error = error.localizedDescription
            finishStreaming(status: "error")
        }
    }

    /// Interrupt the current agent turn.
    func interrupt() async {
        guard !isStopping else { return }
        guard let client = gatewayClient, let sid = sessionID else {
            finishStreaming(status: "interrupted")
            return
        }

        isStopping = true
        defer { isStopping = false }

        // Update the UI immediately. On iOS this avoids the Stop button looking
        // dead while the gateway waits for the in-flight turn to unwind.
        finishStreaming(status: "interrupted")

        do {
            try await client.interrupt(sessionID: sid)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func finishStreaming(status: String? = nil) {
        if let msgID = streamingMessageID,
           let idx = messages.firstIndex(where: { $0.id == msgID }) {
            messages[idx].isStreaming = false
            if let status {
                messages[idx].status = status
            }
            if messages[idx].content.isEmpty && status == "interrupted" {
                messages[idx].content = "_Interrupted_"
            }
        }
        activeToolCalls = [:]
        isStreaming = false
        streamingMessageID = nil
        avatarState = .idle
        saveHistory()
    }

    /// Respond to a pending approval.
    func respondApproval(choice: String) async {
        guard let client = gatewayClient, let sid = sessionID else { return }
        pendingApproval = nil
        do {
            try await client.respondApproval(sessionID: sid, choice: choice)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Switch the model.
    func switchModel(_ model: String) async {
        guard let client = gatewayClient, let sid = sessionID else { return }
        do {
            try await client.setConfig(key: "model", value: model, sessionID: sid)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Local Persistence

    /// Save current messages to disk (debounced — only call at stable points).
    func saveHistory() {
        guard let sid = sessionID, !messages.isEmpty else { return }
        ChatHistoryStore.shared.saveMessages(messages, forSession: sid)
        let displayID = displaySessionID(for: sid)
        if displayID != sid {
            ChatHistoryStore.shared.saveMessages(messages, forSession: displayID)
        }
    }

    /// Load messages from local disk for a session (instant, no network).
    func loadLocalHistory(sessionID: String) {
        snapshotCurrentSessionState()
        if restoreSessionState(displayID: sessionID) {
            return
        }
        if let cached = ChatHistoryStore.shared.loadMessages(forSession: sessionID) {
            self.messages = cached
            self.sessionID = runtimeSessionID(for: sessionID)
            self.isSessionReady = true
            self.isStreaming = false
            self.streamingMessageID = nil
            self.activeToolCalls = [:]
            snapshotCurrentSessionState()
        }
    }

    /// Delete local history for a session.
    func deleteLocalHistory(sessionID: String) {
        ChatHistoryStore.shared.deleteMessages(forSession: sessionID)
        sessionStates.removeValue(forKey: sessionID)
    }

#if DEBUG
    @discardableResult
    func createLocalTestSession(id: String) -> String {
        snapshotCurrentSessionState()
        sessionID = id
        messages = []
        isStreaming = false
        isSessionReady = true
        pendingApproval = nil
        activeToolCalls = [:]
        error = nil
        avatarState = .idle
        sessionTitle = "New Chat"
        streamingMessageID = nil
        snapshotCurrentSessionState()
        return id
    }

    func switchToLocalTestSession(id: String) {
        snapshotCurrentSessionState()
        _ = restoreSessionState(displayID: id, runtimeID: runtimeSessionID(for: id))
    }

    var testCachedMessageCount: Int {
        guard let sessionID else { return 0 }
        return sessionStates[displaySessionID(for: sessionID)]?.messages.count ?? 0
    }

    func simulateTestResumeResult(displayID: String, runtimeID: String, history: [ChatMessage]) {
        stableSessionByGatewayID[runtimeID] = displayID
        gatewayIDByStableSession[displayID] = runtimeID
        if var liveState = sessionStates[displayID], liveState.isStreaming {
            if liveState.messages.isEmpty {
                liveState.messages = history
            }
            liveState.isSessionReady = true
            sessionStates[displayID] = liveState
        } else {
            sessionStates[displayID] = SessionRuntimeState(
                messages: history,
                isStreaming: false,
                isSessionReady: true
            )
        }
        _ = restoreSessionState(displayID: displayID, runtimeID: runtimeID)
    }

    func applyTestEvent(_ event: GatewayEvent, sessionID: String) {
        applySessionEvent(event, to: sessionID)
    }
#endif

    // MARK: - Event Handling

    private func shouldApplyGlobalEvent(_ event: GatewayEvent) -> Bool {
        switch event {
        case .gatewayReady, .backgroundComplete, .skinChanged, .voiceTranscript, .voiceStatus:
            return true
        default:
            return false
        }
    }

    private func applySessionEvent(_ event: GatewayEvent, to eventSessionID: String) {
        let displayID = displaySessionID(for: eventSessionID)
        var state = sessionStates[displayID] ?? SessionRuntimeState()

        if event.isLiveTurnEvent && !state.isStreaming {
            switch event {
            case .messageStart:
                break
            default:
                let reason = "late live-turn event after stream ended"
                NSLog("[HermesNative] ChatViewModel ignored late live event after stream ended: \(event.debugName)")
                gatewayClient?.recordDroppedEvent(event, sessionID: eventSessionID, reason: reason)
                return
            }
        }

        switch event {
        case .sessionInfo(let info):
            currentModel = info.model
            state.isSessionReady = true

        case .messageStart:
            state.isStreaming = true
            state.avatarState = .speaking
            if state.streamingMessageID == nil {
                let assistantMessage = ChatMessage(role: .assistant, content: "", isStreaming: true)
                state.streamingMessageID = assistantMessage.id
                state.messages.append(assistantMessage)
            }

        case .messageDelta(let text, _):
            if let msgID = state.streamingMessageID,
               let idx = state.messages.firstIndex(where: { $0.id == msgID }) {
                state.messages[idx].content += text
            }

        case .messageComplete(payload: let payload):
            guard let msgID = state.streamingMessageID,
                  let idx = state.messages.firstIndex(where: { $0.id == msgID }) else {
                state.activeToolCalls = [:]
                break
            }
            state.messages[idx].content = payload.text
            state.messages[idx].isStreaming = false
            state.messages[idx].usage = payload.usage
            state.messages[idx].status = payload.status
            state.messages[idx].reasoning = payload.reasoning
            state.messages[idx].toolCalls = Array(state.activeToolCalls.values)
            state.activeToolCalls = [:]
            state.isStreaming = false
            state.streamingMessageID = nil
            state.avatarState = .idle

        case .toolStart(payload: let payload):
            state.avatarState = .toolUse
            state.activeToolCalls[payload.toolID] = ToolCallRecord(
                id: payload.toolID,
                name: payload.name,
                context: payload.context
            )

        case .toolComplete(payload: let payload):
            if var record = state.activeToolCalls[payload.toolID] {
                record.summary = payload.summary
                record.durationSeconds = payload.durationSeconds
                record.inlineDiff = payload.inlineDiff
                record.isComplete = true
                state.activeToolCalls[payload.toolID] = record
            }

        case .toolProgress(let name, let preview):
            for (key, var record) in state.activeToolCalls where record.name == name && !record.isComplete {
                record.context = preview
                state.activeToolCalls[key] = record
            }

        case .reasoningDelta(let text):
            if state.avatarState != .toolUse { state.avatarState = .thinking }
            if let idx = state.messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                state.messages[idx].reasoning = (state.messages[idx].reasoning ?? "") + text
            }

        case .thinkingDelta(let text):
            if state.avatarState != .toolUse { state.avatarState = .thinking }
            if let idx = state.messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                let existing = state.messages[idx].reasoning ?? ""
                let separator = existing.isEmpty ? "" : "\n"
                state.messages[idx].reasoning = existing + separator + text
            }

        case .approvalRequest(payload: let payload):
            state.pendingApproval = payload

        case .error(let message):
            state.error = message
            state.isStreaming = false
            state.avatarState = .error

        case .statusUpdate, .toolGenerating, .reasoningAvailable,
             .gatewayReady, .skinChanged, .backgroundComplete,
             .clarifyRequest, .sudoRequest, .secretRequest,
             .voiceTranscript, .voiceStatus,
             .subagentSpawnRequested, .subagentStart, .subagentComplete,
             .subagentTool, .subagentProgress, .subagentThinking:
            break
        }

        sessionStates[displayID] = state
        if displaySessionID(for: sessionID ?? "") == displayID {
            _ = restoreSessionState(displayID: displayID, runtimeID: eventSessionID)
        }

        if case .messageComplete(let payload) = event {
            ChatHistoryStore.shared.saveMessages(state.messages, forSession: eventSessionID)
            if displayID != eventSessionID {
                ChatHistoryStore.shared.saveMessages(state.messages, forSession: displayID)
            }
            #if !DEBUG
            NotificationService.shared.notifyResponseComplete(
                sessionTitle: state.sessionTitle,
                preview: payload.text.truncated(to: 80),
                sessionID: eventSessionID
            )
            #endif
        } else if case .approvalRequest(let payload) = event {
            #if !DEBUG
            NotificationService.shared.notifyApproval(
                sessionTitle: state.sessionTitle,
                command: payload.command,
                sessionID: eventSessionID
            )
            #endif
        }
    }

    private func handleEvent(_ event: GatewayEvent, eventSessionID: String?) {
        if let eventSessionID, !eventSessionID.isEmpty {
            applySessionEvent(event, to: eventSessionID)
            return
        }

        guard shouldApplyGlobalEvent(event) || sessionID != nil else {
            return
        }

        switch event {
        case .gatewayReady:
            break

        case .sessionInfo(let info):
            currentModel = info.model
            isSessionReady = true

        case .messageStart:
            // Streaming begins — avatar is speaking
            guard isStreaming else { break }
            avatarState = .speaking

        case .messageDelta(let text, _):
            // Append streaming text to the current assistant message. Ignore
            // late deltas after an interrupt; the gateway can still drain one
            // in-flight turn after the UI has already stopped it locally.
            guard isStreaming else { break }
            if let msgID = streamingMessageID,
               let idx = messages.firstIndex(where: { $0.id == msgID }) {
                messages[idx].content += text
            }

        case .messageComplete(payload: let payload):
            // Finalize the assistant message. If the user already hit Stop,
            // `streamingMessageID` is nil; ignore the late completion so it
            // doesn't resurrect an interrupted turn in the UI.
            guard let msgID = streamingMessageID,
                  let idx = messages.firstIndex(where: { $0.id == msgID }) else {
                activeToolCalls = [:]
                return
            }

            messages[idx].content = payload.text
            messages[idx].isStreaming = false
            messages[idx].usage = payload.usage
            messages[idx].status = payload.status
            messages[idx].reasoning = payload.reasoning
            // Merge any accumulated tool calls into the message
            messages[idx].toolCalls = Array(activeToolCalls.values)

            activeToolCalls = [:]
            isStreaming = false
            streamingMessageID = nil
            avatarState = .idle

            // Persist to local storage after each completed response
            saveHistory()

            // Notify if app is backgrounded or this isn't the active session
            let preview = payload.text.truncated(to: 80)
            if let sid = sessionID {
                NotificationService.shared.notifyResponseComplete(
                    sessionTitle: sessionTitle,
                    preview: preview,
                    sessionID: sid
                )
            }

        case .toolStart(payload: let payload):
            guard isStreaming else { break }
            avatarState = .toolUse
            activeToolCalls[payload.toolID] = ToolCallRecord(
                id: payload.toolID,
                name: payload.name,
                context: payload.context
            )

        case .toolComplete(payload: let payload):
            guard isStreaming else { break }
            if var record = activeToolCalls[payload.toolID] {
                record.summary = payload.summary
                record.durationSeconds = payload.durationSeconds
                record.inlineDiff = payload.inlineDiff
                record.isComplete = true
                activeToolCalls[payload.toolID] = record
            }

        case .toolProgress(let name, let preview):
            guard isStreaming else { break }
            // Update matching tool call's progress display
            for (key, var record) in activeToolCalls where record.name == name && !record.isComplete {
                record.context = preview
                activeToolCalls[key] = record
            }

        case .toolGenerating:
            break

        case .reasoningDelta(let text):
            // Thinking/reasoning — avatar thinks
            guard isStreaming else { break }
            if avatarState != .toolUse { avatarState = .thinking }
            // Append to last assistant message's reasoning
            if let idx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                messages[idx].reasoning = (messages[idx].reasoning ?? "") + text
            }

        case .thinkingDelta(let text):
            // Thinking — avatar thinks (unless tool is running)
            guard isStreaming else { break }
            if avatarState != .toolUse { avatarState = .thinking }
            // Append to last assistant message's reasoning (thinking IS reasoning
            // from the model's perspective — e.g. GLM-5.1 fires thinking.delta
            // not reasoning.delta).  Show it live so the user sees progress.
            if let idx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                let existing = messages[idx].reasoning ?? ""
                // Add newline between chunks if we already have content and this
                // isn't a continuation (thinking deltas from the gateway spinner
                // are discrete status messages like "🤔 pondering...")
                let separator = existing.isEmpty ? "" : "\n"
                messages[idx].reasoning = existing + separator + text
            }

        case .reasoningAvailable:
            break

        case .approvalRequest(payload: let payload):
            pendingApproval = payload
            // Push notification so user sees it even if backgrounded/on another session
            if let sid = sessionID {
                NotificationService.shared.notifyApproval(
                    sessionTitle: sessionTitle,
                    command: payload.command,
                    sessionID: sid
                )
            }

        case .statusUpdate:
            break

        case .error(let message):
            self.error = message
            isStreaming = false
            avatarState = .error

        case .skinChanged:
            break

        case .subagentSpawnRequested, .subagentStart, .subagentComplete, .subagentTool, .subagentProgress, .subagentThinking:
            // Subagent delegation events — handled by SpawnTreeStore
            break

        case .backgroundComplete(let taskID, let text):
            NotificationService.shared.notifyBackgroundComplete(taskID: taskID, text: text)

        case .clarifyRequest(let question, _):
            if let sid = sessionID {
                NotificationService.shared.notifyClarify(
                    sessionTitle: sessionTitle,
                    question: question,
                    sessionID: sid
                )
            }

        case .sudoRequest:
            // TODO: Present sudo password dialog
            break

        case .secretRequest:
            // TODO: Present secret input dialog
            break

        case .voiceTranscript, .voiceStatus:
            break
        }
    }
}
