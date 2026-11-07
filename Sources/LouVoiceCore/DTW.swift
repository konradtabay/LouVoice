import Foundation

/// Dependent multivariate DTW with a Sakoe–Chiba band and early abandoning (D10).
public enum DTW {
    /// Normalized distance (total path cost / (n + m)). Returns `.infinity` once it can no
    /// longer beat `cutoff`, which skips most of the work for hopeless references.
    public static func distance(_ a: FeatureSequence, _ b: FeatureSequence,
                                band bandFraction: Double = 0.2, cutoff: Double = .infinity) -> Double {
        let n = a.count, m = b.count, dims = a.dims
        guard n > 0, m > 0, dims == b.dims else { return .infinity }
        let band = max(abs(n - m), Int(Double(max(n, m)) * bandFraction))
        let limit = cutoff.isFinite ? cutoff * Double(n + m) : .infinity

        var previous = [Double](repeating: .infinity, count: m + 1)
        var current = previous
        previous[0] = 0

        return a.values.withUnsafeBufferPointer { av in
            b.values.withUnsafeBufferPointer { bv in
                for i in 1...n {
                    for j in 0...m { current[j] = .infinity }
                    let lo = max(1, i - band), hi = min(m, i + band)
                    var rowMin = Double.infinity
                    if lo <= hi {
                        let ai = (i - 1) * dims
                        for j in lo...hi {
                            let bj = (j - 1) * dims
                            var sum = 0.0
                            for d in 0..<dims { let diff = av[ai + d] - bv[bj + d]; sum += diff * diff }
                            let best = min(previous[j], current[j - 1], previous[j - 1])
                            let value = sum.squareRoot() + best
                            current[j] = value
                            if value < rowMin { rowMin = value }
                        }
                    }
                    if rowMin > limit { return .infinity }
                    swap(&previous, &current)
                }
                return previous[m] / Double(n + m)
            }
        }
    }
}
