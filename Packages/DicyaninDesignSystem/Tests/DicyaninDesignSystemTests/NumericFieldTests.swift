import Testing
@testable import DicyaninDesignSystem

@Suite("NumericFieldParser.parse")
struct NumericParseTests {

    @Test func parsesPlainNumbers() {
        #expect(NumericFieldParser.parse("1.5") == 1.5)
        #expect(NumericFieldParser.parse("-42") == -42)
        #expect(NumericFieldParser.parse("0") == 0)
        #expect(NumericFieldParser.parse("1e3") == 1000)
    }

    @Test func toleratesFormattingNoise() {
        #expect(NumericFieldParser.parse("  2.5  ") == 2.5)
        #expect(NumericFieldParser.parse("3,14") == 3.14)
        #expect(NumericFieldParser.parse("+7") == 7)
        #expect(NumericFieldParser.parse("90°") == 90)
        #expect(NumericFieldParser.parse("50%") == 50)
        #expect(NumericFieldParser.parse(" -12,5° ") == -12.5)
    }

    @Test(arguments: ["", "abc", "1.2.3", "°", "++5", "nan", "inf", "-inf"])
    func rejectsGarbageAndNonFinite(_ input: String) {
        #expect(NumericFieldParser.parse(input) == nil)
    }
}

@Suite("NumericFieldParser clamp/snap/format")
struct NumericMathTests {

    @Test func clamping() {
        #expect(NumericFieldParser.clamp(5, to: 0...10) == 5)
        #expect(NumericFieldParser.clamp(-1, to: 0...10) == 0)
        #expect(NumericFieldParser.clamp(11, to: 0...10) == 10)
    }

    @Test func snapping() {
        #expect(NumericFieldParser.snap(0.24, step: 0.25) == 0.25)
        #expect(NumericFieldParser.snap(1.4, step: 0.5) == 1.5)
        #expect(NumericFieldParser.snap(7, step: 0) == 7)
        #expect(NumericFieldParser.snap(7, step: -1) == 7)
    }

    @Test func formatting() {
        #expect(NumericFieldParser.format(1.0) == "1")
        #expect(NumericFieldParser.format(1.5) == "1.5")
        #expect(NumericFieldParser.format(1.23456) == "1.235")
        #expect(NumericFieldParser.format(1.230) == "1.23")
        #expect(NumericFieldParser.format(-0.0001) == "0")
        #expect(NumericFieldParser.format(-2.5) == "-2.5")
        #expect(NumericFieldParser.format(3.14159, maxFractionDigits: 1) == "3.1")
        #expect(NumericFieldParser.format(3.14159, maxFractionDigits: -1) == "3")
    }
}

@Suite("ScrubMath")
struct ScrubMathTests {

    @Test func dragConvertsToSteps() {
        // 8pt drag = 2 steps at 4pt/step.
        #expect(ScrubMath.value(base: 10, dragDelta: 8, step: 0.5) == 11)
        #expect(ScrubMath.value(base: 10, dragDelta: -8, step: 0.5) == 9)
    }

    @Test func subStepDragIsIgnored() {
        #expect(ScrubMath.value(base: 10, dragDelta: 3, step: 1) == 10)
        #expect(ScrubMath.value(base: 10, dragDelta: -3.9, step: 1) == 10)
    }

    @Test func fineAndCoarseModifiers() {
        #expect(ScrubMath.value(base: 0, dragDelta: 4, step: 1, fine: true) == 0.1)
        #expect(ScrubMath.value(base: 0, dragDelta: 4, step: 1, coarse: true) == 10)
        // fine wins when both held
        #expect(ScrubMath.value(base: 0, dragDelta: 4, step: 1, fine: true, coarse: true) == 0.1)
        #expect(ScrubMath.value(base: 0, dragDelta: 4, step: 1) == 1)
    }
}
