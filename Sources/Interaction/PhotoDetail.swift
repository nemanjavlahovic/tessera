import Foundation
import simd

/// What the renderer needs to draw the open photo this frame.
struct DetailFrame {
    var photo: Int
    /// x, y, width, height in pixels.
    var rect: SIMD4<Double>
    /// The part of the photo shown, as x, y, width, height in 0...1.
    var uv: SIMD4<Double>
    var backdrop: Double
}

/// One photo opened from the grid. It grows out of its cell to fill the screen at its true
/// shape, follows a drag or pinch, and returns to its cell when dismissed.
struct PhotoDetail {
    let item: Int
    let photo: Int
    /// Width / height. Nil until the full photo has been decoded; nothing moves before then.
    var aspect: Double?
    /// The user's drag (px) and pinch applied to the presented photo.
    var offset = SIMD2<Double>.zero
    var scale = 1.0
    private(set) var isClosing = false
    /// 0 = in its cell, 1 = presented.
    private var progress = Spring(value: 0, velocity: 0, target: 1, response: 0.4, tolerance: 0.001)
    /// 1 → 0 after a drag that didn't dismiss: how much of the drag is still applied.
    private var release: Spring?

    init(item: Int, photo: Int) {
        self.item = item
        self.photo = photo
    }

    var isFinished: Bool { isClosing && progress.isSettled }

    mutating func step(_ dt: Double) {
        guard aspect != nil else { return }
        progress.step(dt)
        guard var release else { return }
        release.step(dt)
        if release.isSettled {
            offset = .zero
            scale = 1
            self.release = nil
        } else {
            self.release = release
        }
    }

    /// A finger took hold again: keep whatever is left of the last drag.
    mutating func grab() {
        guard let release else { return }
        offset *= release.value
        scale = 1 + (scale - 1) * release.value
        self.release = nil
    }

    mutating func settleBack() {
        release = Spring(value: 1, velocity: 0, target: 0, response: 0.35, tolerance: 0.001)
    }

    /// Returns to the cell from wherever the photo is now. Faster than opening: the user is done.
    mutating func close() {
        guard !isClosing else { return }
        isClosing = true
        progress = Spring(value: progress.value, velocity: 0, target: 0, response: 0.32, tolerance: 0.001)
    }

    func frame(cell: SIMD4<Double>, viewport: Viewport) -> DetailFrame? {
        guard let aspect else { return nil }
        let held = release?.value ?? 1
        let offset = self.offset * held
        let scale = 1 + (self.scale - 1) * held

        // The photo at rest: as large as fits the screen, centred.
        var size = SIMD2(viewport.width, viewport.width / aspect)
        if size.y > viewport.height { size = SIMD2(viewport.height * aspect, viewport.height) }
        size *= scale
        let center = SIMD2(viewport.width, viewport.height) / 2 + offset
        let presented = SIMD4(center.x - size.x / 2, center.y - size.y / 2, size.x, size.y)

        let e = min(max(progress.value, 0), 1)
        let rect = cell + (presented - cell) * e

        // Show the largest centred part of the photo that has the rectangle's shape, so the
        // crop opens up from the cell's square to the whole photo without ever stretching.
        let shape = rect.z / rect.w
        let uv = shape <= aspect
            ? SIMD4((1 - shape / aspect) / 2, 0, shape / aspect, 1)
            : SIMD4(0, (1 - aspect / shape) / 2, 1, aspect / shape)

        let dragged = min(1, max(simd_length(offset) / (viewport.height * 0.5), (1 - scale) * 2))
        return DetailFrame(photo: photo, rect: rect, uv: uv, backdrop: e * (1 - dragged))
    }
}
