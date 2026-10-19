import CoreGraphics
import Foundation

/// A thread's curve: a centripetal Catmull–Rom spline through its knots
/// (so it passes through every knot without loops or cusps), sampled into a
/// polyline with cumulative arc lengths. A song's time maps evenly onto the
/// length, so the playhead can travel along it.
public struct ThreadPath: Sendable, Equatable {
    /// The curve as a polyline.
    public let points: [CGPoint]
    /// Distance along the curve to each point; the last is the total length.
    public let lengths: [Double]
    /// The index in `points` of each knot.
    public let knotIndices: [Int]
    /// The bounding box of the curve.
    public let bounds: CGRect

    public var length: Double { lengths.last ?? 0 }

    /// - Parameter spacing: roughly how far apart the samples are (more for
    ///   long spans, so curves stay smooth however far they're pulled).
    public init(knots: [CGPoint], spacing: Double = 5) {
        var knots = knots
        if knots.isEmpty { knots = [.zero] }
        if knots.count == 1 { knots.append(knots[0]) }
        var points: [CGPoint] = [knots[0]]
        var knotIndices = [0]
        for span in 0..<(knots.count - 1) {
            let p1 = knots[span], p2 = knots[span + 1]
            // Mirror the ends so the curve leaves and arrives naturally.
            let p0 = span > 0 ? knots[span - 1] : CGPoint(x: 2 * p1.x - p2.x, y: 2 * p1.y - p2.y)
            let p3 = span + 2 < knots.count ? knots[span + 2] : CGPoint(x: 2 * p2.x - p1.x, y: 2 * p2.y - p1.y)
            let chord = Double(hypot(p2.x - p1.x, p2.y - p1.y))
            let samples = max(8, min(400, Int(chord / max(spacing, 0.5))))
            for step in 1...samples {
                points.append(Self.catmullRom(p0, p1, p2, p3, Double(step) / Double(samples)))
            }
            knotIndices.append(points.count - 1)
        }
        var lengths = [0.0]
        lengths.reserveCapacity(points.count)
        for i in 1..<points.count {
            lengths.append(lengths[i - 1] + Double(hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)))
        }
        self.points = points
        self.lengths = lengths
        self.knotIndices = knotIndices
        var minX = points[0].x, maxX = points[0].x, minY = points[0].y, maxY = points[0].y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The point and unit direction a fraction (0...1) of the way along.
    public func sample(atFraction fraction: Double) -> (point: CGPoint, tangent: CGVector) {
        sample(atLength: min(1, max(0, fraction)) * length)
    }

    public func sample(atLength distance: Double) -> (point: CGPoint, tangent: CGVector) {
        guard points.count > 1, length > 0 else { return (points.first ?? .zero, CGVector(dx: 1, dy: 0)) }
        let s = min(length, max(0, distance))
        // Binary search for the segment containing s.
        var low = 0, high = lengths.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if lengths[mid] <= s { low = mid } else { high = mid }
        }
        let a = points[low], b = points[high]
        let segment = lengths[high] - lengths[low]
        let t = segment > 0 ? (s - lengths[low]) / segment : 0
        let point = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        return (point, Self.direction(from: a, to: b))
    }

    /// The curve from its start to `distance` along it.
    public func prefix(toLength distance: Double) -> [CGPoint] {
        guard points.count > 1 else { return points }
        let s = min(length, max(0, distance))
        guard s < length else { return points }
        var result: [CGPoint] = []
        for i in 0..<points.count {
            if lengths[i] <= s {
                result.append(points[i])
            } else {
                result.append(sample(atLength: s).point)
                break
            }
        }
        return result
    }

    /// The closest point on the curve to `point`.
    /// - Returns: how far away it is, how far along the curve (0...1), and the
    ///   knot index a new knot there would get.
    public func nearest(to point: CGPoint) -> (distance: Double, fraction: Double, insertIndex: Int) {
        guard points.count > 1, length > 0 else { return (Double(hypot(point.x - (points.first?.x ?? 0), point.y - (points.first?.y ?? 0))), 0, 1) }
        var best = (distance: Double.infinity, along: 0.0, segment: 0)
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared > 0 ? min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared)) : 0
            let projection = CGPoint(x: a.x + dx * t, y: a.y + dy * t)
            let distance = Double(hypot(point.x - projection.x, point.y - projection.y))
            if distance < best.distance {
                best = (distance, lengths[i] + (lengths[i + 1] - lengths[i]) * Double(t), i)
            }
        }
        // The new knot goes after the last knot at or before this segment.
        let insertIndex = (knotIndices.lastIndex { $0 <= best.segment } ?? 0) + 1
        return (best.distance, best.along / length, min(insertIndex, knotIndices.count - 1))
    }

    static func direction(from a: CGPoint, to b: CGPoint) -> CGVector {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        return length > 0 ? CGVector(dx: dx / length, dy: dy / length) : CGVector(dx: 1, dy: 0)
    }

    /// Centripetal Catmull–Rom (Barry–Goldman), between p1 and p2.
    static func catmullRom(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: Double) -> CGPoint {
        func knot(_ ti: Double, _ a: CGPoint, _ b: CGPoint) -> Double {
            ti + max(1e-4, pow(Double(hypot(b.x - a.x, b.y - a.y)), 0.5))
        }
        let t0 = 0.0
        let t1 = knot(t0, p0, p1)
        let t2 = knot(t1, p1, p2)
        let t3 = knot(t2, p2, p3)
        let u = t1 + (t2 - t1) * t
        func mix(_ a: CGPoint, _ b: CGPoint, _ ta: Double, _ tb: Double) -> CGPoint {
            let w = (u - ta) / (tb - ta)
            return CGPoint(x: a.x + (b.x - a.x) * w, y: a.y + (b.y - a.y) * w)
        }
        let a1 = mix(p0, p1, t0, t1)
        let a2 = mix(p1, p2, t1, t2)
        let a3 = mix(p2, p3, t2, t3)
        let b1 = mix(a1, a2, t0, t2)
        let b2 = mix(a2, a3, t1, t3)
        return mix(b1, b2, t1, t2)
    }
}

public extension BoardPoint {
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }

    init(_ point: CGPoint) {
        self.init(Double(point.x), Double(point.y))
    }
}
