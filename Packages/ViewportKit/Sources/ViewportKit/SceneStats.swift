import Foundation

/// Stats HUD data (specs/viewport.md): triangles · vertices · meshes ·
/// materials · bounds in real-world units for AR scale sanity.
public struct SceneStats: Hashable, Sendable {

    public var triangles: Int
    public var vertices: Int
    public var meshes: Int
    public var materials: Int
    /// Axis-aligned bounds size in stage units (meters for USDZ fast path).
    public var boundsSize: SIMD3<Float>

    public init(
        triangles: Int = 0,
        vertices: Int = 0,
        meshes: Int = 0,
        materials: Int = 0,
        boundsSize: SIMD3<Float> = .zero
    ) {
        self.triangles = triangles
        self.vertices = vertices
        self.meshes = meshes
        self.materials = materials
        self.boundsSize = boundsSize
    }

    /// "12,480 tris · 6,300 verts · 3 meshes · 2 materials"
    public var countsLine: String {
        "\(Self.grouped(triangles)) tris · \(Self.grouped(vertices)) verts"
            + " · \(meshes) \(meshes == 1 ? "mesh" : "meshes")"
            + " · \(materials) \(materials == 1 ? "material" : "materials")"
    }

    /// Bounds in cm below one meter, meters otherwise — the AR-scale readout.
    public var boundsLine: String {
        let dims = [boundsSize.x, boundsSize.y, boundsSize.z]
        guard dims.allSatisfy({ $0.isFinite }), dims.contains(where: { $0 > 0 }) else {
            return "bounds —"
        }
        let useCentimeters = dims.max()! < 1
        let formatted = dims
            .map { useCentimeters ? Self.number($0 * 100, decimals: 1) : Self.number($0, decimals: 2) }
            .joined(separator: " × ")
        return "bounds \(formatted) \(useCentimeters ? "cm" : "m")"
    }

    static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func number(_ value: Float, decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }
}
