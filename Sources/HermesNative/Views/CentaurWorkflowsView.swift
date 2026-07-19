import SwiftUI
import os

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "CentaurWorkflows")

/// Centaur workflow introspection — the Centaur analogue of the Hermes cron
/// dashboard. Schedules (standing definitions) on top, run history below,
/// with cancel for active runs. Read-only otherwise: definitions live in the
/// control plane's source tree, not in the app.
struct CentaurWorkflowsView: View {
    let client: CentaurClient
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var schedules: [CentaurWorkflowSchedule] = []
    @State private var runs: [CentaurWorkflowRun] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var cancellingRunIDs: Set<String> = []
    @State private var selectedRun: CentaurWorkflowRun?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().overlay(Theme.border)
                content
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .task { await load() }
        .sheet(item: $selectedRun) { run in
            RunDetailSheet(run: run)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.accent)
            Text("Workflows")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.primary)
            Spacer()
            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh")
            Button {
                if let onClose { onClose() } else { dismiss() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 26, height: 26)
                    .background(Theme.surfaceHover, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 10) {
                HermesProgressView()
                Text("Loading workflows…")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { Task { await load() } }
                    .buttonStyle(.bordered)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if schedules.isEmpty && runs.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.tertiary)
                Text("No workflows")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.secondary)
                Text("This Centaur deployment has no registered schedules or recorded runs — or its workflow runtime is disabled.")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !schedules.isEmpty {
                        sectionLabel("Schedules", count: schedules.count)
                        ForEach(schedules) { schedule in
                            ScheduleRow(schedule: schedule)
                        }
                    }
                    if !runs.isEmpty {
                        sectionLabel("Runs", count: runs.count)
                        ForEach(runs) { run in
                            RunRow(
                                run: run,
                                isCancelling: cancellingRunIDs.contains(run.runID),
                                onCancel: { Task { await cancel(run) } },
                                onSelect: { selectedRun = run }
                            )
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    private func sectionLabel(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(Theme.tertiary)
            Text("\(count)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.tertiary)
                .padding(.horizontal, 5)
                .background(Theme.surfaceHover, in: Capsule())
        }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            async let fetchedSchedules = client.workflowSchedules()
            async let fetchedRuns = client.workflowRuns(limit: 50)
            schedules = try await fetchedSchedules
            runs = try await fetchedRuns
        } catch {
            log.error("workflow load failed: \(error.localizedDescription)")
            loadError = "Couldn't load workflows: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func cancel(_ run: CentaurWorkflowRun) async {
        cancellingRunIDs.insert(run.runID)
        defer { cancellingRunIDs.remove(run.runID) }
        do {
            try await client.cancelWorkflowRun(runID: run.runID)
            await load()
        } catch {
            loadError = "Cancel failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Rows

private struct ScheduleRow: View {
    let schedule: CentaurWorkflowSchedule

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(schedule.enabled ? Color.green : Theme.tertiary)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(schedule.workflowName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                HStack(spacing: 6) {
                    Text(schedule.kindLabel)
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                    if !schedule.timezone.isEmpty {
                        Text(schedule.timezone)
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiary)
                    }
                    if !schedule.enabled {
                        Text("disabled")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct RunRow: View {
    let run: CentaurWorkflowRun
    let isCancelling: Bool
    let onCancel: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            statusBadge
            VStack(alignment: .leading, spacing: 2) {
                Text(run.workflowName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                HStack(spacing: 6) {
                    if let created = run.createdAt {
                        Text(created.formatted(.relative(presentation: .named)))
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiary)
                    }
                    if run.attempts > 1 {
                        Text("\(run.attempts) attempts")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if let failure = run.failureSummary {
                        Text(failure)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            if run.isActive {
                Button(isCancelling ? "Cancelling…" : "Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isCancelling)
            }
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private var statusBadge: some View {
        Text(run.status)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(statusColor.opacity(0.14), in: Capsule())
    }

    private var statusColor: Color {
        switch run.status.lowercased() {
        case "completed": return .green
        case "failed": return .red
        case "cancelled", "canceled": return .orange
        case "running", "in_progress", "active": return Theme.accent
        default: return Theme.secondary
        }
    }
}

// MARK: - Run detail

private struct RunDetailSheet: View {
    let run: CentaurWorkflowRun
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(run.workflowName)
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
                Spacer()
                Button("Done") { dismiss() }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                detailRow("Run ID", run.runID)
                detailRow("Status", run.status)
                detailRow("Attempts", "\(run.attempts)")
                if let created = run.createdAt {
                    detailRow("Created", created.formatted(date: .abbreviated, time: .standard))
                }
                if let updated = run.updatedAt {
                    detailRow("Updated", updated.formatted(date: .abbreviated, time: .standard))
                }
            }
            if let input = run.input {
                payloadSection("Input", value: input)
            }
            if let result = run.result {
                payloadSection("Result", value: result)
            }
            if let failure = run.failure {
                payloadSection("Failure", value: failure)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 440, minHeight: 320)
        .background(Theme.background)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.tertiary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.primary)
                .textSelection(.enabled)
        }
    }

    private func payloadSection(_ title: String, value: AnyCodable) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.tertiary)
            ScrollView {
                Text(value.displayString)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 110)
            .padding(8)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
