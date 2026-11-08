import Foundation

/// Single-word recogniser: a small 1D convolutional network (D53), trained offline with
/// `scripts/nn/train_word_cnn.py` on this user's takes and shipped as a JSON weights file.
/// Several independently trained networks ("members") are averaged.
///
/// Architecture (must match the training script): 4 residual dilated Conv1d(64) + BatchNorm + GELU
/// layers, masked average + max pooling over time, plus the take length, then one linear layer.
/// Input: the default pipeline's features with the file's `channels` (`featureConfig`), divided by the
/// training spread per channel, centred in a fixed window of `T` frames.
///
/// Calibration (D55): `calibrated(calibration:replay:)` adapts a copy to today's earbud fit from a
/// few labelled takes: BatchNorm statistics re-measured on them and blended 50/50 with the trained
/// ones, then the last layer retrained (with replayed older takes so it doesn't forget).
public struct CNNWordModel: Sendable {
    public let labels: [String]
    public let T: Int
    /// Feature channels the network was trained on (weights file key "channels", e.g. ["acceleration",
    /// "rotation", "attitude"]). Older files have none: the default pipeline's rotation + attitude.
    public let channels: FeatureChannels
    /// The pipeline settings to extract this network's input with: the defaults, with `channels`.
    public var featureConfig: FeatureConfig {
        var c = PipelineConfig.defaults.features
        c.channels = channels
        return c
    }
    var members: [Member]

    struct Conv: Sendable {
        var weight: [Double]   // out × in × k, row-major
        var bias: [Double]
        var out: Int, inp: Int, k: Int, padding: Int, dilation: Int
        var gamma: [Double], beta: [Double], mean: [Double], variance: [Double]
        // BatchNorm folded into a per-channel affine: y = x * a + b.
        var bnA: [Double] = [], bnB: [Double] = []

        mutating func fold() {
            bnA = (0..<out).map { gamma[$0] / (variance[$0] + 1e-5).squareRoot() }
            bnB = (0..<out).map { beta[$0] - mean[$0] * bnA[$0] }
        }
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
        if let names = root["channels"] as? [String] {
            var c: FeatureChannels = []
            for n in names {
                switch n {
                case "acceleration": c.insert(.acceleration)
                case "rotation": c.insert(.rotation)
                case "attitude": c.insert(.attitude)
                default: throw LoadError.badFormat("unknown channel \(n)")
                }
            }
            self.channels = c
        } else {
            self.channels = PipelineConfig.defaults.features.channels
        }
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
            var c = Conv(weight: w, bias: b, out: out, inp: inp, k: l.k, padding: l.padding, dilation: l.dilation,
                         gamma: g, beta: beta, mean: mean, variance: variance)
            c.fold()
            convs.append(c)
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
            let p = Self.softmax(Self.headLogits(m, embedding(m, seq)))
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

    /// Centre-pad or centre-crop to T frames, divided by the training spread; channel-major x[c][t].
    func input(_ m: Member, _ seq: FeatureSequence) -> (x: [[Double]], mask: [Double]) {
        let D = seq.dims, n = seq.count
        precondition(D == m.scale.count, "feature width \(D) ≠ model input \(m.scale.count)")
        var x = [[Double]](repeating: [Double](repeating: 0, count: T), count: D)
        var mask = [Double](repeating: 0, count: T)
        let start = n >= T ? (n - T) / 2 : 0, offset = n >= T ? 0 : (T - n) / 2
        for t in 0..<min(n, T) {
            for c in 0..<D { x[c][offset + t] = seq[frame: start + t, dim: c] / m.scale[c] }
            mask[offset + t] = 1
        }
        return (x, mask)
    }

    /// Pooled features the last layer sees: masked mean and max per channel, plus the take length.
    func embedding(_ m: Member, _ seq: FeatureSequence) -> [Double] {
        let (x, mask) = input(m, seq)
        var h = x
        for (i, conv) in m.convs.enumerated() {
            let y = Self.activate(conv, Self.convolve(conv, h, T), conv.bnA, conv.bnB)
            h = i == 0 ? y : zip(h, y).map { zip($0, $1).map(+) }
        }
        return Self.pool(h, mask)
    }

