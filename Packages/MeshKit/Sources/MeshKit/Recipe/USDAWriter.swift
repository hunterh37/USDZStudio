import Foundation

/// Authors a `RecipeBuildResult` as `.usda` text: one Xform per part with a
/// polygonal Mesh child, flat-color UsdPreviewSurface materials under a
/// Materials scope (shader as a *child* of the Material — the real-file shape
/// the bridge and inspector expect), and GeomSubset bindings for faces tagged
/// via `assignMaterial`.
public enum USDAWriter {

    public static func usda(for build: RecipeBuildResult) -> String {
        let recipe = build.recipe
        let root = sanitize(recipe.name)
        var out = Lines()

        out.add("#usda 1.0")
        out.add("(")
        out.add("    defaultPrim = \"\(root)\"")
        out.add("    metersPerUnit = \(format(recipe.metersPerUnit ?? 1))")
        out.add("    upAxis = \"\(recipe.upAxis ?? "Y")\"")
        out.add(")")
        out.add("")
        out.add("def Xform \"\(root)\"")
        out.add("{")

        let materials = Dictionary(uniqueKeysWithValues:
            (recipe.materials ?? []).map { (sanitize($0.name), $0) })

        for part in build.parts {
            write(part, root: root, materials: materials, into: &out)
        }

        if !materials.isEmpty {
            out.add("    def Scope \"Materials\"")
            out.add("    {")
            for name in materials.keys.sorted() {
                write(materials[name]!, sanitizedName: name, into: &out)
            }
            out.add("    }")
        }
        out.add("}")
        return out.text
    }

    // MARK: - Parts

    private static func write(_ part: BuiltPart, root: String,
                              materials: [String: RecipeMaterial], into out: inout Lines) {
        let name = sanitize(part.name)
        let flat = part.flat
        let boundMaterial = part.material.map(sanitize)
        let needsBindingAPI = boundMaterial != nil
            || flat.subsets.keys.contains { materials[sanitize($0)] != nil }

        out.add("    def Xform \"\(name)\"")
        out.add("    {")
        if let t = part.transform {
            var order: [String] = []
            if let v = t.translate, v.count == 3 {
                out.add("        double3 xformOp:translate = (\(v.map(format).joined(separator: ", ")))")
                order.append("\"xformOp:translate\"")
            }
            if let v = t.rotateDegrees, v.count == 3 {
                out.add("        float3 xformOp:rotateXYZ = (\(v.map(format).joined(separator: ", ")))")
                order.append("\"xformOp:rotateXYZ\"")
            }
            if let v = t.scale, v.count == 3 {
                out.add("        float3 xformOp:scale = (\(v.map(format).joined(separator: ", ")))")
                order.append("\"xformOp:scale\"")
            }
            if !order.isEmpty {
                out.add("        uniform token[] xformOpOrder = [\(order.joined(separator: ", "))]")
            }
        }
        out.add("")
        let apiClause = needsBindingAPI ? " (\n            prepend apiSchemas = [\"MaterialBindingAPI\"]\n        )" : ""
        out.add("        def Mesh \"Geom\"\(apiClause)")
        out.add("        {")

        let (lo, hi) = extent(of: flat.points)
        out.add("            float3[] extent = [(\(format(lo.x)), \(format(lo.y)), \(format(lo.z))), (\(format(hi.x)), \(format(hi.y)), \(format(hi.z)))]")
        out.add("            int[] faceVertexCounts = [\(flat.faceVertexCounts.map(String.init).joined(separator: ", "))]")
        out.add("            int[] faceVertexIndices = [\(flat.faceVertexIndices.map(String.init).joined(separator: ", "))]")
        out.add("            point3f[] points = [\(flat.points.map(point3).joined(separator: ", "))]")
        if let material = boundMaterial, let spec = materials[material] {
            let c = spec.diffuseColor
            out.add("            color3f[] primvars:displayColor = [(\(format(c[0])), \(format(c[1])), \(format(c[2])))]")
        }
        out.add("            uniform token subdivisionScheme = \"none\"")
        if let material = boundMaterial {
            out.add("            rel material:binding = </\(root)/Materials/\(material)>")
        }

        // GeomSubsets: material-named subsets get a binding; others are plain tags.
        for subsetName in flat.subsets.keys.sorted() {
            let indices = flat.subsets[subsetName]!
            let sanitized = sanitize(subsetName)
            let isMaterial = materials[sanitized] != nil
            out.add("")
            let subsetAPI = isMaterial ? " (\n                prepend apiSchemas = [\"MaterialBindingAPI\"]\n            )" : ""
            out.add("            def GeomSubset \"\(sanitized)\"\(subsetAPI)")
            out.add("            {")
            out.add("                uniform token elementType = \"face\"")
            out.add("                uniform token familyName = \"materialBind\"")
            out.add("                int[] indices = [\(indices.map(String.init).joined(separator: ", "))]")
            if isMaterial {
                out.add("                rel material:binding = </\(root)/Materials/\(sanitized)>")
            }
            out.add("            }")
        }
        out.add("        }")
        out.add("    }")
        out.add("")
    }

    // MARK: - Materials

    private static func write(_ material: RecipeMaterial, sanitizedName: String,
                              into out: inout Lines) {
        let c = material.diffuseColor
        out.add("        def Material \"\(sanitizedName)\"")
        out.add("        {")
        out.add("            token outputs:surface.connect = <PreviewSurface.outputs:surface>")
        out.add("")
        out.add("            def Shader \"PreviewSurface\"")
        out.add("            {")
        out.add("                uniform token info:id = \"UsdPreviewSurface\"")
        out.add("                color3f inputs:diffuseColor = (\(format(c[0])), \(format(c[1])), \(format(c[2])))")
        out.add("                float inputs:metallic = \(format(material.metallic ?? 0))")
        out.add("                float inputs:roughness = \(format(material.roughness ?? 0.8))")
        if let opacity = material.opacity {
            out.add("                float inputs:opacity = \(format(opacity))")
        }
        out.add("                token outputs:surface")
        out.add("            }")
        out.add("        }")
    }

    // MARK: - Formatting

    /// USD identifier: letters/digits/underscore, not starting with a digit.
    public static func sanitize(_ name: String) -> String {
        var out = ""
        for scalar in name.unicodeScalars {
            out.append(CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII
                       ? Character(scalar) : "_")
        }
        if out.isEmpty { out = "Unnamed" }
        if out.first!.isNumber { out = "_" + out }
        return out
    }

    public static func extent(of points: [SIMD3<Double>]) -> (SIMD3<Double>, SIMD3<Double>) {
        guard var lo = points.first else { return (.zero, .zero) }
        var hi = lo
        for p in points.dropFirst() {
            lo = SIMD3(Swift.min(lo.x, p.x), Swift.min(lo.y, p.y), Swift.min(lo.z, p.z))
            hi = SIMD3(Swift.max(hi.x, p.x), Swift.max(hi.y, p.y), Swift.max(hi.z, p.z))
        }
        return (lo, hi)
    }

    static func point3(_ p: SIMD3<Double>) -> String {
        "(\(format(p.x)), \(format(p.y)), \(format(p.z)))"
    }

    /// Compact numeric formatting: integral values without a trailing ".0",
    /// otherwise shortest round-trip Double description.
    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int(value))
        }
        return "\(value)"
    }

    private struct Lines {
        var text = ""
        mutating func add(_ line: String) { text += line + "\n" }
    }
}
