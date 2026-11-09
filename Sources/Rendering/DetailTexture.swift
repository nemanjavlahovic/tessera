import Foundation
import ImageIO
import Metal

/// The one full, uncropped photo shown by the photo view. Decoded off the main thread on demand.
@MainActor
final class DetailTexture {
    private(set) var texture: MTLTexture?
    private(set) var photo: Int?
    private var loading: Int?
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let urls: [URL]

    init(device: MTLDevice, queue: MTLCommandQueue, urls: [URL]) {
        self.device = device
        self.queue = queue
        self.urls = urls
    }

    /// Loads `photo` unless it is already loaded or on its way, then reports its width / height.
    /// Reports nil if the file can't be decoded.
    func load(_ photo: Int, onReady: @escaping @MainActor (Double?) -> Void) {
        if self.photo == photo, let texture {
            onReady(Double(texture.width) / Double(texture.height))
            return
        }
        guard loading != photo else { return }
        loading = photo
        let url = urls[photo]
        Task {
            let image = await Task.detached(priority: .userInitiated) {
                ImageDecoder.bgra(url: url, maxPixelSize: 1536)
            }.value
            guard loading == photo else { return }
            loading = nil
            guard let image, let texture = makeTexture(image) else {
                onReady(nil)
                return
            }
            self.texture = texture
            self.photo = photo
            onReady(Double(image.width) / Double(image.height))
        }
    }

    private func makeTexture(_ image: DecodedImage) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: image.width,
                                                                  height: image.height, mipmapped: true)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        image.bytes.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: image.width * 4)
        }
        // Mipmaps keep the photo clean while it is still small, growing out of its cell.
        if let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            commands.commit()
        }
        return texture
    }
}

struct DecodedImage: Sendable {
    let bytes: [UInt8]
    let width: Int
    let height: Int
}

extension ImageDecoder {
    /// Decodes the whole image, uncropped, with its long side at most `maxPixelSize`.
    static func bgra(url: URL, maxPixelSize: Int) -> DecodedImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? DecodedImage(bytes: bytes, width: width, height: height) : nil
    }
}
