import MetalKit
import QuartzCore
import Synchronization

/// Draws the library with instanced quads placed entirely by the vertex shader. The CPU only
/// writes small layout descriptions and a ~1,000-entry residency table per frame.
/// Scrolling and zooming submit just the cells on screen; a re-sort submits all 100,000 items.
@MainActor
final class Renderer: NSObject, MTKViewDelegate {
    struct Stats {
        var fps: Double
        var gpuMilliseconds: Double
    }

    let controller: GridController
    var onStats: ((Stats) -> Void)?

    private let queue: MTLCommandQueue
    private let gridPipeline: MTLRenderPipelineState
    private let morphPipeline: MTLRenderPipelineState
    private let detailPipeline: MTLRenderPipelineState
    private let detailTexture: DetailTexture
    private let sampler: MTLSamplerState
    private let textures: TileTextures
    private let cellOfItemBuffers: [MTLBuffer]
    private let itemOfCellBuffers: [MTLBuffer]
    private let photoOfItemBuffer: MTLBuffer
    private let residencyBuffers: [MTLBuffer]
    private let inFlight = DispatchSemaphore(value: 3)
    private let gpuTime = GPUTime()
    private var frameIndex = 0
    private var statsWindowStart = 0.0
    private var statsFrames = 0

    init(view: MTKView, device: MTLDevice, queue: MTLCommandQueue, library: Library, textures: TileTextures) throws {
        self.queue = queue
        self.textures = textures
        controller = GridController(library: library)

        let functions = device.makeDefaultLibrary()!
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.fragmentFunction = functions.makeFunction(name: "tileFragment")
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = view.colorPixelFormat
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .sourceAlpha
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        descriptor.vertexFunction = functions.makeFunction(name: "gridVertex")
        gridPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.vertexFunction = functions.makeFunction(name: "morphVertex")
        morphPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.vertexFunction = functions.makeFunction(name: "detailVertex")
        descriptor.fragmentFunction = functions.makeFunction(name: "detailFragment")
        detailPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        detailTexture = DetailTexture(device: device, queue: queue, urls: textures.fullURLs)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: samplerDescriptor)!

