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

    // MARK: - Nature (extended)

    /// Flower: a thin stem topped by a flattened bloom with a small core.
    public static func flower() throws -> HalfEdgeMesh {
        let stemH = 0.6
        let stem = try cylinder(radius: 0.03, height: stemH, sides: 6,
                                at: SIMD3(0, stemH / 2, 0))
        let bloom = try sphere(radius: 0.18, rings: 4, segments: 8,
                               at: SIMD3(0, stemH + 0.1, 0))
            .scaled(by: SIMD3(1.2, 0.5, 1.2))
        let core = try sphere(radius: 0.08, rings: 4, segments: 6,
                              at: SIMD3(0, stemH + 0.14, 0))
        return .merged([stem, bloom, core])
    }

    /// Cactus: a rounded column with two shorter side arms.
    public static func cactus() throws -> HalfEdgeMesh {
        let bodyH = 1.0
        let body = try cylinder(radius: 0.18, height: bodyH, sides: 10,
                                at: SIMD3(0, bodyH / 2, 0))
        let armR = try cylinder(radius: 0.07, height: 0.5, sides: 8,
                                at: SIMD3(0.2, 0.6, 0))
        let armL = try cylinder(radius: 0.07, height: 0.45, sides: 8,
                                at: SIMD3(-0.2, 0.55, 0))
        return .merged([body, armR, armL])
    }

    /// Palm tree: a slender trunk crowned with a ring of splayed fronds.
    public static func palmTree() throws -> HalfEdgeMesh {
        let trunkH = 1.4
        let trunk = try cylinder(radius: 0.09, height: trunkH, sides: 8,
                                 at: SIMD3(0, trunkH / 2, 0))
        var parts = [trunk]
        let frondCount = 6
        for i in 0..<frondCount {
            let angle = 2 * Double.pi * Double(i) / Double(frondCount)
            let frond = try box(0.6, 0.04, 0.14, at: SIMD3(0.32, trunkH + 0.05, 0))
                .rotatedX(-0.25)
                .rotatedY(angle)
            parts.append(frond)
        }
        return .merged(parts)
    }

    /// Tree stump: a short, wide cylinder.
    public static func stump() throws -> HalfEdgeMesh {
        let h = 0.35
        return try cylinder(radius: 0.3, height: h, sides: 10, at: SIMD3(0, h / 2, 0))
    }

    /// Log pile: three horizontal logs stacked in a pyramid.
    public static func logPile() throws -> HalfEdgeMesh {
        func log(_ x: Double, _ y: Double) throws -> HalfEdgeMesh {
            try cylinder(radius: 0.15, height: 0.9, sides: 8, at: SIMD3(x, y, 0))
                .rotatedX(.pi / 2)
        }
        let a = try log(-0.16, 0.15)
        let b = try log(0.16, 0.15)
        let c = try log(0, 0.41)
        return .merged([a, b, c])
    }

    // MARK: - Furniture (extended)

    /// Stool: a round seat on four splayed legs.
    public static func stool() throws -> HalfEdgeMesh {
        let seatY = 0.45
        let seat = try cylinder(radius: 0.22, height: 0.05, sides: 12,
                                at: SIMD3(0, seatY, 0))
        let s = 0.15
        let legs = try [(-s, -s), (s, -s), (-s, s), (s, s)]
            .map { try leg($0.0, $0.1, thickness: 0.04,
                           height: seatY - 0.025, topY: seatY - 0.025) }
        return .merged([seat] + legs)
    }

    /// Bookshelf: two sides, a back, and four evenly spaced shelves.
    public static func bookshelf() throws -> HalfEdgeMesh {
        let w = 0.8, h = 1.4, d = 0.3, t = 0.04
        let left = try box(t, h, d, at: SIMD3(-w / 2 + t / 2, h / 2, 0))
        let right = try box(t, h, d, at: SIMD3(w / 2 - t / 2, h / 2, 0))
        let back = try box(w, h, t, at: SIMD3(0, h / 2, -d / 2 + t / 2))
        var parts = [left, right, back]
        for i in 0...3 {
            let y = 0.04 + Double(i) * (h - 0.08) / 3
            parts.append(try box(w - 2 * t, t, d - t, at: SIMD3(0, y, 0)))
        }
        return .merged(parts)
    }

    /// Bed: a frame with a mattress, pillow, and headboard.
    public static func bed() throws -> HalfEdgeMesh {
        let frame = try box(1.0, 0.25, 1.9, at: SIMD3(0, 0.125, 0))
        let mattress = try box(0.94, 0.12, 1.8, at: SIMD3(0, 0.31, 0))
        let pillow = try box(0.8, 0.1, 0.3, at: SIMD3(0, 0.42, -0.7))
        let headboard = try box(1.0, 0.5, 0.08, at: SIMD3(0, 0.25, -0.95))
        return .merged([frame, mattress, pillow, headboard])
    }

    /// Wardrobe: a tall cabinet on stubby feet with two door handles.
    public static func wardrobe() throws -> HalfEdgeMesh {
        let w = 0.9, h = 1.7, d = 0.5
        let body = try box(w, h - 0.1, d, at: SIMD3(0, (h - 0.1) / 2 + 0.1, 0))
        let feet = try [(-w / 2 + 0.05, -d / 2 + 0.05), (w / 2 - 0.05, -d / 2 + 0.05),
                        (-w / 2 + 0.05, d / 2 - 0.05), (w / 2 - 0.05, d / 2 - 0.05)]
            .map { try box(0.08, 0.1, 0.08, at: SIMD3($0.0, 0.05, $0.1)) }
        let h1 = try box(0.04, 0.2, 0.04, at: SIMD3(-0.06, h / 2, d / 2))
        let h2 = try box(0.04, 0.2, 0.04, at: SIMD3(0.06, h / 2, d / 2))
        return .merged([body, h1, h2] + feet)
    }

    /// Desk lamp: a weighted base, stem, arm, and a down-facing conical shade.
    public static func deskLamp() throws -> HalfEdgeMesh {
        let base = try cylinder(radius: 0.18, height: 0.05, sides: 12,
                                at: SIMD3(0, 0.025, 0))
        let stem = try cylinder(radius: 0.03, height: 0.7, sides: 6,
                                at: SIMD3(0, 0.35, 0))
        let arm = try box(0.32, 0.04, 0.04, at: SIMD3(0.14, 0.68, 0))
        let shade = try cone(radius: 0.13, height: 0.2, sides: 10,
                             at: SIMD3(0.3, 0.6, 0))
            .rotatedX(.pi)
        return .merged([base, stem, arm, shade])
    }

    // MARK: - Structures (extended)

    /// Well: a circular stone wall, two posts, and a small pyramidal roof.
    public static func well() throws -> HalfEdgeMesh {
        let wall = try cylinder(radius: 0.5, height: 0.6, sides: 12,
                                at: SIMD3(0, 0.3, 0))
        let p1 = try box(0.08, 0.9, 0.08, at: SIMD3(-0.45, 0.75, 0))
        let p2 = try box(0.08, 0.9, 0.08, at: SIMD3(0.45, 0.75, 0))
        let roof = try cone(radius: 0.7, height: 0.4, sides: 4, at: SIMD3(0, 1.4, 0))
            .rotatedY(.pi / 4)
        return .merged([wall, p1, p2, roof])
    }

    /// Silo: a tall cylinder capped by a flattened dome.
    public static func silo() throws -> HalfEdgeMesh {
        let bodyH = 1.6
        let body = try cylinder(radius: 0.4, height: bodyH, sides: 14,
                                at: SIMD3(0, bodyH / 2, 0))
        let dome = try sphere(radius: 0.4, rings: 5, segments: 14,
                              at: SIMD3(0, bodyH, 0))
            .scaled(by: SIMD3(1, 0.6, 1))
        return .merged([body, dome])
    }

    /// Tent: a four-sided pyramid with a small door slab.
    public static func tent() throws -> HalfEdgeMesh {
        let body = try cone(radius: 0.8, height: 1.0, sides: 4, at: SIMD3(0, 0.5, 0))
            .rotatedY(.pi / 4)
        let door = try box(0.25, 0.5, 0.05, at: SIMD3(0, 0.25, 0.55))
        return .merged([body, door])
    }

    /// Windmill: a tapered tower, cap, hub, and four cross-shaped sails.
    public static func windmill() throws -> HalfEdgeMesh {
        let towerH = 1.5
        let tower = try cone(radius: 0.5, height: towerH, sides: 12,
                             at: SIMD3(0, towerH / 2, 0))
        let cap = try cone(radius: 0.35, height: 0.4, sides: 12,
                           at: SIMD3(0, towerH + 0.2, 0))
        let hub = try cylinder(radius: 0.08, height: 0.1, sides: 8,
                               at: SIMD3(0, towerH, 0.56))
            .rotatedX(.pi / 2)
        let up = try box(0.12, 0.8, 0.04, at: SIMD3(0, towerH + 0.4, 0.56))
        let down = try box(0.12, 0.8, 0.04, at: SIMD3(0, towerH - 0.4, 0.56))
        let left = try box(0.8, 0.12, 0.04, at: SIMD3(-0.4, towerH, 0.56))
        let right = try box(0.8, 0.12, 0.04, at: SIMD3(0.4, towerH, 0.56))
        return .merged([tower, cap, hub, up, down, left, right])
    }

    /// Bridge: a flat deck on four piers with two side rails.
    public static func bridge() throws -> HalfEdgeMesh {
        let deck = try box(2.0, 0.12, 0.6, at: SIMD3(0, 0.7, 0))
        let piers = try [(-0.9, -0.25), (0.9, -0.25), (-0.9, 0.25), (0.9, 0.25)]
            .map { try box(0.12, 0.7, 0.12, at: SIMD3($0.0, 0.35, $0.1)) }
        let railL = try box(2.0, 0.15, 0.04, at: SIMD3(0, 0.85, -0.28))
        let railR = try box(2.0, 0.15, 0.04, at: SIMD3(0, 0.85, 0.28))
        return .merged([deck, railL, railR] + piers)
    }

    // MARK: - Props (extended)

    /// Bucket: a cylindrical pail with an arched handle.
    public static func bucket() throws -> HalfEdgeMesh {
        let body = try cylinder(radius: 0.25, height: 0.4, sides: 12,
                                at: SIMD3(0, 0.2, 0))
        let handle = try box(0.5, 0.04, 0.04, at: SIMD3(0, 0.5, 0))
        return .merged([body, handle])
    }

    /// Chest: a box body with a raised lid and a front latch.
    public static func chest() throws -> HalfEdgeMesh {
        let body = try box(0.7, 0.4, 0.45, at: SIMD3(0, 0.2, 0))
        let lid = try box(0.72, 0.15, 0.47, at: SIMD3(0, 0.47, 0))
        let latch = try box(0.1, 0.12, 0.03, at: SIMD3(0, 0.35, 0.23))
        return .merged([body, lid, latch])
    }

    /// Vase: a small base, a rounded belly, and a narrow neck.
    public static func vase() throws -> HalfEdgeMesh {
        let base = try cylinder(radius: 0.12, height: 0.1, sides: 12,
                                at: SIMD3(0, 0.05, 0))
        let belly = try sphere(radius: 0.22, rings: 6, segments: 12,
                               at: SIMD3(0, 0.28, 0))
            .scaled(by: SIMD3(1, 1.1, 1))
        let neck = try cylinder(radius: 0.09, height: 0.18, sides: 12,
                                at: SIMD3(0, 0.52, 0))
        return .merged([base, belly, neck])
    }

    /// Signpost: a round post with a rectangular sign board.
    public static func signpost() throws -> HalfEdgeMesh {
        let post = try cylinder(radius: 0.05, height: 1.4, sides: 8,
                                at: SIMD3(0, 0.7, 0))
        let sign = try box(0.6, 0.3, 0.05, at: SIMD3(0.1, 1.1, 0))
        return .merged([post, sign])
    }

    /// Mailbox: a post topped by a round-roofed box with a raised flag.
    public static func mailbox() throws -> HalfEdgeMesh {
        let post = try box(0.08, 0.9, 0.08, at: SIMD3(0, 0.45, 0))
        let body = try box(0.25, 0.25, 0.4, at: SIMD3(0, 1.0, 0))
        let roundTop = try cylinder(radius: 0.125, height: 0.4, sides: 10,
                                    at: SIMD3(0, 1.125, 0))
            .rotatedX(.pi / 2)
        let flag = try box(0.03, 0.15, 0.1, at: SIMD3(0.14, 1.05, 0.1))
        return .merged([post, body, roundTop, flag])
    }

    // MARK: - Vehicles

    /// Rocket: a cylindrical body, a nose cone, and three tail fins.
    public static func rocket() throws -> HalfEdgeMesh {
        let bodyH = 1.2
        let body = try cylinder(radius: 0.22, height: bodyH, sides: 12,
                                at: SIMD3(0, bodyH / 2 + 0.1, 0))
        let nose = try cone(radius: 0.22, height: 0.4, sides: 12,
                            at: SIMD3(0, bodyH + 0.3, 0))
        var parts = [body, nose]
        for i in 0..<3 {
            let angle = 2 * Double.pi * Double(i) / 3
            let fin = try box(0.05, 0.3, 0.25, at: SIMD3(0, 0.2, 0.22))
                .rotatedY(angle)
            parts.append(fin)
        }
        return .merged(parts)
    }

    /// Sailboat: a boxy hull, a mast, and a single sail.
    public static func sailboat() throws -> HalfEdgeMesh {
        let hull = try box(1.2, 0.3, 0.5, at: SIMD3(0, 0.15, 0))
        let mast = try cylinder(radius: 0.04, height: 1.2, sides: 8,
                                at: SIMD3(0, 0.9, 0))
        let sail = try box(0.04, 0.8, 0.5, at: SIMD3(0.03, 0.95, 0))
        return .merged([hull, mast, sail])
    }

    /// Car: a body, a cabin, and four wheels.
    public static func car() throws -> HalfEdgeMesh {
        let body = try box(1.4, 0.3, 0.6, at: SIMD3(0, 0.35, 0))
        let cabin = try box(0.7, 0.3, 0.55, at: SIMD3(-0.05, 0.65, 0))
        func wheel(_ x: Double, _ z: Double) throws -> HalfEdgeMesh {
            try cylinder(radius: 0.18, height: 0.14, sides: 10, at: SIMD3(x, 0.18, z))
                .rotatedX(.pi / 2)
        }
        let wheels = try [(-0.45, -0.3), (0.45, -0.3), (-0.45, 0.3), (0.45, 0.3)]
            .map { try wheel($0.0, $0.1) }
        return .merged([body, cabin] + wheels)
    }

    /// Wagon: an open bin, a pull handle, and four wheels.
    public static func wagon() throws -> HalfEdgeMesh {
        let bin = try box(0.9, 0.3, 0.5, at: SIMD3(0, 0.4, 0))
        func wheel(_ x: Double, _ z: Double) throws -> HalfEdgeMesh {
            try cylinder(radius: 0.2, height: 0.08, sides: 10, at: SIMD3(x, 0.2, z))
                .rotatedX(.pi / 2)
        }
        let wheels = try [(-0.3, -0.28), (0.3, -0.28), (-0.3, 0.28), (0.3, 0.28)]
            .map { try wheel($0.0, $0.1) }
        let handle = try box(0.5, 0.05, 0.05, at: SIMD3(0.6, 0.5, 0))
        return .merged([bin, handle] + wheels)
    }

    /// Hot air balloon: a scaled envelope, a connecting neck, and a basket.
    public static func hotAirBalloon() throws -> HalfEdgeMesh {
        let balloon = try sphere(radius: 0.6, rings: 8, segments: 12,
                                 at: SIMD3(0, 1.3, 0))
            .scaled(by: SIMD3(1, 1.15, 1))
        let neck = try cone(radius: 0.25, height: 0.3, sides: 10,
                            at: SIMD3(0, 0.75, 0))
            .rotatedX(.pi)
        let basket = try box(0.3, 0.3, 0.3, at: SIMD3(0, 0.15, 0))
        return .merged([balloon, neck, basket])
    }
}
