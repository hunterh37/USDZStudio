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
            description: """
            Render the stage (or an isolated subtree via 'paths') for visual judgment. \
            Named 'views' cover the canonical front|side|top|persp; 'angles' add arbitrary \
            orbit shots as {azimuth, elevation, distance} (degrees; azimuth orbits the up axis, \
            elevation tilts above the horizon, distance scales the auto-framed dolly, default 1). \
            Cameras auto-frame the subject so any angle stays in shot. statsOnly returns \
            bbox/tri-count/material summaries instead of pixels.
            """,
            inputSchema: Schema.object([
                "paths": Schema.array(of: Schema.primRef, "isolate these subtrees (default whole stage)"),
                "views": Schema.array(of: .object(["type": "string"]), "subset of front|side|top|persp"),
                "angles": Schema.array(of: Schema.object([
                    "azimuth": Schema.number("degrees orbiting the up axis (0 = front, 90 = right side)"),
                    "elevation": Schema.number("degrees above the horizon (90 = straight down)"),
                    "distance": Schema.number("dolly multiplier on the auto-framed distance (default 1)"),
                ], required: ["azimuth", "elevation"]), "arbitrary orbit shots"),
                "size": Schema.integer("image edge in pixels (default 512)"),
                "statsOnly": Schema.boolean("skip pixels; return geometric summary (default false when a renderer is available)"),
            ])
        ) { args in
            var isolate: [PrimPath] = []
            if let raw = args["paths"].arrayValue {
                for entry in raw { isolate.append(try session.resolve(.object(["path": entry]))) }
            }
            let angles = try parseAngles(args["angles"])
            // Named views default in only when the caller specified no custom angles.
            let namedViews = args["views"].stringArrayValue ?? (angles.isEmpty ? defaultViews : [])
            guard namedViews.allSatisfy({ defaultViews.contains($0) }) else {
                throw ToolError.invalidParams("'views' must be a subset of \(defaultViews.joined(separator: ", "))")
            }
            guard !namedViews.isEmpty || !angles.isEmpty else {
                throw ToolError.invalidParams("provide at least one of 'views' or 'angles'")
            }

            let statsOnly = args["statsOnly"].boolValue ?? (renderer == nil)
            if statsOnly {
                return statsSummary(session: session, isolate: isolate)
            }
            guard let renderer else {
                // The native SceneKit renderer needs no usdrecord and is the
                // intended default; reaching here means the host wired no
                // renderer at all (see RenderKit / the app-renderer wiring).
                throw ToolError.unsupported(
                    "this server was configured without a renderer — reconfigure with a renderer (RenderKit's native SceneKit renderer needs no usdrecord), or call again with statsOnly: true")
            }
            return try await renderImages(
                session: session, isolate: isolate, views: namedViews, angles: angles,
                size: args["size"].intValue ?? 512,
                renderer: renderer, workDirectory: workDirectory)
        })

        server.register(MCPTool(
            name: "find_best_view", group: .render,
            description: """
            Rank camera angles by how much of the subject they reveal, without rendering. \
            Samples an orbit sphere and scores each angle by the projected silhouette footprint \
            of the subject's bounds — the most informative angles come first. Feed the returned \
            {azimuth, elevation} straight into render_views 'angles' for an optimal capture.
            """,
            inputSchema: Schema.object([
                "paths": Schema.array(of: Schema.primRef, "isolate these subtrees (default whole stage)"),
                "count": Schema.integer("how many top angles to return (default 3)"),
            ])
        ) { args in
            var isolate: [PrimPath] = []
            if let raw = args["paths"].arrayValue {
                for entry in raw { isolate.append(try session.resolve(.object(["path": entry]))) }
            }
            let count = args["count"].intValue ?? 3
            guard count >= 1 else { throw ToolError.invalidParams("'count' must be >= 1") }
            guard let frame = subjectBounds(session: session, isolate: isolate), frame.maxExtent > 0 else {
                throw ToolError.failed("nothing measurable: subjects have no geometry")
            }
            let ranked = bestAngles(framing: frame, count: count)
            return .object(["angles": .array(ranked.map { angle in
                .object([
                    "azimuth": .number(angle.azimuth),
                    "elevation": .number(angle.elevation),
                    "coverage": .number(angle.coverage),
                ])
            })])
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

    /// A named camera shot: the prim authored into the render stage plus the
    /// stable label echoed back to the caller.
    struct Shot {
        var name: String
        var camera: Prim
    }

    static func renderImages(
        session: EditSession, isolate: [PrimPath], views: [String], angles: [Angle], size: Int,
        renderer: any RenderExecuting, workDirectory: URL
    ) async throws -> JSONValue {
        guard size >= 64, size <= 4096 else {
            throw ToolError.invalidParams("'size' must be within 64...4096")
        }
        // Author the (possibly isolated) stage as a temp usda the renderer can open.
        let snapshot = session.stage.currentSnapshot
        let roots = isolatedRoots(snapshot: snapshot, isolate: isolate)
        guard let frame = bounds(of: roots, metadata: snapshot.metadata), frame.maxExtent > 0 else {
            throw ToolError.failed("nothing renderable: subjects have no geometry")
        }
        // Named views first, then arbitrary orbit angles, each auto-framed.
        var shots = views.compactMap { view in camera(view: view, framing: frame).map { Shot(name: view, camera: $0) } }
        for (index, angle) in angles.enumerated() {
            shots.append(Shot(name: "angle\(index)", camera: sphericalCamera(name: "angle\(index)", angle: angle, framing: frame)))
        }

        let isolated = StageSnapshot(metadata: snapshot.metadata, rootPrims: roots + shots.map(\.camera))
        let usda = USDASerializer.serialize(isolated)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let stageURL = workDirectory.appendingPathComponent("render-stage.usda")
        try usda.write(to: stageURL, atomically: true, encoding: .utf8)

        var images: [JSONValue] = []
        for shot in shots {
            let outputURL = workDirectory.appendingPathComponent("render-\(shot.name).png")
            do {
                try await renderer.render(
                    stageURL: stageURL, outputURL: outputURL,
                    cameraPath: "/AgentCam_\(shot.name)", size: size)
            } catch {
                throw ToolError.failed("render '\(shot.name)' failed: \(error)")
            }
            images.append(.object(["view": .string(shot.name), "path": .string(outputURL.path)]))
        }
        return .object(["statsOnly": .bool(false), "images": .array(images)])
    }

    /// Materialize the subtrees to render, re-rooted so they stand alone.
    static func isolatedRoots(snapshot: StageSnapshot, isolate: [PrimPath]) -> [Prim] {
        guard !isolate.isEmpty else { return snapshot.rootPrims }
        return isolate.compactMap { path in
            snapshot.rootPrims.lazy.compactMap { $0.prim(at: path) }.first.map { reroot($0) }
        }
    }

    /// World bounds of a set of (already re-rooted) prims.
    static func bounds(of roots: [Prim], metadata: StageMetadata) -> GeometryProbe.BBox? {
        let probe = InMemoryStage(StageSnapshot(metadata: metadata, rootPrims: roots))
        var bbox: GeometryProbe.BBox?
        for root in roots {
            if let b = GeometryProbe.worldBBox(of: root.path, in: probe) {
                bbox = bbox.map { $0.union(b) } ?? b
            }
        }
        return bbox
    }

    /// World bounds of the current session's subject (whole stage or isolate).
    static func subjectBounds(session: EditSession, isolate: [PrimPath]) -> GeometryProbe.BBox? {
        let snapshot = session.stage.currentSnapshot
        return bounds(of: isolatedRoots(snapshot: snapshot, isolate: isolate), metadata: snapshot.metadata)
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
        return cameraPrim(name: view, eye: eye, center: center, up: up)
    }

    /// A spherical orbit shot: `azimuth`/`elevation` in degrees around the
    /// subject, `distance` a multiplier on the auto-framed dolly.
    static func sphericalCamera(name: String, angle: Angle, framing bbox: GeometryProbe.BBox) -> Prim {
        let center = bbox.center
        let distance = max(bbox.maxExtent, 1e-3) * 2.2 * angle.distance
        let eye = eyePosition(angle: angle, distance: distance, center: center)
        // Callers pass generated "angleN" names, which always form a valid path.
        return cameraPrim(name: name, eye: eye, center: center, up: upVector(elevation: angle.elevation))!
    }

    /// Shared Camera-prim factory. `nil` only when `name` can't form a path.
    static func cameraPrim(name: String, eye: [Double], center: [Double], up: [Double]) -> Prim? {
        guard let path = PrimPath("/AgentCam_\(name)") else { return nil }
        return Prim(
            path: path, typeName: "Camera",
            attributes: [
                Attribute(name: "focalLength", value: .double(35)),
                Attribute(name: transformAttributeName, value: .matrix4(lookAt(eye: eye, center: center, up: up))),
                Attribute(name: "xformOpOrder", value: .tokenArray(["xformOp:transform"]), isUniform: true),
            ])
    }

    /// Eye position on the orbit sphere for `angle` at `distance` from `center`.
    /// Azimuth 0 faces +Z (front); +azimuth swings toward +X; elevation lifts +Y.
    static func eyePosition(angle: Angle, distance: Double, center: [Double]) -> [Double] {
        let az = angle.azimuth * .pi / 180
        let el = angle.elevation * .pi / 180
        let dir = [cos(el) * sin(az), sin(el), cos(el) * cos(az)]
        return [center[0] + distance * dir[0], center[1] + distance * dir[1], center[2] + distance * dir[2]]
    }

    /// Up vector for an orbit shot: swap to a horizontal reference near the
    /// poles, where the world up collapses onto the view direction.
    static func upVector(elevation: Double) -> [Double] {
        abs(elevation) >= 89 ? [0, 0, -1] : [0, 1, 0]
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

    // MARK: - Arbitrary orbit angles

    /// A viewing direction on the orbit sphere. `coverage` is filled in only by
    /// the optimizer (`bestAngles`); it is 0 for caller-supplied angles.
    struct Angle: Equatable {
        var azimuth: Double
        var elevation: Double
        var distance: Double = 1
        var coverage: Double = 0
    }

    /// Parse the `angles` array from tool input into validated `Angle`s.
    static func parseAngles(_ value: JSONValue) throws -> [Angle] {
        guard let raw = value.arrayValue else {
            guard value.isNull else { throw ToolError.invalidParams("'angles' must be an array") }
            return []
        }
        return try raw.map { entry in
            guard let azimuth = entry["azimuth"].doubleValue,
                  let elevation = entry["elevation"].doubleValue else {
                throw ToolError.invalidParams("each angle needs numeric 'azimuth' and 'elevation'")
            }
            guard elevation >= -90, elevation <= 90 else {
                throw ToolError.invalidParams("'elevation' must be within -90...90")
            }
            let distance = entry["distance"].doubleValue ?? 1
            guard distance > 0 else { throw ToolError.invalidParams("'distance' must be > 0") }
            return Angle(azimuth: azimuth, elevation: elevation, distance: distance)
        }
    }

    /// Azimuths (every 45°) × elevations sampled to find the most revealing shot.
    static let sampledAzimuths: [Double] = stride(from: 0, to: 360, by: 45).map(Double.init)
    static let sampledElevations: [Double] = [15, 35, 55]

    /// Rank orbit angles by projected silhouette footprint of `bbox`. Larger
    /// footprint ⇒ more of the subject faces the camera ⇒ more informative.
    /// Ties break toward lower azimuth then lower elevation for determinism.
    static func bestAngles(framing bbox: GeometryProbe.BBox, count: Int) -> [Angle] {
        var scored: [Angle] = []
        for elevation in sampledElevations {
            for azimuth in sampledAzimuths {
                let angle = Angle(azimuth: azimuth, elevation: elevation)
                scored.append(Angle(
                    azimuth: azimuth, elevation: elevation,
                    coverage: projectedFootprint(framing: bbox, angle: angle)))
            }
        }
        scored.sort {
            if $0.coverage != $1.coverage { return $0.coverage > $1.coverage }
            if $0.azimuth != $1.azimuth { return $0.azimuth < $1.azimuth }
            return $0.elevation < $1.elevation
        }
        return Array(scored.prefix(count))
    }

    /// Area of the subject's bounds projected onto the camera image plane for
    /// `angle`. Distance-independent: it depends only on view direction and up.
    static func projectedFootprint(framing bbox: GeometryProbe.BBox, angle: Angle) -> Double {
        let center = bbox.center
        let eye = eyePosition(angle: angle, distance: 1, center: center)
        let matrix = lookAt(eye: eye, center: center, up: upVector(elevation: angle.elevation))
        let xAxis = [matrix[0], matrix[1], matrix[2]]
        let yAxis = [matrix[4], matrix[5], matrix[6]]
        var minU = Double.greatestFiniteMagnitude, maxU = -Double.greatestFiniteMagnitude
        var minV = Double.greatestFiniteMagnitude, maxV = -Double.greatestFiniteMagnitude
        for corner in corners(of: bbox) {
            let rel = GeometryProbe.sub(corner, center)
            let u = GeometryProbe.dot(rel, xAxis)
            let v = GeometryProbe.dot(rel, yAxis)
            minU = min(minU, u); maxU = max(maxU, u)
            minV = min(minV, v); maxV = max(maxV, v)
        }
        return (maxU - minU) * (maxV - minV)
    }

    /// The eight corners of a bounding box.
    static func corners(of bbox: GeometryProbe.BBox) -> [[Double]] {
        var out: [[Double]] = []
        for x in [bbox.min[0], bbox.max[0]] {
            for y in [bbox.min[1], bbox.max[1]] {
                for z in [bbox.min[2], bbox.max[2]] {
                    out.append([x, y, z])
                }
            }
        }
        return out
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
