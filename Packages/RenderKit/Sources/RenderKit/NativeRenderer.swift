import AgentMCP
import Foundation

#if canImport(SceneKit)
import AppKit
import ModelIO
import SceneKit
import SceneKit.ModelIO
#endif

/// Chooses which `RenderExecuting` backs `render_views`. Native by default;
/// Storm (`usdrecord`) only when the operator opts in with `DICYANIN_USDRECORD`
/// pointing at a real binary. Pure and injectable so the policy is unit-tested
/// without a filesystem or GPU.
public enum NativeRendererSelection {
    public static func make(
        environment: [String: String],
        fileExists: (String) -> Bool
    ) -> any RenderExecuting {
        if let override = environment["DICYANIN_USDRECORD"], !override.isEmpty, fileExists(override) {
            return UsdrecordRenderer(usdrecordPath: override)
        }
        return NativeSceneKitRenderer()
    }
}

/// Pure parsing of the render stage the `render_views` tool hands the renderer.
///
/// The tool always feeds a `USDASerializer`-produced `.usda` (see
/// `RenderTools.renderImages`), so the format is regular and self-authored:
/// `UsdPreviewSurface` materials under a `Looks` scope, `material:binding`
/// relationships on the renderable prims, and one `Camera` prim per shot whose
/// `xformOp:transform` encodes the framing. This enum turns that text into the
/// two things a native renderer needs — per-prim diffuse colour and the camera
/// pose — without linking any GPU framework, so it is exhaustively unit-tested.
public enum RenderStageParse {

    /// Prim (leaf) name → resolved diffuse RGB in 0...1, following each prim's
    /// `material:binding` to its `Material`'s `UsdPreviewSurface.inputs:diffuseColor`.
    /// Model I/O imports the geometry but drops these colours, so the renderer
    /// re-applies them; this is the resolution the app's viewport does natively.
    static func diffuseColorsByPrimName(usda: String) -> [String: [Double]] {
        let materials = materialDiffuse(usda: usda)     // material leaf name → rgb
        let bindings = primBindings(usda: usda)         // prim leaf name → material leaf name
        var out: [String: [Double]] = [:]
        for (prim, material) in bindings {
            if let rgb = materials[material] { out[prim] = rgb }
        }
        return out
    }

    /// Prim (leaf) name → the resolved diffuse **texture** asset path, following
    /// each prim's `material:binding` to a `Material` whose `UsdPreviewSurface`
    /// diffuse is driven by a `UsdUVTexture` (`inputs:file = @...@`). Model I/O
    /// drops these, and `applyColors` only ever set a constant colour, so a
    /// textured material rendered flat grey (#90). This resolution lets the
    /// renderer bind the real image.
    static func textureFilesByPrimName(usda: String) -> [String: String] {
        let materials = materialTextureFiles(usda: usda)  // material leaf → asset path
        let bindings = primBindings(usda: usda)           // prim leaf → material leaf
        var out: [String: String] = [:]
        for (prim, material) in bindings {
            if let file = materials[material] { out[prim] = file }
        }
        return out
    }

