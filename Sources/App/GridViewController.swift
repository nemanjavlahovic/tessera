import MetalKit
import UIKit

@MainActor
final class GridViewController: UIViewController {
    private let device = MTLCreateSystemDefaultDevice()!
    private lazy var metalView = TileView(frame: .zero, device: device)
    private let hud = UILabel()
    private let hudBackground = UIVisualEffectView(effect: UIGlassEffect())
    private let modeControl = UISegmentedControl(items: ["Date", "Color"])
    private var renderer: Renderer?
    private let tick = UISelectionFeedbackGenerator()
    private let thud = UIImpactFeedbackGenerator(style: .medium)
    private let lift = UIImpactFeedbackGenerator(style: .soft)
    private var lastTick = 0.0
    private var isHUDHidden = false
    private var isPhotoOpen = false

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        metalView.colorPixelFormat = .bgra8Unorm
        metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        metalView.preferredFramesPerSecond = 120
        metalView.isPaused = true
        metalView.isMultipleTouchEnabled = true
        metalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(metalView)

        hud.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        hud.textColor = .white
        hud.numberOfLines = 2
        hud.textAlignment = .center
        hud.text = "Loading photos…"
        hud.translatesAutoresizingMaskIntoConstraints = false
        hudBackground.cornerConfiguration = .capsule()
        hudBackground.translatesAutoresizingMaskIntoConstraints = false
        hudBackground.isUserInteractionEnabled = false // touches go through to the grid
        hudBackground.contentView.addSubview(hud)
        view.addSubview(hudBackground)

        modeControl.selectedSegmentIndex = 0
        modeControl.isEnabled = false
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        modeControl.addAction(UIAction { [weak self] _ in self?.modeChanged() }, for: .valueChanged)
        view.addSubview(modeControl)

        NSLayoutConstraint.activate([
            metalView.topAnchor.constraint(equalTo: view.topAnchor),
            metalView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            metalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            hudBackground.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            hudBackground.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hud.topAnchor.constraint(equalTo: hudBackground.contentView.topAnchor, constant: 8),
            hud.bottomAnchor.constraint(equalTo: hudBackground.contentView.bottomAnchor, constant: -8),
            hud.leadingAnchor.constraint(equalTo: hudBackground.contentView.leadingAnchor, constant: 18),
            hud.trailingAnchor.constraint(equalTo: hudBackground.contentView.trailingAnchor, constant: -18),

            modeControl.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            modeControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            modeControl.widthAnchor.constraint(equalToConstant: 200),
        ])

        Task { await load() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateViewport()
    }

    private func load() async {
        guard let photos = PhotoFiles.inBundle(), !photos.thumbs.isEmpty else {
            hud.text = "No photos bundled.\nRun scripts/fetch-photos.sh"
            return
        }
        let device = self.device
        let queue = device.makeCommandQueue()!
        let atlas = await Task.detached(priority: .userInitiated) {
            TileTextures.loadThumbnails(device: device, queue: queue, urls: photos.thumbs)
        }.value
        let library = await Task.detached(priority: .userInitiated) { Library(photoColors: atlas.colors) }.value

        do {
            let textures = TileTextures(device: device, thumbs: atlas.texture, fullURLs: photos.full)
            let renderer = try Renderer(view: metalView, device: device, queue: queue, library: library, textures: textures)
            renderer.onStats = { [weak self] stats in self?.showStats(stats) }
            renderer.controller.onEvent = { [weak self] event in self?.handle(event) }
            metalView.delegate = renderer
            metalView.onTouches = { [weak renderer] points, time in renderer?.controller.touchesChanged(points, time: time) }
            self.renderer = renderer
            updateViewport()
            modeControl.isEnabled = true
            metalView.isPaused = false
        } catch {
            hud.text = "Metal setup failed:\n\(error.localizedDescription)"
        }
    }

    private func updateViewport() {
        let scale = metalView.contentScaleFactor
        let size = metalView.bounds.size
        guard let renderer, size.width > 0 else { return }
        let insets = view.safeAreaInsets
        renderer.controller.setViewport(Viewport(
            width: size.width * scale,
            height: size.height * scale,
            safeTop: (insets.top + 56) * scale,     // clear the HUD
            safeBottom: (insets.bottom + 56) * scale, // clear the sort control
            scale: scale
        ))
    }

    private func modeChanged() {
        guard let controller = renderer?.controller else { return }
        let mode: GridController.Mode = modeControl.selectedSegmentIndex == 0 ? .date : .color
        if !controller.setMode(mode, now: CACurrentMediaTime(), reduceMotion: UIAccessibility.isReduceMotionEnabled) {
            modeControl.selectedSegmentIndex = controller.mode == .date ? 0 : 1
        }
    }

    private func handle(_ event: GridController.Event) {
        switch event {
        case .tick:
            // A fast pinch crosses many column counts; cap the ticks so they stay distinct.
            let now = CACurrentMediaTime()
            guard now - lastTick > 0.04 else { return }
            lastTick = now
            tick.selectionChanged()
        case .lock:
            thud.impactOccurred()
        case .detail(let isOpen):
            if isOpen { lift.impactOccurred() }
            isPhotoOpen = isOpen
            updateOverlays()
        case .toggleHUD:
            isHUDHidden.toggle()
            updateOverlays()
        }
    }

    /// The HUD and sort control step aside for an open photo; a two-finger tap hides the HUD alone.
    private func updateOverlays() {
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
            self.hudBackground.alpha = self.isPhotoOpen || self.isHUDHidden ? 0 : 1
            self.modeControl.alpha = self.isPhotoOpen ? 0 : 1
        }
    }

    private func showStats(_ stats: Renderer.Stats) {
        guard let controller = renderer?.controller else { return }
        hud.text = String(format: "%.0f fps · %.2f ms GPU · 100,000 photos\n", stats.fps, stats.gpuMilliseconds) + controller.caption()
    }
}

/// An MTKView that reports raw touches immediately (no gesture-recognizer delay), in pixels.
final class TileView: MTKView {
    var onTouches: (([SIMD2<Double>], Double) -> Void)?
    private var active: [UITouch] = []

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where !active.contains(touch) { active.append(touch) }
        report(event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { report(event) }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        active.removeAll { touches.contains($0) }
        report(event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        active.removeAll { touches.contains($0) }
        report(event)
    }

    private func report(_ event: UIEvent?) {
        let scale = Double(contentScaleFactor)
        let points = active.map { touch -> SIMD2<Double> in
            let p = touch.location(in: self)
            return SIMD2(Double(p.x) * scale, Double(p.y) * scale)
        }
        onTouches?(points, event?.timestamp ?? CACurrentMediaTime())
    }
}

struct PhotoFiles: Sendable {
    let thumbs: [URL]
    let full: [URL]

    static func inBundle() -> PhotoFiles? {
        guard let root = Bundle.main.url(forResource: "Photos", withExtension: nil),
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: "thumb").path())
        else { return nil }
        let sorted = names.filter { $0.hasSuffix(".jpg") }.sorted()
        return PhotoFiles(thumbs: sorted.map { root.appending(path: "thumb/\($0)") },
                          full: sorted.map { root.appending(path: "full/\($0)") })
    }
}
