import Foundation
import simd

/// The result of importing a motion file: the rest skeleton plus the normalized clip.
public struct MotionImport: Sendable, Equatable {
    public var skeleton: Skeleton
    public var clip: Clip
}

/// A pure BVH (BioVision Hierarchy) parser — the representative motion importer that produces a
/// normalized `Clip` + `Skeleton`. Text-only and fully deterministic. Returns `nil` on malformed
/// input rather than throwing (a reported outcome, per the repo discipline).
public enum BVHImporter {
    struct Channels { var order: [String]; var hasPosition: Bool }

    public static func parse(_ text: String) -> MotionImport? {
        var tokens = tokenize(text)
        guard tokens.first == "HIERARCHY" else { return nil }
        tokens.removeFirst()

        var paths: [String] = []
        var parents: [Int?] = []
        var offsets: [Vec3] = []
        var channels: [Channels] = []
        var stack: [Int] = []
        var pathStack: [String] = []

        // Parse HIERARCHY until MOTION.
        var i = 0
        func next() -> String? { i < tokens.count ? tokens[i] : nil }
        while let tok = next(), tok != "MOTION" {
            switch tok {
            case "ROOT", "JOINT":
                i += 1
                guard let name = next() else { return nil }
                i += 1
                guard next() == "{" else { return nil }
                i += 1
                let parent = stack.last
                let fullPath = (pathStack.last.map { $0 + "/" } ?? "") + name
                paths.append(fullPath)
                parents.append(parent)
                offsets.append(.zero)
                channels.append(Channels(order: [], hasPosition: false))
                stack.append(paths.count - 1)
                pathStack.append(fullPath)
            case "OFFSET":
                i += 1
                guard let x = doubleAt(tokens, i), let y = doubleAt(tokens, i + 1),
                      let z = doubleAt(tokens, i + 2), let cur = stack.last else { return nil }
                offsets[cur] = Vec3(x, y, z)
                i += 3
            case "CHANNELS":
                i += 1
                guard let countStr = next(), let count = Int(countStr), let cur = stack.last else { return nil }
                i += 1
                var order: [String] = []
                var hasPos = false
                for _ in 0..<count {
                    guard let c = next() else { return nil }
                    order.append(c)
                    if c.hasSuffix("position") { hasPos = true }
                    i += 1
                }
                channels[cur] = Channels(order: order, hasPosition: hasPos)
            case "End":
                // "End Site { OFFSET x y z }" — skip without adding a joint.
                i += 1
                guard next() == "Site", tokens[safe: i + 1] == "{" else { return nil }
                i += 2
                // Skip to the matching closing brace.
                var depth = 1
                while depth > 0, let t = next() {
                    if t == "{" { depth += 1 } else if t == "}" { depth -= 1 }
                    i += 1
                }
            case "}":
                if stack.isEmpty || pathStack.isEmpty { return nil }
                stack.removeLast()
                pathStack.removeLast()
                i += 1
            default:
                return nil
            }
        }
        guard next() == "MOTION" else { return nil }
        i += 1
        guard next() == "Frames:", let frameCountStr = tokens[safe: i + 1], let frameCount = Int(frameCountStr)
        else { return nil }
        i += 2
        guard next() == "Frame", tokens[safe: i + 1] == "Time:", let dt = doubleAt(tokens, i + 2)
        else { return nil }
        i += 3

        let perFrame = channels.reduce(0) { $0 + $1.order.count }
        guard perFrame > 0 else { return nil }

        // Rest skeleton (offsets as local translations).
        let joints = (0..<paths.count).map { k in
            RigJoint(id: paths[k], path: paths[k], parent: parents[k],
                     restLocal: RigTransform(translation: offsets[k]))
        }
        let skeleton = Skeleton(joints: joints)

        // Frames.
        var tracks = [[Keyframe]](repeating: [], count: paths.count)
        for f in 0..<frameCount {
            var values: [Double] = []
            for _ in 0..<perFrame {
                guard let v = doubleAt(tokens, i) else { return nil }
                values.append(v)
                i += 1
            }
            var cursor = 0
            for k in 0..<paths.count {
                let spec = channels[k]
                var pos = offsets[k]
                var euler: [(axis: Vec3, deg: Double)] = []
                for ch in spec.order {
                    let val = values[cursor]; cursor += 1
                    switch ch {
                    case "Xposition": pos.x = val
                    case "Yposition": pos.y = val
                    case "Zposition": pos.z = val
                    case "Xrotation": euler.append((Vec3(1, 0, 0), val))
                    case "Yrotation": euler.append((Vec3(0, 1, 0), val))
                    case "Zrotation": euler.append((Vec3(0, 0, 1), val))
                    default: return nil
                    }
                }
                var rot = Quat.identity
                for e in euler { rot = rot.multiplied(by: Quat(axis: e.axis, degrees: e.deg)) }
                tracks[k].append(Keyframe(time: Double(f) * dt,
                                          transform: RigTransform(translation: pos, rotation: rot.normalized)))
            }
        }

        let clip = Clip(name: "bvh", channels: tracks,
                        startTime: 0, endTime: Double(max(0, frameCount - 1)) * dt)
        return MotionImport(skeleton: skeleton, clip: clip)
    }

    static func tokenize(_ text: String) -> [String] {
        text.split { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }.map(String.init)
    }

    static func doubleAt(_ tokens: [String], _ index: Int) -> Double? {
        guard index >= 0, index < tokens.count else { return nil }
        return Double(tokens[index])
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
