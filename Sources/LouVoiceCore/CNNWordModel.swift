import Foundation

/// Single-word recogniser: a small 1D convolutional network (D51), trained offline with
/// `scripts/nn/train_word_cnn.py` on this user's takes and shipped as a JSON weights file.
/// Several independently trained networks ("members") are averaged.
///
/// Architecture (must match the training script): 4 residual dilated Conv1d(64) + BatchNorm + GELU
/// layers, masked average + max pooling over time, plus the take length, then one linear layer.
/// Input: the default pipeline's features (`PipelineConfig.defaults.features`), divided by the
/// training spread per channel, centred in a fixed window of `T` frames.
public struct CNNWordModel: Sendable {
    public let labels: [String]
    public let T: Int
    let members: [Member]

    struct Conv: Sendable {
        var weight: [Double]   // out × in × k, row-major
        var bias: [Double]
        var out: Int, inp: Int, k: Int, padding: Int, dilation: Int
        // BatchNorm folded into a per-channel affine: y = x * a + b.
        var bnA: [Double], bnB: [Double]
    }

    struct Member: Sendable {
        var scale: [Double]
        var convs: [Conv]
        var headW: [Double]    // classes × features
        var headB: [Double]
    }

    // Conv layer shapes from the training script: (kernel, padding, dilation).
    static let layout: [(k: Int, padding: Int, dilation: Int)] = [(5, 2, 1), (5, 2, 1), (5, 4, 2), (3, 4, 4)]

    public enum LoadError: Error { case badFormat(String) }

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    public init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let labels = root["labels"] as? [String], let T = root["T"] as? Int,
              let members = root["members"] as? [[String: Any]], !members.isEmpty
        else { throw LoadError.badFormat("missing labels / T / members") }
        self.labels = labels
        self.T = T
        self.members = try members.map(Self.member)
    }

    private static func flat(_ any: Any?) -> [Double] {
        if let n = any as? NSNumber { return [n.doubleValue] }
        if let a = any as? [Any] { return a.flatMap { flat($0) } }
        return []
    }

    private static func member(_ m: [String: Any]) throws -> Member {
        guard let state = m["state"] as? [String: Any] else { throw LoadError.badFormat("member without state") }
        let scale = flat(m["scale"])
        var convs: [Conv] = []
        var inp = scale.count
        for (i, l) in layout.enumerated() {
            let w = flat(state["convs.\(i).weight"]), b = flat(state["convs.\(i).bias"])
            let g = flat(state["norms.\(i).weight"]), beta = flat(state["norms.\(i).bias"])
            let mean = flat(state["norms.\(i).running_mean"]), variance = flat(state["norms.\(i).running_var"])
            let out = b.count
            guard out > 0, w.count == out * inp * l.k, g.count == out, mean.count == out, variance.count == out
            else { throw LoadError.badFormat("conv \(i) shape") }
            let a = (0..<out).map { g[$0] / (variance[$0] + 1e-5).squareRoot() }
            let bb = (0..<out).map { beta[$0] - mean[$0] * a[$0] }
            convs.append(Conv(weight: w, bias: b, out: out, inp: inp, k: l.k, padding: l.padding, dilation: l.dilation, bnA: a, bnB: bb))
            inp = out
        }
        let hw = flat(state["head.weight"]), hb = flat(state["head.bias"])
        guard !hb.isEmpty, hw.count == hb.count * (2 * inp + 1) else { throw LoadError.badFormat("head shape") }
        return Member(scale: scale, convs: convs, headW: hw, headB: hb)
    }

    /// Class probabilities (averaged over members), in `labels` order.
    public func probabilities(_ seq: FeatureSequence) -> [Double] {
        var sum = [Double](repeating: 0, count: labels.count)
        for m in members {
            let p = Self.softmax(logits(m, seq))
            for i in sum.indices { sum[i] += p[i] }
        }
        return sum.map { $0 / Double(members.count) }
    }

    /// Ranked like the DTW classifier so the rest of the decoder can use it: lower score = better.
    /// Score is 1 − probability renormalised over `allowed` (nil = all labels).
    public func rank(_ seq: FeatureSequence, allowed: Set<String>? = nil) -> [RankedLabel] {
        let p = probabilities(seq)
        let keep = labels.indices.filter { allowed?.contains(labels[$0]) ?? true }
        let total = keep.reduce(0) { $0 + p[$1] }
        guard total > 0 else { return [] }
        return keep.map { RankedLabel(label: labels[$0], score: 1 - p[$0] / total) }.sorted { $0.score < $1.score }
    }

    // MARK: Forward pass (eval mode: dropout off, BatchNorm uses running statistics)

    func logits(_ m: Member, _ seq: FeatureSequence) -> [Double] {
        let D = seq.dims, n = seq.count
        precondition(D == m.scale.count, "feature width \(D) ≠ model input \(m.scale.count)")
        // Centre-pad or centre-crop to T frames; channel-major x[c][t].
        var x = [[Double]](repeating: [Double](repeating: 0, count: T), count: D)
        var mask = [Double](repeating: 0, count: T)
        let start = n >= T ? (n - T) / 2 : 0, offset = n >= T ? 0 : (T - n) / 2
        for t in 0..<min(n, T) {
            for c in 0..<D { x[c][offset + t] = seq[frame: start + t, dim: c] / m.scale[c] }
            mask[offset + t] = 1
        }
        var h = x
        for (i, conv) in m.convs.enumerated() {
            let y = Self.apply(conv, h, T)
            h = i == 0 ? y : zip(h, y).map { zip($0, $1).map(+) }
        }
        let valid = max(1, mask.reduce(0, +))
        var pooled: [Double] = []
        pooled.reserveCapacity(2 * h.count + 1)
        for row in h { pooled.append(zip(row, mask).reduce(0) { $0 + $1.0 * $1.1 } / valid) }
        for row in h { pooled.append(zip(row, mask).map { $1 > 0 ? $0 : -Double.infinity }.max() ?? 0) }
        pooled.append(mask.reduce(0, +) / 50)
        let k = pooled.count
        return m.headB.indices.map { j in
            var s = m.headB[j]
            for f in 0..<k { s += m.headW[j * k + f] * pooled[f] }
            return s
        }
    }

    static func apply(_ c: Conv, _ x: [[Double]], _ T: Int) -> [[Double]] {
        var out = [[Double]](repeating: [Double](repeating: 0, count: T), count: c.out)
        for o in 0..<c.out {
            var row = [Double](repeating: c.bias[o], count: T)
            for i in 0..<c.inp {
                let xi = x[i]
                for j in 0..<c.k {
                    let w = c.weight[(o * c.inp + i) * c.k + j]
                    let shift = j * c.dilation - c.padding
                    let lo = max(0, -shift), hi = min(T, T - shift)
                    if lo >= hi { continue }
                    for t in lo..<hi { row[t] += w * xi[t + shift] }
                }
            }
            for t in 0..<T { row[t] = gelu(row[t] * c.bnA[o] + c.bnB[o]) }
            out[o] = row
        }
        return out
    }

    static func gelu(_ v: Double) -> Double { 0.5 * v * (1 + erf(v / 2.0.squareRoot())) }

    static func softmax(_ z: [Double]) -> [Double] {
        let m = z.max() ?? 0
        let e = z.map { exp($0 - m) }
        let s = e.reduce(0, +)
        return e.map { $0 / s }
    }
}
