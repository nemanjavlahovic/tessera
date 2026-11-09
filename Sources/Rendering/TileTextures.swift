import Foundation
import ImageIO
import Metal
import Synchronization
import simd

/// Three texture tiers, all `texture2d_array`s:
/// - thumbs: 128px, one slice per photo, always resident (this is why no tile is ever blank)
/// - medium: 384px slots, loaded when cells are bigger than ~200px
/// - large: 1024px slots, loaded when cells are bigger than ~420px
@MainActor
final class TileTextures {
    nonisolated static let thumbSize = 128
    private static let tiers = [TierSpec(size: 384, slots: 192), TierSpec(size: 1024, slots: 24)]
    private static let fadeDuration = 0.18
    private static let uploadsPerFrame = 4

    private struct TierSpec { let size: Int; let slots: Int }

    let thumbs: MTLTexture
    private(set) var tierTextures: [MTLTexture] = []
    private var slotPhoto: [[Int]]
    private var slotLastUsed: [[Int]]
    private var slotLoadedAt: [[Double]]
    private var residentSlot: [[Int32]]
    private var pending = Set<Int>()
    private var wanted = Set<Int>()
    let fullURLs: [URL]
    private let decodeQueue: OperationQueue
    private let shared = DecodeShared()

    init(device: MTLDevice, thumbs: MTLTexture, fullURLs: [URL]) {
        self.thumbs = thumbs
        self.fullURLs = fullURLs
        let photoCount = fullURLs.count
        slotPhoto = Self.tiers.map { [Int](repeating: -1, count: $0.slots) }
        slotLastUsed = Self.tiers.map { [Int](repeating: -1_000, count: $0.slots) }
        slotLoadedAt = Self.tiers.map { [Double](repeating: 0, count: $0.slots) }
        residentSlot = Self.tiers.map { _ in [Int32](repeating: -1, count: photoCount) }
        decodeQueue = OperationQueue()
        decodeQueue.maxConcurrentOperationCount = 4
        decodeQueue.qualityOfService = .userInitiated
        tierTextures = Self.tiers.map { spec in
            Self.makeArray(device: device, size: spec.size, slices: spec.slots)
        }
    }

    /// Declares which photos are on screen (closest to centre first) and the sharpest tier
    /// they need (0 = thumbnails are enough). Starts decodes for anything missing.
    func request(photos: [Int], tier: Int, frame: Int) {
        var keys = Set<Int>()
        if tier > 0 {
            for photo in photos {
                for t in 0..<tier {
                    let slot = residentSlot[t][photo]
                    if slot >= 0 {
                        slotLastUsed[t][Int(slot)] = frame
                        continue
                    }
                    let key = photo * 4 + t
                    keys.insert(key)
                    if pending.insert(key).inserted { enqueueDecode(photo: photo, tier: t, key: key) }
                }
            }
        }
        if keys != wanted {
            wanted = keys
            shared.wanted.withLock { $0 = keys }
        }
    }

    /// Copies finished decodes into free (or least-recently-used) slots and queues their mipmaps.
    func uploadFinished(frame: Int, now: Double, commandBuffer: MTLCommandBuffer) {
        let batch = shared.finished.withLock { finished -> [Decoded] in
            let count = min(finished.count, Self.uploadsPerFrame)
            let batch = Array(finished.prefix(count))
            finished.removeFirst(count)
            return batch
        }
        guard !batch.isEmpty else { return }

        var uploaded: [(MTLTexture, Int)] = []
        for decoded in batch {
            pending.remove(decoded.key)
            guard !decoded.bytes.isEmpty, wanted.contains(decoded.key) else { continue }
            let photo = decoded.key / 4, tier = decoded.key % 4
            guard let slot = allocateSlot(tier: tier, frame: frame) else { continue }
            let size = Self.tiers[tier].size
            let texture = tierTextures[tier]
            decoded.bytes.withUnsafeBytes { raw in
                texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, slice: slot,
                                withBytes: raw.baseAddress!, bytesPerRow: size * 4, bytesPerImage: size * size * 4)
            }
            slotPhoto[tier][slot] = photo
            slotLastUsed[tier][slot] = frame
            slotLoadedAt[tier][slot] = now
            residentSlot[tier][photo] = Int32(slot)
            uploaded.append((texture, slot))
        }

