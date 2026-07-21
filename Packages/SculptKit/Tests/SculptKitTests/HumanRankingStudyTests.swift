import Testing
import Foundation
@testable import SculptKit

@Suite("Sculpt-accuracy P0 follow-up (#94) — human-ranking study harness")
struct HumanRankingStudyTests {

    // MARK: - model

    @Test func consensusRankAveragesParticipantsAndHandlesEmpty() {
        let r = RankedReference(name: "a", measuredSimilarity: 0.5, humanRanks: [1, 3])
        #expect(r.consensusRank == 2)
        let none = RankedReference(name: "b", measuredSimilarity: 0.5, humanRanks: [])
        #expect(none.consensusRank == 0)
    }

    @Test func participantCountReadsFirstRowAndEmptyStudy() {
        let s = RankingStudy(references: [
            RankedReference(name: "a", measuredSimilarity: 0.9, humanRanks: [1, 2, 3])
        ])
        #expect(s.participantCount == 3)
        #expect(RankingStudy(references: []).participantCount == 0)
    }

    // MARK: - Spearman / ranks

    @Test func spearmanPerfectInverseTiesAndDegenerate() {
        #expect(abs(HumanRankingStudy.spearman([1, 2, 3, 4], [10, 20, 30, 40]) - 1) < 1e-9)
        #expect(abs(HumanRankingStudy.spearman([1, 2, 3, 4], [40, 30, 20, 10]) + 1) < 1e-9)
        #expect(HumanRankingStudy.spearman([1, 1, 2, 3], [5, 5, 6, 7]) > 0.9)
        #expect(HumanRankingStudy.spearman([1], [1]) == 0)              // too few
        #expect(HumanRankingStudy.spearman([2, 2, 2], [1, 2, 3]) == 0)  // flat series
    }

    @Test func ranksAverageTies() {
        #expect(HumanRankingStudy.ranks([5, 5, 9]) == [1.5, 1.5, 3])
    }

    // MARK: - Fisher interval

    @Test func fisherIntervalWidensWhenTooSmall() {
        let (lo, hi) = HumanRankingStudy.fisherInterval(rho: 0.9, n: 3, criticalZ: 1.96)
        #expect(lo == -1 && hi == 1)
    }

    @Test func fisherIntervalBracketsRho() {
        let (lo, hi) = HumanRankingStudy.fisherInterval(rho: 0.8, n: 30, criticalZ: 1.96)
        #expect(lo < 0.8 && hi > 0.8)
        #expect(lo > -1 && hi < 1)
    }

    // MARK: - analyze

    @Test func analyzeReportsNegativeRhoWhenMetricAgreesWithPanel() throws {
        // Higher measured similarity ↔ lower (better) human rank ⇒ ρ = −1.
        let refs = (1...6).map { i in
            RankedReference(name: "r\(i)",
                            measuredSimilarity: Double(7 - i) / 10,
                            humanRanks: [Double(i)])
        }
        let c = try HumanRankingStudy.analyze(RankingStudy(references: refs))
        #expect(abs(c.rho + 1) < 1e-9)
        #expect(c.n == 6)
        #expect(c.participants == 1)
        #expect(c.confidence == 0.95)
        #expect(c.ciLow <= c.rho && c.ciHigh >= c.rho)
    }

    @Test func analyzeThrowsOnEmptyStudy() {
        #expect(throws: HumanRankingStudy.StudyError.empty) {
            _ = try HumanRankingStudy.analyze(RankingStudy(references: []))
        }
    }

    @Test func analyzeThrowsOnRaggedPanel() {
        let s = RankingStudy(references: [
            RankedReference(name: "a", measuredSimilarity: 0.9, humanRanks: [1, 2]),
            RankedReference(name: "b", measuredSimilarity: 0.5, humanRanks: [1]),
        ])
        #expect(throws: HumanRankingStudy.StudyError.raggedPanel) {
            _ = try HumanRankingStudy.analyze(s)
        }
    }

    @Test func analyzeSmallStudyHasUninformativeCI() throws {
        let s = RankingStudy(references: [
            RankedReference(name: "a", measuredSimilarity: 0.9, humanRanks: [1]),
            RankedReference(name: "b", measuredSimilarity: 0.5, humanRanks: [2]),
            RankedReference(name: "c", measuredSimilarity: 0.1, humanRanks: [3]),
        ])
        let c = try HumanRankingStudy.analyze(s)
        #expect(c.n == 3)
        #expect(c.ciLow == -1 && c.ciHigh == 1)
    }

    // MARK: - CSV ingest

    @Test func parseCSVBuildsStudy() throws {
        let csv = """
        reference,measuredSimilarity,alice,bob
        disc,0.83,1,2
        box,0.55,3,3
        ring,0.20,2,1
        """
        let study = try HumanRankingStudy.parseCSV(csv)
        #expect(study.references.count == 3)
        #expect(study.participantCount == 2)
        #expect(study.references[0].name == "disc")
        #expect(study.references[1].consensusRank == 3)
    }

    @Test func parseCSVRejectsEmpty() {
        #expect(throws: HumanRankingStudy.StudyError.empty) {
            _ = try HumanRankingStudy.parseCSV("   \n  \n")
        }
    }

    @Test func parseCSVRejectsTooFewColumnsInHeader() {
        #expect(throws: HumanRankingStudy.StudyError.self) {
            _ = try HumanRankingStudy.parseCSV("reference,measuredSimilarity\ndisc,0.8")
        }
    }

    @Test func parseCSVRejectsRaggedRow() {
        #expect(throws: HumanRankingStudy.StudyError.self) {
            _ = try HumanRankingStudy.parseCSV("reference,measured,alice\ndisc,0.8")
        }
    }

    @Test func parseCSVRejectsBadMeasured() {
        #expect(throws: HumanRankingStudy.StudyError.self) {
            _ = try HumanRankingStudy.parseCSV("reference,measured,alice\ndisc,NaNish,1")
        }
    }

    @Test func parseCSVRejectsBadRank() {
        #expect(throws: HumanRankingStudy.StudyError.self) {
            _ = try HumanRankingStudy.parseCSV("reference,measured,alice\ndisc,0.8,best")
        }
    }

    // MARK: - JSON ingest

    @Test func parseJSONRoundTrips() throws {
        let study = RankingStudy(references: [
            RankedReference(name: "a", measuredSimilarity: 0.7, humanRanks: [1, 2])
        ])
        let data = try JSONEncoder().encode(study)
        let back = try HumanRankingStudy.parseJSON(data)
        #expect(back == study)
    }
}
