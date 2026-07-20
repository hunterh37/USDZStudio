import Foundation
import EditingKit
import USDCore

/// External renderer seam. The repo has no in-process renderer; rendering is
/// out-of-process via `usdrecord` (like the CLI thumbnail command). Injecting
/// this keeps every tool unit-testable without USD tooling installed.
public protocol RenderExecuting: Sendable {
    /// Render `stageURL` to `outputURL` (PNG) through the camera prim at
    /// `cameraPath` (authored into the stage by the render tool).
    func render(stageURL: URL, outputURL: URL, cameraPath: String, size: Int) async throws
}

/// §3.4 Render tools — visual judgment only, opt-in, never automatic.
/// `stats_only` returns geometric summaries in place of pixels when the agent
/// only needs confirmation, not judgment.
public enum RenderTools {

    public static let defaultViews = ["front", "side", "top", "persp"]

    public static func register(
        on server: MCPServer, session: EditSession,
        renderer: (any RenderExecuting)?,
        workDirectory: URL
    ) {
        server.register(MCPTool(
            name: "render_views", group: .render,
            description: "Render the stage (or an isolated subtree via 'paths') from multiple views for visual judgment. statsOnly returns bbox/tri-count/material summaries instead of pixels. Default views: front, side, top, persp.",
            inputSchema: Schema.object([
                "paths": Schema.array(of: Schema.primRef, "isolate these subtrees (default whole stage)"),
                "views": Schema.array(of: .object(["type": "string"]), "subset of front|side|top|persp"),
                "size": Schema.integer("image edge in pixels (default 512)"),
                "statsOnly": Schema.boolean("skip pixels; return geometric summary (default false when a renderer is available)"),
            ])
        ) { args in
            let views = args["views"].stringArrayValue ?? defaultViews
            guard views.allSatisfy({ defaultViews.contains($0) }), !views.isEmpty else {
                throw ToolError.invalidParams("'views' must be a non-empty subset of \(defaultViews.joined(separator: ", "))")
            }
            var isolate: [PrimPath] = []
            if let raw = args["paths"].arrayValue {
                for entry in raw { isolate.append(try session.resolve(.object(["path": entry]))) }
            }

            let statsOnly = args["statsOnly"].boolValue ?? (renderer == nil)
            if statsOnly {
                return statsSummary(session: session, isolate: isolate)
            }
            guard let renderer else {
                throw ToolError.unsupported(
                    "no renderer available (usdrecord not found) — call again with statsOnly: true")
            }
            return try await renderImages(
                session: session, isolate: isolate, views: views,
                size: args["size"].intValue ?? 512,
                renderer: renderer, workDirectory: workDirectory)
        })

        server.register(MCPTool(
            name: "raycast", group: .render,
            description: "Cast a world-space ray against stage geometry; returns the nearest hit prim, distance, and point. Cheap spatial ground truth.",
            inputSchema: Schema.object([
                "origin": Schema.vec3,
                "direction": Schema.vec3,
            ], required: ["origin", "direction"])
        ) { args in
            guard let origin = args["origin"].doubleArrayValue, origin.count == 3,
                  let direction = args["direction"].doubleArrayValue, direction.count == 3
            else {
                throw ToolError.invalidParams("'origin' and 'direction' must be [x, y, z]")
            }
            guard let hit = GeometryProbe.raycast(origin: origin, direction: direction, in: session.stage) else {
                return .object(["hit": .bool(false)])
            }
            return .object([
                "hit": .bool(true),
                "path": .string(hit.path.description),
                "primId": .string(session.id(for: hit.path)),
                "distance": .number(hit.distance),
                "point": .array(hit.point.map { .number($0) }),
            ])
        })
    }

    // MARK: - stats_only summary (freecad-mcp's token-saving toggle)

    static func statsSummary(session: EditSession, isolate: [PrimPath]) -> JSONValue {
        let targets: [PrimPath] = isolate.isEmpty
            ? session.stage.rootPrims.map(\.path) : isolate
        var summaries: [JSONValue] = []
        for path in targets {
            var payload: [String: JSONValue] = ["path": .string(path.description)]
            if let box = GeometryProbe.worldBBox(of: path, in: session.stage) {
                payload["bbox"] = box.asJSON
            }
            var triangles = 0
            var materials = Set<String>()
            if let prim = session.stage.prim(at: path) {
                for descendant in prim.flattened() {
                    if case .intArray(let counts)? = descendant.attribute(named: "faceVertexCounts")?.value {
                        triangles += counts.reduce(0) { $0 + max(0, $1 - 2) }
                    }
                    if let binding = descendant.relationships.first(where: { $0.name == "material:binding" }),
                       let target = binding.targets.first {
                        materials.insert(target.description)
                    }
                }
            }
            payload["triangles"] = .number(Double(triangles))
            payload["materials"] = .array(materials.sorted().map { .string($0) })
            summaries.append(.object(payload))
        }
        return .object(["statsOnly": .bool(true), "subjects": .array(summaries)])
    }

    // MARK: - Real rendering (isolated-object render via a temp sub-stage)

