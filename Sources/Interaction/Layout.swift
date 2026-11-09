import Foundation

/// A concrete grid on screen, in pixels: which arrangement, how many columns, and where it is scrolled.
struct Layout {
    var arrangement: ArrangementID
    var cols: Int
    /// Empty cells before the first item. Lets a pinch keep the photo under the fingers in its column.
    var shift: Int
    var pitch: Double
    var gap: Double
    var originX: Double
    var top: Double
    var scrollY: Double
    var maxScroll: Double
    var isScrollable: Bool

    var rows: Int { (Library.itemCount + shift + cols - 1) / cols }

    /// Screen y of a row's top edge.
    func rowY(_ row: Int) -> Double { top + Double(row) * pitch - scrollY }

    /// Rows intersecting the screen, extended by `margin` px on both sides.
    func visibleRows(height: Double, margin: Double) -> ClosedRange<Int> {
        let first = Int(floor((scrollY - top - margin) / pitch))
        let last = Int(floor((scrollY - top + height + margin) / pitch))
        let lower = min(max(0, first), rows - 1)
        return lower...max(lower, min(rows - 1, last))
    }
}

struct Viewport: Equatable {
    var width: Double = 1
    var height: Double = 1
    var safeTop: Double = 0
    var safeBottom: Double = 0
    /// Pixels per point.
    var scale: Double = 1
}

/// What the renderer draws this frame.
struct FrameState {
    enum Style {
        /// Two rigid grids, `b` crossfaded over `a` by `t`. Used for scrolling and zooming.
        case grid
        /// Every tile travels from its cell in `a` to its cell in `b`. Used for re-sorting.
        case morph
    }

    var style: Style
    var a: Layout
    var b: Layout
    var t: Double
    var stagger: Double = 0
    var focal: SIMD2<Double> = .zero
    /// Morph only: crossfade the two grids underneath the travelling tiles, so the screen stays
    /// covered when every tile is in the air at once.
    var underlay = false
    var detail: DetailFrame?
}
