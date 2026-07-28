#if os(macOS)
import Charts
import SwiftUI

@MainActor
internal struct CronDashboardCanvas: View {
    @EnvironmentObject private var gatewayClientWrapper: GatewayClientWrapper
    @EnvironmentObject private var sessionList: SessionListViewModel

    /// Called when the user wants to jump to a specific session from a cron run.
    internal var onOpenSession: ((String) -> Void)?

    @State private var cronListVM = CronListViewModel()
    @ObservedObject private var store: CronRunHistoryStore = .shared

    @State private var timeHorizon: CronDashboardView.TimeHorizon = .day
    @State private var expandedJobID: String?
    @State private var selectedRecord: CronRunRecord?
    @State private var bucketSelection: BucketSelection?

    @State private var layout = DashboardLayout()
    @State private var didLoadLayout = false
    @State private var canvasBounds: CGSize = .zero
    @State private var isEditing = false
    @State private var showsTitleBars = true
    @State private var showAddPalette = false
    @AppStorage("cronDashboardToolbarCollapsed") private var toolbarCollapsed = false

    private let registry = CronDashboardCanvas.makeRegistry()

    private struct BucketSelection: Identifiable {
        internal let id = UUID()
        internal let records: [CronRunRecord]
    }

    // MARK: - Derived data (mirrors CronDashboardView logic)

    private var filteredRecords: [CronRunRecord] {
        let all = store.allRecordsSorted()
        guard let cutoff = timeHorizon.cutoff else { return all }
        return all.filter { $0.firedAt >= cutoff }
    }

    private var totalRuns: Int { filteredRecords.count }
    private var okRuns: Int { filteredRecords.filter { $0.isOk }.count }
    private var errorRuns: Int { filteredRecords.filter { !$0.isOk }.count }
    private var successRate: Double {
        totalRuns > 0 ? Double(okRuns) / Double(totalRuns) * 100 : 0
    }

    private var jobNames: [String] {
        Set(filteredRecords.map { $0.jobName }).sorted()
    }

    // MARK: - Session linkage

    /// Best-effort: find the session spawned by a cron run.
    /// Gateway may return `record.sessionID` directly; if not, match by job name +
    /// closest `startedAt` to `firedAt` among cron-sourced sessions.
    private func sessionID(for record: CronRunRecord) -> String? {
        if let sid = record.sessionID, !sid.isEmpty { return sid }
        let candidates = sessionList.sessions.filter {
            $0.isCron && ($0.title?.lowercased() == record.jobName.lowercased())
        }
        return candidates.min(by: {
            abs(($0.startedAt ?? .distantPast).timeIntervalSince(record.firedAt)) <
            abs(($1.startedAt ?? .distantPast).timeIntervalSince(record.firedAt))
        })?.id
    }

    // MARK: - Body

