import Foundation
import simd

/// A single keyframe: a joint's local transform at a time code.
public struct Keyframe: Sendable, Equatable, Codable {
    public var time: Double
    public var transform: RigTransform
    public init(time: Double, transform: RigTransform) {
        self.time = time
        self.transform = transform
    }
}

/// Pose interpolation used by clips and blend graphs.
public enum PoseBlend {
    /// Per-joint blend: lerp translation/scale, slerp rotation. `t` is clamped to `0...1`.
    public static func blend(_ a: Pose, _ b: Pose, t: Double) -> Pose {
        let w = simd_clamp(t, 0.0, 1.0)
        let n = min(a.jointCount, b.jointCount)
        var out: [RigTransform] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let la = a.locals[i], lb = b.locals[i]
            out.append(RigTransform(
                translation: la.translation + (lb.translation - la.translation) * w,
                rotation: la.rotation.slerp(to: lb.rotation, t: w),
                scale: la.scale + (lb.scale - la.scale) * w))
        }
        return Pose(locals: out)
    }

    /// Additive layering: apply `layer`'s delta-from-`reference` on top of `base`, scaled by weight.
    public static func additive(base: Pose, layer: Pose, reference: Pose, weight: Double) -> Pose {
        let w = simd_clamp(weight, 0.0, 1.0)
        let n = min(base.jointCount, min(layer.jointCount, reference.jointCount))
        var out: [RigTransform] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let b = base.locals[i], l = layer.locals[i], r = reference.locals[i]
            let deltaT = (l.translation - r.translation) * w
            // Rotation delta relative to reference, weighted via slerp from identity.
            let deltaRot = r.rotation.conjugate.multiplied(by: l.rotation).normalized
            let weightedDelta = Quat.identity.slerp(to: deltaRot, t: w)
            out.append(RigTransform(
                translation: b.translation + deltaT,
                rotation: b.rotation.multiplied(by: weightedDelta).normalized,
                scale: b.scale + (l.scale - r.scale) * w))
        }
        return Pose(locals: out)
    }
}

/// An animation clip: per-joint keyframe tracks over a time range.
///
/// Channels are parallel to a skeleton's joints; an empty channel means "use the rest local".
public struct Clip: Sendable, Equatable, Codable {
    public var name: String
    /// One sorted keyframe track per joint (may be empty).
    public private(set) var channels: [[Keyframe]]
    public var startTime: Double
    public var endTime: Double

    public init(name: String, channels: [[Keyframe]], startTime: Double, endTime: Double) {
        self.name = name
        self.channels = channels.map { $0.sorted { $0.time < $1.time } }
        self.startTime = startTime
        self.endTime = endTime
    }

    public var jointCount: Int { channels.count }
    public var duration: Double { endTime - startTime }

    /// Insert or replace a keyframe on a joint channel (returns a new clip).
    public func settingKeyframe(_ keyframe: Keyframe, joint: Int) -> Clip {
        var copy = channels
        copy[joint].removeAll { abs($0.time - keyframe.time) < 1e-9 }
        copy[joint].append(keyframe)
        copy[joint].sort { $0.time < $1.time }
        return Clip(name: name, channels: copy, startTime: startTime, endTime: endTime)
    }

    /// Sample the clip at `time`, falling back to `rest` for joints with no keyframes.
    public func sample(at time: Double, rest: Pose) -> Pose {
        var out = rest.locals
        for j in 0..<min(jointCount, rest.jointCount) {
            if let t = sampleChannel(channels[j], at: time) { out[j] = t }
        }
        return Pose(locals: out)
    }

    /// Interpolate one channel; `nil` when the channel is empty.
    func sampleChannel(_ keys: [Keyframe], at time: Double) -> RigTransform? {
        guard let first = keys.first, let last = keys.last else { return nil }
        if time <= first.time { return first.transform }
        if time >= last.time { return last.transform }
        // Find the bracketing pair.
        var lo = keys[0]
        for k in keys.dropFirst() {
            if k.time >= time {
                let span = k.time - lo.time
                let u = span > 1e-12 ? (time - lo.time) / span : 0
                return RigTransform(
                    translation: lo.transform.translation + (k.transform.translation - lo.transform.translation) * u,
                    rotation: lo.transform.rotation.slerp(to: k.transform.rotation, t: u),
                    scale: lo.transform.scale + (k.transform.scale - lo.transform.scale) * u)
            }
            lo = k
        }
        // coverage:disable — unreachable: `time` is strictly between first and last here, so the
        // loop always finds a bracketing key and returns; this satisfies the compiler only.
        return last.transform
        // coverage:enable
    }

    /// Trim to `[start, end]`, dropping out-of-range keys and clamping the range.
    public func trimmed(start: Double, end: Double) -> Clip {
        let s = min(start, end), e = max(start, end)
        let trimmed = channels.map { $0.filter { $0.time >= s && $0.time <= e } }
        return Clip(name: name, channels: trimmed, startTime: s, endTime: e)
    }

    /// Retime keyframes by `scale` about the start, then `offset`. `scale <= 0` is treated as 1.
    public func retimed(scale: Double, offset: Double) -> Clip {
        let s = scale > 0 ? scale : 1
        let mapped = channels.map { track in
            track.map { Keyframe(time: startTime + ($0.time - startTime) * s + offset, transform: $0.transform) }
        }
        return Clip(name: name, channels: mapped,
                    startTime: startTime + offset, endTime: startTime + duration * s + offset)
    }
}

/// A small blend graph: clips combined by weighted blends and additive layers, evaluated to a pose.
public indirect enum BlendNode: Sendable {
    case clip(Clip)
    case blend(BlendNode, BlendNode, weight: Double)
    case additive(base: BlendNode, layer: BlendNode, reference: Pose, weight: Double)

    /// Evaluate the graph at `time` against a `rest` pose.
    public func evaluate(at time: Double, rest: Pose) -> Pose {
        switch self {
        case .clip(let c):
            return c.sample(at: time, rest: rest)
        case .blend(let a, let b, let w):
            return PoseBlend.blend(a.evaluate(at: time, rest: rest),
                                   b.evaluate(at: time, rest: rest), t: w)
        case .additive(let base, let layer, let reference, let w):
            return PoseBlend.additive(base: base.evaluate(at: time, rest: rest),
                                      layer: layer.evaluate(at: time, rest: rest),
                                      reference: reference, weight: w)
        }
    }
}
