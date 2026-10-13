import Foundation

/// Throughput from measured bytes over elapsed time (same algorithm as Android's SpeedMeter).
/// `current` uses a sliding window; `average` covers the whole transfer.
public struct SpeedMeter: Sendable {
    private var samples: [(t: TimeInterval, bytes: Int64)] = []
    private var start: (t: TimeInterval, bytes: Int64)?
    private var lastBytes: Int64 = 0
    public let window: TimeInterval

    public init(window: TimeInterval = 2) { self.window = window }

    public mutating func add(bytesDone: Int64, at t: TimeInterval) {
        if start == nil { start = (t, bytesDone) }
        lastBytes = bytesDone
        samples.append((t, bytesDone))
        while samples.count > 2, t - samples[0].t > window { samples.removeFirst() }
    }

    /// Bytes per second over the window, nil until two samples exist.
    public var current: Double? {
        guard samples.count >= 2, let f = samples.first, let l = samples.last, l.t > f.t else { return nil }
        return Double(l.bytes - f.bytes) / (l.t - f.t)
    }

    public func average(at t: TimeInterval) -> Double? {
        guard let s = start, t > s.t else { return nil }
        return Double(lastBytes - s.bytes) / (t - s.t)
    }

    public func eta(totalBytes: Int64) -> TimeInterval? {
        guard let r = current, r > 0 else { return nil }
        return Double(max(0, totalBytes - lastBytes)) / r
    }
}
