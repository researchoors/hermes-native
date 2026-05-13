import SwiftUI

/// Native force-directed wiki graph using SwiftUI Canvas + TimelineView.
/// Adapted from rayfix/ForceDirectedGraph — pure Swift, no WebKit.
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
            Canvas { context, size in
                let wasZero = viewModel.canvasSize == .zero
                viewModel.canvasSize = size
                if wasZero && size != .zero && viewModel.simNodes.isEmpty && !viewModel.graph.pages.isEmpty {
                    viewModel.setupSimulation()
                }
                viewModel.tick()

                context.translateBy(x: viewModel.panOffset.width, y: viewModel.panOffset.height)
                context.scaleBy(x: viewModel.zoom, y: viewModel.zoom)

                // Links
                for (si, ti) in viewModel.simLinks {
                    guard viewModel.simNodes.indices.contains(si),
                          viewModel.simNodes.indices.contains(ti) else { continue }
                    let sp = viewModel.simNodes[si].position
                    let tp = viewModel.simNodes[ti].position
                    var path = Path()
                    path.move(to: sp)
                    path.addLine(to: tp)
                    context.stroke(path, with: .color(Color(hex: "7c7cff")!.opacity(0.35)), lineWidth: 1)
                }

                // Nodes (sorted by z so labels overlap correctly)
                let sorted = viewModel.simNodes.sorted {
                    $0.position.y < $1.position.y
                }
                for node in sorted {
                    let r = viewModel.nodeRadius(for: node.type)
                    let ellipse = CGRect(x: node.position.x - r, y: node.position.y - r, width: r * 2, height: r * 2)
                    context.fill(Path(ellipseIn: ellipse), with: .color(viewModel.color(for: node.type)))
                    context.stroke(Path(ellipseIn: ellipse), with: .color(.white.opacity(0.3)), lineWidth: 1)
                }

                // Labels in screen space so text is crisp regardless of zoom
                context.transform = .identity
                for node in viewModel.simNodes {
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
        .background(Theme.background)
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
            HStack(spacing: 6) {
                if viewModel.isLoading {
                    ProgressView().controlSize(.small)
                    Text("Loading…").font(.caption2)
                } else if let error = viewModel.error {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                    Text(error)
                        .font(.caption2)
                        .lineLimit(2)
                        .frame(maxWidth: 280, alignment: .leading)
                }
            }
            .foregroundStyle(Theme.secondary)
            .padding(8)
            .padding(12)
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: 2) {
                Text("canvas: \(Int(viewModel.canvasSize.width))×\(Int(viewModel.canvasSize.height))")
                Text("pages: \(viewModel.graph.pages.count)")
                Text("nodes: \(viewModel.simNodes.count)")
                Text("links: \(viewModel.simLinks.count)")
                Text("loading: \(viewModel.isLoading)")
                Text("error: \(viewModel.error ?? "nil")")
                Text("zoom: \(String(format: "%.2f", viewModel.zoom))")
                Text("pan: \(Int(viewModel.panOffset.width)), \(Int(viewModel.panOffset.height))")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(Color.red)
            .padding(8)
            .background(Color.black.opacity(0.7))
            .cornerRadius(6)
            .padding(12)
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