    static func pool(_ h: [[Double]], _ mask: [Double]) -> [Double] {
        let valid = max(1, mask.reduce(0, +))
        var pooled: [Double] = []
        pooled.reserveCapacity(2 * h.count + 1)
        for row in h { pooled.append(zip(row, mask).reduce(0) { $0 + $1.0 * $1.1 } / valid) }
        for row in h { pooled.append(zip(row, mask).map { $1 > 0 ? $0 : -Double.infinity }.max() ?? 0) }
        pooled.append(mask.reduce(0, +) / 50)
        return pooled
    }

    static func headLogits(_ m: Member, _ e: [Double]) -> [Double] {
        let k = e.count
        return m.headB.indices.map { j in
            var s = m.headB[j]
            for f in 0..<k { s += m.headW[j * k + f] * e[f] }
            return s
        }
    }

    /// Conv1d output before BatchNorm (bias included), out × T.
    static func convolve(_ c: Conv, _ x: [[Double]], _ T: Int) -> [[Double]] {
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
            out[o] = row
        }
        return out
    }

    /// BatchNorm as a per-channel affine, then GELU.
    static func activate(_ c: Conv, _ y: [[Double]], _ a: [Double], _ b: [Double]) -> [[Double]] {
        y.indices.map { o in y[o].map { gelu($0 * a[o] + b[o]) } }
    }

    static func gelu(_ v: Double) -> Double { 0.5 * v * (1 + erf(v / 2.0.squareRoot())) }

    static func softmax(_ z: [Double]) -> [Double] {
        let m = z.max() ?? 0
        let e = z.map { exp($0 - m) }
        let s = e.reduce(0, +)
        return e.map { $0 / s }
    }

    // MARK: Calibration (D55)

    public struct CalibrationOptions: Sendable {
        /// Share of the re-measured BatchNorm statistics (0 = keep trained, 1 = calibration only).
        public var statsBlend = 0.5
        public var steps = 150
        public var learningRate = 0.01
        public var replayBatch = 32
        /// Weight of the replayed older takes in the last-layer loss.
        public var replayWeight = 0.5
        public var seed: UInt64 = 1
        public init() {}
    }

    /// A copy adapted to today's fit. `calibration`: labelled takes recorded now (a few per word).
    /// `replay`: labelled older takes (a sample of the training set) so the last layer doesn't forget.
    public func calibrated(calibration: [(FeatureSequence, String)], replay: [(FeatureSequence, String)],
                           options: CalibrationOptions = CalibrationOptions()) -> CNNWordModel {
        let calib = calibration.filter { labels.contains($0.1) && $0.0.count >= 4 }
        let rep = replay.filter { labels.contains($0.1) && $0.0.count >= 4 }
        guard !calib.isEmpty else { return self }
        var copy = self
        copy.members = members.enumerated().map { i, m in
            var m = Self.recentred(m, on: calib.map(\.0), blend: options.statsBlend, model: self)
            var o = options
            o.seed = options.seed &+ UInt64(i)
            Self.retrainHead(&m, calib: calib.map { (embedding(m, $0.0), labels.firstIndex(of: $0.1)!) },
                             replay: rep.map { (embedding(m, $0.0), labels.firstIndex(of: $0.1)!) }, options: o)
            return m
        }
        return copy
    }

    /// BatchNorm statistics re-measured over all frames of the calibration takes (as PyTorch does in
    /// training mode, padding included), layer by layer, then blended with the trained statistics.
    static func recentred(_ member: Member, on seqs: [FeatureSequence], blend: Double, model: CNNWordModel) -> Member {
        var m = member
        var hs = seqs.map { model.input(member, $0).x }
        for li in m.convs.indices {
            let c = m.convs[li]
            let ys = hs.map { convolve(c, $0, model.T) }
            let n = Double(ys.count * model.T)
            var mean = [Double](repeating: 0, count: c.out), sq = mean
            for y in ys { for o in 0..<c.out { for v in y[o] { mean[o] += v; sq[o] += v * v } } }
            mean = mean.map { $0 / n }
            let biased = (0..<c.out).map { max(0, sq[$0] / n - mean[$0] * mean[$0]) }
            // Normalise with this batch's statistics (training mode) to feed the next layer.
            let a = (0..<c.out).map { c.gamma[$0] / (biased[$0] + 1e-5).squareRoot() }
            let b = (0..<c.out).map { c.beta[$0] - mean[$0] * a[$0] }
            let outs = ys.map { activate(c, $0, a, b) }
            hs = li == 0 ? outs : zip(hs, outs).map { h, y in zip(h, y).map { zip($0, $1).map(+) } }
            // Running statistics use the unbiased variance.
            let unbiased = biased.map { $0 * n / max(1, n - 1) }
            m.convs[li].mean = (0..<c.out).map { (1 - blend) * c.mean[$0] + blend * mean[$0] }
            m.convs[li].variance = (0..<c.out).map { (1 - blend) * c.variance[$0] + blend * unbiased[$0] }
            m.convs[li].fold()
        }
        return m
    }

