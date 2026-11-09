import Foundation
import simd

/// Where each of the 100k items sits. `cellOfItem` drives the GPU; `itemOfCell` answers
/// "which photo is under this finger".
struct Arrangement: Sendable {
    let cellOfItem: [UInt32]
    let itemOfCell: [UInt32]

    init(itemOfCell: [UInt32]) {
        var cellOfItem = [UInt32](repeating: 0, count: itemOfCell.count)
        for (cell, item) in itemOfCell.enumerated() { cellOfItem[Int(item)] = UInt32(cell) }
        self.itemOfCell = itemOfCell
        self.cellOfItem = cellOfItem
    }
}

enum ArrangementID: Int, CaseIterable, Sendable {
    case date, color, picture
}

/// A mock library: ~1,000 real photos repeated into 100,000 items, plus three
/// arrangements of those same items. Every item appears exactly once in each.
struct Library: Sendable {
    static let itemCount = 100_000
    static let pictureColumns = 216
    static var pictureRows: Int { (itemCount + pictureColumns - 1) / pictureColumns }

    let photoCount: Int
    let photoOfItem: [UInt16]
    let arrangements: [Arrangement]

    init(photoColors: [SIMD3<Float>]) {
        let n = Self.itemCount
        photoCount = photoColors.count
        var rng = SplitMix64(seed: 7)

        // Date order: every block of `photoCount` items is a fresh shuffle of all photos.
        var photoOfItem = [UInt16](repeating: 0, count: n)
        var block = Array(0..<photoCount)
        var i = 0
        while i < n {
            block.shuffle(using: &rng)
            for p in block where i < n {
                photoOfItem[i] = UInt16(p)
                i += 1
            }
        }
        self.photoOfItem = photoOfItem

        let date = Arrangement(itemOfCell: (0..<n).map { UInt32($0) })
        let color = Self.colorArrangement(photoColors: photoColors, photoOfItem: photoOfItem, rng: &rng)
        let picture = Self.pictureArrangement(photoColors: photoColors, photoOfItem: photoOfItem, rng: &rng)
        arrangements = [date, color, picture]
    }

    subscript(_ id: ArrangementID) -> Arrangement { arrangements[id.rawValue] }

    /// Rainbow order: photos ranked by hue (greys last), with a little jitter so the
    /// ~100 copies of each photo spread out instead of sitting in one run.
    private static func colorArrangement(photoColors: [SIMD3<Float>], photoOfItem: [UInt16], rng: inout SplitMix64) -> Arrangement {
        let ranked = photoColors.indices.sorted { hueKey(photoColors[$0]) < hueKey(photoColors[$1]) }
        var rank = [Float](repeating: 0, count: photoColors.count)
        for (r, p) in ranked.enumerated() { rank[p] = Float(r) / Float(photoColors.count) }
        let keys = photoOfItem.map { rank[Int($0)] + Float.random(in: -0.02...0.02, using: &rng) }
        let order = keys.indices.sorted { keys[$0] < keys[$1] }
        return Arrangement(itemOfCell: order.map { UInt32($0) })
    }

    private static func hueKey(_ c: SIMD3<Float>) -> Float {
        let hi = c.max(), lo = c.min()
        let saturation = hi > 0 ? (hi - lo) / hi : 0
        if saturation < 0.07 || hi < 0.12 { return 2 - hi } // greys after the rainbow, light to dark
        var hue: Float
        if hi == c.x { hue = (c.y - c.z) / (hi - lo) }
        else if hi == c.y { hue = 2 + (c.z - c.x) / (hi - lo) }
        else { hue = 4 + (c.x - c.y) / (hi - lo) }
        hue = (hue / 6).truncatingRemainder(dividingBy: 1)
        if hue < 0 { hue += 1 }
        return (hue + 0.04).truncatingRemainder(dividingBy: 1)
    }

    /// The picture: each cell of a 216-wide grid gets a target colour (plus a little dither),
    /// then cells, visited in random order, each take the closest-coloured photo that still has
    /// unused copies. Every item lands in exactly one cell, so the morph is a true rearrangement.
    private static func pictureArrangement(photoColors: [SIMD3<Float>], photoOfItem: [UInt16], rng: inout SplitMix64) -> Arrangement {
        let n = photoOfItem.count
        let target = matchBrightness(of: Picture.sunset(width: pictureColumns, height: pictureRows),
                                     to: photoOfItem.map { photoColors[Int($0)] })

        var copies = [[UInt32]](repeating: [], count: photoColors.count)
        for (item, photo) in photoOfItem.enumerated() { copies[Int(photo)].append(UInt32(item)) }
        for p in copies.indices { copies[p].shuffle(using: &rng) }
        let features = photoColors.map(perceptual)
        var available = copies.indices.filter { !copies[$0].isEmpty }

        var order = Array(0..<n)
        order.shuffle(using: &rng)
        var itemOfCell = [UInt32](repeating: 0, count: n)
        for cell in order {
            let dither = SIMD3<Float>(Float.random(in: -0.03...0.03, using: &rng),
                                      Float.random(in: -0.03...0.03, using: &rng),
                                      Float.random(in: -0.03...0.03, using: &rng))
            let want = perceptual(target[cell] + dither)
            var bestIndex = 0
            var bestDistance = Float.infinity
            for (index, photo) in available.enumerated() {
                let distance = simd_length_squared(features[photo] - want)
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }
            let photo = available[bestIndex]
            itemOfCell[cell] = copies[photo].removeLast()
            if copies[photo].isEmpty {
                available.swapAt(bestIndex, available.count - 1)
                available.removeLast()
            }
        }
        return Arrangement(itemOfCell: itemOfCell)
    }

    /// Shifts each target pixel's brightness to the library's brightness at the same rank, so the
    /// picture asks for as many dark, mid and light photos as the library actually has.
    private static func matchBrightness(of target: [SIMD3<Float>], to supply: [SIMD3<Float>]) -> [SIMD3<Float>] {
        let luma = { (c: SIMD3<Float>) in simd_dot(c, SIMD3(0.2126, 0.7152, 0.0722)) }
        let available = supply.map(luma).sorted()
        let cells = target.prefix(available.count)
        let ranked = cells.indices.sorted { luma(cells[$0]) < luma(cells[$1]) }
        var result = Array(cells)
        for (rank, cell) in ranked.enumerated() {
            let shift = available[rank] - luma(cells[cell])
            result[cell] = simd_clamp(cells[cell] + shift, .zero, SIMD3(repeating: 1))
        }
        return result
    }

    /// An opponent colour space where brightness counts most, roughly how the eye ranks
    /// "close enough" at a few pixels per photo.
    private static func perceptual(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let luma = simd_dot(c, SIMD3(0.2126, 0.7152, 0.0722))
        return SIMD3(luma * 1.8, c.x - c.y, (c.x + c.y) * 0.5 - c.z)
    }
}

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
