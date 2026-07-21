import Foundation

/// A real light authored by the `lighting` pass — the USD-native analog of
/// img2threejs's "real lights, not texture-baked emission". SculptKit stays a
/// pure leaf: it only describes the light; the executor realizes it as a
/// `UsdLux` prim.
public struct LightSpec: Codable, Sendable, Equatable, Identifiable {
    /// The four `UsdLux` light types the pipeline can author.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case distant, sphere, rect, dome

        /// The USD prim type name for this light kind.
        public var usdTypeName: String {
            switch self {
            case .distant: return "DistantLight"
            case .sphere: return "SphereLight"
            case .rect: return "RectLight"
            case .dome: return "DomeLight"
            }
        }
    }

    /// USD-identifier-safe name, unique among lights; also the node id.
    public var id: String { name }
    public var name: String
    public var kind: Kind
    /// Emission intensity (>= 0). Interpreted per `UsdLux` (nits/steradian).
    public var intensity: Double
    /// Light colour, linear RGB in 0...1.
    public var color: [Double]
    /// Local translation of the light prim.
    public var translation: [Double]
    /// Local rotation (Euler degrees) — orients directional/rect/distant lights.
    public var rotationEulerDegrees: [Double]

    public init(name: String, kind: Kind, intensity: Double = 1,
                color: [Double] = [1, 1, 1],
                translation: [Double] = [0, 0, 0],
                rotationEulerDegrees: [Double] = [0, 0, 0]) {
        self.name = name
        self.kind = kind
        self.intensity = intensity
        self.color = color
        self.translation = translation
        self.rotationEulerDegrees = rotationEulerDegrees
    }
}

/// One level-of-detail tier authored by the `optimization` pass — the
/// USD-native analog of img2threejs's pass-gated LOD system. Purely
/// declarative: the executor authors a `sculptLOD` descriptor on the root, so
/// SculptKit performs no mesh decimation itself and stays a pure leaf.
public struct LODTier: Codable, Sendable, Equatable {
    public var name: String
    /// Screen-coverage threshold (0...1) at or below which this tier is used —
    /// smaller on-screen objects fall to coarser tiers.
    public var screenCoverage: Double
    /// Fraction of source detail retained (0 < d <= 1); 1 = full detail.
    public var decimation: Double

    public init(name: String, screenCoverage: Double, decimation: Double) {
        self.name = name
        self.screenCoverage = screenCoverage
        self.decimation = decimation
    }
}

/// The LOD manifest authored onto the sculpt root as a `sculptLOD` string
/// attribute in the optimization pass, mirroring the `sculptRuntime` /
/// `sculptProjectedTexture` descriptor pattern.
public struct LODManifest: Codable, Sendable, Equatable {
    public var tiers: [LODTier]

    public init(tiers: [LODTier]) {
        self.tiers = tiers
    }

    public init(spec: ObjectSculptSpec) {
        self.init(tiers: spec.lodTiers)
    }

    /// True when there is at least one tier to author.
    public var hasTiers: Bool { !tiers.isEmpty }

    /// Deterministic JSON (sorted keys) for authoring onto the stage.
    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

/// How a component joins its parent — img2threejs's "declare a join method;
/// nothing floats mid-air" contract. The attachment-correctness gate rejects
/// geometry leaves that are unspecified or explicitly `.free`.
public enum AttachmentKind: String, Codable, Sendable, Equatable, CaseIterable {
    /// A base/grounding component (the spec root or a load-bearing base).
    case root
    /// Rigidly fused to its parent (shares a surface/seam).
    case weld
    /// Mounted on a declared socket/pivot.
    case socket
    /// Pinned/bolted at a contact point.
    case pin
    /// Explicitly free-floating — rejected by the attachment gate.
    case free
}
