import Testing
import Foundation
@testable import ScriptingKit

@Suite("ScriptManifest")
struct ScriptManifestTests {

    @Test func decodesFullManifestFromHarnessJSON() throws {
        let json = """
        {
          "name": "Batch Rename",
          "description": "Regex find/replace across prim names.",
          "mutates": true,
          "args": [
            {"name": "pattern", "type": "str", "default": "^(.*)$", "help": "Regex."},
            {"name": "frame", "type": "float", "default": null, "help": "Frame."},
            {"name": "limit", "type": "int", "default": 10, "help": ""},
            {"name": "lower", "type": "bool", "default": false, "help": "Lowercase."}
          ]
        }
        """
        let manifest = try ScriptManifest.decode(fromJSON: Data(json.utf8))
        #expect(manifest.name == "Batch Rename")
        #expect(manifest.mutates)
        #expect(manifest.arguments.count == 4)

        let pattern = try #require(manifest.argument(named: "pattern"))
        #expect(pattern.kind == .string)
        #expect(pattern.defaultValue == .string("^(.*)$"))

        let frame = try #require(manifest.argument(named: "frame"))
        #expect(frame.kind == .float)
        #expect(frame.defaultValue == nil)          // JSON null → no default

        #expect(manifest.argument(named: "limit")?.defaultValue == .int(10))
        #expect(manifest.argument(named: "lower")?.defaultValue == .bool(false))
    }

    @Test func toleratesMissingOptionalFields() throws {
        let manifest = try ScriptManifest.decode(fromJSON: Data(#"{"name":"Audit"}"#.utf8))
        #expect(manifest.name == "Audit")
        #expect(manifest.description.isEmpty)
        #expect(!manifest.mutates)
        #expect(manifest.arguments.isEmpty)
    }

    @Test func unknownArgTypeFallsBackToString() throws {
        let manifest = try ScriptManifest.decode(
            fromJSON: Data(#"{"name":"X","args":[{"name":"a","type":"weird"}]}"#.utf8))
        #expect(manifest.argument(named: "a")?.kind == .string)
    }

    @Test func flagConvertsUnderscoresToDashes() {
        let arg = ScriptArgument(name: "dry_run_mode", kind: .bool)
        #expect(arg.flag == "--dry-run-mode")
    }

    @Test func roundTripsThroughCodable() throws {
        let manifest = ScriptManifest(
            name: "Round", description: "trip", mutates: true,
            arguments: [ScriptArgument(name: "count", kind: .int, help: "n",
                                       defaultValue: .int(3))])
        let data = try JSONEncoder().encode(manifest)
        let decoded = try ScriptManifest.decode(fromJSON: data)
        #expect(decoded == manifest)
    }

    @Test func defaultValueDisplayAndTruthiness() {
        #expect(ScriptArgument.DefaultValue.bool(true).boolValue)
        #expect(ScriptArgument.DefaultValue.int(0).boolValue == false)
        #expect(ScriptArgument.DefaultValue.string("yes").boolValue)
        #expect(ScriptArgument.DefaultValue.double(2.5).displayString == "2.5")
    }
}
