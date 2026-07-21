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
        if let tcps = metadata.timeCodesPerSecond {
            lines.append("    timeCodesPerSecond = \(number(tcps))")
        }
        if let start = metadata.startTimeCode {
            lines.append("    startTimeCode = \(number(start))")
        }
        if let end = metadata.endTimeCode {
            lines.append("    endTimeCode = \(number(end))")
        }
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
            if let attributeLines = attributeLines(for: attribute, pad: inner) {
                lines.append(contentsOf: attributeLines)
                if attribute.name == "xformOp:transform" { hasTransformOp = true }
            } else {
                lines.append("\(inner)# unsupported attribute \(quoted(attribute.name)) (\(attribute.value.typeLabel)) omitted")
            }
        }
        if hasTransformOp {
            lines.append("\(inner)uniform token[] xformOpOrder = [\"xformOp:transform\"]")
        }
        for relationship in prim.relationships {
            let uniform = relationship.isUniform ? "uniform " : ""
            let targets = relationship.targets.map { "<\($0.description)>" }
            let rhs = targets.count == 1 ? targets[0] : "[\(targets.joined(separator: ", "))]"
            lines.append("\(inner)\(uniform)rel \(relationship.name) = \(rhs)")
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

    /// Full lines for one attribute — honouring `uniform`, `.timeSamples`, and
    /// attribute metadata — or `nil` for a value type USD can't express (so the
    /// caller emits an "omitted" comment).
    static func attributeLines(for attribute: Attribute, pad inner: String) -> [String]? {
        guard let type = typeToken(for: attribute.value, name: attribute.name) else { return nil }
        let uniform = attribute.isUniform ? "uniform " : ""

        if attribute.isAnimated, let samples = attribute.timeSamples {
            var lines = ["\(inner)\(uniform)\(type) \(attribute.name).timeSamples = {"]
            for sample in samples {
                guard let literal = valueLiteral(for: sample.value, name: attribute.name) else { continue }
                lines.append("\(inner)    \(number(sample.time)): \(literal),")
            }
            lines.append("\(inner)}")
            return lines
        }

        guard let literal = valueLiteral(for: attribute.value, name: attribute.name) else { return nil }
        let head = "\(inner)\(uniform)\(type) \(attribute.name) = \(literal)"
        guard !attribute.metadata.isEmpty else { return [head] }
        // Attribute metadata (e.g. `elementSize`, `interpolation`) is authored
        // verbatim; callers pre-format each value (quoting tokens themselves).
        var lines = [head + " ("]
        for key in attribute.metadata.keys.sorted() {
            lines.append("\(inner)    \(key) = \(attribute.metadata[key]!)")
        }
        lines.append("\(inner))")
        return lines
    }

    /// One `type name = value` declaration, or nil for `.unsupported`. Retained
    /// for callers that only need the flat static form (no uniform/metadata).
    static func declaration(for attribute: Attribute) -> String? {
        guard let type = typeToken(for: attribute.value, name: attribute.name),
              let literal = valueLiteral(for: attribute.value, name: attribute.name) else { return nil }
        return "\(type) \(attribute.name) = \(literal)"
    }

    /// The leading USD type token for a value (e.g. `float3[]`, `color3f`), or
    /// nil for `.unsupported` and malformed fixed-arity values.
    static func typeToken(for value: AttributeValue, name: String) -> String? {
        switch value {
        case .bool: return "bool"
        case .int: return "int"
        case .double: return name.hasPrefix("inputs:") ? "float" : "double"
        case .string: return "string"
        case .token: return "token"
        case .asset: return "asset"
        case .vector(let v):
            guard (2...4).contains(v.count) else { return nil }
            return name.hasPrefix("inputs:") && v.count == 3 ? "color3f" : "double\(v.count)"
        case .matrix4(let v): return v.count == 16 ? "matrix4d" : nil
        case .intArray: return "int[]"
        case .doubleArray(let v):
            switch name {
            case "points": return v.count % 3 == 0 ? "point3f[]" : nil
            case "normals": return v.count % 3 == 0 ? "normal3f[]" : nil
            case "primvars:st": return v.count % 2 == 0 ? "texCoord2f[]" : nil
            default: return "double[]"
            }
        case .stringArray: return "string[]"
        case .tokenArray: return "token[]"
        case .float3Array(let v):
            guard v.count % 3 == 0 else { return nil }
            // Schema-typed geometry attributes must keep their declared role
            // types, or reopening tools won't treat them as geometry.
            switch name {
            case "points": return "point3f[]"
            case "normals": return "normal3f[]"
            default: return "float3[]"
            }
        case .quatfArray(let v): return v.count % 4 == 0 ? "quatf[]" : nil
        case .matrix4dArray(let v): return !v.isEmpty && v.count % 16 == 0 ? "matrix4d[]" : nil
        case .unsupported: return nil
        }
    }

    /// The right-hand-side literal for a value, or nil when the type token is
    /// also nil (kept in lockstep with `typeToken`).
    static func valueLiteral(for value: AttributeValue, name: String) -> String? {
        switch value {
        case .bool(let v): return "\(v)"
        case .int(let v): return "\(v)"
        case .double(let v): return number(v)
        case .string(let v): return quoted(v)
        case .token(let v): return quoted(v)
        case .asset(let v): return "@\(v)@"
        case .vector(let v):
            guard (2...4).contains(v.count) else { return nil }
            return tuple(v)
        case .matrix4(let v):
            guard v.count == 16 else { return nil }
            return matrixLiteral(v, base: 0)
        case .intArray(let v):
            return "[\(v.map(String.init).joined(separator: ", "))]"
        case .doubleArray(let v):
            switch name {
            case "points", "normals": return vectorArrayLiteral(v, arity: 3)
            case "primvars:st": return vectorArrayLiteral(v, arity: 2)
            default: return "[\(v.map(number).joined(separator: ", "))]"
            }
        case .stringArray(let v): return "[\(v.map(quoted).joined(separator: ", "))]"
        case .tokenArray(let v): return "[\(v.map(quoted).joined(separator: ", "))]"
        case .float3Array(let v): return vectorArrayLiteral(v, arity: 3)
        case .quatfArray(let v): return vectorArrayLiteral(v, arity: 4)
        case .matrix4dArray(let v):
            guard !v.isEmpty, v.count % 16 == 0 else { return nil }
            let matrices = stride(from: 0, to: v.count, by: 16)
                .map { matrixLiteral(v, base: $0) }
                .joined(separator: ", ")
            return "[\(matrices)]"
        case .unsupported: return nil
        }
    }

    private static func vectorArrayLiteral(_ flat: [Double], arity: Int) -> String? {
        guard flat.count % arity == 0 else { return nil }
        // Slice into `flat` per vector rather than copying each group into a
        // fresh `Array` — this runs over every point/normal/UV on save.
        let elements = stride(from: 0, to: flat.count, by: arity)
            .map { tuple(flat[$0..<($0 + arity)]) }
            .joined(separator: ", ")
        return "[\(elements)]"
    }

    private static func matrixLiteral(_ flat: [Double], base: Int) -> String {
        let rows = stride(from: base, to: base + 16, by: 4)
            .map { tuple(flat[$0..<($0 + 4)]) }
            .joined(separator: ", ")
        return "( \(rows) )"
    }

    // MARK: - Lexical helpers

    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15
            ? String(Int64(value))
            : String(value)
    }

    /// Accepts any `Double` sequence (`[Double]` or an `ArraySlice` view) so
    /// callers can pass a slice of a flat buffer without allocating a copy.
    static func tuple<S: Sequence>(_ values: S) -> String where S.Element == Double {
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
