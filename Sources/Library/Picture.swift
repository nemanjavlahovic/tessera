import simd

/// The image the whole library assembles into: a sunset over two mountain ranges,
/// mirrored in a lake. Generated, so there are no rights to worry about.
enum Picture {
    static func sunset(width: Int, height: Int) -> [SIMD3<Float>] {
        let aspect = Float(height) / Float(width)
        var pixels = [SIMD3<Float>](repeating: .zero, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let u = (Float(x) + 0.5) / Float(width)
                let v = (Float(y) + 0.5) / Float(height)
                pixels[y * width + x] = scene(u: u, v: v, aspect: aspect)
            }
        }
        return pixels
    }

    private static let shore: Float = 0.72

    private static func scene(u: Float, v: Float, aspect: Float) -> SIMD3<Float> {
        guard v > shore else { return landscape(u: u, v: v, aspect: aspect) }
        let ripple = 0.006 * sin(v * 420) * (v - shore) * 6
        let mirrored = landscape(u: u + ripple, v: 2 * shore - v, aspect: aspect)
        let depth = (v - shore) / (1 - shore)
        return simd_mix(mirrored * 0.7, SIMD3(0.03, 0.04, 0.10), SIMD3(repeating: depth * 0.8))
    }

    private static func landscape(u: Float, v: Float, aspect: Float) -> SIMD3<Float> {
        var c = sky(v)

        let dx = u - 0.5
        let dy = (v - 0.55) * aspect
        let r = (dx * dx + dy * dy).squareRoot()
        let sunRadius: Float = 0.16
        if r < sunRadius {
            c = SIMD3(1.0, 0.86, 0.55)
        } else {
            c += SIMD3(1.0, 0.55, 0.25) * exp(-(r - sunRadius) * 9) * 0.55
        }

        let far = 0.58 + 0.045 * sin(u * 7.0 + 1.2) + 0.02 * sin(u * 19.0 + 0.4) + 0.008 * sin(u * 61.0)
        if v > far { c = simd_mix(c, SIMD3(0.42, 0.20, 0.40), SIMD3(repeating: 0.8)) }

        let near = 0.645 + 0.04 * sin(u * 4.5 + 3.8) + 0.015 * sin(u * 23.0 + 2.0) + 0.006 * sin(u * 71.0)
        if v > near { c = SIMD3(0.13, 0.07, 0.17) }

        return simd_clamp(c, .zero, SIMD3(repeating: 1))
    }

    private static func sky(_ v: Float) -> SIMD3<Float> {
        let stops: [(Float, SIMD3<Float>)] = [
            (0.00, SIMD3(0.04, 0.05, 0.20)),
            (0.22, SIMD3(0.20, 0.12, 0.42)),
            (0.40, SIMD3(0.70, 0.24, 0.42)),
            (0.53, SIMD3(0.98, 0.50, 0.24)),
            (0.66, SIMD3(1.00, 0.80, 0.45)),
        ]
        guard v > stops[0].0 else { return stops[0].1 }
        for i in 1..<stops.count where v <= stops[i].0 {
            let (v0, c0) = stops[i - 1], (v1, c1) = stops[i]
            return simd_mix(c0, c1, SIMD3(repeating: (v - v0) / (v1 - v0)))
        }
        return stops[stops.count - 1].1
    }
}
