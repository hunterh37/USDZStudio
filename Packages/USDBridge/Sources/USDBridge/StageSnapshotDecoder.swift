import Foundation
import USDCore

/// Wire format emitted by `Resources/Python/stage_snapshot.py`.
/// Kept private; the public surface is `StageSnapshot` from USDCore
/// ("snapshots out, commands in" — specs/usd-bridge.md).
struct SnapshotDTO: Decodable {
    struct MetadataDTO: Decodable {
        var upAxis: String?
        var metersPerUnit: Double?
        var defaultPrim: String?
        var customLayerData: [String: String]?
    }
    struct AttributeDTO: Decodable {
        var name: String
        var type: String
        var bool: Bool?
        var int: Int?
        var double: Double?
        var string: String?
        var doubles: [Double]?
        var ints: [Int]?
        var strings: [String]?
    }
    struct VariantSetDTO: Decodable {
        var name: String
        var variants: [String]
        var selection: String?
    }
    struct RelationshipDTO: Decodable {
        var name: String
        var targets: [String]?
        var uniform: Bool?
    }
    struct PrimDTO: Decodable {
        var path: String
        var type: String?
        var active: Bool?
        var visibility: String?
        var attributes: [AttributeDTO]?
        var relationships: [RelationshipDTO]?
        var metadata: [String: String]?
        var variantSets: [VariantSetDTO]?
        var children: [PrimDTO]?
    }
    var metadata: MetadataDTO?
    var prims: [PrimDTO]
}

/// Decodes the bridge's JSON snapshot payload into a `StageSnapshot`.
public enum StageSnapshotDecoder {

    public static func decode(_ data: Data, sourceURL: URL? = nil) throws -> StageSnapshot {
        let dto: SnapshotDTO
        do {
            dto = try JSONDecoder().decode(SnapshotDTO.self, from: data)
        } catch {
            throw BridgeError.malformedSnapshot(detail: String(describing: error))
        }
        return StageSnapshot(
            sourceURL: sourceURL,
            metadata: try metadata(from: dto.metadata),
            rootPrims: try dto.prims.map(prim(from:)))
    }

    private static func metadata(from dto: SnapshotDTO.MetadataDTO?) throws -> StageMetadata {
        guard let dto else { return StageMetadata() }
        var upAxis = UpAxis.y
        if let raw = dto.upAxis {
            guard let parsed = UpAxis(rawValue: raw) else {
                throw BridgeError.malformedSnapshot(detail: "unknown upAxis '\(raw)'")
            }
            upAxis = parsed
        }
        let metersPerUnit = dto.metersPerUnit ?? 1.0
        guard metersPerUnit > 0, metersPerUnit.isFinite else {
            throw BridgeError.malformedSnapshot(detail: "invalid metersPerUnit \(metersPerUnit)")
        }
        return StageMetadata(
            upAxis: upAxis,
            metersPerUnit: metersPerUnit,
            defaultPrim: dto.defaultPrim,
            customLayerData: dto.customLayerData ?? [:])
    }

    private static func prim(from dto: SnapshotDTO.PrimDTO) throws -> Prim {
        guard let path = PrimPath(dto.path) else {
            throw BridgeError.malformedSnapshot(detail: "invalid prim path '\(dto.path)'")
        }
        var visibility = Visibility.inherited
        if let raw = dto.visibility {
            guard let parsed = Visibility(rawValue: raw) else {
                throw BridgeError.malformedSnapshot(detail: "unknown visibility '\(raw)' at \(dto.path)")
            }
            visibility = parsed
        }
        let children = try (dto.children ?? []).map(prim(from:))
        for child in children where child.path.parent != path {
            throw BridgeError.malformedSnapshot(
                detail: "child \(child.path) is not a direct child of \(path)")
        }
        return Prim(
            path: path,
            typeName: dto.type ?? "",
            isActive: dto.active ?? true,
            visibility: visibility,
            attributes: try (dto.attributes ?? []).map(attribute(from:)),
            relationships: try (dto.relationships ?? []).map(relationship(from:)),
            metadata: dto.metadata ?? [:],
            variantSets: (dto.variantSets ?? []).map {
                VariantSet(name: $0.name, variants: $0.variants, selection: $0.selection)
            },
            children: children)
    }

    /// Decodes a relationship, e.g. `material:binding` or `skel:skeleton`.
    ///
    /// The Python side already prunes property targets down to prim paths, but a
    /// malformed target is still possible from a hand-edited layer; those are
    /// dropped rather than failing the whole open, since a bad relationship
    /// target shouldn't cost the user the file (specs/usd-bridge.md — degrade,
    /// never lose data).
    private static func relationship(from dto: SnapshotDTO.RelationshipDTO) throws -> Relationship {
        Relationship(
            name: dto.name,
            targets: (dto.targets ?? []).compactMap(PrimPath.init),
            isUniform: dto.uniform ?? true)
    }

    private static func attribute(from dto: SnapshotDTO.AttributeDTO) throws -> Attribute {
        let value: AttributeValue
        switch dto.type {
        case "bool":
            guard let v = dto.bool else { throw missingValue(dto) }
            value = .bool(v)
        case "int":
            guard let v = dto.int else { throw missingValue(dto) }
            value = .int(v)
        case "double", "float":
            guard let v = dto.double else { throw missingValue(dto) }
            value = .double(v)
        case "string":
            guard let v = dto.string else { throw missingValue(dto) }
            value = .string(v)
        case "token":
            guard let v = dto.string else { throw missingValue(dto) }
            value = .token(v)
        case "asset":
            guard let v = dto.string else { throw missingValue(dto) }
            value = .asset(v)
        case "vector":
            guard let v = dto.doubles, (2...4).contains(v.count) else { throw missingValue(dto) }
            value = .vector(v)
        case "matrix4d":
            guard let v = dto.doubles, v.count == 16 else { throw missingValue(dto) }
            value = .matrix4(v)
        case "float3[]":
            guard let v = dto.doubles, v.count % 3 == 0 else { throw missingValue(dto) }
            value = .float3Array(v)
        case "int[]":
            guard let v = dto.ints else { throw missingValue(dto) }
            value = .intArray(v)
        case "double[]", "float[]":
            guard let v = dto.doubles else { throw missingValue(dto) }
            value = .doubleArray(v)
        case "string[]", "token[]":
            guard let v = dto.strings else { throw missingValue(dto) }
            value = .stringArray(v)
        default:
            // Exotic types are preserved by name, never dropped (PRD pillar 2).
            value = .unsupported(typeName: dto.type)
        }
        return Attribute(name: dto.name, value: value)
    }

    private static func missingValue(_ dto: SnapshotDTO.AttributeDTO) -> BridgeError {
        .malformedSnapshot(detail: "attribute '\(dto.name)' has type '\(dto.type)' but no matching value")
    }
}
