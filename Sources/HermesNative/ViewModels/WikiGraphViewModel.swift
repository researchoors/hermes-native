import SwiftUI
import Combine
import os.log

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "WikiGraphViewModel")

/// Force-directed graph simulation adapted from rayfix/ForceDirectedGraph.
/// Uses a simple spring-charge model with centering force.
@MainActor
final class WikiGraphViewModel: ObservableObject {

    // MARK: - Published

    @Published var graph: WikiGraph = .empty
    @Published var selectedPage: WikiPage?
    @Published var showPageDetail = false

    /// Currently selected node index (not page, local sim index).
    @Published var selectedNodeIndex: Int?

    /// Node currently hovered (macOS) — highlights node + its connections.
    @Published var hoveredNodeIndex: Int?

    var selectedNodeTitle: String? {
        guard let idx = selectedNodeIndex, simNodes.indices.contains(idx) else { return nil }
        return simNodes[idx].label
    }
    @Published var isLoading = false
    @Published var error: String?

    // MARK: - Simulation State

    struct SimNode: Identifiable {
        let id: String
        var position: CGPoint
        var velocity: CGVector = .zero
        var isDragging = false
        let type: String
        let label: String
    }

    @Published var simNodes: [SimNode] = []
    @Published var simLinks: [(sourceIndex: Int, targetIndex: Int)] = []

    /// Connection count per node (degree centrality) — drives node sizing.
    private(set) var degrees: [Int] = []

    // Simulation parameters (tuned for ~20-50 nodes)
    private let friction: CGFloat = 0.92
    private let springLength: CGFloat = 120
    private let springConstant: CGFloat = 0.008
    private let chargeConstant: CGFloat = 8000
    private let centerPull: CGFloat = 0.0005
    private let iterationsPerFrame = 2
    private let maxVelocity: CGFloat = 30
    private let maxRepulsionForce: CGFloat = 500

    // Simulated annealing — energy decays so the graph settles into a calm,
    // stable layout instead of wiggling forever. Reheated on setup/drag.
    private var alpha: CGFloat = 1.0
    private let alphaDecay: CGFloat = 0.0228   // ~300 ticks to settle
    private let alphaMin: CGFloat = 0.002
    private let alphaReheat: CGFloat = 0.5

    // View transforms
    @Published var zoom: CGFloat = 1.0
    @Published var panOffset: CGSize = .zero
    var canvasSize: CGSize = .zero

    // MARK: - Color mapping

    func color(for type: String) -> Color {
        switch type {
        case "entity": return Color(hex: "7c7cff")!    // purple
        case "concept": return Color(hex: "5cb85c")!   // green
        case "comparison": return Color(hex: "e8a838")! // orange
        case "query": return Color(hex: "ff6b9d")!     // pink
        case "raw": return Color(hex: "888888")!       // gray
        default: return Color(hex: "aaaaaa")!
        }
    }

    func nodeRadius(for type: String) -> CGFloat {
        type == "entity" ? 7 : 5
    }

    /// Degree-aware radius: hubs (many connections) render larger so the
    /// most-connected pages in the "second brain" stand out.
    func nodeRadius(at index: Int) -> CGFloat {
        guard simNodes.indices.contains(index) else { return 5 }
        let base = nodeRadius(for: simNodes[index].type)
        let degree = degrees.indices.contains(index) ? degrees[index] : 0
        // Logarithmic growth so a 50-link hub isn't absurdly large.
        let bonus = min(CGFloat(degree) * 0.9, 10)
        return base + log2(CGFloat(degree) + 1) * 1.4 + bonus * 0.15
    }

    // MARK: - Gateway

    @Published var selectedWikiPath: String?
    @Published var availableWikis: [String] = []