        guard !uploaded.isEmpty, let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        for (texture, slot) in uploaded {
            if let view = texture.makeTextureView(pixelFormat: texture.pixelFormat, textureType: .type2D,
                                                  levels: 0..<texture.mipmapLevelCount, slices: slot..<(slot + 1)) {
                blit.generateMipmaps(for: view)
            }
        }
        blit.endEncoding()
    }

    /// Fills the per-photo residency table the shader reads.
    func writeResidency(into pointer: UnsafeMutableRawPointer, now: Double) {
        let table = pointer.bindMemory(to: PhotoResidency.self, capacity: fullURLs.count)
        for photo in 0..<fullURLs.count {
            let medium = residentSlot[0][photo], large = residentSlot[1][photo]
            table[photo] = PhotoResidency(
                mediumSlot: medium,
                largeSlot: large,
                mediumAlpha: medium >= 0 ? fade(since: slotLoadedAt[0][Int(medium)], now: now) : 0,
                largeAlpha: large >= 0 ? fade(since: slotLoadedAt[1][Int(large)], now: now) : 0
            )
        }
    }

    private func fade(since loadedAt: Double, now: Double) -> Float {
        Float(min(1, max(0, (now - loadedAt) / Self.fadeDuration)))
    }

    /// A free slot, or the least recently used one that no in-flight frame can still be reading.
    private func allocateSlot(tier: Int, frame: Int) -> Int? {
        var best: Int?
        var bestUsed = frame - 3
        for slot in 0..<slotPhoto[tier].count {
            if slotPhoto[tier][slot] < 0 { return slot }
            if slotLastUsed[tier][slot] < bestUsed {
                bestUsed = slotLastUsed[tier][slot]
                best = slot
            }
        }
        if let best { residentSlot[tier][slotPhoto[tier][best]] = -1 }
        return best
    }

    private func enqueueDecode(photo: Int, tier: Int, key: Int) {
        let url = fullURLs[photo]
        let size = Self.tiers[tier].size
        let shared = self.shared
        decodeQueue.addOperation {
            var bytes: [UInt8] = []
            if shared.wanted.withLock({ $0.contains(key) }) {
                bytes = ImageDecoder.squareBGRA(url: url, size: size) ?? []
            }
            shared.finished.withLock { $0.append(Decoded(key: key, bytes: bytes)) }
        }
    }

    nonisolated private static func makeArray(device: MTLDevice, size: Int, slices: Int) -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .bgra8Unorm
        descriptor.width = size
        descriptor.height = size
        descriptor.arrayLength = slices
        descriptor.mipmapLevelCount = Int(log2(Double(size))) + 1
        descriptor.usage = [.shaderRead, .pixelFormatView]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)!
    }

    /// Decodes every thumbnail in parallel into one resident array texture, and measures each
    /// photo's average colour (used by the colour sort and the picture).
    nonisolated static func loadThumbnails(device: MTLDevice, queue: MTLCommandQueue, urls: [URL]) -> ThumbnailAtlas {
        let size = thumbSize
        let sliceBytes = size * size * 4
        var pixels = [UInt8](repeating: 0, count: sliceBytes * urls.count)
        var colors = [SIMD3<Float>](repeating: SIMD3(repeating: 0.5), count: urls.count)
        pixels.withUnsafeMutableBufferPointer { pixelBuffer in
            colors.withUnsafeMutableBufferPointer { colorBuffer in
                nonisolated(unsafe) let pixelBase = pixelBuffer.baseAddress!
                nonisolated(unsafe) let colorBase = colorBuffer.baseAddress! // each iteration writes its own slice
                DispatchQueue.concurrentPerform(iterations: urls.count) { i in
                    guard let bytes = ImageDecoder.squareBGRA(url: urls[i], size: size) else { return }
                    let slice = pixelBase + i * sliceBytes
                    var sum = SIMD3<Float>.zero
                    for p in 0..<(size * size) {
                        let b = bytes[p * 4], g = bytes[p * 4 + 1], r = bytes[p * 4 + 2]
                        sum += SIMD3(Float(r), Float(g), Float(b))
                    }
                    bytes.withUnsafeBytes { slice.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: sliceBytes) }
                    colorBase[i] = sum / Float(size * size * 255)
                }
            }
        }

        let texture = makeArray(device: device, size: size, slices: urls.count)
        pixels.withUnsafeBytes { raw in
            for i in 0..<urls.count {
                texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, slice: i,
                                withBytes: raw.baseAddress! + i * sliceBytes, bytesPerRow: size * 4, bytesPerImage: sliceBytes)
            }
        }
        if let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
        }
        return ThumbnailAtlas(texture: texture, colors: colors)
    }
}

/// The finished thumbnail texture, handed from the loading thread to the main actor.
/// Safe to send: nothing writes to it after loading completes.
struct ThumbnailAtlas: @unchecked Sendable {
    let texture: MTLTexture
    let colors: [SIMD3<Float>]
}

struct PhotoResidency {
    var mediumSlot: Int32
    var largeSlot: Int32
    var mediumAlpha: Float
    var largeAlpha: Float
}

private struct Decoded: Sendable {
    let key: Int
    let bytes: [UInt8]
}

private final class DecodeShared: Sendable {
    let wanted = Mutex<Set<Int>>([])
    let finished = Mutex<[Decoded]>([])
}

enum ImageDecoder {
    /// Decodes a square, centre-cropped BGRA bitmap at `size` px, using ImageIO's
    /// downsampling decoder so large JPEGs never decode at full resolution.
    static func squareBGRA(url: URL, size: Int) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // Photos keep their original shape on disk. Ask for a decode whose short side is `size`,
        // so the square crop below never has to scale up.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelWidth = properties?[kCGImagePropertyPixelWidth] as? Double ?? 1
        let pixelHeight = properties?[kCGImagePropertyPixelHeight] as? Double ?? 1
        let longSide = Double(size) * max(pixelWidth, pixelHeight) / min(pixelWidth, pixelHeight)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(longSide.rounded(.up)),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                          bytesPerRow: size * 4, space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            context.interpolationQuality = .high
            let w = CGFloat(image.width), h = CGFloat(image.height)
            let scale = CGFloat(size) / min(w, h)
            context.draw(image, in: CGRect(x: (CGFloat(size) - w * scale) / 2, y: (CGFloat(size) - h * scale) / 2,
                                           width: w * scale, height: h * scale))
            return true
        }
        return drawn ? bytes : nil
    }
}
