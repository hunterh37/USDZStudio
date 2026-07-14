import Testing
@testable import DicyaninDesignSystem

@Suite("Spacing (4pt grid)")
struct SpacingTests {

    @Test func gridMultiplies() {
        #expect(Spacing.grid(0) == 0)
        #expect(Spacing.grid(1) == 4)
        #expect(Spacing.grid(6) == 24)
        #expect(Spacing.grid(-2) == 0)
    }

    @Test func namedTokensSitOnGrid() {
        for token in [Spacing.xxs, Spacing.xs, Spacing.sm, Spacing.md, Spacing.lg, Spacing.xl] {
            #expect(token.truncatingRemainder(dividingBy: Spacing.unit) == 0)
        }
        #expect(Spacing.xxs < Spacing.xs && Spacing.xs < Spacing.sm && Spacing.sm < Spacing.md
                && Spacing.md < Spacing.lg && Spacing.lg < Spacing.xl)
    }

    @Test func snapping() {
        #expect(Spacing.snapped(0) == 0)
        #expect(Spacing.snapped(5) == 4)
        #expect(Spacing.snapped(6) == 8)
        #expect(Spacing.snapped(-3) == 0)
        #expect(Spacing.snapped(16) == 16)
    }
}

@Suite("ColorToken")
struct ColorTokenTests {

    @Test func parsesSixDigitHex() {
        let token = ColorToken(hex: "#FF8000")
        #expect(token?.red == 1)
        #expect(token?.green == Double(0x80) / 255)
        #expect(token?.blue == 0)
        #expect(token?.alpha == 1)
    }

    @Test func parsesEightDigitHex() {
        let token = ColorToken(hex: "00FF0080")
        #expect(token?.green == 1)
        #expect(token?.alpha == Double(0x80) / 255)
    }

    @Test func parsingIsCaseAndWhitespaceTolerant() {
        #expect(ColorToken(hex: "  #ff8000 ") != nil)
        #expect(ColorToken(hex: "aBcDeF") != nil)
    }

    @Test(arguments: ["", "#FFF", "#FFFFF", "#GGGGGG", "1234567", "#123456789"])
    func rejectsMalformedHex(_ hex: String) {
        #expect(ColorToken(hex: hex) == nil)
    }

    @Test func componentsClampToUnitRange() {
        let token = ColorToken(red: 2, green: -1, blue: 0.5, alpha: 3)
        #expect(token.red == 1 && token.green == 0 && token.blue == 0.5 && token.alpha == 1)
    }

    @Test func hexRoundTrip() {
        #expect(ColorToken(hex: "#4C8DFF")?.hexString == "#4C8DFF")
        #expect(ColorToken(hex: "#4C8DFF80")?.hexString == "#4C8DFF80")
        let roundTripped = ColorToken(hex: Palette.accent.hexString)
        #expect(roundTripped == Palette.accent)
    }

    @Test func paletteIsDistinct() {
        let all = [Palette.windowBackground, Palette.panelBackground, Palette.panelBorder,
                   Palette.textPrimary, Palette.textSecondary, Palette.accent,
                   Palette.warning, Palette.error, Palette.viewportBackground]
        #expect(Set(all).count == all.count)
    }

    @Test func typeScaleIsMonotonic() {
        #expect(TypeScale.caption < TypeScale.label)
        #expect(TypeScale.label < TypeScale.body)
        #expect(TypeScale.body < TypeScale.heading)
        #expect(TypeScale.heading < TypeScale.title)
        #expect(TypeScale.inspectorField == TypeScale.body)
    }
}
