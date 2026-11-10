import Foundation
import simd

/// The whole interaction model. Zoom is one continuous number over "stops":
/// stop k < 40 is a grid with k + 1 columns; stop 40 is the overview, where all 100k
/// items fit on screen (the picture in Date mode, the rainbow in Color mode).
///
/// Zooming between two grid stops scales both grids rigidly around the photo under the
/// fingers and crossfades one into the other. Changing the arrangement (re-sorting, or
/// crossing into the picture) moves every tile to its new cell.
@MainActor
final class GridController {
    enum Mode { case date, color }

    /// Moments the app answers outside the Metal view: haptics and overlay visibility.
    enum Event {
        /// The grid crossed to another column count.
        case tick
        /// The zoom came to rest on the overview.
        case lock
        /// The photo view opened (true) or started closing (false).
        case detail(Bool)
        /// A two-finger tap: show or hide the HUD.
        case toggleHUD
    }

    var onEvent: ((Event) -> Void)?

    static let overviewStop = 40
    private static let morphStagger = 0.5
    /// How far a pinch can push past one column before letting go opens the photo.
    private static let minZoom = -0.35
    private static let openZoom = -0.1

    private enum Gesture {
        case none
        case drag(lastY: Double)
        case pinch(startDistance: Double, startColumns: Double, lastFocalY: Double)
        case blocked
    }

    private enum DetailGesture {
        case none
        case drag(start: SIMD2<Double>, time: Double)
        case pinch(start: SIMD2<Double>, distance: Double)
        case blocked
    }

    /// A touch that may turn out to be a tap rather than a drag or pinch.
    private struct TapCandidate {
        var point: SIMD2<Double>
        var time: Double
        var distance = 0.0
        var isStill = true
    }

    private enum ScrollMotion {
        case none
        case momentum(Double)
        case spring(Spring)
    }

    /// The photo a pinch holds on to, and where on screen it is held.
    private struct Anchor {
        var item: Int
        var fx: Double
        var fy: Double
        /// Screen x where the pinch began. Fixed, so every stop picks the same column for the item.
        var x: Double
        var focal: SIMD2<Double>
    }

    private struct Morph {
        let from: Mode
        let fromScroll: Double
        let start: Double
        let duration: Double
        let crossfade: Bool
    }

    let library: Library
    private(set) var mode: Mode = .date
    private var viewport = Viewport()
    private var zoom = 4.0
    private var scroll = 0.0
    private var shift = 0
    /// Where the other sort order was left. Color starts at the top, where the rainbow begins.
    private var parkedScroll = 0.0
    private var dragRaw = 0.0
    private var scrollMotion = ScrollMotion.none
    private var zoomSpring: Spring?
    private var anchor: Anchor?
    private var morph: Morph?
    private var gesture = Gesture.none
    private var scrollVelocity = VelocityTracker()
    private var zoomVelocity = VelocityTracker()
    private var lastFrameTime: Double?
    private var hasViewport = false
    private var detail: PhotoDetail?
    private var detailGesture = DetailGesture.none
    private var detailVelocity = VelocityTracker()
    private var tap: TapCandidate?
    private var twoFingerTap: TapCandidate?
    private var lastStop = 4

    init(library: Library) {
        self.library = library
    }

    func setViewport(_ newValue: Viewport) {
        guard newValue != viewport else { return }
        viewport = newValue
        if !hasViewport {
            hasViewport = true
            scroll = restingLayout().maxScroll // open on the newest photos, like Photos
        }
    }

    // MARK: - Layouts

    private var restStop: Int { Int(zoom.rounded()) }

    private func arrangement(stop: Int, mode: Mode) -> ArrangementID {
        switch (mode, stop >= Self.overviewStop) {
        case (.date, false): .date
        case (.date, true): .picture
        case (.color, _): .color
        }
    }

