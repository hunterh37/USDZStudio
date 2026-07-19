import Foundation
import EditingKit
import USDCore

/// §5 Spatial relationship solver — "B on top of A, centered" resolved from
/// the two prims' world-space bounding boxes into a concrete translation.
/// Converts weak LLM coordinate reasoning into deterministic placement
/// (SceneCraft: declarative constraints beat raw coordinate emission).
public enum SpatialSolver {

    public enum Rule: String, Sendable, CaseIterable {
        case onTop = "on_top"
        case below = "below"
        case leftOf = "left_of"
        case rightOf = "right_of"
        case inFrontOf = "in_front_of"
        case behind = "behind"
        case insideCenter = "inside_center"
    }

    public enum Align: String, Sendable, CaseIterable {
        /// Center on the anchor in the non-rule axes (default).
        case center
        /// Keep the subject's current position in the non-rule axes.
        case keep
    }

    public struct Constraint: Sendable {
        public var anchor: PrimPath
        public var rule: Rule
        public var align: Align
        public var gap: Double

        public init(anchor: PrimPath, rule: Rule, align: Align = .center, gap: Double = 0) {
            self.anchor = anchor
            self.rule = rule
            self.align = align
            self.gap = gap
        }
    }

    /// Parse the tool-call `relativeTo` clause.
    public static func constraint(from json: JSONValue, session: EditSession) throws -> Constraint {
        let anchor = try session.resolve(json, key: "anchor")
        guard let ruleRaw = json["rule"].stringValue else {
            throw ToolError.invalidParams("relativeTo needs 'rule' (\(Rule.allCases.map(\.rawValue).joined(separator: ", ")))")
        }
        guard let rule = Rule(rawValue: ruleRaw) else {
            throw ToolError.invalidParams("unknown rule '\(ruleRaw)'")
        }
        let align: Align
        if let alignRaw = json["align"].stringValue {
            guard let parsed = Align(rawValue: alignRaw) else {
                throw ToolError.invalidParams("unknown align '\(alignRaw)' (center, keep)")
            }
            align = parsed
        } else {
            align = .center
        }
        return Constraint(anchor: anchor, rule: rule, align: align, gap: json["gap"].doubleValue ?? 0)
    }

    /// Resolve the constraint into the subject's new world translation, then
    /// into a local TRS (translation swapped in, rotation/scale preserved).
    public static func solve(
        subject: PrimPath, constraint: Constraint, stage: any USDStageMutable & USDStageProtocol
    ) throws -> TRS {
        guard let subjectBox = GeometryProbe.worldBBox(of: subject, in: stage) else {
            throw ToolError.invalidParams("subject \(subject) has no geometry to place")
        }
        guard let anchorBox = GeometryProbe.worldBBox(of: constraint.anchor, in: stage) else {
            throw ToolError.invalidParams("anchor \(constraint.anchor) has no geometry")
        }

        // Target position of the subject's bbox center, world space.
        var target = subjectBox.center
        let half = subjectBox.size.map { $0 / 2 }
        let g = constraint.gap

        func centerNonRuleAxes(except axis: Int) {
            guard constraint.align == .center else { return }
            for i in 0..<3 where i != axis { target[i] = anchorBox.center[i] }
        }

        switch constraint.rule {
        case .onTop:
            target[1] = anchorBox.max[1] + half[1] + g
            centerNonRuleAxes(except: 1)
        case .below:
            target[1] = anchorBox.min[1] - half[1] - g
            centerNonRuleAxes(except: 1)
        case .leftOf:
            target[0] = anchorBox.min[0] - half[0] - g
            centerNonRuleAxes(except: 0)
        case .rightOf:
            target[0] = anchorBox.max[0] + half[0] + g
            centerNonRuleAxes(except: 0)
        case .inFrontOf:
            target[2] = anchorBox.max[2] + half[2] + g
            centerNonRuleAxes(except: 2)
        case .behind:
            target[2] = anchorBox.min[2] - half[2] - g
            centerNonRuleAxes(except: 2)
        case .insideCenter:
            target = anchorBox.center
        }

        // World-space delta the subject must move by.
        let delta = [
            target[0] - subjectBox.center[0],
            target[1] - subjectBox.center[1],
            target[2] - subjectBox.center[2],
        ]

        // Convert the world delta into the subject's parent space so it can
        // be authored as a local translation.
        var localDelta = delta
        let parentMatrix = stage.worldMatrix(at: subject.parent)
        if let inverse = Matrix4.inverse(parentMatrix) {
            // Direction transform: ignore translation row.
            localDelta = [
                delta[0] * inverse[0] + delta[1] * inverse[4] + delta[2] * inverse[8],
                delta[0] * inverse[1] + delta[1] * inverse[5] + delta[2] * inverse[9],
                delta[0] * inverse[2] + delta[1] * inverse[6] + delta[2] * inverse[10],
            ]
        }

        var trs = stage.transform(at: subject)
        trs.translation = [
            trs.translation[0] + localDelta[0],
            trs.translation[1] + localDelta[1],
            trs.translation[2] + localDelta[2],
        ]
        return trs
    }
}