    /// `Material` leaf name → its diffuse `UsdUVTexture.inputs:file` asset path
    /// (the raw `@...@` token, package-relative paths included).
    static func materialTextureFiles(usda: String) -> [String: String] {
        var out: [String: String] = [:]
        var current: String?
        for line in usda.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let name = definitionName(trimmed, keyword: "def Material") {
                current = name
            } else if trimmed.hasPrefix("def "), !trimmed.contains("Shader") {
                current = nil
            }
            // The first `inputs:file = @...@` inside a material scope (the diffuse
            // texture's UsdUVTexture Shader). Keep the first — normal/roughness
            // maps come later and aren't the base colour.
            if let current, out[current] == nil, trimmed.contains("inputs:file"),
               let asset = assetToken(in: trimmed) {
                out[current] = asset
            }
        }
        return out
    }

    /// The `@...@`-delimited asset path on a line, without the delimiters.
    static func assetToken(in line: String) -> String? {
        guard let open = line.firstIndex(of: "@") else { return nil }
        let afterOpen = line.index(after: open)
        guard let close = line[afterOpen...].firstIndex(of: "@") else { return nil }
        let token = String(line[afterOpen..<close])
        return token.isEmpty ? nil : token
    }

    /// Resolve a USD texture asset path to an absolute filesystem path relative
    /// to the stage file. Handles the `usdz` package case where an internal ref
    /// looks like `0/earth.jpg` or `@./0/earth.jpg@`; when the stage itself is a
    /// `.usdz` package we cannot address files inside it as loose paths, so the
    /// caller must extract — this returns the package-qualified path unchanged
    /// for that case (signalled by a nil return). Pure and testable.
    static func resolveTexturePath(assetPath: String, stageURL: URL) -> String? {
        let path = assetPath.hasPrefix("./") ? String(assetPath.dropFirst(2)) : assetPath
        if path.hasPrefix("/") { return path }                 // already absolute
        // Loose texture beside (or under) the stage's .usda directory.
        let base = stageURL.deletingLastPathComponent()
        return base.appendingPathComponent(path).standardizedFileURL.path
    }

    /// `Material` leaf name → its `inputs:diffuseColor` RGB.
    static func materialDiffuse(usda: String) -> [String: [Double]] {
        var out: [String: [Double]] = [:]
        var current: String?
        for line in usda.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let name = definitionName(trimmed, keyword: "def Material") {
                current = name                       // enter a material scope
            } else if trimmed.hasPrefix("def "), !trimmed.contains("Shader") {
                current = nil                        // a non-Shader def leaves the scope
            }
            if let current, let rgb = colorTriplet(after: "inputs:diffuseColor", in: trimmed) {
                out[current] = rgb                   // diffuseColor lives on the child Shader
            }
        }
        return out
    }

    /// Prim (any type) leaf name → the leaf name of its bound material.
    static func primBindings(usda: String) -> [String: String] {
        var out: [String: String] = [:]
        var current: String?
        for line in usda.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let name = anyDefinitionName(trimmed) { current = name }
            if trimmed.contains("material:binding"),
               let target = angleTarget(in: trimmed),
               let prim = current {
                out[prim] = lastPathComponent(target)
            }
        }
        return out
    }

    /// The 16 row-major transform values and focal length of the named `Camera`
    /// prim, or `nil` when it is absent or malformed.
    static func camera(named name: String, usda: String) -> (rows: [Double], focal: Double)? {
        guard let header = usda.range(of: "def Camera \"\(name)\"") else { return nil }
        // Restrict to this prim's block: from the header to the next top-level
        // `def ` (cameras the tool authors have no children, so this is safe).
        let rest = String(usda[header.upperBound...])
        let block: String
        if let next = rest.range(of: "\ndef ") {
            block = String(rest[..<next.lowerBound])
        } else {
            block = rest
        }
        guard let rows = matrixValues(after: "xformOp:transform", in: block), rows.count == 16 else {
            return nil
        }
        let focal = scalar(after: "focalLength", in: block) ?? 35
        return (rows, focal)
    }

    // MARK: - Line helpers (pure)

    /// The quoted name in `def <keyword> "Name"`, or `nil` if the line is not
    /// that kind of definition.
    static func definitionName(_ line: String, keyword: String) -> String? {
        guard line.hasPrefix(keyword) else { return nil }
        return quoted(line)
    }

    /// The quoted name of any `def <Type> "Name"` line.
    static func anyDefinitionName(_ line: String) -> String? {
        guard line.hasPrefix("def ") else { return nil }
        return quoted(line)
    }

    /// First double-quoted substring in `line`.
    static func quoted(_ line: String) -> String? {
        guard let open = line.firstIndex(of: "\""),
              let close = line[line.index(after: open)...].firstIndex(of: "\"")
        else { return nil }
        return String(line[line.index(after: open)..<close])
    }

    /// The `</path/to/Target>` reference on a line, without the brackets.
    static func angleTarget(in line: String) -> String? {
        guard let open = line.firstIndex(of: "<"),
              let close = line.firstIndex(of: ">"), open < close
        else { return nil }
        return String(line[line.index(after: open)..<close])
    }

    /// Last `/`-separated component of a prim path.
    static func lastPathComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Parse `<key> = (r, g, b)` on a line into three doubles.
    static func colorTriplet(after key: String, in line: String) -> [Double]? {
        guard line.contains(key), let open = line.firstIndex(of: "("),
              let close = line.firstIndex(of: ")"), open < close
        else { return nil }
        let comps = line[line.index(after: open)..<close]
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return comps.count == 3 ? comps : nil
    }

    /// Parse `<key> = <number>` (the first numeric token after `=`).
    static func scalar(after key: String, in text: String) -> Double? {
        guard let keyRange = text.range(of: key),
              let eq = text[keyRange.upperBound...].firstIndex(of: "=")
        else { return nil }
        let after = text[text.index(after: eq)...]
        var token = ""
        for ch in after {
            if ch.isNumber || ch == "." || ch == "-" || ch == "e" || ch == "E" || ch == "+" {
                token.append(ch)
            } else if !token.isEmpty {
                break
            } else if ch == " " || ch == "\t" {
                continue
            } else {
                break
            }
        }
        return Double(token)
    }

    /// Parse `<key> = ( (..),(..),(..),(..) )` into its flat numeric values.
    static func matrixValues(after key: String, in text: String) -> [Double]? {
        guard let keyRange = text.range(of: key),
              let eq = text[keyRange.upperBound...].firstIndex(of: "=")
        else { return nil }
        let after = text[text.index(after: eq)...]
        // Take up to the matching close of the outer paren group: the first ')'
        // that is followed (ignoring spaces/newlines) by a non-')' or end.
        guard let outerOpen = after.firstIndex(of: "(") else { return nil }
        var depth = 0
        var end: String.Index?
        var i = outerOpen
        while i < after.endIndex {
            let ch = after[i]
            if ch == "(" { depth += 1 }
            if ch == ")" {
                depth -= 1
                if depth == 0 { end = i; break }
            }
            i = after.index(after: i)
        }
        guard let close = end else { return nil }
        let body = after[after.index(after: outerOpen)..<close]
        let values = body
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ")
            .compactMap { Double($0) }
        return values.isEmpty ? nil : values
    }
}

