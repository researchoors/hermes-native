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

    /// Which grip the pointer is currently over, so it can highlight (and only
    /// that one). Cleared on exit.
    @State private var hoveredHandle: HandleRef?

    private struct HandleRef: Equatable {
        internal let id: UUID
        internal let handle: PanelHandle
    }

    private static let coordSpace = "thoughtDashboardCanvas"
    private static let titleBarHeight: CGFloat = 28
    /// Hit-target thickness for an edge / corner grab zone (invisible, generous).
    private static let edgeGrip: CGFloat = 9
    private static let cornerGrip: CGFloat = 20
    /// Visible handle chrome drawn on the focused panel so resizing is obvious.
    private static let edgeHandleThickness: CGFloat = 4
    private static let edgeHandleLength: CGFloat = 26
    private static let cornerHandleSize: CGFloat = 11

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
        .overlay(resizeGrips(panel, bounds: bounds, isFocused: isFocused))
        .offset(x: panel.frame.minX, y: panel.frame.minY)
        // Any touch on the panel body focuses it (without stealing drags).
        .simultaneousGesture(TapGesture().onEnded { layout.bringToFront(panel.id) })
    }

    private func titleBar(_ panel: DashboardPanel, bounds: CGSize, isFocused: Bool) -> some View {
        HStack(spacing: 6) {
            // Grip glyph → this bar is the drag handle for moving the panel.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isFocused ? Theme.secondary : Theme.tertiary)
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
    //
    // Each grip is a generous, invisible hit zone pinned to an edge/corner,
    // with VISIBLE handle chrome drawn on top when the panel is focused — so
    // the user can see where to grab, not just discover it by hunting. The
    // hovered handle brightens to accent. Chrome only shows on the focused
    // panel to avoid a canvas full of handles.

    private func resizeGrips(_ panel: DashboardPanel, bounds: CGSize, isFocused: Bool) -> some View {
        ZStack {
            grip(panel, .top, bounds: bounds, isFocused: isFocused)
                .frame(height: Self.edgeGrip).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            grip(panel, .bottom, bounds: bounds, isFocused: isFocused)
                .frame(height: Self.edgeGrip).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            grip(panel, .leading, bounds: bounds, isFocused: isFocused)
                .frame(width: Self.edgeGrip).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            grip(panel, .trailing, bounds: bounds, isFocused: isFocused)
                .frame(width: Self.edgeGrip).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            // Corners drawn last → win the hit test over the edges they overlap.
            corner(panel, .topLeading, bounds: bounds, alignment: .topLeading, isFocused: isFocused)
            corner(panel, .topTrailing, bounds: bounds, alignment: .topTrailing, isFocused: isFocused)
            corner(panel, .bottomLeading, bounds: bounds, alignment: .bottomLeading, isFocused: isFocused)
            corner(panel, .bottomTrailing, bounds: bounds, alignment: .bottomTrailing, isFocused: isFocused)
        }
    }

    private func grip(_ panel: DashboardPanel, _ handle: PanelHandle, bounds: CGSize, isFocused: Bool) -> some View {
        let isHot = hoveredHandle == HandleRef(id: panel.id, handle: handle)
        let horizontal = handle == .top || handle == .bottom
        return ZStack {
            Color.clear
            if isFocused {
                // A short capsule centered on the edge — the visible grab bar.
                Capsule()
                    .fill(isHot ? Theme.accent : Theme.secondary.opacity(0.7))
                    .frame(
                        width: horizontal ? Self.edgeHandleLength : Self.edgeHandleThickness,
                        height: horizontal ? Self.edgeHandleThickness : Self.edgeHandleLength
                    )
            }
        }
        .contentShape(Rectangle())
        .gesture(dragGesture(handle, panel: panel, bounds: bounds))
        .onHover { inside in setHover(inside, panel: panel, handle: handle) }
        .pointerStyleResize(handle)
    }

    private func corner(
        _ panel: DashboardPanel,
        _ handle: PanelHandle,
        bounds: CGSize,
        alignment: Alignment,
        isFocused: Bool
    ) -> some View {
        let isHot = hoveredHandle == HandleRef(id: panel.id, handle: handle)
        return ZStack {
            Color.clear
            if isFocused {
                // A filled dot marks each corner as a resize handle.
                Circle()
                    .fill(isHot ? Theme.accent : Theme.surface)
                    .overlay(Circle().stroke(isHot ? Theme.accent : Theme.secondary, lineWidth: 1.5))
                    .frame(width: Self.cornerHandleSize, height: Self.cornerHandleSize)
            }
        }
        .frame(width: Self.cornerGrip, height: Self.cornerGrip)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .contentShape(Rectangle())
        .gesture(dragGesture(handle, panel: panel, bounds: bounds))
        .onHover { inside in setHover(inside, panel: panel, handle: handle) }
        .pointerStyleResize(handle)
    }

    private func setHover(_ inside: Bool, panel: DashboardPanel, handle: PanelHandle) {
        let ref = HandleRef(id: panel.id, handle: handle)
        if inside {
            hoveredHandle = ref
        } else if hoveredHandle == ref {
            hoveredHandle = nil
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
