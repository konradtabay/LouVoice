import Foundation

/// Which earbud produced the motion data (CMDeviceMotion.sensorLocation).
public enum SensorLocation: String, Codable, Sendable {
    case unknown, left, right
}

/// One headphone-motion reading, independent of CoreMotion so the core stays testable.
public struct MotionSample: Codable, Hashable, Sendable {
    /// Seconds (device timestamp; any monotonic clock).
    public var t: Double
    /// User acceleration in g, gravity removed, device frame.
    public var accel: Vec3
    /// Rotation rate in rad/s, device frame.
    public var rotation: Vec3
    /// Gravity in g, device frame.
    public var gravity: Vec3
    /// Attitude quaternion.
    public var attitude: Quat
    /// Euler attitude in radians (used for nod/shake detection).
    public var pitch: Double, roll: Double, yaw: Double
    public var location: SensorLocation

    public init(t: Double, accel: Vec3 = .zero, rotation: Vec3 = .zero, gravity: Vec3 = Vec3(0, 0, -1),
                attitude: Quat = .identity, pitch: Double = 0, roll: Double = 0, yaw: Double = 0,
                location: SensorLocation = .unknown) {
        self.t = t; self.accel = accel; self.rotation = rotation; self.gravity = gravity
        self.attitude = attitude; self.pitch = pitch; self.roll = roll; self.yaw = yaw; self.location = location
    }

    enum CodingKeys: String, CodingKey { case t, a, r, g, q, p, l }

    // Compact keys: datasets hold thousands of samples.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try c.decode(Double.self, forKey: .t)
        accel = try c.decode(Vec3.self, forKey: .a)
        rotation = try c.decode(Vec3.self, forKey: .r)
        gravity = try c.decode(Vec3.self, forKey: .g)
        attitude = try c.decode(Quat.self, forKey: .q)
        let e = try c.decode(Vec3.self, forKey: .p)
        pitch = e.x; roll = e.y; yaw = e.z
        location = try c.decodeIfPresent(SensorLocation.self, forKey: .l) ?? .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(t, forKey: .t)
        try c.encode(accel, forKey: .a)
        try c.encode(rotation, forKey: .r)
        try c.encode(gravity, forKey: .g)
        try c.encode(attitude, forKey: .q)
        try c.encode(Vec3(pitch, roll, yaw), forKey: .p)
        try c.encode(location, forKey: .l)
    }
}