    /// Adam on the last layer: cross-entropy on all calibration takes + `replayWeight` × a random
    /// replay batch each step.
    static func retrainHead(_ m: inout Member, calib: [([Double], Int)], replay: [([Double], Int)], options o: CalibrationOptions) {
        let k = m.headB.count, F = calib[0].0.count
        var W = m.headW, B = m.headB
        var mW = [Double](repeating: 0, count: W.count), vW = mW, mB = [Double](repeating: 0, count: k), vB = mB
        let (b1, b2, eps) = (0.9, 0.999, 1e-8)
        var rng = SeededRNG(seed: o.seed)
        for step in 1...max(1, o.steps) {
            var gW = [Double](repeating: 0, count: W.count), gB = [Double](repeating: 0, count: k)
            func add(_ batch: [([Double], Int)], weight: Double) {
                guard !batch.isEmpty else { return }
                let w = weight / Double(batch.count)
                for (e, y) in batch {
                    var z = B
                    for j in 0..<k { for f in 0..<F { z[j] += W[j * F + f] * e[f] } }
                    let p = softmax(z)
                    for j in 0..<k {
                        let g = (p[j] - (j == y ? 1 : 0)) * w
                        gB[j] += g
                        for f in 0..<F { gW[j * F + f] += g * e[f] }
                    }
                }
            }
            add(calib, weight: 1)
            if !replay.isEmpty {
                let batch = (0..<min(o.replayBatch, replay.count)).map { _ in replay[Int(rng.next() % UInt64(replay.count))] }
                add(batch, weight: o.replayWeight)
            }
            let c1 = 1 - pow(b1, Double(step)), c2 = 1 - pow(b2, Double(step))
            for i in W.indices {
                mW[i] = b1 * mW[i] + (1 - b1) * gW[i]; vW[i] = b2 * vW[i] + (1 - b2) * gW[i] * gW[i]
                W[i] -= o.learningRate * (mW[i] / c1) / ((vW[i] / c2).squareRoot() + eps)
            }
            for j in 0..<k {
                mB[j] = b1 * mB[j] + (1 - b1) * gB[j]; vB[j] = b2 * vB[j] + (1 - b2) * gB[j] * gB[j]
                B[j] -= o.learningRate * (mB[j] / c1) / ((vB[j] / c2).squareRoot() + eps)
            }
        }
        m.headW = W
        m.headB = B
    }

    // MARK: Saving a calibration

    /// What calibration changed (BatchNorm statistics and last layer), as JSON.
    public func calibrationData() throws -> Data {
        let ms: [[String: Any]] = members.map { m in
            ["means": m.convs.map(\.mean), "vars": m.convs.map(\.variance), "headW": m.headW, "headB": m.headB]
        }
        return try JSONSerialization.data(withJSONObject: ["labels": labels, "members": ms])
    }

    /// The model with a saved calibration applied. Throws if it doesn't fit this model.
    public func applying(calibration data: Data) throws -> CNNWordModel {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["labels"] as? [String]) == labels, let ms = root["members"] as? [[String: Any]], ms.count == members.count
        else { throw LoadError.badFormat("calibration doesn't match the model") }
        var copy = self
        for (i, d) in ms.enumerated() {
            let means = (d["means"] as? [Any])?.map { Self.flat($0) } ?? [], vars = (d["vars"] as? [Any])?.map { Self.flat($0) } ?? []
            let hw = Self.flat(d["headW"]), hb = Self.flat(d["headB"])
            guard means.count == copy.members[i].convs.count, vars.count == means.count,
                  hw.count == copy.members[i].headW.count, hb.count == copy.members[i].headB.count
            else { throw LoadError.badFormat("calibration shape") }
            for li in copy.members[i].convs.indices {
                guard means[li].count == copy.members[i].convs[li].out, vars[li].count == means[li].count
                else { throw LoadError.badFormat("calibration layer \(li)") }
                copy.members[i].convs[li].mean = means[li]
                copy.members[i].convs[li].variance = vars[li]
                copy.members[i].convs[li].fold()
            }
            copy.members[i].headW = hw
            copy.members[i].headB = hb
        }
        return copy
    }
}
