import Foundation

public enum Signal {
    public struct Resampled: Sendable {
        public var samples: [MotionSample]
        /// Largest gap between consecutive raw samples, in seconds.
        public var maxGap: Double
    }

    /// Interpolate onto a uniform grid at `rate` Hz (D6). Bluetooth jitter and drops otherwise
    /// look like the word was said faster or slower.
    public static func resample(_ raw: [MotionSample], rate: Double = 25) -> Resampled {
        let input = raw.sorted { $0.t < $1.t }
        guard let first = input.first, let last = input.last, input.count >= 2, last.t > first.t else {
            return Resampled(samples: input, maxGap: 0)
        }
        var maxGap = 0.0
        for i in 1..<input.count { maxGap = max(maxGap, input[i].t - input[i - 1].t) }

        let count = Int(((last.t - first.t) * rate).rounded(.down)) + 1
        var out: [MotionSample] = []
        out.reserveCapacity(count)
        var j = 0
        for k in 0..<count {
            let t = first.t + Double(k) / rate
            while j + 1 < input.count, input[j + 1].t <= t { j += 1 }
            let a = input[j], b = input[min(j + 1, input.count - 1)]
            let span = b.t - a.t
            let f = span > 0 ? min(max((t - a.t) / span, 0), 1) : 0
            out.append(MotionSample(
                t: t,
                accel: a.accel.lerp(b.accel, f),
                rotation: a.rotation.lerp(b.rotation, f),
                gravity: a.gravity.lerp(b.gravity, f),
                attitude: a.attitude.nlerp(b.attitude, f),
                pitch: a.pitch + (b.pitch - a.pitch) * f,
                roll: a.roll + (b.roll - a.roll) * f,
                yaw: a.yaw + remainder(b.yaw - a.yaw, 2 * .pi) * f,
                location: a.location))
        }
        return Resampled(samples: out, maxGap: maxGap)
    }

    /// 2nd-order Butterworth high-pass coefficients (RBJ cookbook, Q = 1/√2).
    struct Biquad {
        var b0, b1, b2, a1, a2: Double
        init(highPass cutoff: Double, rate: Double) {
            let w0 = 2 * Double.pi * cutoff / rate
            let alpha = sin(w0) / (2 * (0.5).squareRoot())
            let c = cos(w0)
            let a0 = 1 + alpha
            b0 = (1 + c) / 2 / a0
            b1 = -(1 + c) / a0
            b2 = (1 + c) / 2 / a0
            a1 = -2 * c / a0
            a2 = (1 - alpha) / a0
        }
        func run(_ x: [Double]) -> [Double] {
            guard let x0 = x.first else { return [] }
            var y = [Double](repeating: 0, count: x.count)
            // Start in steady state for a constant input (high-pass output of DC is 0).
            var x1 = x0, x2 = x0, y1 = 0.0, y2 = 0.0
            for i in x.indices {
                let v = b0 * x[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = x[i]; y2 = y1; y1 = v
                y[i] = v
            }
            return y
        }
    }

    /// Zero-phase high-pass (forward + backward) with odd reflection padding (D8).
    public static func highPass(_ x: [Double], cutoff: Double, rate: Double) -> [Double] {
        let n = x.count
        guard n >= 4, cutoff > 0 else { return x }
        let pad = min(n - 1, Int(rate * 1.0))
        var padded: [Double] = []
        padded.reserveCapacity(n + 2 * pad)
        for i in stride(from: pad, through: 1, by: -1) { padded.append(2 * x[0] - x[i]) }
        padded.append(contentsOf: x)
        for i in 1...pad { padded.append(2 * x[n - 1] - x[n - 1 - i]) }
        let filter = Biquad(highPass: cutoff, rate: rate)
        let forward = filter.run(padded)
        let backward = filter.run(forward.reversed())
        return Array(backward.reversed()[pad..<(pad + n)])
    }
}
