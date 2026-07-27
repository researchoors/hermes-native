#if os(macOS)
import SwiftUI

/// Canvas mode for the live chat (option B): the current session rearranged into
/// resizable, draggable panels — the **conversation itself** as the dominant
/// panel, with the live lenses (flamechart, tools, thinking, skills, files)
/// docked around it. Toggled per session from the chat toolbar; flipping it off
/// returns to the normal full-width transcript. Non-destructive: it's the same
/// `ChatViewModel`, so the conversation streams here exactly as it does normally.
///
/// The message composer is docked at the BOTTOM, outside the canvas, so shrinking
/// or moving the conversation panel can never trap the user's input box.
///
/// Anti-beachball: one owned flamechart engine → the single 30 Hz timer (the
/// flamechart is a singleton kind). Every other panel — including the
/// conversation — is value-driven and re-renders only on data change, so the
/// live canvas costs exactly one timer, same as the normal chat's inline strip.
internal struct SessionChatCanvas: View {
    @ObservedObject internal var chatViewModel: ChatViewModel
    @ObservedObject internal var subagentGraph: SubagentGraphIntegrator
    @ObservedObject internal var reasoningGraph: ReasoningGraphIntegrator
    /// Chat identity + skin, resolved by the host so the conversation panel
    /// matches the rest of the app.
    internal let persona: Persona
    internal let skinProvider: ChatSkinProviding
    /// Composer focus wiring, owned by ChatView (so canvas clicks can restore
    /// first-responder just like the normal transcript).
    internal var isInputFocused: FocusState<Bool>.Binding
    @Binding internal var inputFieldRef: FocusableTextView?
    /// Leave Canvas mode (back to the normal transcript).
    internal let onExit: () -> Void

    @StateObject private var engine = ThoughtGraphLayoutEngine()
    @State private var layout = DashboardLayout()
    @State private var didLoadLayout = false
    @State private var showAddPalette = false
    @State private var canvasBounds: CGSize = .zero
    /// Cross-highlight shared between the flamechart, tools, and files panels.
    @State private var selectedNodeID: String?
    private let registry = PanelRegistry.chatCanvas

    /// The current turn's live nodes, composed from the active tool calls and
    /// the two graph integrators — the same composition the inline strip and the
    /// session-graph sheet use, so the canvas lenses agree with them.
    private var liveNodes: [ThoughtGraphNode] {
        ThoughtGraphLayoutEngine.composeTimeline(
            tools: Array(chatViewModel.activeToolCalls.values).sorted { $0.id < $1.id },
            agentNodes: subagentGraph.agentNodes,
            reasoningNodes: reasoningGraph.reasoningNodes
        )
    }

    private var liveContext: PanelContext {
        PanelContext(
            nodes: liveNodes,
            compactions: chatViewModel.currentTurnCompactions,
            skills: chatViewModel.activeSkills,
            isThinking: reasoningGraph.isThinking,
            isStreaming: chatViewModel.isStreaming,
            selection: $selectedNodeID,
            engine: engine,
            onJumpToTool: nil
        )
    }

    internal var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.border)
            GeometryReader { geo in
                DashboardCanvasView(
                    layout: $layout,
                    title: { registry.title(for: $0) },
                    icon: { registry.icon(for: $0) },
                    onLayoutCommitted: { layout.store(key: DashboardLayout.chatCanvasKey) },
                    content: { panel in panelContent(panel) }
                )
                .onAppear {
                    canvasBounds = geo.size
                    loadLayoutIfNeeded(bounds: geo.size)
                }
                .onChange(of: geo.size) { _, newSize in canvasBounds = newSize }
            }

            Divider().overlay(Theme.border)
            // Composer docked outside the canvas — always reachable.
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    /// Render a panel's content: the conversation is host-supplied (the live
    /// transcript); every other kind is built by the registry from the live
    /// context.
    private func panelContent(_ panel: DashboardPanel) -> AnyView {
        if panel.kind == .conversation {
            return AnyView(
                ConversationPanel(
                    chatViewModel: chatViewModel,
                    persona: persona,
                    skinProvider: skinProvider
                )
            )
        }
        return registry.content(for: panel.kind, context: liveContext)
    }

    // MARK: - Chrome

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button(action: onExit) {
                Label("Exit Canvas", systemImage: "rectangle.compress.vertical")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondary)
            .help("Back to the normal transcript")

            Text("drag the title bar to move · drag an edge or corner to resize")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .layoutPriority(-1)

            Spacer()

            Button {
                showAddPalette.toggle()
            } label: {
                Label("Add panel", systemImage: "plus.rectangle")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .popover(isPresented: $showAddPalette, arrowEdge: .bottom) { addPalette }

            Button {
                layout = DashboardLayout.seededChatCanvas(for: canvasBounds)
                layout.store(key: DashboardLayout.chatCanvasKey)
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.tertiary)
            .help("Reset to the default canvas layout")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Theme.surface.opacity(0.5))
    }

    private var addPalette: some View {
        let present = layout.panels.map(\.kind)
        let options = registry.addableDescriptors(present: present)
        return VStack(alignment: .leading, spacing: 2) {
            Text("Add a panel")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .padding(.bottom, 4)
            if options.isEmpty {
                Text("Every panel is already on the canvas.")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
            } else {
                ForEach(options) { descriptor in
                    Button {
                        addPanel(descriptor)
                        showAddPalette = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: descriptor.icon)
                                .frame(width: 16)
                                .foregroundStyle(Theme.accent)
                            Text(descriptor.title)
                                .foregroundStyle(Theme.primary)
                            Spacer()
                        }
                        .font(.system(size: 12))
                        .contentShape(Rectangle())
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(width: 200)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if chatViewModel.pendingApproval != nil {
                ApprovalBanner()
                    .environmentObject(chatViewModel)
                    .padding(.horizontal, 24)
            }
            if chatViewModel.pendingClarify != nil {
                ClarifyBanner()
                    .environmentObject(chatViewModel)
                    .padding(.horizontal, 24)
            }
            ChatInputBar(isFocused: isInputFocused, inputFieldRef: $inputFieldRef)
                .environmentObject(chatViewModel)
                .frame(maxWidth: 840, alignment: .center)
                .id(chatViewModel.currentSessionID ?? "no-session")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Theme.surface.opacity(0.4))
    }

    // MARK: - Layout lifecycle

    private func loadLayoutIfNeeded(bounds: CGSize) {
        guard !didLoadLayout else { return }
        didLoadLayout = true
        let loaded = DashboardLayout.loadStored(key: DashboardLayout.chatCanvasKey)
            ?? DashboardLayout.seededChatCanvas(for: bounds)
        layout = loaded.clamped(to: bounds)
    }

    private func addPanel(_ descriptor: PanelDescriptor) {
        let size = CGSize(
            width: min(360, max(DashboardPanel.minSize.width, canvasBounds.width * 0.4)),
            height: min(300, max(DashboardPanel.minSize.height, canvasBounds.height * 0.5))
        )
        let offset = CGFloat(layout.panels.count % 5) * 24
        let origin = CGPoint(
            x: max(0, (canvasBounds.width - size.width) / 2 + offset),
            y: max(0, (canvasBounds.height - size.height) / 2 + offset)
        )
        let panel = DashboardPanel(kind: descriptor.kind, frame: CGRect(origin: origin, size: size))
            .clamped(to: canvasBounds)
        layout.panels.append(panel)
        layout.store(key: DashboardLayout.chatCanvasKey)
    }
}
#endif
