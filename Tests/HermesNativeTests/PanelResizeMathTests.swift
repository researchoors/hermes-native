import CoreGraphics
import Testing
@testable import HermesNative

@Suite("Panel resize math")
internal struct PanelResizeMathTests {
    private let bounds = CGSize(width: 1000, height: 800)
    private let start = CGRect(x: 100, y: 100, width: 400, height: 300)

    // MARK: - Move

    @Test("Move translates the origin and preserves size")
    internal func moveTranslates() {
        let moved = PanelResizeMath.apply(
            handle: .move, startFrame: start, translation: CGSize(width: 50, height: -30), bounds: bounds
        )
        #expect(moved.origin == CGPoint(x: 150, y: 70))
        #expect(moved.size == start.size)
    }

    @Test("Move clamps the panel fully on-canvas")
    internal func moveClampsToBounds() {
        // Drag hard past the top-left: origin pins at 0,0.
        let topLeft = PanelResizeMath.apply(
            handle: .move, startFrame: start, translation: CGSize(width: -9999, height: -9999), bounds: bounds
        )
        #expect(topLeft.origin == .zero)

        // Drag hard past the bottom-right: the far edges stop at the bounds.
        let bottomRight = PanelResizeMath.apply(
            handle: .move, startFrame: start, translation: CGSize(width: 9999, height: 9999), bounds: bounds
        )
        #expect(bottomRight.maxX == bounds.width)
        #expect(bottomRight.maxY == bounds.height)
        #expect(bottomRight.size == start.size)
    }

    // MARK: - Resize: trailing / bottom (far edges grow)

    @Test("Trailing resize grows width, anchored on the left edge")
    internal func trailingResize() {
        let r = PanelResizeMath.apply(
            handle: .trailing, startFrame: start, translation: CGSize(width: 120, height: 0), bounds: bounds
        )
        #expect(r.minX == start.minX)      // left edge fixed
        #expect(r.width == 520)
        #expect(r.height == start.height)  // vertical untouched
    }

    @Test("Bottom-trailing corner grows both dimensions from the top-left anchor")
    internal func bottomTrailingCorner() {
        let r = PanelResizeMath.apply(
            handle: .bottomTrailing, startFrame: start, translation: CGSize(width: 100, height: 80), bounds: bounds
        )
        #expect(r.origin == start.origin)
        #expect(r.width == 500)
        #expect(r.height == 380)
    }

    // MARK: - Resize: leading / top (near edges move, anchoring the far edge)

    @Test("Leading resize moves the left edge while pinning the right edge")
    internal func leadingResizePinsRightEdge() {
        let r = PanelResizeMath.apply(
            handle: .leading, startFrame: start, translation: CGSize(width: 60, height: 0), bounds: bounds
        )
        #expect(r.maxX == start.maxX)  // right edge fixed
        #expect(r.minX == 160)
        #expect(r.width == 340)
    }

    @Test("Top resize moves the top edge while pinning the bottom edge")
    internal func topResizePinsBottomEdge() {
        let r = PanelResizeMath.apply(
            handle: .top, startFrame: start, translation: CGSize(width: 0, height: -40), bounds: bounds
        )
        #expect(r.maxY == start.maxY)  // bottom edge fixed
        #expect(r.minY == 60)
        #expect(r.height == 340)
    }

    // MARK: - Minimum size

    @Test("Resize never shrinks below the minimum size")
    internal func minimumSizeEnforced() {
        // Collapse from the trailing edge far past zero width.
        let collapsed = PanelResizeMath.apply(
            handle: .trailing, startFrame: start, translation: CGSize(width: -9999, height: 0), bounds: bounds
        )
        #expect(collapsed.width == DashboardPanel.minSize.width)
        #expect(collapsed.minX == start.minX)  // still anchored left

        // Collapse from the leading edge: min size holds, right edge stays pinned.
        let collapsedLeading = PanelResizeMath.apply(
            handle: .leading, startFrame: start, translation: CGSize(width: 9999, height: 0), bounds: bounds
        )
        #expect(collapsedLeading.width == DashboardPanel.minSize.width)
        #expect(collapsedLeading.maxX == start.maxX)
    }

    // MARK: - Resize clamps to canvas

    @Test("Trailing resize can't grow past the right edge of the canvas")
    internal func resizeClampsToBounds() {
        let r = PanelResizeMath.apply(
            handle: .trailing, startFrame: start, translation: CGSize(width: 9999, height: 0), bounds: bounds
        )
        #expect(r.maxX == bounds.width)
    }

    // MARK: - Idempotence from a fixed start frame

    @Test("Applying the same translation from the same start frame is stable")
    internal func idempotentFromStart() {
        let t = CGSize(width: 33, height: 21)
        let a = PanelResizeMath.apply(handle: .bottomTrailing, startFrame: start, translation: t, bounds: bounds)
        let b = PanelResizeMath.apply(handle: .bottomTrailing, startFrame: start, translation: t, bounds: bounds)
        #expect(a == b)
    }
}
