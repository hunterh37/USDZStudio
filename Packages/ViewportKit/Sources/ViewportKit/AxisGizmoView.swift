import SwiftUI

/// Two-way channel between the SwiftUI overlay layer and the RealityKit
/// coordinator: the coordinator publishes each camera change so overlays can
/// re-project, and overlays request view snaps (orientation-gizmo clicks)
/// which the coordinator applies to the live camera.
@MainActor
public final class ViewportCameraLink: ObservableObject {

    @Published public private(set) var camera = OrbitCamera()
    /// Set by the coordinator; invoked by overlays to snap the view.
    var snapHandler: ((AxisGizmoModel.HalfAxis) -> Void)?

    public init() {}

    func publish(_ camera: OrbitCamera) {
        guard camera != self.camera else { return }
        self.camera = camera
    }

    public func snap(to axis: AxisGizmoModel.HalfAxis) {
        snapHandler?(axis)
    }
}

/// The corner XYZ orientation gizmo: colored half-axes that rotate with the
/// camera; clicking an axis tip snaps to the matching ortho-style view
/// (specs/viewport.md). Drawing only — all geometry comes from AxisGizmoModel.
struct AxisGizmoView: View {

    @ObservedObject var link: ViewportCameraLink

    @State private var hovered: AxisGizmoModel.HalfAxis?

    private let diameter: CGFloat = 84
    private let tipRadius: CGFloat = 9

    /// Distance from gizmo center to a tip center, leaving room for the tip
    /// circle inside the canvas.
    private var axisRadius: CGFloat { diameter / 2 - tipRadius - 2 }

    static func color(for axis: AxisGizmoModel.HalfAxis) -> Color {
        switch axis.label {
        case "X": Color(red: 0.91, green: 0.34, blue: 0.30)
        case "Y": Color(red: 0.45, green: 0.78, blue: 0.35)
        default:  Color(red: 0.34, green: 0.55, blue: 0.98)
        }
    }

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            for tip in AxisGizmoModel.tips(camera: link.camera) {
                draw(tip, in: &context, center: center)
            }
        }
        .frame(width: diameter, height: diameter)
        .background(.black.opacity(0.25), in: Circle())
        .contentShape(Circle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hovered = hitAxis(at: point)
            case .ended: hovered = nil
            }
        }
        .onTapGesture(coordinateSpace: .local) { point in
            guard let axis = hitAxis(at: point) else { return }
            link.snap(to: axis)
        }
        .help("Orientation — click an axis to view along it")
        .accessibilityLabel("Orientation gizmo")
    }

    private func hitAxis(at point: CGPoint) -> AxisGizmoModel.HalfAxis? {
        AxisGizmoModel.hitTest(
            x: point.x - diameter / 2,
            y: point.y - diameter / 2,
            radius: axisRadius,
            hitRadius: tipRadius + 2,
            camera: link.camera)
    }

    private func draw(_ tip: AxisGizmoModel.Tip, in context: inout GraphicsContext,
                      center: CGPoint) {
        let color = Self.color(for: tip.axis)
        let point = CGPoint(
            x: center.x + tip.offsetX * axisRadius,
            y: center.y + tip.offsetY * axisRadius)
        // Far-side tips render dimmer so orientation reads at a glance.
        let dim = tip.depth > 0 ? 0.45 : 1.0
        let isHovered = hovered == tip.axis

        if tip.axis.isPositive {
            var line = Path()
            line.move(to: center)
            line.addLine(to: point)
            context.stroke(line, with: .color(color.opacity(0.9 * dim)), lineWidth: 2)
        }
        let circle = Path(ellipseIn: CGRect(
            x: point.x - tipRadius, y: point.y - tipRadius,
            width: tipRadius * 2, height: tipRadius * 2))
        if tip.axis.isPositive || isHovered {
            context.fill(circle, with: .color(color.opacity((isHovered ? 1 : 0.9) * dim)))
            context.draw(
                Text(tip.axis.label)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.8)),
                at: point)
        } else {
            context.stroke(circle, with: .color(color.opacity(0.7 * dim)), lineWidth: 1.5)
            context.fill(circle, with: .color(color.opacity(0.15 * dim)))
        }
    }
}