    private func layout(stop: Int, mode: Mode, shift: Int) -> Layout {
        let id = arrangement(stop: stop, mode: mode)
        if stop >= Self.overviewStop {
            let cols = Library.pictureColumns, rows = Library.pictureRows
            let pitch = min(viewport.width / Double(cols), viewport.height / Double(rows))
            return Layout(arrangement: id, cols: cols, shift: 0, pitch: pitch, gap: 0,
                          originX: (viewport.width - Double(cols) * pitch) / 2,
                          top: (viewport.height - Double(rows) * pitch) / 2,
                          scrollY: 0, maxScroll: 0, isScrollable: false)
        }
        let cols = stop + 1
        let pitch = viewport.width / Double(cols)
        let gap: Double = switch cols {
        case ...3: 4
        case ...8: 3
        case ...16: 2
        case ...28: 1
        default: 0
        }
        var result = Layout(arrangement: id, cols: cols, shift: min(shift, cols - 1), pitch: pitch, gap: gap,
                            originX: 0, top: viewport.safeTop, scrollY: 0, maxScroll: 0, isScrollable: true)
        result.maxScroll = maxScroll(of: result)
        return result
    }

    private func maxScroll(of layout: Layout) -> Double {
        max(0, Double(layout.rows) * layout.pitch + viewport.safeTop + viewport.safeBottom - viewport.height)
    }

    private func restingLayout() -> Layout {
        var result = layout(stop: restStop, mode: mode, shift: shift)
        result.scrollY = scroll
        return result
    }

    /// The layout for `stop` at rest, shifted so the anchored item sits in the column the pinch
    /// started over, and scrolled so it sits under the fingers.
    private func layout(stop: Int, mode: Mode, anchoredTo anchor: Anchor) -> Layout {
        let cell = Int(library[arrangement(stop: stop, mode: mode)].cellOfItem[anchor.item])
        let cols = stop + 1
        let column = min(max(Int(floor(anchor.x / (viewport.width / Double(cols)))), 0), cols - 1)
        let shift = ((column - cell) % cols + cols) % cols
        var result = layout(stop: stop, mode: mode, shift: shift)
        guard result.isScrollable else { return result }
        let row = (cell + result.shift) / result.cols
        let scrollY = result.top + (Double(row) + anchor.fy) * result.pitch - anchor.focal.y
        result.scrollY = min(max(scrollY, 0), result.maxScroll)
        return result
    }

    /// Mid-zoom between two grid stops: both grids at the same in-between cell size, each
    /// positioned so the anchored item stays under the fingers.
    private func zoomFrame(anchor: Anchor, lower: Int, upper: Int) -> FrameState {
        let a = layout(stop: lower, mode: mode, anchoredTo: anchor)
        guard upper != lower else { return FrameState(style: .grid, a: a, b: a, t: 0) }
        let b = layout(stop: upper, mode: mode, anchoredTo: anchor)
        let t = max(zoom - Double(lower), 0) // below one column the single grid just keeps growing
        let pitch = viewport.width / (zoom + 1)
        let gap = a.gap + (b.gap - a.gap) * t

        func cell(in layout: Layout) -> Int {
            Int(library[layout.arrangement].cellOfItem[anchor.item]) + layout.shift
        }
        func column(in layout: Layout) -> Double { Double(cell(in: layout) % layout.cols) + anchor.fx }
        let anchorX = column(in: a) * a.pitch * (1 - t) + column(in: b) * b.pitch * t

        func scaled(_ layout: Layout) -> Layout {
            var result = layout
            result.pitch = pitch
            result.gap = gap
            result.originX = anchorX - column(in: layout) * pitch
            result.maxScroll = maxScroll(of: result)
            let row = Double(cell(in: layout) / layout.cols) + anchor.fy
            result.scrollY = min(max(result.top + row * pitch - anchor.focal.y, 0), result.maxScroll)
            return result
        }
        return FrameState(style: .grid, a: scaled(a), b: scaled(b), t: t)
    }

