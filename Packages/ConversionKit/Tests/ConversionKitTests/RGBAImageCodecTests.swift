import Testing
import Foundation
@testable import ConversionKit

@Suite("RGBAImage PNG codec")
struct RGBAImageCodecTests {

    @Test func opaqueRoundTripsExactly() throws {
        var img = RGBAImage(width: 3, height: 2, fill: (10, 20, 30, 255))
        img.setPixel(x: 2, y: 1, to: (200, 100, 50, 255))
        let data = try RGBAImageCodec.encodePNG(img)
        let back = try RGBAImageCodec.decode(data)
        #expect(back.width == 3 && back.height == 2)
        #expect(back.pixels == img.pixels)
    }

    @Test func fullyTransparentPixelRoundTrips() throws {
        // Alpha 0 and alpha 255 take the fast path in (un)premultiply.
        var img = RGBAImage(width: 2, height: 1, fill: (255, 255, 255, 255))
        img.setPixel(x: 0, y: 0, to: (0, 0, 0, 0))
        let back = try RGBAImageCodec.decode(RGBAImageCodec.encodePNG(img))
        #expect(back.pixel(x: 0, y: 0).a == 0)
        #expect(back.pixel(x: 1, y: 0) == (255, 255, 255, 255))
    }

    @Test func partialAlphaSurvivesWithinTolerance() throws {
        // Semi-transparent color exercises the premultiply/unpremultiply math.
        let img = RGBAImage(width: 1, height: 1, fill: (200, 100, 40, 128))
        let back = try RGBAImageCodec.decode(RGBAImageCodec.encodePNG(img))
        let p = back.pixel(x: 0, y: 0)
        #expect(p.a == 128)
        #expect(abs(Int(p.r) - 200) <= 2)
        #expect(abs(Int(p.g) - 100) <= 2)
    }

    @Test func decodeRejectsGarbage() {
        #expect(throws: RGBAImageCodec.CodecError.decodeFailed) {
            _ = try RGBAImageCodec.decode(Data([0, 1, 2, 3]))
        }
    }
}
