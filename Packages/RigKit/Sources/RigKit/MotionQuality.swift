import Foundation
import simd

/// An authored rotation limit on a joint, about a local axis, in degrees.
public struct JointLimit: Sendable, Equatable, Codable {
    public var joint: Int
    public var axis: Vec3
    public var minDegrees: Double
    public var maxDegrees: Double
    public init(joint: Int, axis: Vec3, minDegrees: Double, maxDegrees: Double) {
        self.joint = joint
        self.axis = axis
        self.minDegrees = minDegrees
        self.maxDegrees = maxDegrees
    }
}

/// Everything the motion-quality metric samples over. Pure data; pose sampling happens upstream.
public struct MotionSample: Sendable, Equatable {
    public var skeleton: Skeleton
    public var poses: [Pose]
    public var times: [Double]
    public var footJoints: [Int]
    public var groundY: Double
    public var limits: [JointLimit]
    public var seamTimes: [Double]
    public var ikResidual: Double
    public var boneRadius: Double

    public init(skeleton: Skeleton, poses: [Pose], times: [Double],
                footJoints: [Int] = [], groundY: Double = 0, limits: [JointLimit] = [],
                seamTimes: [Double] = [], ikResidual: Double = 0, boneRadius: Double = 0.05) {
        self.skeleton = skeleton
        self.poses = poses
        self.times = times
        self.footJoints = footJoints
        self.groundY = groundY
        self.limits = limits
        self.seamTimes = seamTimes
        self.ikResidual = ikResidual
        self.boneRadius = boneRadius
    }
}

/// The scored breakdown. Every sub-score is in `0...1` (higher is better).
public struct MotionQualityReport: Sendable, Equatable, Codable {
    public var smoothness: Double
    public var footSlide: Double
    public var interpenetration: Double
    public var limitCompliance: Double
    public var seamContinuity: Double
    public var naturalness: Double
    /// The worst-weighted blend — one bad sub-metric can't be masked by the others.
    public var measuredMotionQuality: Double
}

/// A pure, deterministic, resolution-independent motion-quality metric. The runtime analog of the
/// sculpt pipeline's `measuredSimilarity`; every sub-metric is a pure function with golden values.
public enum MotionQuality {
    /// Default continue-gate floor. A hand-authored smooth clip scores above; a jittery/sliding one below.
    public static let defaultFloor = 0.6

    // Scale constants chosen so smooth motion → ~1 and degenerate motion → low. Fixed = stable.
    static let jerkScale = 2.0
    static let slideScale = 40.0
    static let penScale = 12.0
    static let seamScale = 8.0

    /// Assess a sampled motion. Returns `nil` when it can't be measured (fewer than two samples or
    /// mismatched times) — the caller then does not enforce the floor for that step.
    public static func assess(_ s: MotionSample) -> MotionQualityReport? {
        guard s.poses.count >= 2, s.poses.count == s.times.count else { return nil }
        let positions = s.poses.map { $0.worldPositions(s.skeleton) }

        let smoothness = smoothnessScore(positions, times: s.times)
        let footSlide = footSlideScore(positions, times: s.times, footJoints: s.footJoints, groundY: s.groundY)
        let interpen = interpenetrationScore(positions, skeleton: s.skeleton, radius: s.boneRadius)
        let limit = limitScore(s)
        let seam = seamScore(positions, times: s.times, seamTimes: s.seamTimes)
        let natural = naturalnessScore(positions, times: s.times)

        let subs = [smoothness, footSlide, interpen, limit, seam, natural]
        let mean = subs.reduce(0, +) / Double(subs.count)
        let worst = subs.min() ?? 0
        let measured = 0.5 * worst + 0.5 * mean
        return MotionQualityReport(smoothness: smoothness, footSlide: footSlide,
                                   interpenetration: interpen, limitCompliance: limit,
                                   seamContinuity: seam, naturalness: natural,
                                   measuredMotionQuality: measured)
    }

    // MARK: sub-metrics (pure)