/// Native, dependency-free renderer for AgentMCP's `render_views`: loads the USD
/// stage with Model I/O + SceneKit and snapshots it offscreen through the camera
/// prim the render tool authored — the same Apple frameworks the app's viewport
/// is built on. No `usd-core` / `usdrecord` required, so `render_views` returns
/// real pixels out of the box; `usd-core` stays reserved for authoring/round-trip.
public struct NativeSceneKitRenderer: RenderExecuting {
    public init() {}


    // coverage:disable — drives SceneKit/Metal offscreen (needs a GPU); the
    // parsing it depends on (RenderStageParse) is exhaustively unit-tested, and
    // the render tool's stage/camera authoring is tested against a stub renderer.
    public func render(stageURL: URL, outputURL: URL, cameraPath: String, size: Int) async throws {
        #if canImport(SceneKit)
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw NativeRenderError.noMetalDevice
        }
        let usda = try String(contentsOf: stageURL, encoding: .utf8)

        let asset = MDLAsset(url: stageURL)
        asset.loadTextures()
        let scene = SCNScene(mdlAsset: asset)

        // Studio backdrop + a soft neutral environment so PBR materials read.
        scene.background.contents = NSColor(calibratedWhite: 0.09, alpha: 1)
        scene.lightingEnvironment.contents = NSColor(calibratedWhite: 0.5, alpha: 1)
        scene.lightingEnvironment.intensity = 1.1

        // Re-apply diffuse colours + textures Model I/O dropped (#90).
        let colors = RenderStageParse.diffuseColorsByPrimName(usda: usda)
        let textures = RenderStageParse.textureFilesByPrimName(usda: usda)
        applyColors(colors, textures: textures, stageURL: stageURL, to: scene.rootNode)

        // Key + fill + ambient, tuned to avoid blowing out light materials.
        scene.rootNode.addChildNode(makeLight(.ambient, 120, nil))
        scene.rootNode.addChildNode(makeLight(.directional, 700, SCNVector3(-0.85, 0.6, 0)))
        scene.rootNode.addChildNode(makeLight(.directional, 300, SCNVector3(-0.25, -1.4, 0.3)))

        let pov = camera(named: RenderStageParse.lastPathComponent(cameraPath), usda: usda, scene: scene)
        scene.rootNode.addChildNode(pov)

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = pov
        let image = renderer.snapshot(
            atTime: 0, with: CGSize(width: size, height: size), antialiasingMode: .multisampling4X)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw NativeRenderError.encodeFailed }
        try png.write(to: outputURL)
        #else
        throw NativeRenderError.unsupportedPlatform
        #endif
    }
    // coverage:enable
}

public enum NativeRenderError: Error {
    case noMetalDevice
    case encodeFailed
    case unsupportedPlatform
    case usdrecordFailed(status: Int32)
}