    internal var body: some View {
        VStack(spacing: 0) {
            if toolbarCollapsed {
                collapsedBar
            } else {
                canvasBar
            }
            Divider().overlay(Theme.border)
            GeometryReader { geo in
                DashboardCanvasView(
                    layout: $layout,
                    isEditing: isEditing,
                    showsTitleBars: showsTitleBars,
                    title: { registry.title(for: $0) },
                    icon: { registry.icon(for: $0) },
                    onLayoutCommitted: { layout.store(key: DashboardLayout.cronDashboardKey) },
                    content: { panelContent($0) }
                )
                .onAppear {
                    canvasBounds = geo.size
                    loadLayoutIfNeeded(bounds: geo.size)
                }
                .onChange(of: geo.size) { _, newSize in
                    canvasBounds = newSize
                    loadLayoutIfNeeded(bounds: newSize)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .task { await refreshData() }
    }

    // MARK: - Canvas bar

    private var canvasBar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $timeHorizon) {
                ForEach(CronDashboardView.TimeHorizon.allCases, id: \.self) { h in
                    Text(h.rawValue).tag(h)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            .labelsHidden()

            Spacer()

            Button { Task { await refreshData() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondary)
            .help("Refresh cron jobs")

            if isEditing {
                Button { showAddPalette.toggle() } label: {
                    Label("Add panel", systemImage: "plus.rectangle")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .popover(isPresented: $showAddPalette, arrowEdge: .bottom) { addPalette }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showsTitleBars.toggle() }
            } label: {
                Image(systemName: showsTitleBars ? "menubar.rectangle" : "rectangle")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(showsTitleBars ? Theme.secondary : Theme.accent)
            .help(showsTitleBars ? "Hide panel headers" : "Show panel headers")

            Button(action: resetToDefault) {
                Image(systemName: "rectangle.arrowtriangle.2.inward")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondary)
            .help("Reset layout")

            Button {
                if isEditing { layout.store(key: DashboardLayout.cronDashboardKey); showAddPalette = false }
                withAnimation(.easeInOut(duration: 0.15)) { isEditing.toggle() }
            } label: {
                Label(isEditing ? "Done" : "Edit",
                      systemImage: isEditing ? "checkmark" : "slider.horizontal.3")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(isEditing ? Theme.accent : Theme.secondary)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) { toolbarCollapsed = true }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .help("Collapse toolbar")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.surface.opacity(0.6))
    }

    private var collapsedBar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { toolbarCollapsed = false }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 22, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 22)
        .background(Theme.surface.opacity(0.5))
    }

    // MARK: - Panel content

    private func panelContent(_ panel: DashboardPanel) -> AnyView {
        switch panel.kind {
        case .cronSummary:
            return AnyView(CronSummaryPanel(
                totalRuns: totalRuns,
                okRuns: okRuns,
                errorRuns: errorRuns,
                successRate: successRate
            ))
        case .cronVolume:
            return AnyView(CronVolumePanel(
                records: filteredRecords,
                timeHorizon: timeHorizon,
                onSelectBucket: { records in
                    bucketSelection = records.isEmpty ? nil : BucketSelection(records: records)
                }
            )
            .popover(item: $bucketSelection) { item in
                runListPopover(title: "\(item.records.count) activation(s)", records: item.records)
            })
        case .cronJobs:
            return AnyView(CronJobsPanel(
                jobs: cronListVM.jobs,
                store: store,
                expandedJobID: $expandedJobID,
                onPause:  { id in Task { await cronListVM.pauseJob(id: id) } },
                onResume: { id in Task { await cronListVM.resumeJob(id: id) } },
                onRemove: { id in Task { await cronListVM.removeJob(id: id) } },
                onUpdatePrompt: { id, p in Task { await cronListVM.updatePrompt(id: id, newPrompt: p) } },
                onOpenSession: openSession(for:)
            ))
        case .cronTimeline:
            return AnyView(CronTimelinePanel(
                records: filteredRecords,
                jobNames: jobNames,
                timeHorizon: timeHorizon,
                onSelect: { record in selectedRecord = record }
            )
            .popover(item: $selectedRecord) { record in
                runDetailPopover(record: record)
            })
        case .cronBreakdown:
            return AnyView(CronBreakdownPanel(
                records: filteredRecords,
                onSelect: { record in selectedRecord = record }
            )
            .popover(item: $selectedRecord) { record in
                runDetailPopover(record: record)
            })
        case .cronFailureLog:
            return AnyView(CronFailureLogPanel(
                records: filteredRecords,
                onSelect: { record in selectedRecord = record }
            )
            .popover(item: $selectedRecord) { record in
                runDetailPopover(record: record)
            })
        case .cronNextRuns:
            return AnyView(CronNextRunsPanel(jobs: cronListVM.jobs))
        default:
            return AnyView(PanelEmptyState(
                icon: "questionmark.square.dashed",
                message: "Unknown panel: \(panel.kind.rawValue)"
            ))
        }
    }

    // MARK: - Popovers

    private func runListPopover(title: String, records: [CronRunRecord]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.primary)
            Divider()
            ForEach(records) { record in
                Button { selectedRecord = record } label: {
                    HStack(spacing: 8) {
                        Circle().fill(record.isOk ? Theme.success : Color.red).frame(width: 6, height: 6)
                        Text(record.firedAt, format: .dateTime.month().day().hour().minute().second())
                            .font(.caption2).foregroundStyle(Theme.secondary)
                        Spacer()
                        Text(record.status).font(.caption2.monospacedDigit())
                            .foregroundStyle(record.isOk ? Theme.success : .red)
                        if record.duration != nil {
                            Text(record.durationLabel).font(.caption2.monospacedDigit()).foregroundStyle(Theme.tertiary)
                        }
                        if !record.isOk { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Theme.tertiary) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(width: 280)
    }

    private func runDetailPopover(record: CronRunRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(record.isOk ? Theme.success : Color.red).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.jobName).font(.caption.weight(.semibold)).foregroundStyle(Theme.primary)
                    Text(record.firedAt, format: .dateTime.month().day().hour().minute().second())
                        .font(.caption2).foregroundStyle(Theme.tertiary)
                }
                Spacer()
                if let sid = sessionID(for: record) {
                    Button {
                        openSession(for: record)
                    } label: {
                        Label("Open session", systemImage: "arrow.up.right.square")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Jump to the session this run spawned")
                }
            }
            Divider()
            HStack {
                Text("Status").font(.caption2).foregroundStyle(Theme.tertiary).frame(width: 68, alignment: .leading)
                Text(record.status.capitalized).font(.caption2.monospacedDigit())
                    .foregroundStyle(record.isOk ? Theme.success : .red)
            }
            if record.duration != nil {
                HStack {
                    Text("Duration").font(.caption2).foregroundStyle(Theme.tertiary).frame(width: 68, alignment: .leading)
                    Text(record.durationLabel).font(.caption2.monospacedDigit()).foregroundStyle(Theme.primary)
                }
            }
            if !record.isOk {
                if let msg = record.errorMessage, !msg.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Error").font(.caption2.weight(.semibold)).foregroundStyle(.red)
                        ScrollView {
                            Text(msg)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.red.opacity(0.85))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 120)
                    }
                    .padding(6)
                    .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                } else {
                    Text("No error detail recorded.").font(.caption2).foregroundStyle(.red.opacity(0.7))
                }
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    // MARK: - Session open

    private func openSession(for record: CronRunRecord) {
        guard let sid = sessionID(for: record) else { return }
        onOpenSession?(sid)
    }

    // MARK: - Add palette

    private var addPalette: some View {
        let present = layout.panels.map(\.kind)
        let options = registry.addableDescriptors(present: present)
        return VStack(alignment: .leading, spacing: 2) {
            Text("Add panel")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .padding(.bottom, 4)
            if options.isEmpty {
                Text("Every panel is already visible.")
                    .font(.caption).foregroundStyle(Theme.tertiary)
            } else {
                ForEach(options) { descriptor in
                    Button {
                        addPanel(kind: descriptor.kind)
                        showAddPalette = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: descriptor.icon).frame(width: 16).foregroundStyle(Theme.accent)
                            Text(descriptor.title).foregroundStyle(Theme.primary)
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

    // MARK: - Helpers

    private func refreshData() async {
        cronListVM.setGatewayClient(gatewayClientWrapper.client)
        await cronListVM.refreshJobs()
        store.seedFromJobs(cronListVM.jobs)
        store.detectNewRuns(from: cronListVM.jobs)
    }

    private func loadLayoutIfNeeded(bounds: CGSize) {
        guard !didLoadLayout, bounds.width > 0, bounds.height > 0 else { return }
        didLoadLayout = true
        let loaded = DashboardLayout.loadStored(key: DashboardLayout.cronDashboardKey)
            ?? DashboardLayout.seededCronDashboard(for: bounds)
        layout = loaded.clamped(to: bounds)
    }

    private func addPanel(kind: PanelKind) {
        let size = CGSize(
            width: min(360, max(DashboardPanel.minSize.width, canvasBounds.width * 0.3)),
            height: min(400, max(DashboardPanel.minSize.height, canvasBounds.height * 0.5))
        )
        let frame = PanelResizeMath.vacantSlot(
            size: size, others: layout.panels.map(\.frame), bounds: canvasBounds
        )
        let panel = DashboardPanel(kind: kind, frame: frame).clamped(to: canvasBounds)
        layout.panels.append(panel)
        layout.bringToFront(panel.id)
        layout.store(key: DashboardLayout.cronDashboardKey)
    }

    private func resetToDefault() {
        withAnimation(.easeInOut(duration: 0.18)) {
            layout = DashboardLayout.seededCronDashboard(for: canvasBounds)
            isEditing = false
        }
        layout.store(key: DashboardLayout.cronDashboardKey)
    }

    // MARK: - Registry

    private static func makeRegistry() -> PanelRegistry {
        let r = PanelRegistry()
        r.register(PanelDescriptor(kind: .cronSummary,   title: "Summary",   icon: "chart.bar.fill",         singleton: true, build: nil))
        r.register(PanelDescriptor(kind: .cronVolume,    title: "Volume",    icon: "chart.bar.xaxis",         singleton: true, build: nil))
        r.register(PanelDescriptor(kind: .cronJobs,      title: "Jobs",      icon: "clock.badge.checkmark",   singleton: true, build: nil))
        r.register(PanelDescriptor(kind: .cronTimeline,  title: "Timeline",  icon: "timeline.selection",      singleton: true, build: nil))
        r.register(PanelDescriptor(kind: .cronBreakdown,  title: "Per-Job",      icon: "list.bullet.indent",       singleton: true, build: nil))
        r.register(PanelDescriptor(kind: .cronFailureLog, title: "Failure Log",  icon: "exclamationmark.triangle", singleton: true, build: nil))
        r.register(PanelDescriptor(kind: .cronNextRuns,   title: "Next Runs",    icon: "clock.arrow.circlepath",   singleton: true, build: nil))
        return r
    }
}

// MARK: - Summary panel

private struct CronSummaryPanel: View {
    internal let totalRuns: Int
    internal let okRuns: Int
    internal let errorRuns: Int
    internal let successRate: Double

    internal var body: some View {
        HStack(spacing: 0) {
            chip("\(totalRuns)", "Total", Theme.accent)
            chip("\(okRuns)", "OK", Theme.success)
            chip("\(errorRuns)", "Errors", .red)
            chip(String(format: "%.0f%%", successRate),
                 "Success",
                 successRate >= 90 ? Theme.success : successRate >= 50 ? Theme.warning : .red)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
    }

    private func chip(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.monospacedDigit().bold()).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Volume panel

private struct VolumeBucket: Identifiable {
    internal let id = UUID()
    internal let start: Date
    internal let okCount: Int
    internal let errorCount: Int
    internal let records: [CronRunRecord]
}

private struct CronVolumePanel: View {
    internal let records: [CronRunRecord]
    internal let timeHorizon: CronDashboardView.TimeHorizon
    internal let onSelectBucket: ([CronRunRecord]) -> Void

    private var buckets: [VolumeBucket] {
        let cal = Calendar.current
        let component = timeHorizon.bucketComponent
        let grouped = Dictionary(grouping: records) { r in
            cal.dateInterval(of: component, for: r.firedAt)?.start ?? r.firedAt
        }
        return grouped.map { start, recs in
            VolumeBucket(
                start: start,
                okCount: recs.filter { $0.isOk }.count,
                errorCount: recs.filter { !$0.isOk }.count,
                records: recs
            )
        }.sorted { $0.start < $1.start }
    }

    internal var body: some View {
        if buckets.isEmpty {
            PanelEmptyState(icon: "chart.bar.xaxis", message: "No activations in this time range")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Activation Volume").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.primary)
                    Spacer()
                    HStack(spacing: 12) {
                        LegendItem(color: Theme.success, label: "OK")
                        LegendItem(color: .red, label: "Error")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)

                let b = buckets
                Chart(b) { bucket in
                    BarMark(x: .value("Time", bucket.start), y: .value("Runs", bucket.okCount))
                        .foregroundStyle(by: .value("Status", "OK")).cornerRadius(2)
                    if bucket.errorCount > 0 {
                        BarMark(x: .value("Time", bucket.start), y: .value("Runs", bucket.errorCount))
                            .foregroundStyle(by: .value("Status", "Error")).cornerRadius(2)
                    }
                }
                .chartForegroundStyleScale(["OK": Theme.success, "Error": Color.red])
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisValueLabel(format: timeHorizon.xAxisFormat).font(.caption2)
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3)).foregroundStyle(Theme.border)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisValueLabel().font(.caption2)
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3)).foregroundStyle(Theme.border)
                    }
                }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0).onEnded { val in
                                guard let plotFrame = proxy.plotFrame else { return }
                                let frame = geo[plotFrame]
                                guard frame.contains(val.startLocation) else { return }
                                if let date: Date = proxy.value(atX: val.startLocation.x) {
                                    let cal = Calendar.current
                                    let start = cal.dateInterval(of: timeHorizon.bucketComponent, for: date)?.start ?? date
                                    let hit = b.first { $0.start == start }
                                    onSelectBucket(hit?.records ?? [])
                                }
                            })
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - Jobs panel

private struct CronJobsPanel: View {
    internal let jobs: [CronJob]
    internal let store: CronRunHistoryStore
    @Binding internal var expandedJobID: String?
    internal let onPause: (String) -> Void
    internal let onResume: (String) -> Void
    internal let onRemove: (String) -> Void
    internal let onUpdatePrompt: (String, String) -> Void
    internal let onOpenSession: ((CronRunRecord) -> Void)?

    internal var body: some View {
        if jobs.isEmpty {
            PanelEmptyState(icon: "clock.badge.checkmark", message: "No cron jobs scheduled")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(jobs) { job in
                        CronJobCard(
                            job: job,
                            isExpanded: expandedJobID == job.id,
                            runRecords: store.records(for: job.id),
                            onToggle: {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    expandedJobID = expandedJobID == job.id ? nil : job.id
                                }
                            },
                            onPause: { onPause(job.id) },
                            onResume: { onResume(job.id) },
                            onRemove: { onRemove(job.id) },
                            onUpdatePrompt: { p in onUpdatePrompt(job.id, p) }
                        )
                    }
                }
                .padding(10)
            }
        }
    }
}

