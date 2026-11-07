import Foundation

// MARK: - Vectors

public struct Vec3: Hashable, Sendable {
    public var x: Double, y: Double, z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    public static let zero = Vec3(0, 0, 0)

    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vec3, k: Double) -> Vec3 { Vec3(a.x * k, a.y * k, a.z * k) }
    public static func += (a: inout Vec3, b: Vec3) { a = a + b }
    public func dot(_ b: Vec3) -> Double { x * b.x + y * b.y + z * b.z }
    public func cross(_ b: Vec3) -> Vec3 { Vec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x) }
    public var length: Double { (x * x + y * y + z * z).squareRoot() }
    public var unit: Vec3 { let n = length; return n > 1e-12 ? self * (1 / n) : .zero }
    public func lerp(_ b: Vec3, _ f: Double) -> Vec3 { self + (b - self) * f }
}

extension Vec3: Codable {
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        self.init(try c.decode(Double.self), try c.decode(Double.self), try c.decode(Double.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x); try c.encode(y); try c.encode(z)
    }
}

// MARK: - Quaternions ([w, x, y, z])

public struct Quat: Hashable, Sendable {
    public var w: Double, x: Double, y: Double, z: Double
    public init(_ w: Double, _ x: Double, _ y: Double, _ z: Double) { self.w = w; self.x = x; self.y = y; self.z = z }
    public static let identity = Quat(1, 0, 0, 0)

    public static func * (a: Quat, b: Quat) -> Quat {
        Quat(a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
             a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
             a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
             a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w)
    }
    public var conjugate: Quat { Quat(w, -x, -y, -z) }
    public var normalized: Quat {
        let n = (w * w + x * x + y * y + z * z).squareRoot()
        return n > 0 ? Quat(w / n, x / n, y / n, z / n) : .identity
    }
    public func rotate(_ v: Vec3) -> Vec3 {
        let r = self * Quat(0, v.x, v.y, v.z) * conjugate
        return Vec3(r.x, r.y, r.z)
    }
    /// Axis * angle (radians).
    public var rotationVector: Vec3 {
        var q = self
        if q.w < 0 { q = Quat(-q.w, -q.x, -q.y, -q.z) }
        let s = (q.x * q.x + q.y * q.y + q.z * q.z).squareRoot()
        if s < 1e-9 { return Vec3(2 * q.x, 2 * q.y, 2 * q.z) }
        let k = 2 * atan2(s, q.w) / s
        return Vec3(q.x * k, q.y * k, q.z * k)
    }
    public init(rotationVector v: Vec3) {
        let angle = v.length
        if angle < 1e-12 { self = Quat(1, v.x / 2, v.y / 2, v.z / 2).normalized; return }
        let s = sin(angle / 2) / angle
        self.init(cos(angle / 2), v.x * s, v.y * s, v.z * s)
    }
    /// Normalized lerp with hemisphere fix — fine between consecutive samples.
    public func nlerp(_ b: Quat, _ f: Double) -> Quat {
        let sign: Double = (w * b.w + x * b.x + y * b.y + z * b.z) < 0 ? -1 : 1
        return Quat(w + (sign * b.w - w) * f, x + (sign * b.x - x) * f,
                    y + (sign * b.y - y) * f, z + (sign * b.z - z) * f).normalized
    }
}

extension Quat: Codable {
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        self.init(try c.decode(Double.self), try c.decode(Double.self), try c.decode(Double.self), try c.decode(Double.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(w); try c.encode(x); try c.encode(y); try c.encode(z)
    }
}

// MARK: - 3x3 rotation matrices

public struct Mat3: Sendable {
    public var r0: Vec3, r1: Vec3, r2: Vec3
    public static let identity = Mat3(r0: Vec3(1, 0, 0), r1: Vec3(0, 1, 0), r2: Vec3(0, 0, 1))
    public static func * (m: Mat3, v: Vec3) -> Vec3 { Vec3(m.r0.dot(v), m.r1.dot(v), m.r2.dot(v)) }

    /// Rodrigues: rotation of |v| radians about v.
    public init(rotationVector v: Vec3) {
        let angle = v.length
        guard angle > 1e-12 else { self = .identity; return }
        let a = v * (1 / angle)
        let c = cos(angle), s = sin(angle), t = 1 - c
        r0 = Vec3(t * a.x * a.x + c, t * a.x * a.y - s * a.z, t * a.x * a.z + s * a.y)
        r1 = Vec3(t * a.x * a.y + s * a.z, t * a.y * a.y + c, t * a.y * a.z - s * a.x)
        r2 = Vec3(t * a.x * a.z - s * a.y, t * a.y * a.z + s * a.x, t * a.z * a.z + c)
    }
    public init(r0: Vec3, r1: Vec3, r2: Vec3) { self.r0 = r0; self.r1 = r1; self.r2 = r2 }

    /// Rotation that takes direction `from` onto direction `to`.
    public static func aligning(_ from: Vec3, to: Vec3) -> Mat3 {
        let f = from.unit, t = to.unit
        let axis = f.cross(t)
        let s = axis.length, c = f.dot(t)
        if s < 1e-9 {
            if c > 0 { return .identity }
            let perp = abs(f.x) < 0.9 ? f.cross(Vec3(1, 0, 0)).unit : f.cross(Vec3(0, 1, 0)).unit
            return Mat3(rotationVector: perp * Double.pi)
        }
        return Mat3(rotationVector: axis * (atan2(s, c) / s))
    }
}

// MARK: - Seeded RNG (reproducible augmentation and permutation tests)

public struct SeededRNG: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    public mutating func uniform(_ lo: Double, _ hi: Double) -> Double { Double.random(in: lo...hi, using: &self) }
    public mutating func normal() -> Double {
        let u = max(Double.random(in: 0..<1, using: &self), 1e-12), v = Double.random(in: 0..<1, using: &self)
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
    public mutating func unitVector() -> Vec3 { Vec3(normal(), normal(), normal()).unit }
}

/// Stable FNV-1a hash (Swift's `hashValue` is randomized per process).
public func stableHash(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100_0000_01b3 }
    return h
}

public func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let s = values.sorted()
    return s[s.count / 2]
}