        func buffer(_ values: [UInt32]) -> MTLBuffer {
            values.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! }
        }
        cellOfItemBuffers = library.arrangements.map { buffer($0.cellOfItem) }
        itemOfCellBuffers = library.arrangements.map { buffer($0.itemOfCell) }
        photoOfItemBuffer = library.photoOfItem.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! }
        let residencyLength = MemoryLayout<PhotoResidency>.stride * library.photoCount
        residencyBuffers = (0..<3).map { _ in device.makeBuffer(length: residencyLength, options: .storageModeShared)! }
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        inFlight.wait()
        frameIndex += 1

        let state = controller.frame(at: now)
        if let wanted = controller.detailPhotoWanted {
            detailTexture.load(wanted) { [controller] aspect in controller.detailLoaded(photo: wanted, aspect: aspect) }
        }
        let request = controller.textureRequest(for: state)
        textures.request(photos: request.photos, tier: request.tier, frame: frameIndex)

        guard let commands = queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        textures.uploadFinished(frame: frameIndex, now: now, commandBuffer: commands)
        let residency = residencyBuffers[frameIndex % residencyBuffers.count]
        textures.writeResidency(into: residency.contents(), now: now)

        let semaphore = inFlight
        let gpuTime = self.gpuTime
        commands.addCompletedHandler { buffer in
            gpuTime.milliseconds.withLock { $0 = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000 }
            semaphore.signal()
        }

        if let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
           let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
            let viewport = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
            encoder.setVertexBuffer(photoOfItemBuffer, offset: 0, index: 3)
            encoder.setVertexBuffer(residency, offset: 0, index: 4)
            encoder.setFragmentTexture(textures.thumbs, index: 0)
            encoder.setFragmentTexture(textures.tierTextures[0], index: 1)
            encoder.setFragmentTexture(textures.tierTextures[1], index: 2)
            encoder.setFragmentSamplerState(sampler, index: 0)
            switch state.style {
            case .grid:
                encoder.setRenderPipelineState(gridPipeline)
                // The handoff happens through the middle of each step, so most of a pinch shows
                // one sharp grid rather than two half-transparent ones.
                let x = min(max((state.t - 0.3) / 0.4, 0), 1)
                let fade = x * x * (3 - 2 * x)
                if fade < 1 { drawGrid(state.a, alpha: 1, viewport: viewport, encoder: encoder) }
                if fade > 0 { drawGrid(state.b, alpha: fade, viewport: viewport, encoder: encoder) }
            case .morph:
                if state.underlay {
                    let fade = min(max((state.t - 0.15) / 0.7, 0), 1)
                    encoder.setRenderPipelineState(gridPipeline)
                    drawGrid(state.b, alpha: 1, viewport: viewport, encoder: encoder)
                    if fade < 1 { drawGrid(state.a, alpha: 1 - fade, viewport: viewport, encoder: encoder) }
                }
                var uniforms = Uniforms(viewport: viewport, focal: SIMD2(Float(state.focal.x), Float(state.focal.y)),
                                        t: Float(state.t), stagger: Float(state.stagger), alpha: state.underlay ? 0 : 1, firstRow: 0, firstCol: 0, drawCols: 0,
                                        itemCount: UInt32(Library.itemCount),
                                        a: LayoutUniforms(state.a), b: LayoutUniforms(state.b))
                encoder.setRenderPipelineState(morphPipeline)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setVertexBuffer(cellOfItemBuffers[state.a.arrangement.rawValue], offset: 0, index: 1)
                encoder.setVertexBuffer(cellOfItemBuffers[state.b.arrangement.rawValue], offset: 0, index: 2)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: Library.itemCount)
            }
            if let detail = state.detail, detailTexture.photo == detail.photo, let photo = detailTexture.texture {
                drawDetail(detail, photo: photo, viewport: viewport, encoder: encoder)
            }
            encoder.endEncoding()
            commands.present(drawable)
        }
        commands.commit()
        reportStats(now: now)
    }

    /// Draws the rows of one grid that are on screen.
    private func drawGrid(_ layout: Layout, alpha: Double, viewport: SIMD2<Float>, encoder: MTLRenderCommandEncoder) {
        let rows = layout.visibleRows(height: Double(viewport.y), margin: 0)
        var columns = 0...(layout.cols - 1)
        if layout.isScrollable {
            // Mid-zoom the grid can be narrower or wider than the screen: draw exactly the columns
            // that are on screen, including ones past the grid's own edges.
            let first = Int(floor(-layout.originX / layout.pitch))
            let last = Int(ceil((Double(viewport.x) - layout.originX) / layout.pitch)) - 1
            columns = max(first, -layout.cols)...max(first, min(last, 2 * layout.cols - 1))
        }
        let layoutUniforms = LayoutUniforms(layout)
        var uniforms = Uniforms(viewport: viewport, focal: .zero, t: 0, stagger: 0, alpha: Float(alpha),
                                firstRow: Int32(rows.lowerBound), firstCol: Int32(columns.lowerBound),
                                drawCols: UInt32(columns.count), itemCount: UInt32(Library.itemCount),
                                a: layoutUniforms, b: layoutUniforms)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setVertexBuffer(itemOfCellBuffers[layout.arrangement.rawValue], offset: 0, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: rows.count * columns.count)
    }

    /// Draws the open photo over a black backdrop.
    private func drawDetail(_ detail: DetailFrame, photo: MTLTexture, viewport: SIMD2<Float>, encoder: MTLRenderCommandEncoder) {
        encoder.setRenderPipelineState(detailPipeline)
        encoder.setFragmentTexture(photo, index: 0)
        let quads = [
            DetailUniforms(rect: SIMD4(0, 0, viewport.x, viewport.y), uv: .zero, viewport: viewport,
                           alpha: Float(detail.backdrop), solid: 1),
            DetailUniforms(rect: SIMD4<Float>(detail.rect), uv: SIMD4<Float>(detail.uv), viewport: viewport,
                           alpha: 1, solid: 0),
        ]
        for var uniforms in quads {
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<DetailUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DetailUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    private func reportStats(now: Double) {
        statsFrames += 1
        let elapsed = now - statsWindowStart
        guard elapsed >= 0.25 else { return }
        onStats?(Stats(fps: Double(statsFrames) / elapsed, gpuMilliseconds: gpuTime.milliseconds.withLock { $0 }))
        statsWindowStart = now
        statsFrames = 0
    }
}

/// Written by Metal's completion handler thread, read by the HUD.
private final class GPUTime: Sendable {
    let milliseconds = Mutex<Double>(0)
}

/// Mirrors `LayoutU` in Shaders.metal. Rows are relative to `baseRow` to keep floats exact deep in the library.
struct LayoutUniforms {
    var cols: UInt32
    var shift: UInt32
    var pitch: Float
    var gap: Float
    var originX: Float
    var yOffset: Float
    var baseRow: Int32

    init(_ layout: Layout) {
        let baseRow = floor(layout.scrollY / layout.pitch)
        cols = UInt32(layout.cols)
        shift = UInt32(layout.shift)
        pitch = Float(layout.pitch)
        gap = Float(layout.gap)
        originX = Float(layout.originX)
        yOffset = Float(layout.top - (layout.scrollY - baseRow * layout.pitch))
        self.baseRow = Int32(baseRow)
    }
}

/// Mirrors `Uniforms` in Shaders.metal.
struct Uniforms {
    var viewport: SIMD2<Float>
    var focal: SIMD2<Float>
    var t: Float
    var stagger: Float
    var alpha: Float
    var firstRow: Int32
    var firstCol: Int32
    var drawCols: UInt32
    var itemCount: UInt32
    var a: LayoutUniforms
    var b: LayoutUniforms
}

/// Mirrors `DetailUniforms` in Shaders.metal.
struct DetailUniforms {
    var rect: SIMD4<Float>
    var uv: SIMD4<Float>
    var viewport: SIMD2<Float>
    var alpha: Float
    var solid: Float
}
