import Foundation
import CoreGraphics

/// Median-split BVH over a mesh's *vertices* (the sibling of `PickAccelerator`,
/// which indexes fan triangles). It answers the two queries live vertex editing
/// needs at the 1M-vertex scale without an O(n) per-event scan:
///
/// - **Region select** (`vertices(inScreenRect:)`) — rectangle / lasso-box
///   selection: whole BVH nodes are projected to screen and culled when their
///   screen bounds miss the marquee, so cost tracks the visible/near set rather
///   than the mesh size.
/// - **Nearest pick** (`nearestVertex(toScreenPoint:)`) — click-to-grab: the
///   vertex whose projected position is closest to the cursor within a pixel
///   tolerance.
///
/// Projection is injected as a closure `(worldPoint) -> screenPoint?` returning
/// `nil` when the point is behind the camera. That keeps this type pure Swift
/// (no RealityKit, no camera coupling) and exhaustively unit-testable with a
/// trivial projection stub.
public struct VertexAccelerator {

    struct Node {
        var lower: SIMD3<Float>
        var upper: SIMD3<Float>
        /// Leaf: range into `order`. Inner: left child is `index + 1`, right is
        /// `rightChild`.
        var range: Range<Int>?
        var rightChild: Int = 0
    }

    /// Vertex positions, indexed by prim vertex index (parallel to the mesh's
    /// `positions` array — the index *is* the identity used by the edit layer).
    private let positions: [SIMD3<Float>]
    private var order: [Int] = []
    private var nodes: [Node] = []

    private static let leafSize = 16

    public init(positions: [SIMD3<Float>]) {
        self.positions = positions
        order = Array(positions.indices)
        guard !order.isEmpty else { return }
        nodes.reserveCapacity(2 * order.count / Self.leafSize + 2)
        _ = build(range: 0..<order.count)
    }

    public var isEmpty: Bool { nodes.isEmpty }

    private mutating func build(range: Range<Int>) -> Int {
        var lower = SIMD3<Float>(repeating: .infinity)
        var upper = SIMD3<Float>(repeating: -.infinity)
        for i in range {
            let p = positions[order[i]]
            lower = simd_min_f(lower, p)
            upper = simd_max_f(upper, p)
        }
        let nodeIndex = nodes.count
        if range.count <= Self.leafSize {
            nodes.append(Node(lower: lower, upper: upper, range: range))
            return nodeIndex
        }
        nodes.append(Node(lower: lower, upper: upper, range: nil))
        let extent = upper - lower
        let axis = extent.x >= extent.y && extent.x >= extent.z ? 0 : (extent.y >= extent.z ? 1 : 2)
        var slice = Array(order[range])
        slice.sort { positions[$0][axis] < positions[$1][axis] }
        order.replaceSubrange(range, with: slice)
        let mid = range.lowerBound + range.count / 2
        _ = build(range: range.lowerBound..<mid)          // left = nodeIndex + 1
        nodes[nodeIndex].rightChild = build(range: mid..<range.upperBound)
        return nodeIndex
    }

    /// Prim vertex indices whose projected screen position falls inside `rect`.
    ///
    /// Nodes are culled when the screen-space bounding box of their eight AABB
    /// corners misses `rect`. A node with any corner behind the camera cannot be
    /// culled safely (its projected bound is unreliable), so it is descended —
    /// conservative, never dropping a genuine hit.
    public func vertices(inScreenRect rect: CGRect,
                         project: (SIMD3<Float>) -> CGPoint?) -> Set<Int> {
        var hits: Set<Int> = []
        guard !nodes.isEmpty else { return hits }
        var stack = [0]
        while let nodeIndex = stack.popLast() {
            let node = nodes[nodeIndex]
            if let bounds = projectedBounds(node, project: project), separated(bounds, rect) {
                continue // whole node misses the marquee
            }
            if let range = node.range {
                for i in range {
                    let v = order[i]
                    if let sp = project(positions[v]), rect.contains(sp) { hits.insert(v) }
                }
            } else {
                stack.append(nodeIndex + 1)
                stack.append(node.rightChild)
            }
        }
        return hits
    }

    /// The prim vertex index nearest `point` in screen space, within `tolerance`
    /// pixels, or `nil` if nothing qualifies. Ties break to the lowest index for
    /// determinism.
    public func nearestVertex(toScreenPoint point: CGPoint, tolerance: CGFloat,
                              project: (SIMD3<Float>) -> CGPoint?) -> Int? {
        let box = CGRect(x: point.x - tolerance, y: point.y - tolerance,
                         width: 2 * tolerance, height: 2 * tolerance)
        var best: Int?
        var bestDistSq = tolerance * tolerance
        for v in vertices(inScreenRect: box, project: project) {
            guard let sp = project(positions[v]) else { continue }
            let dx = sp.x - point.x, dy = sp.y - point.y
            let d = dx * dx + dy * dy
            guard d <= bestDistSq else { continue }
            // Strictly nearer wins; exact ties break to the lowest vertex index.
            if best == nil || d < bestDistSq || v < best! {
                best = v
                bestDistSq = d
            }
        }
        return best
    }

    /// True only when the two rects are provably disjoint — *inclusive* of a
    /// shared edge, so a node whose projected bound merely touches the marquee is
    /// descended, never culled. (`CGRect.intersects` treats edge-touching as no
    /// overlap, which would drop boundary vertices — regression-tested.)
    private func separated(_ a: CGRect, _ b: CGRect) -> Bool {
        a.maxX < b.minX || a.minX > b.maxX || a.maxY < b.minY || a.minY > b.maxY
    }

    /// Screen-space bounding box of a node's eight AABB corners, or `nil` when
    /// any corner projects behind the camera (caller must then descend).
    private func projectedBounds(_ node: Node,
                                 project: (SIMD3<Float>) -> CGPoint?) -> CGRect? {
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for xi in 0...1 {
            for yi in 0...1 {
                for zi in 0...1 {
                    let corner = SIMD3<Float>(xi == 0 ? node.lower.x : node.upper.x,
                                              yi == 0 ? node.lower.y : node.upper.y,
                                              zi == 0 ? node.lower.z : node.upper.z)
                    guard let sp = project(corner) else { return nil }
                    minX = Swift.min(minX, sp.x); minY = Swift.min(minY, sp.y)
                    maxX = Swift.max(maxX, sp.x); maxY = Swift.max(maxY, sp.y)
                }
            }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func simd_min_f(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(Swift.min(a.x, b.x), Swift.min(a.y, b.y), Swift.min(a.z, b.z))
    }
    private func simd_max_f(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(Swift.max(a.x, b.x), Swift.max(a.y, b.y), Swift.max(a.z, b.z))
    }
}
