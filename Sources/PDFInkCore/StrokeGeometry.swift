import Foundation
import CoreGraphics

/// Pure geometry helpers: pressure→width mapping, Catmull-Rom smoothing,
/// and affine transforms between PDF page space and view space.
public enum StrokeGeometry {

    // MARK: - Pressure → width

    /// Maps normalized pressure to a stroke width in PDF points.
    /// Pen: 0.5pt–4pt scaled by the base width preset (baseWidth 2.0 == spec range).
    /// Highlighter: constant width (pressure-independent) so alpha blending stays uniform.
    public static func width(forPressure pressure: CGFloat, baseWidth: CGFloat, tool: Tool) -> CGFloat {
        switch tool {
        case .highlighter:
            return baseWidth * 6.0
        default:
            let p = min(max(pressure, 0), 1)
            let scale = baseWidth / 2.0 // baseWidth presets: 1, 2, 4
            let minW = 0.5 * scale
            let maxW = 4.0 * scale
            return minW + (maxW - minW) * p
        }
    }

    // MARK: - Catmull-Rom smoothing

    /// One cubic Bézier segment produced by Catmull-Rom fitting.
    public struct BezierSegment: Equatable {
        public var start: CGPoint
        public var c1: CGPoint
        public var c2: CGPoint
        public var end: CGPoint
        /// Interpolated pressures at start/end of the segment.
        public var startPressure: CGFloat
        public var endPressure: CGFloat
    }

    /// Converts a polyline of samples into smoothed cubic Bézier segments using
    /// centripetal-style Catmull-Rom (uniform parameterization, tension 0).
    /// Standard conversion: c1 = p1 + (p2 - p0)/6, c2 = p2 - (p3 - p1)/6.
    public static func catmullRomSegments(_ samples: [StrokeSample]) -> [BezierSegment] {
        guard samples.count >= 2 else { return [] }
        var segments: [BezierSegment] = []
        segments.reserveCapacity(samples.count - 1)
        for i in 0..<(samples.count - 1) {
            let p1 = samples[i].point
            let p2 = samples[i + 1].point
            let p0 = i > 0 ? samples[i - 1].point : p1
            let p3 = i + 2 < samples.count ? samples[i + 2].point : p2
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6.0,
                             y: p1.y + (p2.y - p0.y) / 6.0)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6.0,
                             y: p2.y - (p3.y - p1.y) / 6.0)
            segments.append(BezierSegment(start: p1, c1: c1, c2: c2, end: p2,
                                          startPressure: samples[i].pressure,
                                          endPressure: samples[i + 1].pressure))
        }
        return segments
    }

    /// Builds a single smoothed CGPath through all samples (constant-width use,
    /// e.g. highlighter or hit-testing).
    public static func smoothedPath(_ samples: [StrokeSample]) -> CGPath {
        let path = CGMutablePath()
        guard let first = samples.first else { return path }
        path.move(to: first.point)
        if samples.count == 1 {
            path.addLine(to: first.point)
            return path
        }
        for seg in catmullRomSegments(samples) {
            path.addCurve(to: seg.end, control1: seg.c1, control2: seg.c2)
        }
        return path
    }

    // MARK: - Page ↔ view transforms

    /// Derives the affine transform that maps source-space points to destination-space
    /// points given the images of three reference points (origin, unit-x, unit-y).
    /// Handles scale, translation, rotation, and axis flips exactly.
    public static func affineTransform(mappingOrigin q0: CGPoint,
                                       unitX q1: CGPoint,
                                       unitY q2: CGPoint) -> CGAffineTransform {
        CGAffineTransform(a: q1.x - q0.x, b: q1.y - q0.y,
                          c: q2.x - q0.x, d: q2.y - q0.y,
                          tx: q0.x, ty: q0.y)
    }

    // MARK: - Hit testing (stroke-level eraser)

    /// True if `point` lies within `tolerance` of the stroke's polyline.
    public static func stroke(_ stroke: Stroke, contains point: CGPoint, tolerance: CGFloat) -> Bool {
        let pts = stroke.samples.map(\.point)
        guard !pts.isEmpty else { return false }
        let tol2 = tolerance * tolerance
        if pts.count == 1 {
            return squaredDistance(point, pts[0]) <= tol2
        }
        for i in 0..<(pts.count - 1) {
            if squaredDistanceToSegment(point, pts[i], pts[i + 1]) <= tol2 {
                return true
            }
        }
        return false
    }

    public static func squaredDistance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return dx * dx + dy * dy
    }

    public static func squaredDistanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let apx = p.x - a.x, apy = p.y - a.y
        let len2 = abx * abx + aby * aby
        if len2 == 0 { return squaredDistance(p, a) }
        let t = min(max((apx * abx + apy * aby) / len2, 0), 1)
        let proj = CGPoint(x: a.x + t * abx, y: a.y + t * aby)
        return squaredDistance(p, proj)
    }
}