/// Storm-backed renderer: shells out to a real `usdrecord`. Opt-in via
/// `DICYANIN_USDRECORD`; the native SceneKit renderer is the zero-config default.
public struct UsdrecordRenderer: RenderExecuting {
    public var usdrecordPath: String

    public init(usdrecordPath: String) { self.usdrecordPath = usdrecordPath }

    // coverage:disable — spawns the real usdrecord binary; the render tool's stage/camera authoring is unit-tested against a stub renderer.
    public func render(stageURL: URL, outputURL: URL, cameraPath: String, size: Int) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: usdrecordPath)
        process.arguments = [
            "--imageWidth", String(size),
            "--camera", cameraPath,
            stageURL.path, outputURL.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NativeRenderError.usdrecordFailed(status: process.terminationStatus)
        }
    }
    // coverage:enable
}

#if canImport(SceneKit)
extension NativeSceneKitRenderer {
    // coverage:disable — SceneKit scene-graph mutation, exercised only under a GPU.
    private func applyColors(
        _ colors: [String: [Double]],
        textures: [String: String],
        stageURL: URL,
        to node: SCNNode
    ) {
        if let name = node.name, let geometry = node.geometry {
            // A prim bound to a texture-driven diffuse: load the image and set it
            // as diffuse.contents (albedo is sRGB). Falls back to the constant
            // colour when the texture can't be loaded, and to nothing when the
            // prim has neither (leaving Model I/O's material).
            if let asset = textures[name],
               let path = RenderStageParse.resolveTexturePath(assetPath: asset, stageURL: stageURL),
               let image = NSImage(contentsOfFile: path) {
                let material = SCNMaterial()
                material.lightingModel = .physicallyBased
                material.diffuse.contents = image
                material.roughness.contents = 0.5
                material.metalness.contents = 0.0
                geometry.materials = [material]
            } else if let rgb = colors[name] {
                let material = SCNMaterial()
                material.lightingModel = .physicallyBased
                material.diffuse.contents = NSColor(
                    red: CGFloat(rgb[0]), green: CGFloat(rgb[1]), blue: CGFloat(rgb[2]), alpha: 1)
                material.roughness.contents = 0.5
                material.metalness.contents = 0.0
                geometry.materials = [material]
            }
        }
        node.childNodes.forEach { applyColors(colors, textures: textures, stageURL: stageURL, to: $0) }
    }

    private func makeLight(_ type: SCNLight.LightType, _ intensity: CGFloat, _ euler: SCNVector3?) -> SCNNode {
        let node = SCNNode()
        let light = SCNLight()
        light.type = type
        light.intensity = intensity
        node.light = light
        if let euler { node.eulerAngles = euler }
        return node
    }

    /// A camera node framing the subject: the authored camera pose when present,
    /// else an auto-framed 3/4 fallback so a render still succeeds.
    private func camera(named name: String, usda: String, scene: SCNScene) -> SCNNode {
        let node = SCNNode()
        let cam = SCNCamera()
        cam.zNear = 0.01
        cam.zFar = 1000
        cam.automaticallyAdjustsZRange = false
        cam.wantsHDR = true
        node.camera = cam

        if let parsed = RenderStageParse.camera(named: name, usda: usda) {
            let m = parsed.rows
            let eye = SCNVector3(m[12], m[13], m[14])
            let forward = SCNVector3(-m[8], -m[9], -m[10])   // camera looks down local -Z
            let up = SCNVector3(m[4], m[5], m[6])
            node.position = eye
            node.look(
                at: SCNVector3(eye.x + forward.x, eye.y + forward.y, eye.z + forward.z),
                up: up, localFront: SCNVector3(0, 0, -1))
            // USD default vertical aperture (mm) → vertical field of view.
            cam.fieldOfView = CGFloat(2 * atan(15.2908 / (2 * parsed.focal)) * 180 / Double.pi)
            cam.projectionDirection = .vertical
        } else {
            cam.fieldOfView = 32
            let (minB, maxB) = scene.rootNode.boundingBox
            let center = SCNVector3((minB.x + maxB.x) / 2, (minB.y + maxB.y) / 2, (minB.z + maxB.z) / 2)
            let extent = max(maxB.x - minB.x, max(maxB.y - minB.y, maxB.z - minB.z))
            node.position = SCNVector3(
                center.x + extent * 1.5, center.y + extent * 1.0, center.z + extent * 1.8)
            node.look(at: center)
        }
        return node
    }
    // coverage:enable
}
#endif