    static func meanDT(_ times: [Double]) -> Double {
        guard times.count >= 2 else { return 1 }
        let span = times.last! - times.first!
        let dt = span / Double(times.count - 1)
        return dt > 1e-9 ? dt : 1
    }

    /// Normalized jerk: the mean third finite difference of joint world positions relative to the
    /// mean first difference (dimensionless, so it is scale- and sampling-rate-independent). Low
    /// third-vs-first ratio ⇒ smooth motion.
    static func smoothnessScore(_ pos: [[Vec3]], times: [Double]) -> Double {
        guard pos.count >= 4 else { return 1 }
        let jointCount = pos[0].count
        var third = 0.0, first = 0.0
        var nThird = 0, nFirst = 0
        for j in 0..<jointCount {
            for i in 1..<pos.count { first += simd_length(pos[i][j] - pos[i - 1][j]); nFirst += 1 }
            for i in 3..<pos.count {
                let d = pos[i][j] - 3 * pos[i - 1][j] + 3 * pos[i - 2][j] - pos[i - 3][j]
                third += simd_length(d); nThird += 1
            }
        }
        let meanFirst = nFirst > 0 ? first / Double(nFirst) : 0
        let meanThird = nThird > 0 ? third / Double(nThird) : 0
        let ratio = meanThird / (meanFirst + 1e-9)
        return 1.0 / (1.0 + jerkScale * ratio)
    }

    /// Horizontal drift of feet while planted (near the ground with low vertical speed).
    static func footSlideScore(_ pos: [[Vec3]], times: [Double], footJoints: [Int], groundY: Double) -> Double {
        guard !footJoints.isEmpty else { return 1 }
        let dt = meanDT(times)
        var slide = 0.0
        for f in footJoints {
            for i in 1..<pos.count {
                let a = pos[i - 1][f], b = pos[i][f]
                let plantedA = abs(a.y - groundY) < 0.05
                let plantedB = abs(b.y - groundY) < 0.05
                let vy = abs(b.y - a.y) / dt
                if plantedA && plantedB && vy < 0.1 {
                    slide += simd_length(Vec3(b.x - a.x, 0, b.z - a.z))
                }
            }
        }
        return 1.0 / (1.0 + slideScale * slide)
    }

    /// Coarse capsule self-intersection between non-adjacent bones.
    static func interpenetrationScore(_ pos: [[Vec3]], skeleton: Skeleton, radius: Double) -> Double {
        var maxPen = 0.0
        let joints = skeleton.joints
        for frame in pos {
            for i in joints.indices {
                guard let pi = joints[i].parent else { continue }
                for k in joints.indices where k > i {
                    guard let pk = joints[k].parent else { continue }
                    // Skip bones that share a joint (adjacent) — they legitimately touch.
                    if i == k || i == pk || k == pi || pi == pk { continue }
                    let d = WeightSolve.distanceToSegment(frame[i], frame[k], frame[pk])
                    let d2 = segmentSegmentDistance(frame[i], frame[pi], frame[k], frame[pk])
                    let dist = min(d, d2)
                    maxPen = max(maxPen, max(0, 2 * radius - dist))
                }
            }
        }
        return 1.0 / (1.0 + penScale * maxPen)
    }

    /// Fraction of sampled joint values within their authored limits, scaled by IK residual health.
    static func limitScore(_ s: MotionSample) -> Double {
        var within = 0, total = 0
        for limit in s.limits {
            for pose in s.poses {
                total += 1
                let angle = swingAngle(pose.locals[limit.joint].rotation, about: limit.axis)
                if angle >= limit.minDegrees - 1e-6 && angle <= limit.maxDegrees + 1e-6 { within += 1 }
            }
        }
        let compliance = total > 0 ? Double(within) / Double(total) : 1.0
        let residualFactor = s.ikResidual <= 1e-3 ? 1.0 : min(1.0, 1e-3 / s.ikResidual)
        return compliance * residualFactor
    }

