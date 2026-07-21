import Foundation

/// The outcome of a solve. A non-converging solve is a *reported* result, never a thrown error or a
/// silent bad pose — mirrors MeshKit's precondition-diagnostic discipline.
public struct SolveResult: Sendable, Equatable {
    /// The solved pose (best effort even when `converged == false`).
    public var pose: Pose
    /// Whether the effector reached the target within tolerance.
    public var converged: Bool
    /// Iterations actually run (0 for closed-form analytic solves that need none).
    public var iterations: Int
    /// Final distance between the effector and the target (world units).
    public var residual: Double

    public init(pose: Pose, converged: Bool, iterations: Int, residual: Double) {
        self.pose = pose
        self.converged = converged
        self.iterations = iterations
        self.residual = residual
    }
}

/// A pure, deterministic pose solver: identical input yields identical output.
public protocol RigSolver {
    associatedtype Params
    static func solve(_ skeleton: Skeleton, pose: Pose, params: Params) -> SolveResult
}

/// A joint chain identified by index, from a root down to the effector, with an IK target.
public struct IKChain: Sendable, Equatable {
    /// Joint indices root→effector; the effector is the last element.
    public var joints: [Int]
    /// World-space goal for the effector.
    public var target: Vec3
    /// Optional world-space pole hint for the bend plane (used by the 2-bone solver).
    public var poleVector: Vec3?
    /// Convergence tolerance in world units.
    public var tolerance: Double
    /// Iteration cap for iterative solvers.
    public var maxIterations: Int

    public init(joints: [Int], target: Vec3, poleVector: Vec3? = nil,
                tolerance: Double = 1e-4, maxIterations: Int = 32) {
        self.joints = joints
        self.target = target
        self.poleVector = poleVector
        self.tolerance = tolerance
        self.maxIterations = maxIterations
    }
}

/// Which solver an IK request should use.
public enum IKSolverKind: String, Sendable, Equatable, CaseIterable, Codable {
    case twoBone, ccd, fabrik

    /// Parse a tool-facing string; unknown/absent values fall back to the safe general solver.
    public init(parsing raw: String?) {
        switch raw?.lowercased() {
        case "twobone", "two_bone", "analytic": self = .twoBone
        case "fabrik": self = .fabrik
        default: self = .ccd
        }
    }
}

public enum IKSolvers {
    /// Dispatch to the requested solver. `twoBone` requires exactly a 3-joint chain
    /// (root, mid, effector); other lengths fall back to CCD so the call never silently no-ops.
    public static func solve(_ skeleton: Skeleton, pose: Pose,
                             chain: IKChain, kind: IKSolverKind) -> SolveResult {
        switch kind {
        case .twoBone:
            if chain.joints.count == 3 {
                return TwoBoneIK.solve(skeleton, pose: pose, params: chain)
            }
            return CCD.solve(skeleton, pose: pose, params: chain)
        case .ccd:
            return CCD.solve(skeleton, pose: pose, params: chain)
        case .fabrik:
            return FABRIK.solve(skeleton, pose: pose, params: chain)
        }
    }
}
