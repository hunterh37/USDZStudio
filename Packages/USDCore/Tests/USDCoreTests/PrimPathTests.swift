import Testing
import Foundation
@testable import USDCore

@Suite("PrimPath parsing")
struct PrimPathParsingTests {

    @Test func parsesRoot() {
        let path = PrimPath("/")
        #expect(path == .root)
        #expect(path?.isRoot == true)
        #expect(path?.name == "/")
        #expect(path?.depth == 0)
        #expect(path?.description == "/")
    }

    @Test func parsesNestedPath() {
        let path = PrimPath("/Car/Wheels/FrontLeft")
        #expect(path?.components == ["Car", "Wheels", "FrontLeft"])
        #expect(path?.name == "FrontLeft")
        #expect(path?.depth == 3)
        #expect(path?.description == "/Car/Wheels/FrontLeft")
    }

    @Test(arguments: ["", "Car", "relative/path", "//", "/Car//Wheel", "/Car/", "/Car/1Wheel", "/Car/Whe el", "/Car/Whe-el"])
    func rejectsInvalidStrings(_ raw: String) {
        #expect(PrimPath(raw) == nil)
    }

    @Test func componentInitValidates() {
        #expect(PrimPath(components: ["Car", "Wheel"])?.description == "/Car/Wheel")
        #expect(PrimPath(components: []) == .root)
        #expect(PrimPath(components: ["bad name"]) == nil)
    }

    @Test func underscoreAndDigitsAllowed() {
        #expect(PrimPath("/_root/mesh_01") != nil)
    }
}

@Suite("PrimPath derivation")
struct PrimPathDerivationTests {

    let wheels = PrimPath("/Car/Wheels")!

    @Test func parentWalksUp() {
        #expect(wheels.parent.description == "/Car")
        #expect(wheels.parent.parent == .root)
        #expect(PrimPath.root.parent == .root)
    }

    @Test func appendingValidatesName() {
        #expect(wheels.appending("FrontLeft")?.description == "/Car/Wheels/FrontLeft")
        #expect(wheels.appending("front left") == nil)
        #expect(PrimPath.root.appending("Car")?.description == "/Car")
    }

    @Test func ancestry() {
        let deep = PrimPath("/Car/Wheels/FrontLeft")!
        #expect(PrimPath.root.isAncestor(of: deep))
        #expect(wheels.isAncestor(of: deep))
        #expect(deep.isDescendant(of: wheels))
        #expect(!deep.isAncestor(of: wheels))
        #expect(!wheels.isAncestor(of: wheels))
        #expect(!PrimPath("/Boat")!.isAncestor(of: deep))
        // Sibling prefix strings must not count as ancestry.
        #expect(!PrimPath("/Car")!.isAncestor(of: PrimPath("/Carpet")!))
    }

    @Test func commonAncestor() {
        let fl = PrimPath("/Car/Wheels/FrontLeft")!
        let fr = PrimPath("/Car/Wheels/FrontRight")!
        #expect(fl.commonAncestor(with: fr) == wheels)
        #expect(fl.commonAncestor(with: PrimPath("/Boat")!) == .root)
        #expect(fl.commonAncestor(with: fl) == fl)
        #expect(fl.commonAncestor(with: wheels) == wheels)
    }

    @Test func comparableOrdersLexicographically() {
        let paths = ["/B", "/A/Z", "/A", "/A/B"].map { PrimPath($0)! }
        #expect(paths.sorted().map(\.description) == ["/A", "/A/B", "/A/Z", "/B"])
        #expect(PrimPath.root < PrimPath("/A")!)
        #expect(!(PrimPath("/A")! < PrimPath("/A")!))
    }
}

@Suite("Prim name validation & sanitization")
struct PrimNameTests {

    @Test func validNames() {
        #expect(PrimPath.isValidName("Mesh"))
        #expect(PrimPath.isValidName("_private"))
        #expect(PrimPath.isValidName("mesh_01"))
    }

    @Test(arguments: ["", "1mesh", "mesh-01", "mesh 01", "mesh.01", "mesh/01"])
    func invalidNames(_ name: String) {
        #expect(!PrimPath.isValidName(name))
    }

    @Test(arguments: ["", "1mesh", "front wheel", "bumper-v2 (final).001", "日本語", "___", "a", "9", "-", "mesh.01/x"])
    func sanitizedNamesAreAlwaysValid(_ raw: String) {
        #expect(PrimPath.isValidName(PrimPath.sanitizedName(from: raw)))
    }

    @Test func sanitizationExamples() {
        #expect(PrimPath.sanitizedName(from: "front wheel") == "front_wheel")
        #expect(PrimPath.sanitizedName(from: "1mesh") == "_1mesh")
        #expect(PrimPath.sanitizedName(from: "") == "_")
        #expect(PrimPath.sanitizedName(from: "ok_name") == "ok_name")
    }

    /// Property-style fuzz: random unicode strings always sanitize to valid names,
    /// and sanitization is idempotent (specs/testing.md layer 5).
    @Test func sanitizationFuzzAndIdempotence() {
        var generator = SplitMix64(seed: 0xD1CE)
        for _ in 0..<500 {
            let length = Int(generator.next() % 24)
            let scalars = (0..<length).compactMap { _ in
                Unicode.Scalar(UInt32(generator.next() % 0x2FF))
            }
            let raw = String(String.UnicodeScalarView(scalars))
            let sanitized = PrimPath.sanitizedName(from: raw)
            #expect(PrimPath.isValidName(sanitized))
            #expect(PrimPath.sanitizedName(from: sanitized) == sanitized)
        }
    }
}

@Suite("PrimPath codable")
struct PrimPathCodableTests {

    @Test func roundTripsThroughJSON() throws {
        let original = PrimPath("/Car/Wheels")!
        let data = try JSONEncoder().encode(original)
        #expect(String(data: data, encoding: .utf8) == "\"\\/Car\\/Wheels\"" || String(data: data, encoding: .utf8) == "\"/Car/Wheels\"")
        let decoded = try JSONDecoder().decode(PrimPath.self, from: data)
        #expect(decoded == original)
    }

    @Test func decodingRejectsInvalidPath() {
        let data = Data("\"not-a-path\"".utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(PrimPath.self, from: data)
        }
    }
}

/// Deterministic PRNG for property-style tests (no seeding of SystemRandom).
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
