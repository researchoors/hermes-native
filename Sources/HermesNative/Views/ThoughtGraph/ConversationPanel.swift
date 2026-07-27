import SwiftUI

/// The live chat conversation as a dashboard panel: the real transcript — the
/// same messages, streaming the same way — rendered inside a resizable canvas
/// panel instead of owning the whole screen. It is NOT a snapshot or a copy: it
/// observes the live `ChatViewModel`, so tokens stream in and bubbles grow here
/// exactly as they do in the normal chat.
///
/// It renders the dialogue and the "typing" indicator only. The flamechart,
/// tools, thinking, and skills each get their OWN canvas panels in Canvas mode,
/// so this panel deliberately omits the inline timeline / skills lens that the
/// normal transcript shows beside a streaming turn — no duplication.
///
/// Timer-free: it re-renders on `ChatViewModel` publishes (new/'grown messages,
/// streaming toggles), never on a clock, so it's safe to compose alongside the
/// singleton flamechart without adding to the canvas's timer cost.
internal struct ConversationPanel: View {
    @ObservedObject internal var chatViewModel: ChatViewModel
    /// The identity the chat presents (harness persona for Centaur, else the
    /// user's Hermes persona) — passed in so this panel doesn't re-derive it.
    internal let persona: Persona
    /// The active skin, resolved by the host so bubbles match the rest of chat.
    internal let skinProvider: ChatSkinProviding
    /// When set (Turns mode), render ONLY this turn's message(s) — the assistant
    /// message with this id and the user prompt that opened it — instead of the
    /// whole transcript. Nil (Scroll mode) shows the full ever-growing thread.
    internal var focusedTurnID: UUID?
    /// Solo mode: the conversation is the ONLY panel on the canvas (the default
    /// full-bleed chat). It then shows the inline live-activity strip (timeline +
    /// skills lens) beside a streaming turn, exactly like the classic transcript,
    /// so a bare canvas reads as today's chat. When any lens is peeled into its
    /// own panel the host turns this off and the strip drops (no duplication —
    /// the lens now has a dedicated panel).
    internal var soloMode: Bool = false
    /// Opens the full session graph from the inline strip's tap target. Only used
    /// in solo mode.
    internal var onExpandTimeline: (() -> Void)?

    /// Coalesce token-by-token auto-scroll: bucket the streaming tail so a full
    /// scroll pass fires per ~256 chars, not per delta (mirrors ChatView).
    private var streamTailKey: String {
        guard let last = chatViewModel.messages.last else { return "none" }
        return "\(last.id):\(last.content.count / 256):\(last.isStreaming)"
    }

    /// The messages to render: the whole transcript in Scroll mode, or just the
    /// focused turn's user+assistant pair in Turns mode. The turn is keyed by its
    /// assistant message id (see SessionTurnBuilder); the immediately preceding
    /// user message is its prompt.
    private var visibleMessages: [ChatMessage] {
        let all = chatViewModel.messages
        guard let focusedTurnID,
              let assistantIdx = all.firstIndex(where: { $0.id == focusedTurnID }) else {
            return all
        }
        var start = assistantIdx
        if assistantIdx > 0, all[assistantIdx - 1].role == .user { start = assistantIdx - 1 }
        return Array(all[start...assistantIdx])
    }

    /// Only follow the streaming tail / show the typing indicator when the
    /// conversation is actually showing the live turn — a pinned past turn is
    /// static, so it neither auto-scrolls nor sprouts a "typing" row.
    private var showsLiveTail: Bool {
        focusedTurnID == nil || focusedTurnID == chatViewModel.messages.last?.id
    }

    internal var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let msgs = visibleMessages
                    ForEach(msgs) { message in
                        let showTimestamp = ChatView.isLastMessageInGroup(message: message, msgs: msgs)
                        let prepared = ChatView.prepareBubbleMessage(message, showTimestamp: showTimestamp)
                        skinProvider.messageBubble(message: prepared, persona: persona)
                            .id(message.id)
                    }

                    if chatViewModel.isStreaming && showsLiveTail {
                        if soloMode {
                            // Solo: reproduce the classic transcript's inline
                            // activity — status + live timeline stacked, skills
                            // lens pinned right — so a bare canvas == today's chat.
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    skinProvider.streamingPanel(
                                        state: chatViewModel.avatarState,
                                        activeToolCalls: chatViewModel.activeToolCalls,
                                        personaName: persona.name,
                                        accentColor: persona.accentColor
                                    )
                                    .id("conversation-streaming-status")

                                    InlineTurnTimelineLive(
                                        chatViewModel: chatViewModel,
                                        subagentGraph: chatViewModel.subagentGraph,
                                        reasoningGraph: chatViewModel.reasoningGraph,
                                        onExpand: onExpandTimeline
                                    )
                                    .id("conversation-inline-timeline")
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                if !chatViewModel.activeSkills.isEmpty {
                                    TurnSkillsLens(skills: chatViewModel.activeSkills)
                                        .frame(width: 168)
                                        .id("conversation-turn-skills")
                                }
                            }
                            .transition(.opacity)
                        } else {
                            // Composed alongside dedicated lens panels — just the
                            // "typing" indicator; the trace lives in those panels.
                            skinProvider.streamingPanel(
                                state: chatViewModel.avatarState,
                                activeToolCalls: chatViewModel.activeToolCalls,
                                personaName: persona.name,
                                accentColor: persona.accentColor
                            )
                            .id("conversation-streaming-status")
                        }
                    }

                    // Bottom anchor for auto-scroll.
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.background)
            .onChange(of: streamTailKey) { _, _ in if showsLiveTail { scrollToBottom(proxy) } }
            .onChange(of: chatViewModel.messages.count) { _, _ in if showsLiveTail { scrollToBottom(proxy) } }
            .onChange(of: focusedTurnID) { _, _ in scrollToTop(proxy) }
            .onAppear { if showsLiveTail { scrollToBottom(proxy, animated: false) } }
        }
    }

    private static let bottomAnchor = "conversation-panel-bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let action = { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
        if animated {
            withAnimation(.easeOut(duration: 0.15), action)
        } else {
            action()
        }
    }

    /// Page to a newly-focused turn from its top, so a stepped-to turn reads from
    /// the prompt down rather than landing mid-reply. No-op when following the
    /// live tail (that path already pins to the bottom).
    private func scrollToTop(_ proxy: ScrollViewProxy) {
        guard !showsLiveTail, let firstID = visibleMessages.first?.id else { return }
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(firstID, anchor: .top) }
    }
}