    /// Between the densest grid and the overview: one continuous zoom. The overview is a plane of
    /// tiles that grows around the fingers, so each "pixel" becomes a square photo. Once the tiles
    /// reach grid size, the plane hands off to the scrolling grid with the same photo held in place.
    private func overviewFrame(anchor: Anchor) -> FrameState {
        let last = Self.overviewStop - 1
        let u = zoom - Double(last)
        let grid = layout(stop: last, mode: mode, anchoredTo: anchor)
        let overview = layout(stop: Self.overviewStop, mode: mode, shift: 0)
        let columns = columns(atZoom: zoom)

        func position(in layout: Layout) -> SIMD2<Double> {
            let cell = Int(library[layout.arrangement].cellOfItem[anchor.item]) + layout.shift
            return SIMD2(Double(cell % layout.cols) + anchor.fx, Double(cell / layout.cols) + anchor.fy)
        }
        // The held photo starts in its grid column and comes fully under the fingers just after.
        let inGrid = position(in: grid), inOverview = position(in: overview)
        let x = min(max(u / 0.12, 0), 1)
        let follow = x * x * (3 - 2 * x)
        let held = SIMD2(inGrid.x * grid.pitch * (1 - follow) + anchor.focal.x * follow, anchor.focal.y)

        var a = grid
        a.pitch = grid.pitch * Double(grid.cols) / columns
        a.originX = held.x - inGrid.x * a.pitch
        a.maxScroll = maxScroll(of: a)
        a.scrollY = min(max(a.top + inGrid.y * a.pitch - held.y, 0), a.maxScroll)

        // The plane keeps the screen covered, like a zoomed scroll view; by the time it is back
        // to overview size that leaves exactly one place for it.
        var b = overview
        b.pitch = overview.pitch * Double(overview.cols) / columns
        let size = SIMD2(Double(b.cols), Double(b.rows)) * b.pitch
        b.originX = size.x >= viewport.width
            ? min(max(held.x - inOverview.x * b.pitch, viewport.width - size.x), 0)
            : (viewport.width - size.x) / 2
        b.top = size.y >= viewport.height
            ? min(max(held.y - inOverview.y * b.pitch, viewport.height - size.y), 0)
            : (viewport.height - size.y) / 2
        return FrameState(style: .grid, a: a, b: b, t: min(u / 0.4, 1))
    }

    private func hitTest(_ layout: Layout, at point: SIMD2<Double>) -> Anchor {
        let colF = (point.x - layout.originX) / layout.pitch
        let rowF = (point.y - layout.top + layout.scrollY) / layout.pitch
        var col = min(max(Int(floor(colF)), 0), layout.cols - 1)
        var row = min(max(Int(floor(rowF)), 0), layout.rows - 1)
        var fx = min(max(colF - Double(col), 0), 1)
        var fy = min(max(rowF - Double(row), 0), 1)
        var cell = row * layout.cols + col - layout.shift
        if cell < 0 || cell >= Library.itemCount {
            // The point is over an empty cell at either end of the library: hold the nearest photo.
            cell = min(max(cell, 0), Library.itemCount - 1)
            col = (cell + layout.shift) % layout.cols
            row = (cell + layout.shift) / layout.cols
            fx = 0.5
            fy = 0.5
        }
        return Anchor(item: Int(library[layout.arrangement].itemOfCell[cell]), fx: fx, fy: fy,
                      x: layout.originX + (Double(col) + fx) * layout.pitch, focal: point)
    }

    /// Pinch maps to "effective columns": linear through the grid stops, then logarithmic
    /// from 40 columns out to the overview's 216.
    private func columns(atZoom z: Double) -> Double {
        let last = Double(Self.overviewStop - 1)
        if z <= last { return z + 1 }
        return Double(Self.overviewStop) * pow(Double(Library.pictureColumns) / Double(Self.overviewStop), z - last)
    }

    private func zoom(forColumns c: Double) -> Double {
        let last = Double(Self.overviewStop - 1)
        if c <= Double(Self.overviewStop) { return c - 1 }
        return last + log(c / Double(Self.overviewStop)) / log(Double(Library.pictureColumns) / Double(Self.overviewStop))
    }

    // MARK: - Frame

