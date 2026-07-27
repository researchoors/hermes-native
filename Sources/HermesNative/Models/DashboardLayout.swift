import CoreGraphics
import Foundation
import os

private let layoutLog = Logger(subsystem: "com.researchoors.HermesNative", category: "DashboardLayout")

/// The user's arrangement of panels on the thought-graph dashboard canvas.
/// Persisted as one personal layout (not per-session yet) so the composition a
/// user builds is the composition they get back next time they open the graph.
/// Ordered back-to-front: `panels.last` draws on top and is the focused panel.
internal struct DashboardLayout: Codable, Equatable {
    internal var panels: [DashboardPanel]

    internal init(panels: [DashboardPanel] = []) {
        self.panels = panels
    }

    internal var isEmpty: Bool { panels.isEmpty }

    // MARK: Mutation (front-to-back ordering via array position)

    /// Bring a panel to the front (end of array) so it draws over its
    /// neighbors and receives the next drag. No-op if already frontmost or absent.
    internal mutating func bringToFront(_ id: UUID) {
        guard let idx = panels.firstIndex(where: { $0.id == id }), idx != panels.count - 1 else { return }
        let panel = panels.remove(at: idx)
        panels.append(panel)
    }

    internal mutating func remove(_ id: UUID) {
        panels.removeAll { $0.id == id }
    }

    /// Replace a panel's frame in place (after a drag or resize), preserving order.
    internal mutating func setFrame(_ frame: CGRect, for id: UUID) {
        guard let idx = panels.firstIndex(where: { $0.id == id }) else { return }
        panels[idx].frame = frame
    }

    /// Clamp every panel into the given canvas bounds (window resized, or a
    /// layout saved on a bigger screen is being restored on a smaller one).
    internal func clamped(to bounds: CGSize) -> DashboardLayout {
        guard bounds.width > 0, bounds.height > 0 else { return self }
        return DashboardLayout(panels: panels.map { $0.clamped(to: bounds) })
    }

    // MARK: Persistence

    private static let userDefaultsKey = "thoughtDashboardLayout.v1"

    /// Load the saved layout, or `nil` if the user has never arranged one (the
    /// caller then seeds a sensible default). Corrupt JSON is logged and treated
    /// as absent rather than throwing — a broken layout should never block the
    /// graph; the caller just re-seeds the default.
    internal static func loadStored() -> DashboardLayout? {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return nil }
        do {
            let layout = try JSONDecoder().decode(DashboardLayout.self, from: data)
            return layout.isEmpty ? nil : layout
        } catch {
            layoutLog.error("dashboard layout load failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Persist this layout as the user's personal arrangement. Logs and no-ops
    /// on an encode failure — losing a layout is preferable to a crash.
    internal func store() {
        do {
            let data = try JSONEncoder().encode(self)
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        } catch {
            layoutLog.error("dashboard layout store failed: \(error.localizedDescription)")
        }
    }

    /// A first-run tiled arrangement, laid out for the given canvas size. Mirrors
    /// today's fixed panes (flamechart dominant, files + skills stacked to its
    /// right) so opening the dashboard the first time looks familiar, then the
    /// user rearranges from there.
    internal static func seededDefault(for bounds: CGSize) -> DashboardLayout {
        let w = max(bounds.width, DashboardPanel.minSize.width * 2 + 24)
        let h = max(bounds.height, DashboardPanel.minSize.height * 2 + 24)
        let gap: CGFloat = 8
        let rightColumnWidth = max(DashboardPanel.minSize.width, w * 0.28)
        let leftWidth = w - rightColumnWidth - gap * 3
        let rightX = leftWidth + gap * 2
        let halfH = (h - gap * 3) / 2
        return DashboardLayout(panels: [
            DashboardPanel(
                kind: .flamechart,
                frame: CGRect(x: gap, y: gap, width: leftWidth, height: h - gap * 2)
            ),
            DashboardPanel(
                kind: .files,
                frame: CGRect(x: rightX, y: gap, width: rightColumnWidth, height: halfH)
            ),
            DashboardPanel(
                kind: .skills,
                frame: CGRect(x: rightX, y: gap * 2 + halfH, width: rightColumnWidth, height: halfH)
            )
        ]).clamped(to: bounds)
    }
}
