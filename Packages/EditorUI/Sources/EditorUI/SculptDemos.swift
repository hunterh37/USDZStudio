import Foundation
import SculptKit

/// Bundled demo specs for the in-app sculpt runner, so "watch it build" needs
/// no reference image or agent round-trip.
public enum SculptDemos {

    /// A cute low-poly cottage: cream walls, a red pyramid roof, a door, two
    /// windows, and a chimney. Every geometry leaf is painted so the material
    /// pass has something to bind.
    public static func lowPolyHouse() -> ObjectSculptSpec {
        // The walls ground the object; everything else welds onto them, so the
        // attachment-correctness gate ("nothing floats") passes.
        let walls = ComponentNode(
            name: "Walls", shape: .primitive(.box),
            translation: [0, 0.75, 0], width: 2, height: 1.5, depth: 2, materialID: "wall",
            attachment: .root)
        let roof = ComponentNode(
            name: "Roof", shape: .primitive(.cone),
            translation: [0, 2.1, 0], height: 1.2, radius: 1.7, segments: 4, materialID: "roof",
            attachment: .weld)
        let door = ComponentNode(
            name: "Door", shape: .primitive(.box),
            translation: [0, 0.45, 1.02], width: 0.5, height: 0.9, depth: 0.1, materialID: "wood",
            attachment: .weld)
        let window = ComponentNode(
            name: "Window", shape: .primitive(.box),
            translation: [-0.6, 1.0, 1.02], width: 0.4, height: 0.4, depth: 0.1, materialID: "glass",
            repetition: RepetitionSystem(name: "bay", count: 2, step: [1.2, 0, 0]),
            attachment: .weld)
        let chimney = ComponentNode(
            name: "Chimney", shape: .primitive(.box),
            translation: [0.6, 2.2, 0.1], width: 0.3, height: 0.9, depth: 0.3, materialID: "wall",
            attachment: .weld)

        let root = ComponentNode(
            name: "House", shape: .group,
            children: [walls, roof, door, window, chimney])

        var inventory = DetailInventory()
        inventory.upsert(DetailItem(id: "roof-pitch", description: "steep pyramid roof", kind: .bevel, mappedTo: "Roof"))
        inventory.upsert(DetailItem(id: "door-front", description: "front door", kind: .seam, mappedTo: "Door"))
        inventory.upsert(DetailItem(id: "glass", description: "glossy window panes", kind: .gloss, mappedTo: "glass"))

        return ObjectSculptSpec(
            name: "House", objectClass: .object, root: root,
            materials: [
                MaterialSpec(id: "wall", baseColor: [0.93, 0.87, 0.73], roughness: 0.8),
                MaterialSpec(id: "roof", baseColor: [0.72, 0.20, 0.16], roughness: 0.6),
                MaterialSpec(id: "wood", baseColor: [0.40, 0.26, 0.13], roughness: 0.7),
                MaterialSpec(id: "glass", baseColor: [0.40, 0.62, 0.80], roughness: 0.15, metallic: 0.1),
            ],
            lights: [
                // A warm key sun so the lighting pass authors a real UsdLux light.
                LightSpec(name: "Sun", kind: .distant, intensity: 3, color: [1.0, 0.96, 0.88],
                          translation: [3, 5, 4], rotationEulerDegrees: [-50, 30, 0]),
            ],
            lodTiers: [
                LODTier(name: "near", screenCoverage: 1.0, decimation: 1.0),
                LODTier(name: "far", screenCoverage: 0.15, decimation: 0.35),
            ],
            detailInventory: inventory)
    }
}
