import USDCore
import RigKit

/// Canonical UsdSkel attribute names authored by the rig commands.
enum SkelAttr {
    static let translations = "translations"
    static let rotations = "rotations"
    static let scales = "scales"
    static let jointIndices = "primvars:skel:jointIndices"
    static let jointWeights = "primvars:skel:jointWeights"
}

/// Restore-or-remove helper: authoring an attribute is undone either by restoring the previous
/// value or, when there was none, by removing the attribute (the clean inverse).
struct AttributeUndo: Sendable, Hashable {
    let path: PrimPath
    let name: String
    let previous: Attribute?

    func revert(on stage: any USDStageMutable) throws {
        if let previous {
            try stage.apply(.setAttribute(path: path, attribute: previous))
        } else {
            try stage.apply(.removeAttribute(path: path, name: name))
        }
    }
}

/// Author a whole skeletal pose at default time (the static per-joint local transforms). Used by
/// `set_joint_pose` and to bake a solved IK pose. Fully undoable.
public struct AuthorSkelPoseCommand: EditCommand {
    public let path: PrimPath
    let newAttributes: [Attribute]
    let undos: [AttributeUndo]

    public var label: String { "Pose \(path.name)" }

    public init(path: PrimPath, pose: Pose, existing prim: Prim?) {
        self.path = path
        self.newAttributes = [
            Attribute(name: SkelAttr.translations, value: .float3Array(pose.translationsFlat)),
            Attribute(name: SkelAttr.rotations, value: .quatfArray(pose.rotationsFlat)),
            Attribute(name: SkelAttr.scales, value: .float3Array(pose.scalesFlat)),
        ]
        self.undos = newAttributes.map {
            AttributeUndo(path: path, name: $0.name, previous: prim?.attribute(named: $0.name))
        }
    }

    public func execute(on stage: any USDStageMutable) throws {
        for attribute in newAttributes {
            try stage.apply(.setAttribute(path: path, attribute: attribute))
        }
    }

    public func undo(on stage: any USDStageMutable) throws {
        for undo in undos { try undo.revert(on: stage) }
    }
}

/// Insert or replace a keyframe at `timeCode` for a whole pose, writing into the `.timeSamples` of
/// the three channel attributes (the path exercised by the closed time-sampled round-trip).
public struct SetSkelKeyframeCommand: EditCommand {
    public let path: PrimPath
    public let timeCode: Double
    let newAttributes: [Attribute]
    let undos: [AttributeUndo]

    public var label: String { "Key \(path.name) @ \(SetSkelKeyframeCommand.format(timeCode))" }

    public init(path: PrimPath, timeCode: Double, pose: Pose, existing prim: Prim?) {
        self.path = path
        self.timeCode = timeCode
        func keyed(_ name: String, _ carrier: AttributeValue, _ value: AttributeValue) -> Attribute {
            let existingAttr = prim?.attribute(named: name)
            var samples = existingAttr?.timeSamples ?? []
            samples.removeAll { abs($0.time - timeCode) < 1e-9 }
            samples.append(TimeSample(time: timeCode, value: value))
            samples.sort { $0.time < $1.time }
            return Attribute(name: name, value: carrier, isUniform: false,
                             metadata: existingAttr?.metadata ?? [:], timeSamples: samples)
        }
        self.newAttributes = [
            keyed(SkelAttr.translations, .float3Array([]), .float3Array(pose.translationsFlat)),
            keyed(SkelAttr.rotations, .quatfArray([]), .quatfArray(pose.rotationsFlat)),
            keyed(SkelAttr.scales, .float3Array([]), .float3Array(pose.scalesFlat)),
        ]
        self.undos = newAttributes.map {
            AttributeUndo(path: path, name: $0.name, previous: prim?.attribute(named: $0.name))
        }
    }

    public func execute(on stage: any USDStageMutable) throws {
        for attribute in newAttributes {
            try stage.apply(.setAttribute(path: path, attribute: attribute))
        }
    }

    public func undo(on stage: any USDStageMutable) throws {
        for undo in undos { try undo.revert(on: stage) }
    }

    static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }
}

/// Author skin weights (`primvars:skel:jointIndices` / `jointWeights`) with a constant
/// `elementSize` (influences per vertex), clamped to the export-profile cap by the caller.
public struct AuthorSkinCommand: EditCommand {
    public let path: PrimPath
    let newAttributes: [Attribute]
    let undos: [AttributeUndo]

    public var label: String { "Skin \(path.name)" }

    public init(path: PrimPath, indices: [Int], weights: [Double],
                influencesPerVertex: Int, existing prim: Prim?) {
        self.path = path
        let meta = ["elementSize": String(influencesPerVertex)]
        self.newAttributes = [
            Attribute(name: SkelAttr.jointIndices, value: .intArray(indices), metadata: meta),
            Attribute(name: SkelAttr.jointWeights, value: .doubleArray(weights), metadata: meta),
        ]
        self.undos = newAttributes.map {
            AttributeUndo(path: path, name: $0.name, previous: prim?.attribute(named: $0.name))
        }
    }

    public func execute(on stage: any USDStageMutable) throws {
        for attribute in newAttributes {
            try stage.apply(.setAttribute(path: path, attribute: attribute))
        }
    }

    public func undo(on stage: any USDStageMutable) throws {
        for undo in undos { try undo.revert(on: stage) }
    }
}

/// Set the stage's animation time range (the clip window). Undoable against the prior metadata.
public struct SetClipRangeCommand: EditCommand {
    public let name: String
    let newMetadata: StageMetadata
    let oldMetadata: StageMetadata

    public var label: String { "Clip \(name)" }

    public init(name: String, startTimeCode: Double, endTimeCode: Double, current: StageMetadata) {
        self.name = name
        self.oldMetadata = current
        var updated = current
        updated.startTimeCode = min(startTimeCode, endTimeCode)
        updated.endTimeCode = max(startTimeCode, endTimeCode)
        self.newMetadata = updated
    }

    public func execute(on stage: any USDStageMutable) throws {
        try stage.apply(.setStageMetadata(newMetadata))
    }

    public func undo(on stage: any USDStageMutable) throws {
        try stage.apply(.setStageMetadata(oldMetadata))
    }
}
