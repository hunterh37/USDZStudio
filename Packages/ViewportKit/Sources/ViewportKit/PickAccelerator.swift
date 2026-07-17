import Foundation

/// Median-split BVH over the edited mesh's fan triangles, so hover picking is
/// O(log n) per mouse-move instead of O(faces) — the difference between "fine
/// on a cube" and "fine on the 1M-tri stress target". Built once per mesh
/// revision (the coordinator caches it), traversed per event.
///
/// Correctness contract: `pickFace` returns exactly what
/// `MeshPicker.pickFace` returns, for every ray (fuzz-compared in tests).
public struct PickAccelerator {

    struct Triangle {
        var a: SIMD3<Double>
        var b: SIMD3<Double>
        var c: SIMD3<Double>
        var faceIndex: Int
        var centroid: SIMD3<Double> { (a + b + c) / 3 }
    }

    struct Node {
        var lower: SIMD3<Double>
        var upper: SIMD3<Double>
        /// Leaf: range into `order`. Inner: left child is `index + 1`,
        /// right child is `rightChild`.
        var range: Range<Int>?
        var rightChild: Int = 0
    }

    private var triangles: [Triangle] = []
    private var order: [Int] = []
    private var nodes: [Node] = []

    private static let leafSize = 8

    public init(_ data: EditedMeshData) {
        for (f, loop) in data.faceLoops.enumerated() {
            guard loop.count >= 3, loop.allSatisfy({ data.positions.indices.contains($0) }) else { continue }
            let pts = loop.map { SIMD3<Double>(data.positions[$0]) }
            for i in 1..<(pts.count - 1) {
                triangles.append(Triangle(a: pts[0], b: pts[i], c: pts[i + 1], faceIndex: f))
            }
        }
        order = Array(triangles.indices)
        guard !order.isEmpty else { return }
        nodes.reserveCapacity(2 * order.count / Self.leafSize + 2)
        _ = build(range: 0..<order.count)
    }

    /// Recursively builds a node over `order[range]`; returns its index.
    private mutating func build(range: Range<Int>) -> Int {
        var lower = SIMD3<Double>(repeating: .infinity)
        var upper = SIMD3<Double>(repeating: -.infinity)
        for i in range {
            let t = triangles[order[i]]
            for p in [t.a, t.b, t.c] {
                lower = simd_min_d(lower, p)
                upper = simd_max_d(upper, p)
            }
        }
        let nodeIndex = nodes.count
        if range.count <= Self.leafSize {
            nodes.append(Node(lower: lower, upper: upper, range: range))
            return nodeIndex
        }
        nodes.append(Node(lower: lower, upper: upper, range: nil))
        // Split along the widest axis at the centroid median.
        let extent = upper - lower
        let axis = extent.x >= extent.y && extent.x >= extent.z ? 0 : (extent.y >= extent.z ? 1 : 2)
        var slice = Array(order[range])
        slice.sort { triangles[$0].centroid[axis] < triangles[$1].centroid[axis] }
        order.replaceSubrange(range, with: slice)
        let mid = range.lowerBound + range.count / 2
        _ = build(range: range.lowerBound..<mid) // left = nodeIndex + 1
        nodes[nodeIndex].rightChild = build(range: mid..<range.upperBound)
        return nodeIndex
    }

    /// Nearest face hit, identical to `MeshPicker.pickFace` results.
    public func pickFace(ray: CameraRay.Ray) -> MeshPicker.Hit? {
        guard !nodes.isEmpty else { return nil }
        let invDir = SIMD3<Double>(1 / ray.direction.x, 1 / ray.direction.y, 1 / ray.direction.z)
        var best: MeshPicker.Hit?
        var stack: [Int] = [0]
        while let nodeIndex = stack.popLast() {
            let node = nodes[nodeIndex]
            guard rayHitsBox(ray, invDir: invDir, lower: node.lower, upper: node.upper,
                             maxT: (best?.distance ?? .infinity) * (1 + 1e-8) + 1e-9) else { continue }
            if let range = node.range {
                for i in range {
                    let t = triangles[order[i]]
                    guard let hit = MeshPicker.intersect(ray: ray, a: t.a, b: t.b, c: t.c) else { continue }
                    // Same ordering as MeshPicker (Hit.isBetter): the
                    // correctness contract demands exact parity.
                    if MeshPicker.Hit.isBetter(hit, t.faceIndex, than: best) {
                        best = MeshPicker.Hit(faceIndex: t.faceIndex, distance: hit)
                    }
                }
            } else {
                stack.append(nodeIndex + 1)
                stack.append(node.rightChild)
            }
        }
        return best
    }

    /// Slab test; rejects boxes entirely beyond the current best hit.
    /// Axis-parallel rays are handled explicitly: `(bound − origin) × ∞` is
    /// NaN when the origin sits exactly on the bound, and a NaN-poisoned
    /// min/max silently culls the correct subtree (regression-tested).
    private func rayHitsBox(_ ray: CameraRay.Ray, invDir: SIMD3<Double>,
                            lower: SIMD3<Double>, upper: SIMD3<Double>, maxT: Double) -> Bool {
        var tMin = 0.0, tMax = maxT
        for axis in 0..<3 {
            if abs(ray.direction[axis]) < 1e-300 {
                // Parallel to this slab: inside-or-on the bounds, or a miss.
                if ray.origin[axis] < lower[axis] || ray.origin[axis] > upper[axis] { return false }
                continue
            }
            let t1 = (lower[axis] - ray.origin[axis]) * invDir[axis]
            let t2 = (upper[axis] - ray.origin[axis]) * invDir[axis]
            tMin = max(tMin, min(t1, t2))
            tMax = min(tMax, max(t1, t2))
        }
        return tMin <= tMax
    }

    private func simd_min_d(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(Swift.min(a.x, b.x), Swift.min(a.y, b.y), Swift.min(a.z, b.z))
    }
    private func simd_max_d(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(Swift.max(a.x, b.x), Swift.max(a.y, b.y), Swift.max(a.z, b.z))
    }
}