    func frame(at now: Double) -> FrameState {
        let dt = min(max(now - (lastFrameTime ?? now), 0), 1.0 / 30)
        lastFrameTime = now
        stepScroll(dt)
        stepZoom(dt)
        if restStop != lastStop {
            lastStop = restStop
            onEvent?(.tick)
        }

        var state = gridFrame(at: now)
        if var open = detail {
            open.step(dt)
            detail = open.isFinished ? nil : open
            if !open.isFinished {
                state.detail = open.frame(cell: rect(of: open.item, in: state.a), viewport: viewport)
            }
        }
        return state
    }

    private func gridFrame(at now: Double) -> FrameState {
        if let morph {
            let progress = (now - morph.start) / morph.duration
            if progress < 1 {
                var from = layout(stop: restStop, mode: morph.from, shift: shift)
                from.scrollY = morph.fromScroll
                if morph.crossfade {
                    return FrameState(style: .grid, a: from, b: restingLayout(), t: progress)
                }
                // The ripple starts at the sort control, where the tap happened.
                let control = SIMD2(viewport.width / 2, viewport.height - viewport.safeBottom / 2)
                return FrameState(style: .morph, a: from, b: restingLayout(), t: progress,
                                  stagger: Self.morphStagger, focal: control,
                                  underlay: restStop >= Self.overviewStop)
            }
            self.morph = nil
        }

        if let anchor {
            let lower = min(max(Int(floor(zoom)), 0), Self.overviewStop)
            let upper = min(lower + 1, Self.overviewStop)
            if upper == Self.overviewStop && lower != upper { return overviewFrame(anchor: anchor) }
            return zoomFrame(anchor: anchor, lower: lower, upper: upper)
        }

        let resting = restingLayout()
        return FrameState(style: .grid, a: resting, b: resting, t: 0)
    }

    private func stepScroll(_ dt: Double) {
        let maxScroll = restingLayout().maxScroll
        switch scrollMotion {
        case .none:
            break
        case .momentum(var velocity):
            velocity *= pow(0.998, dt * 1000) // UIScrollView's normal deceleration rate
            scroll += velocity * dt
            if scroll < 0 || scroll > maxScroll {
                scrollMotion = .spring(Spring(value: scroll, velocity: velocity, target: scroll < 0 ? 0 : maxScroll,
                                              response: 0.5, tolerance: 0.3))
            } else {
                scrollMotion = abs(velocity) < 8 ? .none : .momentum(velocity)
            }
        case .spring(var spring):
            spring.step(dt)
            scroll = spring.value
            if spring.isSettled {
                scroll = spring.target
                scrollMotion = .none
            } else {
                scrollMotion = .spring(spring)
            }
        }
    }

    private func stepZoom(_ dt: Double) {
        guard var spring = zoomSpring, let anchor else { return }
        spring.step(dt)
        zoom = min(max(spring.value, Self.minZoom), Double(Self.overviewStop))
        guard spring.isSettled else {
            zoomSpring = spring
            return
        }
        zoom = spring.target
        let settled = layout(stop: restStop, mode: mode, anchoredTo: anchor)
        scroll = settled.scrollY
        shift = settled.shift
        self.anchor = nil
        zoomSpring = nil
        if restStop >= Self.overviewStop { onEvent?(.lock) }
    }

    // MARK: - Touches

    /// All active touch positions in px, oldest first.
    func touchesChanged(_ points: [SIMD2<Double>], time: Double) {
        if detail != nil {
            detailTouchesChanged(points, time: time)
            return
        }
        guard morph == nil else {
            if points.isEmpty { gesture = .none }
            return
        }
        switch (gesture, points.count) {
        case (_, 0):
            endGesture(time: time)
            if let tap, tap.isStill, time - tap.time < 0.3 { openDetail(at: tap.point) }
            tap = nil
        case (.none, 1):
            // A touch that stops a fling or lands mid-zoom is not a tap on a photo.
            var isCoasting = anchor != nil
            if case .momentum(let velocity) = scrollMotion, abs(velocity) > viewport.height * 0.25 { isCoasting = true }
            tap = isCoasting ? nil : TapCandidate(point: points[0], time: time)
            beginDrag(at: points[0], time: time)
        case (.drag(let lastY), 1):
            if let start = tap?.point, simd_distance(start, points[0]) > tapSlop { tap = nil }
            moveDrag(by: points[0].y - lastY, to: points[0], time: time)
        case (.pinch, 1):
            endPinch(time: time)
            gesture = .blocked
        case (.blocked, 1):
            break
        case (.pinch(let startDistance, let startColumns, let lastFocalY), _):
            movePinch(points[0], points[1], startDistance: startDistance, startColumns: startColumns,
                      lastFocalY: lastFocalY, time: time)
        default:
            tap = nil
            beginPinch(points[0], points[1], time: time)
        }
    }

