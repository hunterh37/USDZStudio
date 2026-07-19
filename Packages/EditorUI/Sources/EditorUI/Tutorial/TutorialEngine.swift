import Foundation
import Observation
import simd
import USDCore
import EditingKit
import ViewportKit

/// The guided tour: a scripted sequence of *real* editor operations (insert a
/// cube, move it, rotate it, extrude a face, undo) run against a sandbox
/// document and animated live in the viewport. Every step drives the same
/// command pipeline the user will — nothing is faked, and everything lands on
/// the undo stack.
///
/// The engine owns the sandbox `EditorDocument`, a scripted camera pose (slow
/// orbit), and a live-transform channel the viewport renders tweens through.
/// `next()` advances; each step's action awaits its animation before the
/// button re-enables.
@MainActor
@Observable
public final class TutorialEngine {

    // MARK: Step model

    public struct Step: Identifiable, Sendable {
        public let id: Int
        public let systemImage: String
        public let title: String
        public let body: String
    }

    public let steps: [Step] = [
        Step(id: 0, systemImage: "sparkles",
             title: "Welcome to Dicyanin USDZ Editor",
             body: "Let's build something in 60 seconds — every step here is a real edit running through the real engine. Press Next to start."),
        Step(id: 1, systemImage: "cube.fill",
             title: "Create",
             body: "A cube, inserted as a real USD Mesh prim. It just landed in the Outliner on the left — and on the undo stack."),
        Step(id: 2, systemImage: "arrow.up.and.down.and.arrow.left.and.right",
             title: "Move",
             body: "Transforms are undoable commands. This glide is a live transform edit — the Inspector on the right shows the numbers changing."),
        Step(id: 3, systemImage: "rotate.3d.fill",
             title: "Rotate",
             body: "Same pipeline, different verb. Rotation, scale, and snapping all flow through the one command stack, so ⌘Z always works."),
        Step(id: 4, systemImage: "square.3.layers.3d.top.filled",
             title: "Extrude",
             body: "Now the fun part: mesh edit mode. We selected the top face and extruded it — the same E-key tool you'll use, with live face highlighting."),
        Step(id: 5, systemImage: "arrow.uturn.backward",
             title: "Undo anything",
             body: "Watch: ⌘Z pulls the extrude back out, ⇧⌘Z restores it. Every edit you just saw — including the mesh surgery — is one undo entry."),
        Step(id: 6, systemImage: "checkmark.seal.fill",
             title: "You're ready",
             body: "Open a USDZ (or drop one on the window), press Tab on a mesh to edit it, F to frame, and ⌘Z fearlessly. Have fun!"),
    ]

    // MARK: Published state

    public private(set) var document: EditorDocument
    public private(set) var stepIndex = 0
    public private(set) var isAnimating = false
    public var currentStep: Step { steps[stepIndex] }
    public var isLastStep: Bool { stepIndex == steps.count - 1 }

    /// Scripted camera — the viewport follows this while the tour runs.
    public private(set) var cameraPose: ViewportCameraPose?
    /// Live per-prim transforms (RealityKit column-major) for tween frames.
    public private(set) var liveTransforms: [String: float4x4]?

    /// Called when the tour completes or is skipped.
    public var onFinished: (() -> Void)?

    // MARK: Private state

    private let cubePrim: Prim
    private var orbitTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var azimuth = 0.75
    private var elevation = 0.35
    private var cameraTarget = SIMD3<Double>(0, 0.25, 0)
    private var cameraDistance = 3.2
    /// The cube's stage-truth TRS as the steps accumulate edits.
    private var trs = TRS.identity

    public init() throws {
        let (snapshot, url) = try TutorialScene.makeStage()
        self.document = EditorDocument(snapshot: snapshot, modelURL: url)
        self.cubePrim = try TutorialScene.makeCubePrim()
    }

    // MARK: Lifecycle