// MARK: - Timeline panel

private struct CronTimelinePanel: View {
    internal let records: [CronRunRecord]
    internal let jobNames: [String]
    internal let timeHorizon: CronDashboardView.TimeHorizon
    internal let onSelect: (CronRunRecord) -> Void

    @State private var hoveredRecord: CronRunRecord?
    @State private var hoverLocation: CGPoint = .zero

    private let laneH: CGFloat = 28
    private let dotR: CGFloat = 5
    private let hitR: CGFloat = 12   // generous tap/hover radius
    private let labelW: CGFloat = 118
    private let rightPad: CGFloat = 12

    internal var body: some View {
        if records.isEmpty {
            PanelEmptyState(icon: "clock", message: "No activations in this time range")
        } else {
            let minDate = records.map { $0.firedAt }.min() ?? Date()
            let maxDate = records.map { $0.firedAt }.max() ?? Date()
            let span = maxDate.timeIntervalSince(minDate)

            VStack(alignment: .leading, spacing: 0) {
                Text("Timeline by Job")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primary)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                HStack(spacing: 0) {
                    // Job name labels
                    VStack(alignment: .trailing, spacing: 0) {
                        ForEach(jobNames, id: \.self) { name in
                            Text(name)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(hoveredRecord.map { $0.jobName == name ? Theme.primary : Theme.tertiary } ?? Theme.primary)
                                .lineLimit(1).truncationMode(.tail)
                                .frame(width: labelW - 22, height: laneH, alignment: .trailing)
                        }
                    }
                    .padding(.trailing, 8)
                    .padding(.leading, 14)

                    // Plot area: Canvas draws grid + dots; overlay handles hit-testing
                    GeometryReader { geo in
                        let plotW = geo.size.width - rightPad
                        let plotH = geo.size.height

                        ZStack(alignment: .topLeading) {
                            // All rendering in a single Canvas — no per-dot SwiftUI views
                            Canvas { ctx, size in
                                // Grid lines
                                for i in jobNames.indices {
                                    let y = CGFloat(i) * laneH + laneH / 2
                                    ctx.stroke(
                                        Path { p in
                                            p.move(to: CGPoint(x: 0, y: y))
                                            p.addLine(to: CGPoint(x: size.width, y: y))
                                        },
                                        with: .color(Theme.border.opacity(0.3)),
                                        lineWidth: 0.5
                                    )
                                }
                                // Dots
                                for record in records {
                                    let xFrac = span > 0
                                        ? CGFloat(record.firedAt.timeIntervalSince(minDate) / span)
                                        : 0.5
                                    let x = xFrac * plotW
                                    let row = jobNames.firstIndex(of: record.jobName) ?? 0
                                    let y = CGFloat(row) * laneH + laneH / 2
                                    let isHovered = hoveredRecord?.id == record.id
                                    let r = isHovered ? dotR * 1.6 : dotR
                                    let color: Color = record.isOk ? Theme.success : .red
                                    ctx.fill(
                                        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                                        with: .color(color.opacity(isHovered ? 1.0 : 0.85))
                                    )
                                    if isHovered {
                                        ctx.stroke(
                                            Path(ellipseIn: CGRect(x: x - r - 2, y: y - r - 2, width: (r + 2) * 2, height: (r + 2) * 2)),
                                            with: .color(color.opacity(0.4)),
                                            lineWidth: 1.5
                                        )
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                            // Invisible hit-test overlay — same size as Canvas
                            // Uses DragGesture(minimumDistance:0) to get a reliable location
                            // (onTapGesture location closure can get eaten by the canvas panel drag)
                            Rectangle()
                                .fill(.clear)
                                .frame(width: geo.size.width, height: plotH)
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let loc):
                                        hoverLocation = loc
                                        hoveredRecord = hitRecord(at: loc, plotW: plotW, minDate: minDate, span: span)
                                    case .ended:
                                        hoveredRecord = nil
                                    }
                                }
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onEnded { val in
                                            if let hit = hitRecord(at: val.location, plotW: plotW, minDate: minDate, span: span) {
                                                onSelect(hit)
                                            }
                                        }
                                )
                        }
                        .frame(width: geo.size.width, height: plotH)

                        // Tooltip anchored near the hovered dot
                        if let record = hoveredRecord {
                            let xFrac = span > 0
                                ? CGFloat(record.firedAt.timeIntervalSince(minDate) / span)
                                : 0.5
                            let dotX = xFrac * plotW
                            let row = jobNames.firstIndex(of: record.jobName) ?? 0
                            let dotY = CGFloat(row) * laneH + laneH / 2

                            TimelineDotTooltip(record: record)
                                .offset(
                                    x: min(dotX - 4, plotW - 180),
                                    y: dotY - 56
                                )
                                .allowsHitTesting(false)
                                .transition(.opacity)
                                .animation(.easeInOut(duration: 0.1), value: record.id)
                        }
                    }
                    .frame(height: CGFloat(jobNames.count) * laneH)
                }

                // X-axis tick labels
                HStack(spacing: 0) {
                    Spacer().frame(width: labelW)
                    HStack(spacing: 0) {
                        ForEach(0..<6, id: \.self) { i in
                            let frac = span > 0 ? Double(i) / 5.0 : 0
                            let date = Date(timeInterval: frac * span, since: minDate)
                            Text(date, format: timeHorizon.timelineFormat)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Theme.tertiary)
                                .frame(maxWidth: .infinity, alignment: i == 0 ? .leading : i == 5 ? .trailing : .center)
                        }
                    }
                    .padding(.trailing, rightPad)
                }
                .padding(.top, 4)
                .padding(.bottom, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func hitRecord(at loc: CGPoint, plotW: CGFloat, minDate: Date, span: TimeInterval) -> CronRunRecord? {
        records.min(by: { distSq($0, loc: loc, plotW: plotW, minDate: minDate, span: span) <
                         distSq($1, loc: loc, plotW: plotW, minDate: minDate, span: span) })
            .flatMap { r in
                distSq(r, loc: loc, plotW: plotW, minDate: minDate, span: span) <= hitR * hitR ? r : nil
            }
    }

    private func distSq(_ record: CronRunRecord, loc: CGPoint, plotW: CGFloat, minDate: Date, span: TimeInterval) -> CGFloat {
        let xFrac = span > 0 ? CGFloat(record.firedAt.timeIntervalSince(minDate) / span) : 0.5
        let x = xFrac * plotW
        let row = jobNames.firstIndex(of: record.jobName) ?? 0
        let y = CGFloat(row) * laneH + laneH / 2
        let dx = loc.x - x
        let dy = loc.y - y
        return dx * dx + dy * dy
    }
}

private struct TimelineDotTooltip: View {
    internal let record: CronRunRecord

