import Foundation

/// A class of identity-defining small feature. img2threejs's "detail-first"
/// analysis enumerates these before any geometry is authored so nothing that
/// makes the object recognizable is overlooked.
public enum DetailKind: String, Codable, Sendable, CaseIterable {
    case bevel
    case gloss
    case linework
    case wear
    case screw
    case seam
    case emissive
    case other
}

/// One enumerated identity feature. It is "mapped" once `mappedTo` names the
/// component or material that realizes it; unmapped items block the
/// strict-quality gate.
public struct DetailItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var description: String
    public var kind: DetailKind
    /// Name of the component node or material id that realizes this feature.
    public var mappedTo: String?
    /// Latest visual confidence score (0...1) from a review pass, if any.
    public var score: Double?

    public init(id: String, description: String, kind: DetailKind,
                mappedTo: String? = nil, score: Double? = nil) {
        self.id = id
        self.description = description
        self.kind = kind
        self.mappedTo = mappedTo
        self.score = score
    }

    public var isMapped: Bool { mappedTo != nil }
}

/// The detail-first feature inventory for a spec.
public struct DetailInventory: Codable, Sendable, Equatable {
    public var items: [DetailItem]

    public init(items: [DetailItem] = []) {
        self.items = items
    }

    public var mapped: [DetailItem] { items.filter(\.isMapped) }
    public var unmapped: [DetailItem] { items.filter { !$0.isMapped } }
    public var isFullyMapped: Bool { unmapped.isEmpty }

    /// Add (or replace, by id) a detail item.
    public mutating func upsert(_ item: DetailItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
    }

    /// Map a detail item to the component/material that realizes it.
    /// Returns false if the id is unknown.
    @discardableResult
    public mutating func map(id: String, to target: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        items[index].mappedTo = target
        return true
    }
}