    /// Begins the slow orbit and hides the cube (after a beat, so the
    /// viewport has captured its baseline entity set and can re-enable the
    /// cube's entity when the Create step re-inserts the prim).
    public func start() {
        orbitTask = Task { [weak self] in
            // Let the viewport load + capture its baseline before deleting.
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, !Task.isCancelled else { return }
            if self.stepIndex == 0 { self.document.delete(TutorialScene.cubePath) }
            while !Task.isCancelled {
                self.azimuth += 0.0035
                self.publishPose()
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    public func next() {
        guard !isAnimating else { return }
        if isLastStep {
            finish()
            return
        }
        stepIndex += 1
        let step = stepIndex
        isAnimating = true
        actionTask = Task { [weak self] in
            await self?.run(step: step)
            self?.isAnimating = false
        }
    }

    public func skip() { finish() }

    private func finish() {
        orbitTask?.cancel()
        actionTask?.cancel()
        cameraPose = nil
        try? FileManager.default.removeItem(at: document.modelURL ?? URL(fileURLWithPath: "/dev/null"))
        onFinished?()
    }

    // MARK: Step actions — real commands, animated

    private func run(step: Int) async {
        switch step {
        case 1: await createCube()
        case 2: await moveCube()
        case 3: await rotateCube()
        case 4: await extrudeTopFace()
        case 5: await undoRedoDemo()
        default: break
        }
    }

    /// Re-insert the cube prim (one undoable `InsertPrimCommand`), with a
    /// scale-up pop animated through the live-transform channel.
    private func createCube() async {
        document.run(InsertPrimCommand(prim: cubePrim, parent: nil, index: 0))
        document.selection = Selection([TutorialScene.cubePath])
        await tween(duration: 0.7) { t in
            var pop = self.trs
            let s = 0.02 + 0.98 * Self.easeOutBack(t)
            pop.scale = [s, s, s]
            self.publish(pop)
        }
        publish(trs)
    }

    /// Glide the cube up and over — visual tween, then one real "Move" command.
    private func moveCube() async {
        let from = trs.translation
        let to = [0.9, 0.55, 0.0]
        await tween(duration: 1.1) { t in
            var live = self.trs
            let e = Self.easeInOut(t)
            live.translation = zip(from, to).map { $0 + ($1 - $0) * e }
            self.publish(live)
        }
        trs.translation = to
        document.setTransform(TutorialScene.cubePath, to: trs, verb: "Move")
        publish(trs)
    }

    /// A full turn plus a 30° resting tilt, committed as one "Rotate" command.
    private func rotateCube() async {
        let endY = 390.0
        await tween(duration: 1.4) { t in
            var live = self.trs
            live.rotationEulerDegrees = [0, endY * Self.easeInOut(t), 0]
            self.publish(live)
        }
        trs.rotationEulerDegrees = [0, endY.truncatingRemainder(dividingBy: 360), 0]
        document.setTransform(TutorialScene.cubePath, to: trs, verb: "Rotate")
        publish(trs)
    }

    /// Real mesh edit mode: select the top face (amber highlight), then grow
    /// the extrusion live by re-applying the op at increasing distances, and
    /// commit the session as one undoable command.
    private func extrudeTopFace() async {
        // Lift the camera so the top face is clearly visible.
        let startElevation = elevation
        await tween(duration: 0.6) { t in
            self.elevation = startElevation + (0.62 - startElevation) * Self.easeInOut(t)
            self.publishPose()
        }

        document.selection = Selection([TutorialScene.meshPath])
        guard document.enterMeshEditMode(at: TutorialScene.meshPath) == .available else { return }
        document.meshEdit?.tool = .extrude
        // Primitives.box authors faces +X, −X, +Y, −Y, +Z, −Z → top is 2.
        document.selectMeshFace(index: 2)
        try? await Task.sleep(for: .milliseconds(700))

        var applied = false
        for i in 1...16 {
            if Task.isCancelled { break }
            if applied { document.undoMeshEdit() }
            document.selectMeshFace(index: 2)
            document.meshEdit?.extrudeDistance = 0.45 * Self.easeInOut(Double(i) / 16)
            document.applyActiveMeshTool()
            applied = true
            try? await Task.sleep(for: .milliseconds(45))
        }
        try? await Task.sleep(for: .milliseconds(500))
        document.exitMeshEditMode(commit: true)
    }

    /// ⌘Z / ⇧⌘Z live: the extrude collapses back in, then returns.
    private func undoRedoDemo() async {
        try? await Task.sleep(for: .milliseconds(400))
        document.undo()
        try? await Task.sleep(for: .milliseconds(1000))
        document.redo()
        try? await Task.sleep(for: .milliseconds(400))
    }

    // MARK: Animation plumbing

    /// ~60 fps eased tween; the closure receives progress in [0, 1].
    private func tween(duration: TimeInterval, _ apply: @MainActor (Double) -> Void) async {
        let start = Date()
        while !Task.isCancelled {
            let t = min(Date().timeIntervalSince(start) / duration, 1)
            apply(t)
            if t >= 1 { break }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    private func publishPose() {
        cameraPose = ViewportCameraPose(target: cameraTarget, distance: cameraDistance,
                                        azimuth: azimuth, elevation: elevation)
    }

    /// Push a TRS to the viewport's live-transform channel (column-major).
    private func publish(_ value: TRS) {
        liveTransforms = [TutorialScene.cubePath.description: Self.matrix(value)]
    }

    /// USD row-major, row-vector matrix → RealityKit column-major: the
    /// column-vector matrix is the transpose, so columns are the rows.
    static func matrix(_ trs: TRS) -> float4x4 {
        let m = trs.toMatrix()
        func column(_ c: Int) -> SIMD4<Float> {
            SIMD4(Float(m[c * 4]), Float(m[c * 4 + 1]), Float(m[c * 4 + 2]), Float(m[c * 4 + 3]))
        }
        return float4x4(columns: (column(0), column(1), column(2), column(3)))
    }

    // MARK: Easing

    static func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }

    /// Slight overshoot for the create-pop.
    static func easeOutBack(_ t: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
    }
}