    static func renderImages(
        session: EditSession, isolate: [PrimPath], views: [String], size: Int,
        renderer: any RenderExecuting, workDirectory: URL
    ) async throws -> JSONValue {
        guard size >= 64, size <= 4096 else {
            throw ToolError.invalidParams("'size' must be within 64...4096")
        }
        // Author the (possibly isolated) stage as a temp usda the renderer can open.
        let snapshot = session.stage.currentSnapshot
        let roots: [Prim]
        if isolate.isEmpty {
            roots = snapshot.rootPrims
        } else {
            roots = isolate.compactMap { path in
                snapshot.rootPrims.lazy.compactMap { $0.prim(at: path) }.first
                    .map { reroot($0) }
            }
        }
        // Frame the subject: whole-scene bbox drives per-view camera placement.
        let probe = InMemoryStage(StageSnapshot(metadata: snapshot.metadata, rootPrims: roots))
        var bbox: GeometryProbe.BBox?
        for root in roots {
            if let b = GeometryProbe.worldBBox(of: root.path, in: probe) {
                bbox = bbox.map { $0.union(b) } ?? b
            }
        }
        guard let frame = bbox, frame.maxExtent > 0 else {
            throw ToolError.failed("nothing renderable: subjects have no geometry")
        }
        let cameras = views.compactMap { camera(view: $0, framing: frame) }
        let isolated = StageSnapshot(metadata: snapshot.metadata, rootPrims: roots + cameras)
        let usda = USDASerializer.serialize(isolated)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let stageURL = workDirectory.appendingPathComponent("render-stage.usda")
        try usda.write(to: stageURL, atomically: true, encoding: .utf8)

        var images: [JSONValue] = []
        for view in views {
            let outputURL = workDirectory.appendingPathComponent("render-\(view).png")
            do {
                try await renderer.render(
                    stageURL: stageURL, outputURL: outputURL,
                    cameraPath: "/AgentCam_\(view)", size: size)
            } catch {
                throw ToolError.failed("render '\(view)' failed: \(error)")
            }
            images.append(.object(["view": .string(view), "path": .string(outputURL.path)]))
        }
        return .object(["statsOnly": .bool(false), "images": .array(images)])
    }

    /// Author a Camera prim framing `bbox` for one named view.
    static func camera(view: String, framing bbox: GeometryProbe.BBox) -> Prim? {
        let center = bbox.center
        let distance = max(bbox.maxExtent, 1e-3) * 2.2
        let eye: [Double]
        let up: [Double]
        switch view {
        case "front": eye = [center[0], center[1], center[2] + distance]; up = [0, 1, 0]
        case "side": eye = [center[0] + distance, center[1], center[2]]; up = [0, 1, 0]
        case "top": eye = [center[0], center[1] + distance, center[2]]; up = [0, 0, -1]
        case "persp":
            let d = distance * 0.66
            eye = [center[0] + d, center[1] + d, center[2] + d]; up = [0, 1, 0]
        default: return nil
        }
        guard let path = PrimPath("/AgentCam_\(view)") else { return nil }
        return Prim(
            path: path, typeName: "Camera",
            attributes: [
                Attribute(name: "focalLength", value: .double(35)),
                Attribute(name: transformAttributeName, value: .matrix4(lookAt(eye: eye, center: center, up: up))),
                Attribute(name: "xformOpOrder", value: .tokenArray(["xformOp:transform"]), isUniform: true),
            ])
    }

    /// Row-major, row-vector camera matrix: camera looks down its local -Z
    /// at `center` (USD convention); rows are basis vectors, last row = eye.
    static func lookAt(eye: [Double], center: [Double], up: [Double]) -> [Double] {
        func normalize(_ v: [Double]) -> [Double] {
            let length = sqrt(GeometryProbe.dot(v, v))
            guard length > 1e-12 else { return [0, 0, 1] }
            return v.map { $0 / length }
        }
        let zAxis = normalize(GeometryProbe.sub(eye, center))  // camera +Z points backwards
        let xAxis = normalize(GeometryProbe.cross(up, zAxis))
        let yAxis = GeometryProbe.cross(zAxis, xAxis)
        return [
            xAxis[0], xAxis[1], xAxis[2], 0,
            yAxis[0], yAxis[1], yAxis[2], 0,
            zAxis[0], zAxis[1], zAxis[2], 0,
            eye[0], eye[1], eye[2], 1,
        ]
    }

    /// Lift an isolated subtree to the stage root so it renders alone.
    private static func reroot(_ prim: Prim) -> Prim {
        guard prim.path.depth > 1, let newPath = PrimPath("/\(prim.path.name)") else { return prim }
        var moved = prim
        rewrite(&moved, to: newPath)
        return moved
    }

    private static func rewrite(_ prim: inout Prim, to newPath: PrimPath) {
        prim.path = newPath
        for i in prim.children.indices {
            if let childPath = newPath.appending(prim.children[i].name) {
                rewrite(&prim.children[i], to: childPath)
            }
        }
    }
}