    func load(client: GatewayClient, wiki: String? = nil) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let newGraph = try await client.wikiScan(wiki: wiki)
            self.graph = newGraph
            if canvasSize != .zero {
                setupSimulation()
            }
        } catch {
            log.error("wiki.scan failed: \(error.localizedDescription)")
            self.error = error.localizedDescription
        }
    }

    /// Discover available wikis from the server-side registry.
    func discoverWikis(client: GatewayClient) async {
        do {
            let wikis = try await client.wikiList()
            self.availableWikis = wikis.map { $0.name }
        } catch {
            log.warning("wiki.list failed: \(error.localizedDescription)")
            // Non-fatal — the menu will just show "No wikis discovered"
        }
    }

    func loadPage(client: GatewayClient, path: String, wiki: String? = nil) async -> WikiPageContent? {
        do {
            return try await client.wikiPage(path: path, wiki: wiki)
        } catch {
            log.error("wiki.page failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Simulation Setup

    func setupSimulation() {
        guard canvasSize != .zero, !graph.pages.isEmpty else { return }

        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        var rng = SystemRandomNumberGenerator()

        simNodes = graph.pages.map { page in
            let angle = Double.random(in: 0...(2 * .pi), using: &rng)
            let dist = Double.random(in: 50...200, using: &rng)
            return SimNode(
                id: page.id,
                position: CGPoint(
                    x: center.x + cos(angle) * dist,
                    y: center.y + sin(angle) * dist
                ),
                type: page.type,
                label: page.title
            )
        }

        // Deduplicate nodes by ID — graph data may contain duplicates
        var seenIds = Set<String>()
        simNodes = simNodes.filter { node in
            guard !seenIds.contains(node.id) else { return false }
            seenIds.insert(node.id)
            return true
        }

        let idToIndex = Dictionary(uniqueKeysWithValues: simNodes.enumerated().map { ($1.id, $0) })
        simLinks = graph.links.compactMap { link -> (Int, Int)? in
            guard let si = idToIndex[link.source],
                  let ti = idToIndex[link.target] else { return nil }
            return (si, ti)
        }

        // Compute degree (connection count) per node for sizing.
        degrees = Array(repeating: 0, count: simNodes.count)
        for (si, ti) in simLinks {
            if degrees.indices.contains(si) { degrees[si] += 1 }
            if degrees.indices.contains(ti) { degrees[ti] += 1 }
        }

        // Reheat the simulation so it animates into a fresh layout.
        alpha = 1.0
    }

    // MARK: - Simulation Step

    func tick() {
        guard canvasSize != .zero, simNodes.count > 1 else { return }

        // Once the layout has cooled below alphaMin it is stable — stop
        // integrating so nodes stay put (no perpetual wiggle).  Dragging
        // re-heats via dragNode(), so interaction always animates.
        let anyDragging = simNodes.contains { $0.isDragging }
        guard alpha > alphaMin || anyDragging else { return }

        for _ in 0..<iterationsPerFrame {
            var forces = Array(repeating: CGVector.zero, count: simNodes.count)

            // Repulsion (charge) with softening and force cap
            for i in 0..<simNodes.count {
                guard !simNodes[i].isDragging else { continue }
                for j in (i + 1)..<simNodes.count {
                    let dx = simNodes[i].position.x - simNodes[j].position.x
                    let dy = simNodes[i].position.y - simNodes[j].position.y
                    let distSq = dx * dx + dy * dy
                    guard distSq > 0.01 else { continue }
                    let rawForce = chargeConstant / distSq
                    let force = min(rawForce, maxRepulsionForce)
                    let dist = sqrt(distSq)
                    let fx = (dx / dist) * force
                    let fy = (dy / dist) * force
                    forces[i].dx += fx
                    forces[i].dy += fy
                    forces[j].dx -= fx
                    forces[j].dy -= fy
                }
            }

            // Spring forces (links)
            for (si, ti) in simLinks {
                let dx = simNodes[ti].position.x - simNodes[si].position.x
                let dy = simNodes[ti].position.y - simNodes[si].position.y
                let dist = sqrt(dx * dx + dy * dy)
                guard dist > 0 else { continue }
                let force = (dist - springLength) * springConstant
                let fx = (dx / dist) * force
                let fy = (dy / dist) * force
                forces[si].dx += fx
                forces[si].dy += fy
                forces[ti].dx -= fx
                forces[ti].dy -= fy
            }

            // Centering force
            let meanX = simNodes.reduce(0) { $0 + $1.position.x } / CGFloat(simNodes.count)
            let meanY = simNodes.reduce(0) { $0 + $1.position.y } / CGFloat(simNodes.count)
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            for i in 0..<simNodes.count {
                guard !simNodes[i].isDragging else { continue }
                forces[i].dx += (center.x - meanX) * centerPull
                forces[i].dy += (center.y - meanY) * centerPull
            }

            // Integrate with velocity clamp, scaled by annealing energy (alpha)
            for i in 0..<simNodes.count {
                guard !simNodes[i].isDragging else { continue }
                var v = simNodes[i].velocity
                v.dx = (v.dx + forces[i].dx * alpha) * friction
                v.dy = (v.dy + forces[i].dy * alpha) * friction
                let speed = sqrt(v.dx * v.dx + v.dy * v.dy)
                if speed > maxVelocity {
                    let scale = maxVelocity / speed
                    v.dx *= scale
                    v.dy *= scale
                }
                simNodes[i].velocity = v
                simNodes[i].position.x += v.dx
                simNodes[i].position.y += v.dy
            }
        }

        // Cool down. Dragging holds energy high so neighbors keep following.
        if anyDragging {
            alpha = max(alpha, alphaReheat)
        } else {
            alpha += (alphaMin - alpha) * alphaDecay
        }
    }

    // MARK: - Interaction

    func hitTest(point: CGPoint) -> Int? {
        // Convert view point to model space
        let mx = (point.width - panOffset.width) / zoom
        let my = (point.height - panOffset.height) / zoom
        let modelPoint = CGPoint(x: mx, y: my)

        for (index, node) in simNodes.enumerated().reversed() {
            let r = nodeRadius(for: node.type) + 4 // hit padding
            if abs(node.position.x - modelPoint.x) < r && abs(node.position.y - modelPoint.y) < r {
                return index
            }
        }
        return nil
    }

    func startDragging(index: Int, at point: CGPoint) {
        guard simNodes.indices.contains(index) else { return }
        simNodes[index].isDragging = true
        simNodes[index].velocity = .zero
        alpha = max(alpha, alphaReheat)
    }

    func dragNode(index: Int, to point: CGPoint) {
        guard simNodes.indices.contains(index) else { return }
        let mx = (point.x - panOffset.width) / zoom
        let my = (point.y - panOffset.height) / zoom
        simNodes[index].position = CGPoint(x: mx, y: my)
        alpha = max(alpha, alphaReheat)
    }

    func stopDragging(index: Int) {
        guard simNodes.indices.contains(index) else { return }
        simNodes[index].isDragging = false
    }

    /// Update hovered node from a screen point (macOS hover highlight).
    func updateHover(at point: CGPoint) {
        let idx = hitTest(point: CGPoint(x: point.x, y: point.y))
        if idx != hoveredNodeIndex {
            hoveredNodeIndex = idx
        }
    }

    func clearHover() {
        if hoveredNodeIndex != nil { hoveredNodeIndex = nil }
    }

    /// Highlight context: a node is "active" if there's no selection/hover,
    /// or it is the selected/hovered node or one of its neighbors.
    var highlightAnchor: Int? {
        selectedNodeIndex ?? hoveredNodeIndex
    }

    func handleTap(at point: CGPoint) {
        if let index = hitTest(point: point) {
            if selectedNodeIndex == index {
                // Double-tap: open detail
                let pageID = simNodes[index].id
                if let page = graph.pages.first(where: { $0.id == pageID }) {
                    selectedPage = page
                    showPageDetail = true
                }
            } else {
                selectedNodeIndex = index
            }
        } else {
            selectedNodeIndex = nil
        }
    }

    func deselectNode() {
        selectedNodeIndex = nil
    }

    // MARK: - Selection Helpers

    func selectedNodeNeighbors() -> [Int] {
        guard let sel = selectedNodeIndex else { return [] }
        var result = Set<Int>()
        for (si, ti) in simLinks {
            if si == sel { result.insert(ti) }
            if ti == sel { result.insert(si) }
        }
        return Array(result)
    }

    private func neighbors(of anchor: Int) -> Set<Int> {
        var result = Set<Int>()
        for (si, ti) in simLinks {
            if si == anchor { result.insert(ti) }
            if ti == anchor { result.insert(si) }
        }
        return result
    }

    func isNodeConnectedToSelection(_ index: Int) -> Bool {
        guard let anchor = highlightAnchor else { return true }
        if index == anchor { return true }
        return neighbors(of: anchor).contains(index)
    }

    func linkIsConnectedToSelection(_ source: Int, _ target: Int) -> Bool {
        guard let anchor = highlightAnchor else { return true }
        return source == anchor || target == anchor
    }

    func zoomAtPoint(factor: CGFloat, around point: CGPoint) {
        guard factor.isFinite, factor > 0 else { return }
        let oldZoom = zoom
        let newZoom = max(0.3, min(5.0, oldZoom * factor))
        guard newZoom != oldZoom else { return }
        // Adjust pan so the point under the cursor stays fixed
        panOffset.width += point.x * (oldZoom - newZoom)
        panOffset.height += point.y * (oldZoom - newZoom)
        zoom = newZoom
    }

    func resetView() {
        panOffset = .zero
        zoom = 1.0
    }
}

// MARK: - Helpers

extension CGPoint {
    var width: CGFloat { x }
    var height: CGFloat { y }
}

extension CGVector {
    static let zero = CGVector(dx: 0, dy: 0)
}
