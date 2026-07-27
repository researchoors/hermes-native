import SwiftUI

/// A free-form dashboard canvas: floating panels the user drags by the title
/// bar and resizes from any edge or corner, Grafana-style. It knows nothing
/// about WHAT a panel shows — the caller supplies a title, an icon, and a
/// content view per panel via closures — so the same canvas hosts the built-in
/// lenses and any custom sub-view registered later.
///
/// z-order is `layout.panels` array order (last = frontmost); focusing a panel
/// brings it to the end. Frames live in the canvas's own coordinate space, so
/// every drag reads a stable translation from a named space and never feeds
/// back on the moving panel. The layout binding mutates live during a drag
/// (so motion is immediate) but only persists via `onLayoutCommitted` on
/// drag-end, keeping UserDefaults writes off the per-frame path.
internal struct DashboardCanvasView: View {
    @Binding internal var layout: DashboardLayout
    internal let title: (PanelKind) -> String
    internal let icon: (PanelKind) -> String
    internal let onLayoutCommitted: () -> Void
    internal let content: (DashboardPanel) -> AnyView

    /// The in-flight drag: which panel, which handle, and the frame it started
    /// from. Nil when nothing is being dragged.
    @State private var activeDrag: ActiveDrag?

    private struct ActiveDrag: Equatable {
        internal let id: UUID
        internal let handle: PanelHandle
        internal let startFrame: CGRect
    }

    private static let coordSpace = "thoughtDashboardCanvas"
    private static let titleBarHeight: CGFloat = 26
    private static let edgeGrip: CGFloat = 7
    private static let cornerGrip: CGFloat = 14

    internal var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Backdrop — a subtle dotted field reads as "canvas", not a card.
                Theme.background