    /// Velocity continuity across clip seams.
    static func seamScore(_ pos: [[Vec3]], times: [Double], seamTimes: [Double]) -> Double {
        guard !seamTimes.isEmpty, pos.count >= 3 else { return 1 }
        let dt = meanDT(times)
        var worst = 0.0
        for seam in seamTimes {
            // Nearest interior sample to the seam (the range is non-empty since pos.count >= 3).
            var i = 1
            var bestD = Double.infinity
            for k in 1..<(times.count - 1) {
                let d = abs(times[k] - seam)
                if d < bestD { bestD = d; i = k }
            }
            let vBefore = (pos[i][0] - pos[i - 1][0]) / dt
            let vAfter = (pos[i + 1][0] - pos[i][0]) / dt
            worst = max(worst, simd_length(vAfter - vBefore))
        }
        return 1.0 / (1.0 + seamScale * worst)
    }

    /// Bell-shaped speed profile (ease-in/ease-out) rather than flat robotic motion.
    static func naturalnessScore(_ pos: [[Vec3]], times: [Double]) -> Double {
        guard pos.count >= 3 else { return 1 }
        let dt = meanDT(times)
        // Overall speed per interval (mean joint speed).
        var speed: [Double] = []
        for i in 1..<pos.count {
            var s = 0.0
            for j in 0..<pos[i].count { s += simd_distance(pos[i][j], pos[i - 1][j]) }
            speed.append(s / Double(pos[i].count) / dt)
        }
        // Correlate with a sine bell over the interval.
        let n = speed.count
        var bell: [Double] = []
        for i in 0..<n { bell.append(sin(Double(i + 1) / Double(n + 1) * .pi)) }
        let corr = correlation(speed, bell)
        return simd_clamp(corr, 0.0, 1.0)
    }

    // MARK: helpers

    /// The rotation angle (degrees) of a quaternion measured about a given axis.
    static func swingAngle(_ q: Quat, about axis: Vec3) -> Double {
        let len = simd_length(axis)
        guard len > 1e-9 else { return 2 * acos(simd_clamp(abs(q.w), 0, 1)) * 180 / .pi }
        let a = axis / len
        // Signed angle: project the quaternion's vector part onto the axis.
        let vec = Vec3(q.x, q.y, q.z)
        let proj = simd_dot(vec, a)
        let angle = 2 * atan2(proj, q.w)
        return angle * 180 / .pi
    }

    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let n = min(a.count, b.count)
        guard n > 1 else { return 1 }
        let ma = a.prefix(n).reduce(0, +) / Double(n)
        let mb = b.prefix(n).reduce(0, +) / Double(n)
        var cov = 0.0, va = 0.0, vb = 0.0
        for i in 0..<n {
            let da = a[i] - ma, db = b[i] - mb
            cov += da * db; va += da * da; vb += db * db
        }
        guard va > 1e-12 && vb > 1e-12 else { return 0 }
        return cov / (va.squareRoot() * vb.squareRoot())
    }

    /// Shortest distance between segments `p1p2` and `q1q2`.
    static func segmentSegmentDistance(_ p1: Vec3, _ p2: Vec3, _ q1: Vec3, _ q2: Vec3) -> Double {
        let d1 = p2 - p1, d2 = q2 - q1, r = p1 - q1
        let a = simd_dot(d1, d1), e = simd_dot(d2, d2), f = simd_dot(d2, r)
        var s = 0.0, t = 0.0
        if a <= 1e-12 && e <= 1e-12 { return simd_length(r) }
        if a <= 1e-12 {
            t = simd_clamp(f / e, 0, 1)
        } else {
            let c = simd_dot(d1, r)
            if e <= 1e-12 {
                s = simd_clamp(-c / a, 0, 1)
            } else {
                let b = simd_dot(d1, d2)
                let denom = a * e - b * b
                s = denom > 1e-12 ? simd_clamp((b * f - c * e) / denom, 0, 1) : 0
                t = (b * s + f) / e
                if t < 0 { t = 0; s = simd_clamp(-c / a, 0, 1) }
                else if t > 1 { t = 1; s = simd_clamp((b - c) / a, 0, 1) }
            }
        }
        let cp1 = p1 + d1 * s, cp2 = q1 + d2 * t
        return simd_length(cp1 - cp2)
    }
}