    private var tapSlop: Double { 10 * viewport.scale }

    private func endGesture(time: Double) {
        switch gesture {
        case .drag: endDrag(time: time)
        case .pinch: endPinch(time: time)
        case .none, .blocked: break
        }
        gesture = .none
    }

    private func beginDrag(at point: SIMD2<Double>, time: Double) {
        if anchor == nil && restStop >= Self.overviewStop {
            gesture = .drag(lastY: point.y) // the overview doesn't scroll, but a tap opens a photo
            return
        }
        if anchor == nil {
            scrollMotion = .none
            dragRaw = scroll
            scrollVelocity.reset()
            scrollVelocity.add(time: time, value: dragRaw)
        }
        gesture = .drag(lastY: point.y)
    }

    private func moveDrag(by dy: Double, to point: SIMD2<Double>, time: Double) {
        gesture = .drag(lastY: point.y)
        if anchor != nil {
            anchor?.focal.y += dy // a zoom is still settling: carry it with the finger
            return
        }
        guard restStop < Self.overviewStop else { return }
        dragRaw -= dy
        scroll = rubberBand(dragRaw, min: 0, max: restingLayout().maxScroll, dimension: viewport.height)
        scrollVelocity.add(time: time, value: dragRaw)
    }

    private func endDrag(time: Double) {
        guard anchor == nil, restStop < Self.overviewStop else { return }
        let maxScroll = restingLayout().maxScroll
        if scroll < 0 || scroll > maxScroll {
            scrollMotion = .spring(Spring(value: scroll, velocity: 0, target: scroll < 0 ? 0 : maxScroll,
                                          response: 0.45, tolerance: 0.3))
        } else {
            let velocity = scrollVelocity.velocity(at: time)
            scrollMotion = abs(velocity) > 30 ? .momentum(velocity) : .none
        }
    }

    private func beginPinch(_ p0: SIMD2<Double>, _ p1: SIMD2<Double>, time: Double) {
        let focal = (p0 + p1) / 2
        if anchor == nil {
            scrollMotion = .none
            scroll = min(max(scroll, 0), restingLayout().maxScroll)
            anchor = hitTest(restingLayout(), at: focal)
        }
        // If a zoom is still settling, keep holding the same photo: grabbing a new one would jump.
        zoomSpring = nil
        zoomVelocity.reset()
        zoomVelocity.add(time: time, value: zoom)
        twoFingerTap = TapCandidate(point: focal, time: time, distance: simd_distance(p0, p1))
        gesture = .pinch(startDistance: max(simd_distance(p0, p1), 1), startColumns: columns(atZoom: zoom),
                         lastFocalY: focal.y)
    }

    private func movePinch(_ p0: SIMD2<Double>, _ p1: SIMD2<Double>, startDistance: Double, startColumns: Double,
                           lastFocalY: Double, time: Double) {
        let focal = (p0 + p1) / 2
        let distance = simd_distance(p0, p1)
        if let start = twoFingerTap, simd_distance(start.point, focal) > tapSlop || abs(start.distance - distance) > 2 * tapSlop {
            twoFingerTap?.isStill = false
        }
        let scale = distance / startDistance
        var target = zoom(forColumns: startColumns / scale)
        if target < 0 { target = max(target * 0.5, Self.minZoom) } // resist past one column
        zoom = min(target, Double(Self.overviewStop))
        anchor?.focal.y += focal.y - lastFocalY
        anchor?.focal.x = focal.x
        zoomVelocity.add(time: time, value: zoom)
        gesture = .pinch(startDistance: startDistance, startColumns: startColumns, lastFocalY: focal.y)
    }

