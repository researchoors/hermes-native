import Testing
import Foundation
@testable import HermesNative

@Suite("ChatViewModel multi-session switching")
struct ChatViewModelMultiSessionTests {
    @Test("events for an actively running session keep updating while another session is selected")
    @MainActor
    func runningSessionContinuesWhileAnotherSessionIsSelected() async {
        let vm = ChatViewModel()

        let first = vm.createLocalTestSession(id: "session-a")
        vm.applyTestEvent(.messageStart, sessionID: first)
        vm.applyTestEvent(.reasoningDelta(text: "thinking-a"), sessionID: first)
        vm.applyTestEvent(.toolStart(payload: ToolStartPayload(toolID: "tool-a", name: "read_file", context: "opening file")), sessionID: first)

        let second = vm.createLocalTestSession(id: "session-b")
        #expect(vm.currentSessionID == second)
        #expect(vm.messages.isEmpty)

        vm.applyTestEvent(.reasoningDelta(text: " still-thinking-a"), sessionID: first)
        vm.applyTestEvent(.toolComplete(payload: ToolCompletePayload(
            toolID: "tool-a",
            name: "read_file",
            summary: "read file complete",
            durationSeconds: 1.2,
            inlineDiff: nil,
            todos: nil
        )), sessionID: first)
        vm.applyTestEvent(.messageDelta(text: "answer-a", rendered: nil), sessionID: first)

        #expect(vm.currentSessionID == second)
        #expect(vm.messages.isEmpty)

        vm.switchToLocalTestSession(id: first)
        #expect(vm.currentSessionID == first)
        #expect(vm.isStreaming)
        #expect(vm.messages.count == 1)
        #expect(vm.messages[0].reasoning == "thinking-a still-thinking-a")
        #expect(vm.messages[0].content == "answer-a")
        #expect(vm.activeToolCalls.count == 1)
        #expect(vm.activeToolCalls["tool-a"]?.isComplete == true)
    }

    @Test("runtime state follows database ID after session.title mapping")
    @MainActor
    func runtimeStateSurvivesStableIDMapping() async {
        let vm = ChatViewModel()

        let runtimeID = vm.createLocalTestSession(id: "runtime-a")
        vm.applyTestEvent(.messageStart, sessionID: runtimeID)
        vm.applyTestEvent(.messageDelta(text: "partial-a", rendered: nil), sessionID: runtimeID)

        vm.bindRuntimeSession(displayID: "20260503_174500_runtimea", runtimeID: runtimeID)

        let other = vm.createLocalTestSession(id: "session-b")
        #expect(vm.currentSessionID == other)

        vm.switchToLocalTestSession(id: "20260503_174500_runtimea")
        #expect(vm.currentSessionID == runtimeID)
        #expect(vm.isStreaming)
        #expect(vm.messages.count == 1)
        #expect(vm.messages[0].content == "partial-a")
        #expect(vm.testCachedMessageCount == 1)
    }

    @Test("resume history does not overwrite an in-memory live stream")
    @MainActor
    func liveStreamSurvivesLaggingResumeHistory() async {
        let vm = ChatViewModel()

        let live = vm.createLocalTestSession(id: "session-a")
        vm.applyTestEvent(.messageStart, sessionID: live)
        vm.applyTestEvent(.messageDelta(text: "live-partial", rendered: nil), sessionID: live)
        vm.applyTestEvent(.toolStart(payload: ToolStartPayload(toolID: "tool-a", name: "terminal", context: "running")), sessionID: live)
        vm.bindRuntimeSession(displayID: "20260503_180000_live", runtimeID: live)

        // Simulate the resume path getting a non-empty persisted history while
        // the live tool turn is still in memory. The visible state must stay live.
        vm.simulateTestResumeResult(
            displayID: "20260503_180000_live",
            runtimeID: live,
            history: [ChatMessage(role: .user, content: "older prompt")]
        )

        vm.switchToLocalTestSession(id: "20260503_180000_live")
        #expect(vm.currentSessionID == live)
        #expect(vm.isStreaming)
        #expect(vm.messages.count == 1)
        #expect(vm.messages[0].role == .assistant)
        #expect(vm.messages[0].content == "live-partial")
        #expect(vm.activeToolCalls["tool-a"]?.name == "terminal")
    }

    @Test("completing a background running session preserves selected foreground session")
    @MainActor
    func backgroundCompletionDoesNotStealForegroundSelection() async {
        let vm = ChatViewModel()

        let first = vm.createLocalTestSession(id: "session-a")
        vm.applyTestEvent(.messageStart, sessionID: first)
        vm.applyTestEvent(.reasoningDelta(text: "reasoning"), sessionID: first)
        let second = vm.createLocalTestSession(id: "session-b")

        vm.applyTestEvent(.messageComplete(payload: MessageCompletePayload(
            text: "done-a",
            status: "complete",
            usage: nil,
            reasoning: "final reasoning",
            rendered: nil,
            warning: nil
        )), sessionID: first)

        #expect(vm.currentSessionID == second)
        #expect(vm.messages.isEmpty)

        vm.switchToLocalTestSession(id: first)
        #expect(vm.currentSessionID == first)
        #expect(!vm.isStreaming)
        #expect(vm.messages.count == 1)
        #expect(vm.messages[0].content == "done-a")
        #expect(vm.messages[0].status == "complete")
        #expect(vm.messages[0].reasoning == "final reasoning")
    }
}