                if layout.isEmpty {
                    emptyHint
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                ForEach(layout.panels) { panel in
                    panelView(panel, bounds: geo.size)
                }
            }
            .coordinateSpace(name: Self.coordSpace)
            .onChange(of: geo.size) { _, newSize in
                // Window resized (or first layout): keep every panel on-canvas.
                // Never reflow mid-drag — that would fight the user's hand.
                guard activeDrag == nil else { return }
                layout = layout.clamped(to: newSize)
            }
        }
    }

    // MARK: - One panel

    @ViewBuilder
    private func panelView(_ panel: DashboardPanel, bounds: CGSize) -> some View {
        let isFocused = layout.panels.last?.id == panel.id
        VStack(spacing: 0) {
            titleBar(panel, bounds: bounds, isFocused: isFocused)
            content(panel)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        }
        .frame(width: panel.frame.width, height: panel.frame.height)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isFocused ? Theme.accent.opacity(0.55) : Theme.border, lineWidth: isFocused ? 1.5 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(isFocused ? 0.35 : 0.2), radius: isFocused ? 12 : 6, y: 3)
        .overlay(resizeGrips(panel, bounds: bounds))
        .offset(x: panel.frame.minX, y: panel.frame.minY)
        // Any touch on the panel body focuses it (without stealing drags).
        .simultaneousGesture(TapGesture().onEnded { layout.bringToFront(panel.id) })
    }

    private func titleBar(_ panel: DashboardPanel, bounds: CGSize, isFocused: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon(panel.kind))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isFocused ? Theme.accent : Theme.secondary)
            Text(title(panel.kind))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                layout.remove(panel.id)
                onLayoutCommitted()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.tertiary)
                    .padding(3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove panel")
        }
        .padding(.horizontal, 8)
        .frame(height: Self.titleBarHeight)
        .frame(maxWidth: .infinity)
        .background(isFocused ? Theme.surfaceHover : Theme.surface.opacity(0.6))
        .contentShape(Rectangle())
        .gesture(dragGesture(.move, panel: panel, bounds: bounds))
        .pointerStyleGrab()
    }

    // MARK: - Resize grips (8 edges + corners)

    private func resizeGrips(_ panel: DashboardPanel, bounds: CGSize) -> some View {
        ZStack {
            // Edges
            grip(panel, .top, bounds: bounds)
                .frame(height: Self.edgeGrip).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            grip(panel, .bottom, bounds: bounds)
                .frame(height: Self.edgeGrip).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            grip(panel, .leading, bounds: bounds)
                .frame(width: Self.edgeGrip).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            grip(panel, .trailing, bounds: bounds)
                .frame(width: Self.edgeGrip).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            // Corners (drawn last → win the hit test over the edges they overlap)
            corner(panel, .topLeading, bounds: bounds, alignment: .topLeading)
            corner(panel, .topTrailing, bounds: bounds, alignment: .topTrailing)
            corner(panel, .bottomLeading, bounds: bounds, alignment: .bottomLeading)
            corner(panel, .bottomTrailing, bounds: bounds, alignment: .bottomTrailing)
        }
    }

    private func grip(_ panel: DashboardPanel, _ handle: PanelHandle, bounds: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(dragGesture(handle, panel: panel, bounds: bounds))
            .pointerStyleResize(handle)
    }

    private func corner(
        _ panel: DashboardPanel,
        _ handle: PanelHandle,
        bounds: CGSize,
        alignment: Alignment
    ) -> some View {
        ZStack(alignment: cornerGlyphAlignment(handle)) {
            Color.clear
            // A faint corner tick on the bottom-trailing grip makes resize
            // discoverable without cluttering all four corners.
            if handle == .bottomTrailing {
                Image(systemName: "arrow.down.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Theme.tertiary)
                    .padding(2)
            }
        }
        .frame(width: Self.cornerGrip, height: Self.cornerGrip)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .contentShape(Rectangle())
        .gesture(dragGesture(handle, panel: panel, bounds: bounds))
        .pointerStyleResize(handle)
    }

    private func cornerGlyphAlignment(_ handle: PanelHandle) -> Alignment {
        switch handle {
        case .bottomTrailing: return .bottomTrailing
        default: return .center
        }
    }

    // MARK: - Drag/resize gesture

    private func dragGesture(_ handle: PanelHandle, panel: DashboardPanel, bounds: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.coordSpace))
            .onChanged { value in
                // First change of a new drag: capture the start frame once and
                // raise the panel. Subsequent changes recompute from this frame,
                // so translation never accumulates rounding error.
                if activeDrag?.id != panel.id || activeDrag?.handle != handle {
                    activeDrag = ActiveDrag(id: panel.id, handle: handle, startFrame: panel.frame)
                    layout.bringToFront(panel.id)
                }
                guard let start = activeDrag?.startFrame else { return }
                let newFrame = PanelResizeMath.apply(
                    handle: handle,
                    startFrame: start,
                    translation: value.translation,
                    bounds: bounds
                )
                layout.setFrame(newFrame, for: panel.id)
            }
            .onEnded { _ in
                activeDrag = nil
                onLayoutCommitted()
            }
    }

    // MARK: - Empty state

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 30))
                .foregroundStyle(Theme.tertiary)
            Text("Empty canvas")
                .font(.headline)
                .foregroundStyle(Theme.secondary)
            Text("Add a panel to start composing this turn's view.")
                .font(.caption)
                .foregroundStyle(Theme.tertiary)
        }
    }
}

// MARK: - Pointer style helpers (macOS gets resize cursors; iOS no-ops)

private extension View {
    /// Show a resize cursor over a grip on macOS, matching the handle direction.
    @ViewBuilder
    func pointerStyleResize(_ handle: PanelHandle) -> some View {
        #if os(macOS)
        self.onHover { inside in
            if inside {
                Self.resizeCursor(for: handle).set()
            } else {
                NSCursor.arrow.set()
            }
        }
        #else
        self
        #endif
    }

    /// Show an open-hand cursor over a draggable title bar on macOS.
    @ViewBuilder
    func pointerStyleGrab() -> some View {
        #if os(macOS)
        self.onHover { inside in
            if inside { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
        }
        #else
        self
        #endif
    }

    #if os(macOS)
    static func resizeCursor(for handle: PanelHandle) -> NSCursor {
        switch handle {
        case .leading, .trailing: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        // No public diagonal cursor; crosshair reads clearly as "corner resize".
        case .topLeading, .topTrailing, .bottomLeading, .bottomTrailing, .move: return .crosshair
        }
    }
    #endif
}