    private func endPinch(time: Double) {
        guard let anchor else { return }
        if let start = twoFingerTap, start.isStill, time - start.time < 0.3 { onEvent?(.toggleHUD) }
        twoFingerTap = nil
        // Pinched in past a single column: carry on into the photo itself.
        if zoom < Self.openZoom { open(item: anchor.item) }
        let velocity = zoomVelocity.velocity(at: time)
        let projected = (zoom + velocity * 0.12).rounded()
        let target = min(max(projected, floor(zoom) - 1, 0), min(ceil(zoom) + 1, Double(Self.overviewStop)))
        let crossesOverview = zoom > Double(Self.overviewStop - 1) || target >= Double(Self.overviewStop)
        zoomSpring = Spring(value: zoom, velocity: velocity, target: target,
                            response: crossesOverview ? 0.7 : 0.32, tolerance: 0.002)
    }

    // MARK: - Photo view

    /// The photo whose full image the photo view is waiting for.
    var detailPhotoWanted: Int? { detail?.aspect == nil ? detail?.photo : nil }

    /// The full photo is ready (or, with a nil aspect, could not be decoded).
    func detailLoaded(photo: Int, aspect: Double?) {
        guard detail?.photo == photo, detail?.aspect == nil else { return }
        if let aspect {
            detail?.aspect = aspect
        } else {
            detail = nil
            onEvent?(.detail(false))
        }
    }

    private func openDetail(at point: SIMD2<Double>) {
        let layout = restingLayout()
        let hit = hitTest(layout, at: point)
        let cell = rect(of: hit.item, in: layout)
        guard point.x >= cell.x, point.x <= cell.x + cell.z, point.y >= cell.y, point.y <= cell.y + cell.w else { return }
        open(item: hit.item)
    }

    private func open(item: Int) {
        detail = PhotoDetail(item: item, photo: Int(library.photoOfItem[item]))
        detailGesture = .none
        onEvent?(.detail(true))
    }

    private func closeDetail() {
        detail?.close()
        onEvent?(.detail(false))
    }

    /// Where an item's tile sits on screen: x, y, width, height in pixels.
    private func rect(of item: Int, in layout: Layout) -> SIMD4<Double> {
        let cell = Int(library[layout.arrangement].cellOfItem[item]) + layout.shift
        let size = layout.pitch - layout.gap
        return SIMD4(layout.originX + Double(cell % layout.cols) * layout.pitch + layout.gap / 2,
                     layout.rowY(cell / layout.cols) + layout.gap / 2, size, size)
    }

    /// While a photo is open every touch belongs to it: drag it away, pinch it shut, or tap to close.
    private func detailTouchesChanged(_ points: [SIMD2<Double>], time: Double) {
        guard let open = detail, !open.isClosing else {
            detailGesture = .none
            return
        }
        switch (detailGesture, points.count) {
        case (.none, 0):
            break
        case (.blocked, 0):
            detailGesture = .none
        case (.drag(_, let began), 0):
            detailGesture = .none
            let velocity = detailVelocity.velocity(at: time)
            let isTap = simd_length(open.offset) < tapSlop && time - began < 0.3
            // A short, quick flick down is as good as a long drag.
            let isFlungDown = open.offset.y > tapSlop && velocity > viewport.height * 0.4
            if isTap || isFlungDown || open.offset.y > viewport.height * 0.12 {
                closeDetail()
            } else {
                detail?.settleBack()
            }
        case (.pinch, _):
            if points.count >= 2 {
                guard case .pinch(let start, let distance) = detailGesture else { break }
                detail?.offset = (points[0] + points[1]) / 2 - start
                detail?.scale = min(max(simd_distance(points[0], points[1]) / distance, 0.3), 1.15)
            } else {
                detailGesture = points.isEmpty ? .none : .blocked
                if open.scale < 0.85 { closeDetail() } else { detail?.settleBack() }
            }
        case (.none, 1):
            detail?.grab()
            detailVelocity.reset()
            detailGesture = .drag(start: points[0] - (detail?.offset ?? .zero), time: time)
        case (.drag(let start, _), 1):
            let offset = points[0] - start
            detail?.offset = offset
            detail?.scale = 1 - min(abs(offset.y) / viewport.height, 1) * 0.3
            detailVelocity.add(time: time, value: offset.y)
        case (.none, _), (.drag, _):
            detail?.grab()
            let focal = (points[0] + points[1]) / 2
            let scale = detail?.scale ?? 1
            detailGesture = .pinch(start: focal - (detail?.offset ?? .zero),
                                   distance: max(simd_distance(points[0], points[1]), 1) / scale)
        case (.blocked, _):
            break
        }
    }

