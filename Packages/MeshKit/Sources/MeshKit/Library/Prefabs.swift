import Foundation

/// Procedural low-poly prefabs: real-world objects composed from `Primitives`
/// via `HalfEdgeMesh` transforms + `merged`. Every prefab is authored so its
/// base sits on the ground plane (y = 0) and it is centered on X/Z, so it
/// drops into a scene sensibly.
///
/// Each builder returns a single closed, manifold mesh (a disjoint union of
/// its parts). `PrefabTests` checks that contract for every entry.
public enum Prefabs {

    // MARK: - Part helpers (centered at `at`)

    private static func box(_ w: Double, _ h: Double, _ d: Double,
                            at c: SIMD3<Double>) throws -> HalfEdgeMesh {
        try Primitives.box(width: w, height: h, depth: d).translated(by: c)
    }

    private static func cylinder(radius: Double, height: Double, sides: Int = 12,
                                 at c: SIMD3<Double>) throws -> HalfEdgeMesh {
        try Primitives.cylinder(radius: radius, height: height, radialSegments: sides)
            .translated(by: c)
    }

    private static func cone(radius: Double, height: Double, sides: Int = 12,
                             at c: SIMD3<Double>) throws -> HalfEdgeMesh {
        try Primitives.cone(radius: radius, height: height, radialSegments: sides)
            .translated(by: c)
    }

    private static func sphere(radius: Double, rings: Int = 5, segments: Int = 8,
                               at c: SIMD3<Double>) throws -> HalfEdgeMesh {
        try Primitives.uvSphere(radius: radius, rings: rings, segments: segments)
            .translated(by: c)
    }

    /// A rectangular leg of height `h` whose top is at `topY`, footed on the
    /// ground, centered at (x, z).
    private static func leg(_ x: Double, _ z: Double, thickness t: Double,
                            height h: Double, topY: Double) throws -> HalfEdgeMesh {
        try box(t, h, t, at: SIMD3(x, topY - h / 2, z))
    }

    // MARK: - Nature

    /// Rounded broadleaf tree: a trunk with a spherical canopy.
    public static func tree() throws -> HalfEdgeMesh {
        let trunkH = 0.9
        let trunk = try cylinder(radius: 0.09, height: trunkH, sides: 8,
                                 at: SIMD3(0, trunkH / 2, 0))
        let canopy = try sphere(radius: 0.45, rings: 6, segments: 9,
                                at: SIMD3(0, trunkH + 0.3, 0))
            .scaled(by: SIMD3(1, 1.15, 1))
        return .merged([trunk, canopy])
    }

    /// Conifer: a trunk with three stacked cone tiers.
    public static func pineTree() throws -> HalfEdgeMesh {
        let trunkH = 0.5
        let trunk = try cylinder(radius: 0.07, height: trunkH, sides: 8,
                                 at: SIMD3(0, trunkH / 2, 0))
        let t0 = try cone(radius: 0.42, height: 0.5, sides: 10, at: SIMD3(0, trunkH + 0.25, 0))
        let t1 = try cone(radius: 0.33, height: 0.45, sides: 10, at: SIMD3(0, trunkH + 0.6, 0))
        let t2 = try cone(radius: 0.22, height: 0.4, sides: 10, at: SIMD3(0, trunkH + 0.95, 0))
        return .merged([trunk, t0, t1, t2])
    }

    /// Low shrub: a squashed faceted sphere.
    public static func bush() throws -> HalfEdgeMesh {
        try sphere(radius: 0.35, rings: 4, segments: 7, at: SIMD3(0, 0.24, 0))
            .scaled(by: SIMD3(1.2, 0.75, 1.1))
    }

    /// Irregular boulder: a coarse sphere scaled unevenly.
    public static func rock() throws -> HalfEdgeMesh {
        try sphere(radius: 0.4, rings: 3, segments: 6, at: SIMD3(0, 0.24, 0))
            .scaled(by: SIMD3(1.25, 0.65, 0.95))
            .rotatedY(0.4)
    }