    internal var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(record.isOk ? Theme.success : Color.red).frame(width: 6, height: 6)
                Text(record.jobName).font(.caption.weight(.semibold)).foregroundStyle(Theme.primary).lineLimit(1)
            }
            Text(record.firedAt, format: .dateTime.month().day().hour().minute().second())
                .font(.caption2.monospacedDigit()).foregroundStyle(Theme.tertiary)
            HStack(spacing: 8) {
                Text(record.status.capitalized)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(record.isOk ? Theme.success : .red)
                if record.duration != nil {
                    Text(record.durationLabel).font(.caption2.monospacedDigit()).foregroundStyle(Theme.tertiary)
                }
            }
            if !record.isOk {
                Text("Click to inspect").font(.system(size: 9)).foregroundStyle(Theme.accent)
            } else {
                Text("Click to open session").font(.system(size: 9)).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border.opacity(0.4), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        .fixedSize()
    }
}

// MARK: - Breakdown panel

private struct CronBreakdownPanel: View {
    internal let records: [CronRunRecord]
    internal let onSelect: (CronRunRecord) -> Void

    internal var body: some View {
        if records.isEmpty {
            PanelEmptyState(icon: "list.bullet.indent", message: "No activations in this time range")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Per-Job Stats")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.primary)
                    let perJob = Dictionary(grouping: records) { $0.jobID }
                    ForEach(perJob.keys.sorted(), id: \.self) { jobID in
                        let recs = perJob[jobID] ?? []
                        let name = recs.first?.jobName ?? jobID
                        let ok   = recs.filter { $0.isOk }.count
                        let err  = recs.filter { !$0.isOk }.count
                        let total = recs.count
                        let rate = total > 0 ? Double(ok) / Double(total) * 100 : 0
                        HStack(spacing: 10) {
                            Text(name)
                                .font(.caption.weight(.medium)).foregroundStyle(Theme.primary)
                                .lineLimit(1).frame(width: 120, alignment: .leading)
                            GeometryReader { geo in
                                HStack(spacing: 1) {
                                    if ok > 0 {
                                        RoundedRectangle(cornerRadius: 2).fill(Theme.success)
                                            .frame(width: max(2, geo.size.width * CGFloat(ok) / CGFloat(total)))
                                    }
                                    if err > 0 {
                                        RoundedRectangle(cornerRadius: 2).fill(Color.red)
                                            .frame(width: max(2, geo.size.width * CGFloat(err) / CGFloat(total)))
                                    }
                                }
                            }
                            .frame(height: 10)
                            Text(String(format: "%.0f%%", rate))
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .foregroundStyle(rate >= 90 ? Theme.success : rate >= 50 ? Theme.warning : .red)
                                .frame(width: 32, alignment: .trailing)
                            Text("\(total)")
                                .font(.caption2.monospacedDigit()).foregroundStyle(Theme.tertiary)
                                .frame(width: 24, alignment: .trailing)
                        }
                        .padding(8)
                        .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(12)
            }
        }
    }
}

