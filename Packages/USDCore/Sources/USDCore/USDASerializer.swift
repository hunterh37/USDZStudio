import Foundation

/// Serializes a stage snapshot to `.usda` text — the native write path used
/// by the CLI `convert` subcommand and (later) Save As. Deterministic: same
/// snapshot → byte-identical output (spec principle 3).
public enum USDASerializer {

    public static func serialize(_ stage: some USDStageProtocol) -> String {
        var lines: [String] = ["#usda 1.0", "("]
        let metadata = stage.metadata
        if let defaultPrim = metadata.defaultPrim {
            lines.append("    defaultPrim = \(quoted(defaultPrim))")
        }
        lines.append("    metersPerUnit = \(number(metadata.metersPerUnit))")
        lines.append("    upAxis = \(quoted(metadata.upAxis.rawValue))")
        if !metadata.customLayerData.isEmpty {
            lines.append("    customLayerData = {")
            for key in metadata.customLayerData.keys.sorted() {
                lines.append("        string \(key) = \(quoted(metadata.customLayerData[key]!))")
            }
            lines.append("    }")
        }
        lines.append(")")
        lines.append("")
        for prim in stage.rootPrims {
            lines.append(contentsOf: serialize(prim, indent: 0))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Prims

    static func serialize(_ prim: Prim, indent: Int) -> [String] {
        let pad = String(repeating: "    ", count: indent)
        var lines: [String] = []

        let keyword = prim.typeName.isEmpty ? "def" : "def \(prim.typeName)"
        var header = "\(pad)\(keyword) \(quoted(prim.name))"
        if !prim.isActive {
            header += " (\n\(pad)    active = false\n\(pad))"
        }
        lines.append(header + "\n\(pad){")

        let inner = pad + "    "
        if prim.visibility == .invisible {
            lines.append("\(inner)token visibility = \"invisible\"")
        }
        var hasTransformOp = false
        for attribute in prim.attributes {
            if let declaration = declaration(for: attribute) {
                lines.append(inner + declaration)
                if attribute.name == "xformOp:transform" { hasTransformOp = true }
            } else {
                lines.append("\(inner)# unsupported attribute \(quoted(attribute.name)) (\(attribute.value.typeLabel)) omitted")
            }
        }
        if hasTransformOp {
            lines.append("\(inner)uniform token[] xformOpOrder = [\"xformOp:transform\"]")
        }
        if !prim.metadata.isEmpty {
            lines.append("\(inner)custom string[] dicyanin:metadata = ["
                + prim.metadata.keys.sorted().map { quoted("\($0)=\(prim.metadata[$0]!)") }.joined(separator: ", ")
                + "]")
        }
        for (index, child) in prim.children.enumerated() {
            if index > 0 || !lines.isEmpty { lines.append("") }
            lines.append(contentsOf: serialize(child, indent: indent + 1))
        }
        lines.append("\(pad)}")
        return lines
    }

    // MARK: - Attributes

    /// One `type name = value` declaration, or nil for `.unsupported`.
    static func declaration(for attribute: Attribute) -> String? {
        let name = attribute.name
        switch attribute.value {
        case .bool(let value):
            return "bool \(name) = \(value)"
        case .int(let value):
            return "int \(name) = \(value)"
        case .double(let value):
            return "\(name.hasPrefix("inputs:") ? "float" : "double") \(name) = \(number(value))"
        case .string(let value):
            return "string \(name) = \(quoted(value))"
        case .token(let value):
            return "token \(name) = \(quoted(value))"
        case .asset(let value):
            return "asset \(name) = @\(value)@"
        case .vector(let values):
            guard (2...4).contains(values.count) else { return nil }
            let type = name.hasPrefix("inputs:") && values.count == 3
                ? "color3f" : "double\(values.count)"
            return "\(type) \(name) = \(tuple(values))"
        case .matrix4(let values):
            guard values.count == 16 else { return nil }
            let rows = stride(from: 0, to: 16, by: 4)
                .map { tuple(Array(values[$0..<($0 + 4)])) }
                .joined(separator: ", ")
            return "matrix4d \(name) = ( \(rows) )"
        case .intArray(let values):
            return "int[] \(name) = [\(values.map(String.init).joined(separator: ", "))]"
        case .doubleArray(let values):
            // Well-known geometry attributes get their schema types so
            // downstream consumers (RealityKit, usdchecker) see valid data.
            switch name {
            case "points": return vectorArray("point3f[]", name, values, arity: 3)
            case "normals": return vectorArray("normal3f[]", name, values, arity: 3)
            case "primvars:st": return vectorArray("texCoord2f[]", name, values, arity: 2)
            default:
                return "double[] \(name) = [\(values.map(number).joined(separator: ", "))]"
            }
        case .stringArray(let values):
            return "string[] \(name) = [\(values.map(quoted).joined(separator: ", "))]"
        case .unsupported:
            return nil
        }
    }

    private static func vectorArray(_ type: String, _ name: String, _ flat: [Double], arity: Int) -> String? {
        guard flat.count % arity == 0 else { return nil }
        let elements = stride(from: 0, to: flat.count, by: arity)
            .map { tuple(Array(flat[$0..<($0 + arity)])) }
            .joined(separator: ", ")
        return "\(type) \(name) = [\(elements)]"
    }

    // MARK: - Lexical helpers

    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15
            ? String(Int64(value))
            : String(value)
    }

    static func tuple(_ values: [Double]) -> String {
        "(" + values.map(number).joined(separator: ", ") + ")"
    }

    static func quoted(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            + "\""
    }
}
