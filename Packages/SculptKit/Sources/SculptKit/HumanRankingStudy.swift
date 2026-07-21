import Foundation

// Sculpt-accuracy P0 follow-up (#94): the human-ranking study harness.
//
// The remaining #81 acceptance bullet asks for ρ(measuredSimilarity, human):
// collect human orderings for N references, correlate the measured metric
// against the human consensus, and report ρ with n and a confidence interval.
// PR #88 reported ρ against an exact ground-truth ranking as the honest
// stand-in; this harness makes the *human* number reproducible the moment real
// orderings are supplied.
//
// It does NOT fabricate human responses. It ingests orderings (CSV or JSON),
// forms the consensus human rank per reference, and computes Spearman ρ with an
// n and a Fisher-z confidence interval. Feed it real participant data and it
// emits the real number; the tests drive it with a fixture ordering only to
// prove the maths.

/// One reference in the study: the metric's measured similarity and the rank
/// each participant assigned it (1 = judged most similar / best).
public struct RankedReference: Sendable, Equatable, Codable {
    public var name: String
    public var measuredSimilarity: Double
    /// One rank per participant; ties allowed (fractional ranks are fine).
    public var humanRanks: [Double]

    public init(name: String, measuredSimilarity: Double, humanRanks: [Double]) {
        self.name = name
        self.measuredSimilarity = measuredSimilarity
        self.humanRanks = humanRanks
    }

    /// Consensus human position: the mean rank across participants. Lower means
    /// the panel judged this reference closer to the target.
    public var consensusRank: Double {
        guard !humanRanks.isEmpty else { return 0 }
        return humanRanks.reduce(0, +) / Double(humanRanks.count)
    }
}

/// A whole study: the references, each carrying a measured value and the panel's
/// ranks. Codable so real studies can be committed/round-tripped as JSON.
public struct RankingStudy: Sendable, Equatable, Codable {
    public var references: [RankedReference]

    public init(references: [RankedReference]) {
        self.references = references
    }

    /// Participant count = width of the (rectangular) rank matrix, taken from the
    /// first reference. Zero when the study is empty.
    public var participantCount: Int {
        references.first?.humanRanks.count ?? 0
    }
}

/// The reported correlation: ρ, the sample size n (number of references), the
/// participant count, and a two-sided confidence interval.
public struct RankCorrelation: Sendable, Equatable {
    public var rho: Double
    public var n: Int
    public var participants: Int
    public var ciLow: Double
    public var ciHigh: Double
    public var confidence: Double
}

public enum HumanRankingStudy {

    public enum StudyError: Error, Equatable {
        case empty
        case malformedRow(String)
        case raggedPanel
    }

    // MARK: - Analysis

    /// Correlate the measured metric against the human consensus ranking.
    ///
    /// - The correlation is over `references.count` points (the study's n).
    /// - Because human rank 1 = best while high similarity = best, a metric that
    ///   agrees with the panel yields a *negative* ρ; the sign is reported as-is.
    /// - The CI is the Fisher-z interval; with n ≤ 3 it is undefined and widens
    ///   to the whole range [-1, 1] rather than reporting a false precision.
    public static func analyze(_ study: RankingStudy,
                               confidence: Double = 0.95,
                               criticalZ: Double = 1.959963984540054) throws -> RankCorrelation {
        guard !study.references.isEmpty else { throw StudyError.empty }
        let panel = study.participantCount
        guard study.references.allSatisfy({ $0.humanRanks.count == panel }) else {
            throw StudyError.raggedPanel
        }
        let measured = study.references.map(\.measuredSimilarity)
        let human = study.references.map(\.consensusRank)
        let rho = spearman(measured, human)
        let n = study.references.count

        let (lo, hi) = fisherInterval(rho: rho, n: n, criticalZ: criticalZ)
        return RankCorrelation(rho: rho, n: n, participants: panel,
                               ciLow: lo, ciHigh: hi, confidence: confidence)
    }

    /// Two-sided Fisher z-transform confidence interval for a correlation. With
    /// n ≤ 3 the standard error is undefined, so the interval is the full range.
    static func fisherInterval(rho: Double, n: Int, criticalZ: Double) -> (Double, Double) {
        guard n > 3 else { return (-1, 1) }
        let z = atanh(rho)                       // ±∞ at ρ = ±1 → tanh clamps to ±1
        let se = 1 / Double(n - 3).squareRoot()
        return (tanh(z - criticalZ * se), tanh(z + criticalZ * se))
    }

    // MARK: - Spearman (tie-corrected)

    /// Spearman's rank correlation between two equal-length series. Returns 0 for
    /// fewer than two points or a series with no rank variance.
    public static func spearman(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, a.count >= 2 else { return 0 }
        let ra = ranks(a), rb = ranks(b)
        let n = Double(ra.count)
        let meanA = ra.reduce(0, +) / n
        let meanB = rb.reduce(0, +) / n
        var cov = 0.0, varA = 0.0, varB = 0.0
        for i in 0..<ra.count {
            let da = ra[i] - meanA, db = rb[i] - meanB
            cov += da * db; varA += da * da; varB += db * db
        }
        guard varA > 1e-12, varB > 1e-12 else { return 0 }
        return cov / (varA.squareRoot() * varB.squareRoot())
    }

    /// Fractional ranks (ties share the average rank) — the standard Spearman
    /// tie correction.
    static func ranks(_ values: [Double]) -> [Double] {
        let sorted = values.enumerated().sorted { $0.element < $1.element }
        var result = [Double](repeating: 0, count: values.count)
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count && sorted[j + 1].element == sorted[i].element { j += 1 }
            let rank = Double(i + j) / 2 + 1
            for k in i...j { result[sorted[k].offset] = rank }
            i = j + 1
        }
        return result
    }

    // MARK: - Ingest

    /// Parse a study from CSV. Layout (header required):
    ///
    ///     reference,measuredSimilarity,<participant-1>,<participant-2>,…
    ///     disc,0.83,1,2
    ///     box,0.55,3,3
    ///
    /// Each participant column holds that participant's rank for the reference.
    /// At least one participant column is required; rows must be rectangular.
    public static func parseCSV(_ text: String) throws -> RankingStudy {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let header = lines.first else { throw StudyError.empty }
        let headerCols = header.split(separator: ",").count
        guard headerCols >= 3 else { throw StudyError.malformedRow(header) }
        let participants = headerCols - 2

        var refs: [RankedReference] = []
        for line in lines.dropFirst() {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count == headerCols else { throw StudyError.malformedRow(line) }
            guard let measured = Double(cols[1]) else { throw StudyError.malformedRow(line) }
            var humanRanks: [Double] = []
            for k in 0..<participants {
                guard let r = Double(cols[2 + k]) else { throw StudyError.malformedRow(line) }
                humanRanks.append(r)
            }
            refs.append(RankedReference(name: cols[0],
                                        measuredSimilarity: measured,
                                        humanRanks: humanRanks))
        }
        return RankingStudy(references: refs)
    }

    /// Parse a study from JSON (the committed/round-trip form of `RankingStudy`).
    public static func parseJSON(_ data: Data) throws -> RankingStudy {
        try JSONDecoder().decode(RankingStudy.self, from: data)
    }
}