// MARK: - Failure log panel

private struct CronFailureLogPanel: View {
    internal let records: [CronRunRecord]
    internal let onSelect: (CronRunRecord) -> Void

    @State private var searchText = ""

    private var failures: [CronRunRecord] {
        let failed = records.filter { !$0.isOk }.sorted { $0.firedAt > $1.firedAt }
        guard !searchText.isEmpty else { return failed }
        let q = searchText.lowercased()
        return failed.filter {
            $0.jobName.lowercased().contains(q) ||
            ($0.errorMessage ?? "").lowercased().contains(q)
        }
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Failure Log")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primary)
                Spacer()
                Text("\(failures.count) failure\(failures.count == 1 ? "" : "s")")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(failures.isEmpty ? Theme.tertiary : .red)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if records.filter({ !$0.isOk }).isEmpty {
                PanelEmptyState(icon: "checkmark.seal", message: "No failures in this time range")
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary).font(.caption)
                    TextField("Filter by job or error…", text: $searchText)
                        .font(.caption)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 7))
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

                if failures.isEmpty {
                    PanelEmptyState(icon: "magnifyingglass", message: "No matches")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(failures) { record in
                                Button { onSelect(record) } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "exclamationmark.circle.fill")
                                            .foregroundStyle(.red)
                                            .font(.system(size: 12))
                                            .padding(.top, 1)
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 6) {
                                                Text(record.jobName)
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(Theme.primary)
                                                    .lineLimit(1)
                                                Spacer()
                                                Text(record.firedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                                    .font(.caption2.monospacedDigit())
                                                    .foregroundStyle(Theme.tertiary)
                                            }
                                            if let msg = record.errorMessage, !msg.isEmpty {
                                                Text(msg)
                                                    .font(.system(.caption2, design: .monospaced))
                                                    .foregroundStyle(.red.opacity(0.8))
                                                    .lineLimit(2)
                                                    .truncationMode(.tail)
                                            } else {
                                                Text("No error detail recorded")
                                                    .font(.caption2)
                                                    .foregroundStyle(Theme.tertiary)
                                                    .italic()
                                            }
                                        }
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(Theme.tertiary)
                                            .padding(.top, 2)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(Color.red.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Next runs panel

private struct CronNextRunsPanel: View {
    internal let jobs: [CronJob]

    private var upcoming: [(job: CronJob, nextRun: Date)] {
        jobs.compactMap { job in
            guard job.enabled, let next = job.nextRunAt, next > Date() else { return nil }
            return (job, next)
        }.sorted { $0.nextRun < $1.nextRun }
    }

    private var paused: [CronJob] {
        jobs.filter { !$0.enabled }
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Next Runs")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primary)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if jobs.isEmpty {
                PanelEmptyState(icon: "clock.arrow.circlepath", message: "No scheduled jobs")
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(upcoming, id: \.job.id) { item in
                            NextRunRow(job: item.job, nextRun: item.nextRun)
                        }
                        if !paused.isEmpty {
                            Divider().padding(.vertical, 4)
                            HStack {
                                Text("Paused")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Theme.tertiary)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            ForEach(paused) { job in
                                HStack(spacing: 8) {
                                    Image(systemName: "pause.circle")
                                        .foregroundStyle(Theme.tertiary)
                                        .font(.system(size: 13))
                                    Text(job.name)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(Theme.tertiary)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("Paused")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.tertiary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Theme.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                            }
                        }
                        if upcoming.isEmpty && paused.isEmpty {
                            PanelEmptyState(icon: "clock.arrow.circlepath", message: "No upcoming runs scheduled")
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct NextRunRow: View {
    internal let job: CronJob
    internal let nextRun: Date

    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var countdown: String {
        let diff = nextRun.timeIntervalSince(now)
        guard diff > 0 else { return "now" }
        if diff < 60 { return String(format: "%.0fs", diff) }
        if diff < 3600 { return String(format: "%.0fm %02.0fs", floor(diff / 60), diff.truncatingRemainder(dividingBy: 60)) }
        let h = floor(diff / 3600)
        let m = floor((diff - h * 3600) / 60)
        return String(format: "%.0fh %02.0fm", h, m)
    }

    private var urgencyColor: Color {
        let diff = nextRun.timeIntervalSince(now)
        if diff < 60 { return .orange }
        if diff < 300 { return Theme.warning }
        return Theme.success
    }

    internal var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.fill")
                .foregroundStyle(urgencyColor)
                .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 1) {
                Text(job.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Text(nextRun, format: .dateTime.weekday(.abbreviated).hour().minute())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }
            Spacer()
            Text(countdown)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(urgencyColor)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 7))
        .onReceive(timer) { t in now = t }
    }
}
#endif
