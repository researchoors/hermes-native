import SwiftUI

/// Native force-directed wiki graph using SwiftUI Canvas + Timer.
/// Shows color-coded node types, interactive selection, and neighbor highlighting.
struct WikiGraphView: View {
    @StateObject private var viewModel = WikiGraphViewModel()
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper

    // MARK: - Interaction State

    @State private var dragState: DragState = .idle
    @State private var dragNodeIndex: Int?
    @State private var panStartOffset: CGSize = .zero

    private enum DragState {
        case idle, deciding, panning, draggingNode
    }

    // Timer-driven frame pump (TimelineView is unreliable in overlay ZStacks)
    @State private var frameID = UUID()
    private let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                // Main graph canvas
                graphCanvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Detail panel on the right
                if let selIdx = viewModel.selectedNodeIndex,
                   viewModel.simNodes.indices.contains(selIdx) {
                    nodeDetailPanel(nodeIndex: selIdx)
                        .frame(width: 260)
                        .background(Theme.background)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background(Theme.background)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Wiki Graph")
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
                Text("\(viewModel.graph.pages.count) pages · \(viewModel.graph.links.count) links")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
            .padding(10)
            .background(Theme.surface.opacity(0.82), in: RoundedRectangle(cornerRadius: 10))
            .padding(12)
        }
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 6) {
                if viewModel.isLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading…").font(.caption2)
                    }
                } else if let error = viewModel.error {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                        Text(error)
                            .font(.caption2)
                            .lineLimit(2)
                            .frame(maxWidth: 260, alignment: .leading)
                    }
                }

                // Classification Legend
                legendView
            }
            .padding(8)
            .padding(12)
        }
        .overlay(alignment: .bottomTrailing) {
            // Shrunk debug overlay
            if viewModel.error != nil || viewModel.simNodes.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("canvas: \(Int(viewModel.canvasSize.width))×\(Int(viewModel.canvasSize.height))")
                    Text("pages: \(viewModel.graph.pages.count)")
                    Text("nodes: \(viewModel.simNodes.count)")
                    Text("error: \(viewModel.error ?? "nil")")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color.red)
                .padding(6)
                .background(Color.black.opacity(0.7))
                .cornerRadius(6)
                .padding(12)
            }
        }
        .overlay(alignment: .topTrailing) {
            controlsOverlay
        }
        .sheet(isPresented: $viewModel.showPageDetail) {
            if let page = viewModel.selectedPage {
                WikiPageDetailView(page: page, viewModel: viewModel)
                    .frame(minWidth: 560, minHeight: 620)
            }
        }
        .onAppear {
            Task { await viewModel.load(client: gatewayClientWrapper.client) }
        }
    }

    // MARK: - Graph Canvas

    private var graphCanvas: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let wasZero = viewModel.canvasSize == .zero
                viewModel.canvasSize = size
                if wasZero && size != .zero && viewModel.simNodes.isEmpty && !viewModel.graph.pages.isEmpty {
                    viewModel.setupSimulation()
                }
                viewModel.tick()

                let hasSelection = viewModel.selectedNodeIndex != nil

                context.translateBy(x: viewModel.panOffset.width, y: viewModel.panOffset.height)
                context.scaleBy(x: viewModel.zoom, y: viewModel.zoom)

                // Links
                for (si, ti) in viewModel.simLinks {
                    guard viewModel.simNodes.indices.contains(si),
                          viewModel.simNodes.indices.contains(ti) else { continue }

                    let isConnected = !hasSelection || viewModel.linkIsConnectedToSelection(si, ti)
                    let opacity: CGFloat = isConnected ? 0.5 : 0.08
                    let lineWidth: CGFloat = isConnected ? 1.5 : 0.5
                    let color = isConnected
                        ? Color(hex: "7c7cff")!.opacity(opacity)
                        : Theme.secondary.opacity(opacity)

                    let sp = viewModel.simNodes[si].position
                    let tp = viewModel.simNodes[ti].position
                    var path = Path()
                    path.move(to: sp)
                    path.addLine(to: tp)
                    context.stroke(path, with: .color(color), lineWidth: lineWidth)

                    // Relationship label near midpoint when selected
                    if isConnected, hasSelection, viewModel.simNodes.indices.contains(si), viewModel.simNodes.indices.contains(ti) {
                        let mid = CGPoint(x: (sp.x + tp.x) / 2, y: (sp.y + tp.y) / 2)
                        let source = viewModel.simNodes[si]
                        let target = viewModel.simNodes[ti]
                        var labelText = "links to"
                        if viewModel.simNodes[si].id == viewModel.simNodes[viewModel.selectedNodeIndex!].id {
                            labelText = "→ \(target.label)"
                        } else {
                            labelText = "← \(source.label)"
                        }
                        context.draw(
                            Text(labelText)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(Color(hex: "7c7cff")!.opacity(0.7)),
                            at: mid,
                            anchor: .center
                        )
                    }
                }

                // Nodes (sorted by z so labels overlap correctly)
                let sorted = viewModel.simNodes.enumerated().sorted { (a, b) in
                    a.element.position.y < b.element.position.y
                }
                for (index, node) in sorted {
                    let isSelected = viewModel.selectedNodeIndex == index
                    let isConnected = !hasSelection || viewModel.isNodeConnectedToSelection(index)
                    let baseOpacity = isConnected ? 1.0 : 0.2
                    let r = viewModel.nodeRadius(for: node.type)
                    let ellipse = CGRect(x: node.position.x - r, y: node.position.y - r, width: r * 2, height: r * 2)

                    // Selection ring
                    if isSelected {
                        let ringRect = CGRect(x: node.position.x - r - 4, y: node.position.y - r - 4, width: r * 2 + 8, height: r * 2 + 8)
                        context.fill(Path(ellipseIn: ringRect), with: .color(.white.opacity(0.3)))
                    }

                    context.fill(Path(ellipseIn: ellipse), with: .color(viewModel.color(for: node.type).opacity(baseOpacity)))
                    context.stroke(Path(ellipseIn: ellipse), with: .color(.white.opacity(isSelected ? 0.8 : 0.3)))
                }

                // Labels in screen space so text is crisp regardless of zoom
                context.transform = .identity
                for (index, node) in viewModel.simNodes.enumerated() {
                    let isConnected = !hasSelection || viewModel.isNodeConnectedToSelection(index)
                    guard isConnected else { continue }
                    let screenPos = CGPoint(
                        x: node.position.x * viewModel.zoom + viewModel.panOffset.width + 10,
                        y: node.position.y * viewModel.zoom + viewModel.panOffset.height + 4
                    )
                    guard screenPos.x > -50, screenPos.x < size.width + 50,
                          screenPos.y > -20, screenPos.y < size.height + 20 else { continue }
                    context.draw(
                        Text(node.label).font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.85)),
                        at: screenPos, anchor: .leading
                    )
                }
            }
            .gesture(dragGesture, including: .gesture)
            .onReceive(timer) { _ in
                frameID = UUID()
            }
        }
    }

    // MARK: - Node Detail Panel

    @ViewBuilder
    private func nodeDetailPanel(nodeIndex: Int) -> some View {
        let node = viewModel.simNodes[nodeIndex]
        let neighbors = viewModel.selectedNodeNeighbors()
        let page = viewModel.graph.pages.first(where: { $0.id == node.id })

        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(node.label)
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(2)
                Spacer()
                Button {
                    viewModel.deselectNode()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            // Type pill
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.color(for: node.type))
                    .frame(width: 8, height: 8)
                Text(node.type.capitalized)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)

            Divider()
                .padding(.vertical, 10)
                .padding(.horizontal, 14)

            // Stats
            VStack(alignment: .leading, spacing: 8) {
                Text("Connected to \(neighbors.count) page(s)")
                    .font(.caption)
                    .foregroundStyle(Theme.primary)

                if let page = page {
                    if !page.tags.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(page.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption2)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Theme.surface, in: Capsule())
                                    .foregroundStyle(Theme.secondary)
                            }
                        }
                    }

                    if let confidence = page.confidence, !confidence.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.shield")
                                .font(.caption2)
                            Text("Confidence: \(confidence)")
                                .font(.caption2)
                        }
                        .foregroundStyle(Theme.secondary)
                    }

                    if page.contested {
                        Label("Contested", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(Theme.warning)
                    }
                }
            }
            .padding(.horizontal, 14)

            Spacer()

            // Open detail button
            if page != nil {
                Button {
                    viewModel.selectedPage = page
                    viewModel.showPageDetail = true
                } label: {
                    Label("Open Page Detail", systemImage: "arrow.up.right.square")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Legend

    @ViewBuilder
    private var legendView: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Node Types")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.secondary)

            legendRow(color: "#7c7cff", label: "Entity", description: "things, people, tools")
            legendRow(color: "#5cb85c", label: "Concept", description: "ideas, patterns, abstractions")
            legendRow(color: "#e8a838", label: "Comparison", description: "contrasts, benchmarks, trade-offs")
            legendRow(color: "#ff6b9d", label: "Query", description: "questions, hypotheses, todos")
            legendRow(color: "#888888", label: "Raw", description: "unstructured notes")
        }
        .padding(8)
        .background(Theme.surface.opacity(0.82), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func legendRow(color hex: String, label: String, description: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(hex: hex)!)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Theme.primary)
            Text("- \(description)")
                .font(.caption2)
                .foregroundStyle(Theme.secondary)
        }
    }

    // MARK: - Drag / Tap Unified Gesture

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { value in
                switch dragState {
                case .idle:
                    dragState = .deciding
                    panStartOffset = viewModel.panOffset
                case .deciding:
                    let dist = hypot(value.translation.width, value.translation.height)
                    if dist > 5 {
                        if let idx = viewModel.hitTest(point: value.startLocation) {
                            dragState = .draggingNode
                            dragNodeIndex = idx
                            viewModel.startDragging(index: idx, at: value.location)
                        } else {
                            dragState = .panning
                        }
                    }
                case .panning:
                    viewModel.panOffset = CGSize(
                        width: panStartOffset.width + value.translation.width,
                        height: panStartOffset.height + value.translation.height
                    )
                case .draggingNode:
                    if let idx = dragNodeIndex {
                        viewModel.dragNode(index: idx, to: value.location)
                    }
                }
            }
            .onEnded { value in
                if dragState == .deciding {
                    viewModel.handleTap(at: value.startLocation)
                }
                if let idx = dragNodeIndex {
                    viewModel.stopDragging(index: idx)
                }
                dragState = .idle
                dragNodeIndex = nil
            }
    }

    // MARK: - Zoom Controls

    @ViewBuilder
    private var controlsOverlay: some View {
        HStack(spacing: 6) {
            Button {
                let c = CGPoint(x: viewModel.canvasSize.width / 2, y: viewModel.canvasSize.height / 2)
                viewModel.zoomAtPoint(factor: 0.8, around: c)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)

            Text("\(Int(viewModel.zoom * 100))%")
                .font(.caption2.monospacedDigit())
                .frame(minWidth: 32)

            Button {
                let c = CGPoint(x: viewModel.canvasSize.width / 2, y: viewModel.canvasSize.height / 2)
                viewModel.zoomAtPoint(factor: 1.25, around: c)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)

            Button {
                viewModel.resetView()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)

            Divider().frame(height: 14)

            Button {
                Task { await viewModel.load(client: gatewayClientWrapper.client) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
        }
        .foregroundStyle(Theme.secondary)
        .padding(12)
    }
}