    /// Toadstool: a stubby stem under a domed cap.
    public static func mushroom() throws -> HalfEdgeMesh {
        let stemH = 0.28
        let stem = try cylinder(radius: 0.07, height: stemH, sides: 9,
                                at: SIMD3(0, stemH / 2, 0))
        let cap = try sphere(radius: 0.2, rings: 4, segments: 10,
                             at: SIMD3(0, stemH + 0.02, 0))
            .scaled(by: SIMD3(1.1, 0.6, 1.1))
        return .merged([stem, cap])
    }

    // MARK: - Furniture

    /// Four-legged table: a top slab on four corner legs.
    public static func table() throws -> HalfEdgeMesh {
        let topY = 0.72, legT = 0.06, inset = 0.4
        let top = try box(1.0, 0.06, 0.7, at: SIMD3(0, topY, 0))
        let legs = try [(-inset, -0.27), (inset, -0.27), (-inset, 0.27), (inset, 0.27)]
            .map { try leg($0.0, $0.1, thickness: legT, height: topY - 0.03, topY: topY - 0.03) }
        return .merged([top] + legs)
    }

    /// Chair: seat, four legs, and a backrest.
    public static func chair() throws -> HalfEdgeMesh {
        let seatY = 0.45, legT = 0.05, s = 0.18
        let seat = try box(0.45, 0.05, 0.45, at: SIMD3(0, seatY, 0))
        let legs = try [(-s, -s), (s, -s), (-s, s), (s, s)]
            .map { try leg($0.0, $0.1, thickness: legT, height: seatY - 0.025, topY: seatY - 0.025) }
        let back = try box(0.45, 0.45, 0.05, at: SIMD3(0, seatY + 0.25, -0.2))
        return .merged([seat, back] + legs)
    }

    /// Bench: a long seat on two slab legs.
    public static func bench() throws -> HalfEdgeMesh {
        let seatY = 0.42
        let seat = try box(1.4, 0.07, 0.4, at: SIMD3(0, seatY, 0))
        let l0 = try box(0.06, seatY - 0.035, 0.36, at: SIMD3(-0.6, (seatY - 0.035) / 2, 0))
        let l1 = try box(0.06, seatY - 0.035, 0.36, at: SIMD3(0.6, (seatY - 0.035) / 2, 0))
        return .merged([seat, l0, l1])
    }

    // MARK: - Structures

    /// Cottage: a cuboid body with a pyramidal (4-sided cone) roof.
    public static func house() throws -> HalfEdgeMesh {
        let bodyH = 1.0
        let body = try box(1.2, bodyH, 1.0, at: SIMD3(0, bodyH / 2, 0))
        let roof = try cone(radius: 0.95, height: 0.6, sides: 4,
                            at: SIMD3(0, bodyH + 0.3, 0))
            .rotatedY(.pi / 4)
        return .merged([body, roof])
    }

    /// Watchtower: a tall shaft topped with a conical roof.
    public static func watchtower() throws -> HalfEdgeMesh {
        let shaftH = 1.8
        let shaft = try cylinder(radius: 0.4, height: shaftH, sides: 10,
                                 at: SIMD3(0, shaftH / 2, 0))
        let roof = try cone(radius: 0.52, height: 0.7, sides: 10,
                            at: SIMD3(0, shaftH + 0.35, 0))
        return .merged([shaft, roof])
    }

    // MARK: - Props

    /// Barrel: a faceted cylinder with a slight bulge.
    public static func barrel() throws -> HalfEdgeMesh {
        let h = 0.8
        return try cylinder(radius: 0.3, height: h, sides: 12, at: SIMD3(0, h / 2, 0))
    }

    /// Shipping crate: a plain cube resting on the ground.
    public static func crate() throws -> HalfEdgeMesh {
        try box(0.6, 0.6, 0.6, at: SIMD3(0, 0.3, 0))
    }

    /// Street lamp: a tall pole with a boxy lantern head.
    public static func streetLamp() throws -> HalfEdgeMesh {
        let poleH = 1.6
        let pole = try cylinder(radius: 0.05, height: poleH, sides: 8,
                                at: SIMD3(0, poleH / 2, 0))
        let arm = try box(0.4, 0.05, 0.05, at: SIMD3(0.18, poleH, 0))
        let lantern = try box(0.16, 0.22, 0.16, at: SIMD3(0.36, poleH - 0.05, 0))
        return .merged([pole, arm, lantern])
    }
}
