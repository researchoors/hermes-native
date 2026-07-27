import CoreGraphics

/// Which grip on a panel is being dragged during a resize. `.move` is the whole
/// panel (title-bar drag); the rest are the eight edge/corner handles.
internal enum PanelHandle: CaseIterable {
    case move
    case top, bottom, leading, trailing
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    /// Handles that change width from the left / top edge (origin moves with size).
    internal var movesLeadingEdge: Bool {
        switch self {
        case .leading, .topLeading, .bottomLeading: return true
        default: return false
        }
    }

    internal var movesTopEdge: Bool {
        switch self {
        case .top, .topLeading, .topTrailing: return true
        default: return false
        }
    }

    internal var movesTrailingEdge: Bool {
        switch self {
        case .trailing, .topTrailing, .bottomTrailing: return true
        default: return false
        }
    }

    internal var movesBottomEdge: Bool {
        switch self {
        case .bottom, .bottomLeading, .bottomTrailing: return true
        default: return false
        }
    }
}

/// Pure geometry for dragging and resizing a panel. Kept free of SwiftUI so the
/// interaction rules (min size, edge anchoring, canvas clamping) are unit-tested
/// directly instead of through a gesture. Every routine takes the frame the drag
/// STARTED from plus the cumulative translation, so it's idempotent per drag —
/// the view stores the start frame on drag-begin and recomputes from raw
/// translation each change, never accumulating rounding error.
internal enum PanelResizeMath {
    internal static let minSize = DashboardPanel.minSize

    /// Apply a drag `translation` to `startFrame` for the given `handle`,
    /// enforcing `minSize` and keeping the result within `bounds`.
    internal static func apply(
        handle: PanelHandle,
        startFrame: CGRect,
        translation: CGSize,
        bounds: CGSize
    ) -> CGRect {
        switch handle {
        case .move:
            return move(startFrame, by: translation, bounds: bounds)
        default:
            return resize(startFrame, handle: handle, by: translation, bounds: bounds)
        }
    }

    // MARK: Move

    private static func move(_ frame: CGRect, by t: CGSize, bounds: CGSize) -> CGRect {
        var f = frame
        f.origin.x += t.width
        f.origin.y += t.height
        // Clamp so the panel stays fully on-canvas (when it fits).
        let maxX = max(0, bounds.width - f.size.width)
        let maxY = max(0, bounds.height - f.size.height)
        f.origin.x = min(max(0, f.origin.x), maxX)
        f.origin.y = min(max(0, f.origin.y), maxY)
        return f
    }

    // MARK: Resize

    // swiftlint:disable:next function_body_length
    private static func resize(_ frame: CGRect, handle: PanelHandle, by t: CGSize, bounds: CGSize) -> CGRect {
        var minX = frame.minX
        var minY = frame.minY
        var maxX = frame.maxX
        var maxY = frame.maxY

        if handle.movesLeadingEdge {
            // Drag left edge; clamp so width never drops below min and edge stays >= 0.
            minX = min(minX + t.width, maxX - minSize.width)
            minX = max(0, minX)
        }
        if handle.movesTrailingEdge {
            maxX = max(maxX + t.width, minX + minSize.width)
            maxX = min(bounds.width, maxX)
        }
        if handle.movesTopEdge {
            minY = min(minY + t.height, maxY - minSize.height)
            minY = max(0, minY)
        }
        if handle.movesBottomEdge {
            maxY = max(maxY + t.height, minY + minSize.height)
            maxY = min(bounds.height, maxY)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
