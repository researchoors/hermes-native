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

    /// Coalesce token-by-token auto-scroll: bucket the streaming tail so a full
    /// scroll pass fires per ~256 chars, not per delta (mirrors ChatView).
    private var streamTailKey: String {
        guard let last = chatViewModel.messages.last else { return "none" }
        return "\(last.id):\(last.content.count / 256):\(last.isStreaming)"
    }

    internal var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let msgs = chatViewModel.messages
                    ForEach(msgs) { message in
                        let showTimestamp = ChatView.isLastMessageInGroup(message: message, msgs: msgs)
                        let prepared = ChatView.prepareBubbleMessage(message, showTimestamp: showTimestamp)
                        skinProvider.messageBubble(message: prepared, persona: persona)
                            .id(message.id)
                    }

                    if chatViewModel.isStreaming {
                        // The conversational "typing" indicator — avatar state +
                        // current tool. The full activity trace lives in the
                        // flamechart / tools panels, so it isn't repeated here.
                        skinProvider.streamingPanel(
                            state: chatViewModel.avatarState,
                            activeToolCalls: chatViewModel.activeToolCalls,
                            personaName: persona.name,
                            accentColor: persona.accentColor
                        )
                        .id("conversation-streaming-status")
                    }

                    // Bottom anchor for auto-scroll.
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.background)
            .onChange(of: streamTailKey) { _, _ in scrollToBottom(proxy) }
            .onChange(of: chatViewModel.messages.count) { _, _ in scrollToBottom(proxy) }
            .onAppear { scrollToBottom(proxy, animated: false) }
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
}
