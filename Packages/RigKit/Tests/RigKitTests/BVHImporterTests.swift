import XCTest
import simd
@testable import RigKit

final class BVHImporterTests: XCTestCase {
    let valid = """
    HIERARCHY
    ROOT Hips
    {
      OFFSET 0.0 0.0 0.0
      CHANNELS 6 Xposition Yposition Zposition Zrotation Xrotation Yrotation
      JOINT Chest
      {
        OFFSET 0.0 5.0 0.0
        CHANNELS 3 Zrotation Xrotation Yrotation
        End Site
        {
          OFFSET 0.0 5.0 0.0
        }
      }
    }
    MOTION
    Frames: 2
    Frame Time: 0.033333
    0 0 0 0 0 0 0 0 0
    1 2 3 90 0 0 20 0 0
    """

    func testValidParse() {
        let imported = BVHImporter.parse(valid)
        let m = try! XCTUnwrap(imported)
        XCTAssertEqual(m.skeleton.jointCount, 2)          // End Site is not a joint
        XCTAssertEqual(m.skeleton.joints[1].path, "Hips/Chest")
        XCTAssertEqual(m.skeleton.joints[1].restLocal.translation, Vec3(0, 5, 0))
        XCTAssertEqual(m.clip.channels[0].count, 2)       // two frames
        // Frame 1 authored the hips position from the position channels.
        XCTAssertEqual(m.clip.channels[0][1].transform.translation, Vec3(1, 2, 3))
        XCTAssertEqual(m.clip.endTime, 0.033333, accuracy: 1e-9)
        // Determinism.
        XCTAssertEqual(BVHImporter.parse(valid), imported)
    }

    func testMalformedInputsReturnNil() {
        let cases: [String] = [
            "MOTION\nFrames: 0",                                   // not HIERARCHY
            "HIERARCHY\nROOT",                                     // ROOT without a name
            "HIERARCHY\nROOT Hips OFFSET 0 0 0",                   // ROOT without a brace
            "HIERARCHY\nROOT Hips\n{\nOFFSET 0 0\n}",              // OFFSET too short
            "HIERARCHY\nOFFSET 0 0 0",                             // OFFSET with no current joint
            "HIERARCHY\nROOT Hips\n{\nOFFSET 0 0 0\nCHANNELS x\n}",// CHANNELS count not an int
            "HIERARCHY\nCHANNELS 3 A B C",                         // CHANNELS with no current joint
            "HIERARCHY\nROOT Hips\n{\nOFFSET 0 0 0\nEnd Foo\n}",   // End without Site
            "HIERARCHY\nROOT Hips\n{\nOFFSET 0 0 0\nEnd Site OFFSET\n}", // End Site missing brace
            "HIERARCHY\nFOO",                                      // unknown token
            "HIERARCHY\nROOT Hips\n{\nOFFSET 0 0 0\nCHANNELS 0\n}\n}", // unbalanced closing brace
            "HIERARCHY\nROOT Hips\n{\nOFFSET 0 0 0\nCHANNELS 3 Zrotation Xrotation Yrotation\n}", // no MOTION
            validReplacing("Frames: 2", "Frames: x"),             // Frames not an int
            validReplacing("Frames: 2", "Nope: 2"),               // missing Frames:
            validReplacing("Frame Time: 0.033333", "Frame Time: x"), // Frame Time not a double
            "HIERARCHY\nROOT Hips\n{\nOFFSET 0 0 0\nCHANNELS 0\n}\nMOTION\nFrames: 1\nFrame Time: 0.1", // perFrame 0
            validReplacing("1 2 3 90 0 0 20 0 0", "1 2 3 90 0 0 20 0 nope"), // non-double frame value
            validReplacing("1 2 3 90 0 0 20 0 0", "1 2 3 90 0 0"),           // too few frame values
        ]
        for (i, text) in cases.enumerated() {
            XCTAssertNil(BVHImporter.parse(text), "case \(i) should be nil")
        }
    }

    func testUnknownChannelName() {
        let bad = """
        HIERARCHY
        ROOT Hips
        {
          OFFSET 0 0 0
          CHANNELS 1 Wrotation
        }
        MOTION
        Frames: 1
        Frame Time: 0.1
        5
        """
        XCTAssertNil(BVHImporter.parse(bad))
    }

    func testArraySafeSubscript() {
        let a = [10, 20, 30]
        XCTAssertEqual(a[safe: 1], 20)
        XCTAssertNil(a[safe: 5])
        XCTAssertNil(a[safe: -1])
    }

    private func validReplacing(_ needle: String, _ replacement: String) -> String {
        valid.replacingOccurrences(of: needle, with: replacement)
    }
}
