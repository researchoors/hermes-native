import SwiftUI
import os

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "MeetSessionView")

/// Live Google Meet session view — transcript feed, diagram viewer, controls.
/// Connects to the GMeet pipeline's /ws/meet-session WebSocket for real-time events.
struct MeetSessionView: View {
    @StateObject private var viewModel = MeetSessionViewModel()
    @FocusState private var urlFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Top: URL bar + controls
            controlBar

            Divider().background(Theme.border)

            if viewModel.isJoined || viewModel.connectionState == .connected || !viewModel.transcript.isEmpty {
                // Active call: transcript + diagrams
                meetContent
            } else {
                // Pre-call: just the URL input
                Spacer()
                VStack(spacing: 16) {
                    Image(systemName: "video.badge.plus")
                        .font(.system(size: 48))
                        .foregroundStyle(Theme.tertiary)
                    Text("Paste a Google Meet URL to join with Hank Bob")
                        .font(.body)
                        .foregroundStyle(Theme.secondary)
                    Text("The pipeline must be running on port 9120")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiary)
                }
                Spacer()
            }
        }
        .background(Theme.background)
    }

    // MARK: - Control Bar

    private var controlBar: some View {
        HStack(spacing: 12) {
            // Pipeline URL
            TextField("Pipeline URL", text: $viewModel.pipelineURL)
                .textFieldStyle(.plain)
                .font(.caption.monospaced())
                .foregroundStyle(Theme.tertiary)
                .frame(width: 140)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))

            // Meet URL
            TextField("Google Meet URL", text: $viewModel.meetURL)
                .textFieldStyle(.plain)
                .font(.caption)
                .foregroundStyle(Theme.primary)
                .focused($urlFocused)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                .disabled(viewModel.isJoined)

            // Join / Leave
            if !viewModel.isJoined {
                Button {
                    Task { await viewModel.joinCall() }
                } label: {
                    Label("Join", systemImage: "video.fill")
                        .font(.caption.weight(.medium))
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(viewModel.meetURL.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            } else {
                Button {
                    Task { await viewModel.leaveCall() }
                } label: {
                    Label("Leave", systemImage: "phone.down.fill")
                        .font(.caption.weight(.medium))
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }

            // Connection indicator
            connectionDot

            // WS status
            if viewModel.connectionState == .connected {
                Label("Live", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.background)
    }

    private var connectionDot: some View {
        Circle()
            .fill(connectionColor)
            .frame(width: 8, height: 8)
    }

    private var connectionColor: Color {
        switch viewModel.connectionState {
        case .connected: return .green
        case .connecting: return .orange
        case .error: return .red
        case .disconnected: return Theme.tertiary
        }
    }

    // MARK: - Meet Content

    private var meetContent: some View {
        HStack(spacing: 0) {
            // Transcript panel
            transcriptPanel
                .frame(minWidth: 320)

            Divider().background(Theme.border)

            // Diagrams panel
            diagramPanel
                .frame(minWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Transcript Panel

    private var transcriptPanel: some View {
        VStack(spacing: 0) {
            // Status header
            if let status = viewModel.botStatus {
                HStack(spacing: 8) {
                    Circle()
                        .fill(status.isActive ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(status.displayStatus)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.primary)
                    if !status.participants.isEmpty {
                        Text("• \(status.participants.joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: viewModel.connectionState == .connected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                            .font(.caption2)
                        Text(viewModel.transcript.count.description)
                            .font(.caption2.monospacedDigit())
                    }
                    .foregroundStyle(Theme.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.surface)
            }

            Divider().background(Theme.border)

            // Transcript feed
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(viewModel.transcript) { entry in
                            transcriptRow(entry)
                        }
                        // Invisible anchor at bottom for auto-scroll
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: viewModel.transcript.count) { _, _ in
                    if let lastID = viewModel.transcript.last?.id {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func transcriptRow(_ entry: MeetTranscriptEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.speaker)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(entry.isBot ? Theme.accent : Theme.secondary)
                Text(timeAgo(entry.timestamp))
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
            }
            Text(entry.text)
                .font(.callout)
                .foregroundStyle(Theme.primary)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(entry.isBot ? Theme.accent.opacity(0.05) : Color.clear,
                     in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Diagram Panel

    private var diagramPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Diagrams", systemImage: "chart.bar.doc.horizontal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.primary)
                Spacer()
                Text("\(viewModel.diagrams.count) total")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.surface)

            Divider().background(Theme.border)

            if viewModel.diagrams.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.3.group")
                        .font(.title2)
                        .foregroundStyle(Theme.tertiary)
                    Text("When Hank draws a diagram,\nit will appear here")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(viewModel.diagrams) { diagram in
                                diagramCard(diagram)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(12)
                    }
                    .onChange(of: viewModel.diagrams.count) { _, _ in
                        if viewModel.diagrams.last != nil {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }

    private func diagramCard(_ diagram: MeetDiagram) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !diagram.caption.isEmpty {
                Text(diagram.caption)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.secondary)
            }
            MermaidDiagramView(mermaidCode: diagram.mermaid, isStreaming: false)
                .frame(maxWidth: .infinity)
                .padding(8)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.bottom, 4)
    }

    // MARK: - Helpers

    private func timeAgo(_ iso: String) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fmt.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        else { return "" }
        let interval = -date.timeIntervalSinceNow
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        return "\(Int(interval / 3600))h ago"
    }
}

#Preview {
    MeetSessionView()
        .frame(width: 800, height: 600)
}