    // MARK: - Mode

    /// Re-sorts the library in place. With Reduce Motion on, the two orders crossfade instead.
    @discardableResult
    func setMode(_ newMode: Mode, now: Double, reduceMotion: Bool) -> Bool {
        guard newMode != mode, morph == nil, anchor == nil else { return false }
        if case .none = gesture {} else { return false }
        scrollMotion = .none
        let fromScroll = min(max(scroll, 0), restingLayout().maxScroll)
        scroll = min(parkedScroll, layout(stop: restStop, mode: newMode, shift: shift).maxScroll)
        parkedScroll = fromScroll
        // At the overview all 100k tiles travel, so it gets longer; in the grid most only fade.
        let duration = reduceMotion ? 0.25 : restStop >= Self.overviewStop ? 1.1 : 0.7
        morph = Morph(from: mode, fromScroll: fromScroll, start: now, duration: duration, crossfade: reduceMotion)
        mode = newMode
        return true
    }

    // MARK: - What's on screen

    /// Photos on screen (closest to centre first) and the sharpest texture tier they need.
    func textureRequest(for state: FrameState) -> (photos: [Int], tier: Int) {
        guard state.style == .grid else { return ([], 0) }
        let layouts = (state.t > 0 ? [state.a, state.b] : [state.a]).filter(\.isScrollable)
        let largestCell = layouts.map { $0.pitch - $0.gap }.max() ?? 0
        let tier = largestCell > 420 ? 2 : largestCell > 200 ? 1 : 0
        guard tier > 0 else { return ([], 0) }

        var seen = Set<Int>()
        var ranked: [(distance: Double, photo: Int)] = []
        for layout in layouts where layout.pitch - layout.gap > 200 {
            let items = library[layout.arrangement].itemOfCell
            for row in layout.visibleRows(height: viewport.height, margin: viewport.height * 0.25) {
                let distance = abs(layout.rowY(row) + layout.pitch / 2 - viewport.height / 2)
                for col in 0..<layout.cols {
                    let cell = row * layout.cols + col - layout.shift
                    guard cell >= 0, cell < Library.itemCount else { continue }
                    let photo = Int(library.photoOfItem[Int(items[cell])])
                    if seen.insert(photo).inserted { ranked.append((distance, photo)) }
                }
            }
        }
        ranked.sort { $0.distance < $1.distance }
        return (ranked.map(\.photo), tier)
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    /// One line for the HUD: when you are in the library and how dense the grid is.
    func caption() -> String {
        let stop = restStop
        if stop >= Self.overviewStop {
            return mode == .date ? "Every pixel is a photo" : "Sorted by color"
        }
        let cols = stop + 1
        let columnsText = cols == 1 ? "1 column" : "\(cols) columns"
        guard mode == .date else { return "By color · \(columnsText)" }
        let center = hitTest(restingLayout(), at: SIMD2(viewport.width / 2, viewport.height / 2))
        // Mock dates: the library spans 2014 to today, newest at the bottom.
        let start = Date(timeIntervalSince1970: 1_388_534_400)
        let span = Date().timeIntervalSince(start)
        let date = start.addingTimeInterval(span * Double(center.item) / Double(Library.itemCount))
        return "\(Self.monthFormatter.string(from: date)) · \(columnsText)"
    }
}
