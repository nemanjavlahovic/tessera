import Foundation

/// Critically damped spring, stepped with its exact closed-form solution so the result
/// is the same at 60Hz, 120Hz, or after a dropped frame.
struct Spring {
    var value: Double
    var velocity: Double
    let target: Double
    private let omega: Double
    private let tolerance: Double

    init(value: Double, velocity: Double, target: Double, response: Double, tolerance: Double) {
        self.value = value
        self.velocity = velocity
        self.target = target
        self.omega = 2 * .pi / response
        self.tolerance = tolerance
    }

    mutating func step(_ dt: Double) {
        let x0 = value - target
        let b = velocity + omega * x0
        let decay = exp(-omega * dt)
        value = target + (x0 + b * dt) * decay
        velocity = (velocity - omega * b * dt) * decay
    }

    var isSettled: Bool { abs(value - target) < tolerance && abs(velocity) < tolerance * 10 }
}

/// Velocity over the last ~80ms of samples; zero if the finger paused before lifting.
struct VelocityTracker {
    private var samples: [(time: Double, value: Double)] = []

    mutating func reset() { samples.removeAll(keepingCapacity: true) }

    mutating func add(time: Double, value: Double) {
        samples.append((time, value))
        samples.removeAll { $0.time < time - 0.08 }
    }

    func velocity(at now: Double) -> Double {
        guard let first = samples.first, let last = samples.last,
              now - last.time < 0.05, last.time - first.time > 0.004 else { return 0 }
        return (last.value - first.value) / (last.time - first.time)
    }
}

/// UIScrollView's rubber band: resistance grows the further you pull past the edge.
func rubberBand(_ value: Double, min lower: Double, max upper: Double, dimension: Double) -> Double {
    func resist(_ x: Double) -> Double { (1 - 1 / (x * 0.55 / dimension + 1)) * dimension }
    if value < lower { return lower - resist(lower - value) }
    if value > upper { return upper + resist(value - upper) }
    return value
}
