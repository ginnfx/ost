// big board: competition-wide stats computed client-side off already-loaded
// store data (leaderboard + scores + people). Four layers, page title down to
// card caption: page ("THE BOARD") > section label (OVERVIEW, SUPERLATIVES,
// ...) > card caption (mono, describes exactly what the card shows) > content.
// Self-ratings (submitter auto-10s) excluded from rater/curator stats so
// numbers say something true about taste, not bookkeeping.

import SwiftUI

struct StatsView: View {
    let store: AppStore

    var body: some View {
        if store.leaderboard.isEmpty {
            ContentUnavailableView(
                "No stats yet", systemImage: "chart.bar",
                description: Text("Stats appear once OSTs are added and rated.")
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("THE BOARD")
                        .font(.ostDisplay(15, weight: .semibold))
                        .foregroundStyle(Theme.accent)

                    VStack(alignment: .leading, spacing: 12) {
                        sectionLabel("OVERVIEW")
                        OverviewStripCard(metrics: overviewMetrics)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        sectionLabel("SUPERLATIVES")
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: Theme.gridSpacing)],
                            spacing: Theme.gridSpacing
                        ) {
                            if let divisive = mostDivisive {
                                StatTile(
                                    superlative: "MOST DIVISIVE",
                                    value: String(format: "σ %.2f", divisive.stddev ?? 0),
                                    subject: divisive.ost.title,
                                    tint: Theme.pink
                                )
                            }
                            if let consensus = consensusPick {
                                StatTile(
                                    superlative: "CONSENSUS PICK",
                                    value: String(format: "σ %.2f", consensus.stddev ?? 0),
                                    subject: consensus.ost.title,
                                    tint: Theme.accent
                                )
                            }
                            if let top = topRated {
                                StatTile(
                                    superlative: "HIGHEST RATED",
                                    value: String(format: "%.2f", top.average ?? 0),
                                    subject: top.ost.title,
                                    tint: Theme.gold
                                )
                            }
                            if let low = lowestRated {
                                StatTile(
                                    superlative: "LOWEST RATED",
                                    value: String(format: "%.2f", low.average ?? 0),
                                    subject: low.ost.title,
                                    tint: Theme.rust
                                )
                            }
                            if let harsh = harshestRater {
                                StatTile(
                                    superlative: "TOUGHEST RATER",
                                    value: String(format: "%.2f", harsh.average),
                                    subject: "\(harsh.person.name) — lowest average given",
                                    tint: Theme.rust
                                )
                            }
                            if let generous = mostGenerousRater {
                                StatTile(
                                    superlative: "MOST GENEROUS RATER",
                                    value: String(format: "%.2f", generous.average),
                                    subject: "\(generous.person.name) — highest average given",
                                    tint: Theme.gold
                                )
                            }
                            if let most = mostRated {
                                StatTile(
                                    superlative: "MOST RATED",
                                    value: "\(most.ratingCount)",
                                    subject: "\(most.ost.title) — votes cast",
                                    tint: Theme.accent
                                )
                            }
                            if let curator = topCurator {
                                StatTile(
                                    superlative: "BEST SUBMITTER",
                                    value: String(format: "%.2f", curator.average),
                                    subject: "\(curator.person.name) — avg of \(curator.count) picks",
                                    tint: Theme.pink
                                )
                            }
                            if let prolific = mostProlificSubmitter {
                                StatTile(
                                    superlative: "MOST PROLIFIC SUBMITTER",
                                    value: "\(prolific.count)",
                                    subject: "\(prolific.person.name) — OSTs submitted",
                                    tint: Theme.accent
                                )
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        sectionLabel("RATER GRADING CURVE")
                        RankedBarChartCard(
                            caption: "Average score given per rater, self-picks excluded",
                            rows: gradingCurveRows
                        )
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        sectionLabel("SUBMITTER LEADERBOARD")
                        RankedBarChartCard(
                            caption: "Average score their picks received",
                            rows: submitterLeaderboardRows
                        )
                    }

                    if scoreDistribution.contains(where: { $0 > 0 }) {
                        VStack(alignment: .leading, spacing: 12) {
                            sectionLabel("SCORE SPREAD")
                            DistributionCard(
                                counts: scoreDistribution,
                                caption: "Every score cast across the board, self-ratings excluded"
                            )
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 90) // clear now-playing bar
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.ostDisplay(12, weight: .semibold))
            .foregroundStyle(Theme.textDim)
            .kerning(1.4)
    }

    // MARK: Overview

    private var totalOsts: Int { store.leaderboard.count }

    /// Mean of per-OST averages (each OST weighted equally regardless of vote count).
    private var overallAverage: Double? {
        let averages = store.leaderboard.compactMap(\.average)
        guard !averages.isEmpty else { return nil }
        return averages.reduce(0, +) / Double(averages.count)
    }

    private var avgVotesPerOst: Double {
        guard !store.leaderboard.isEmpty else { return 0 }
        let total = store.leaderboard.reduce(0) { $0 + $1.ratingCount }
        return Double(total) / Double(store.leaderboard.count)
    }

    private var overviewMetrics: [OverviewMetric] {
        [
            OverviewMetric(label: "OSTS TRACKED", value: "\(totalOsts)"),
            OverviewMetric(label: "OVERALL AVERAGE", value: overallAverage.map { String(format: "%.2f", $0) } ?? "—"),
            OverviewMetric(label: "RATINGS IN", value: "\(Int((coverage * 100).rounded()))%"),
            OverviewMetric(label: "PERFECT 10s", value: "\(perfectTenCount)"),
            OverviewMetric(label: "AVG VOTES / OST", value: String(format: "%.1f", avgVotesPerOst)),
        ]
    }

    // MARK: Derived superlatives

    /// Highest average, needs a real verdict (≥2 votes) so a lone self-10
    /// doesn't crown a track.
    private var topRated: RankEntry? {
        store.leaderboard
            .filter { $0.average != nil && $0.ratingCount >= 2 }
            .max { ($0.average ?? 0) < ($1.average ?? 0) }
    }

    private var lowestRated: RankEntry? {
        store.leaderboard
            .filter { $0.average != nil && $0.ratingCount >= 2 }
            .min { ($0.average ?? 0) < ($1.average ?? 0) }
    }

    private var mostRated: RankEntry? {
        store.leaderboard.max { $0.ratingCount < $1.ratingCount }
    }

    /// Every submitter with ≥2 rated picks, ranked by average of their OST averages.
    private var submitterAverages: [(person: Person, average: Double, count: Int)] {
        var byPerson: [Int: [Double]] = [:]
        for entry in store.leaderboard {
            guard let sub = entry.ost.submitterId, let avg = entry.average,
                  entry.ratingCount >= 2 else { continue }
            byPerson[sub, default: []].append(avg)
        }
        return byPerson.compactMap { id, avgs -> (Person, Double, Int)? in
            guard avgs.count >= 2, let person = store.people.first(where: { $0.id == id }) else { return nil }
            return (person, avgs.reduce(0, +) / Double(avgs.count), avgs.count)
        }
        .sorted { $0.1 > $1.1 }
    }

    private var topCurator: (person: Person, average: Double, count: Int)? {
        submitterAverages.first
    }

    private var mostProlificSubmitter: (person: Person, count: Int)? {
        var counts: [Int: Int] = [:]
        for entry in store.leaderboard {
            if let sub = entry.ost.submitterId { counts[sub, default: 0] += 1 }
        }
        guard let best = counts.max(by: { $0.value < $1.value }),
              let person = store.people.first(where: { $0.id == best.key }) else { return nil }
        return (person, best.value)
    }

    /// Count each score 1…10 across all non-self ratings (index 0 == score 1).
    private var scoreDistribution: [Int] {
        let submitters = submitterByOst
        var counts = [Int](repeating: 0, count: 10)
        for (ostID, raters) in store.scores {
            for (raterID, score) in raters where submitters[ostID] != raterID {
                // Fractional scores count toward nearest whole bucket.
                let bucket = Int(score.rounded())
                if (1...10).contains(bucket) { counts[bucket - 1] += 1 }
            }
        }
        return counts
    }

    /// ost id -> submitter id, excluding auto self-10s from rater stats.
    private var submitterByOst: [Int: Int] {
        Dictionary(uniqueKeysWithValues: store.leaderboard.compactMap { entry in
            entry.ost.submitterId.map { (entry.ost.id, $0) }
        })
    }

    private var mostDivisive: RankEntry? {
        store.leaderboard
            .filter { ($0.stddev ?? 0) > 0 && $0.ratingCount >= 2 }
            .max { ($0.stddev ?? 0) < ($1.stddev ?? 0) }
    }

    private var consensusPick: RankEntry? {
        store.leaderboard
            .filter { $0.stddev != nil && $0.ratingCount >= 2 }
            .min { ($0.stddev ?? 0) < ($1.stddev ?? 0) }
    }

    /// Per-person average scores GIVEN, excluding own submissions.
    private var raterAverages: [(person: Person, average: Double, count: Int)] {
        let submitters = submitterByOst
        return store.people.compactMap { person in
            var given: [Double] = []
            for (ostID, raters) in store.scores {
                guard submitters[ostID] != person.id, let score = raters[person.id] else { continue }
                given.append(score)
            }
            guard given.count >= 3 else { return nil }   // too few to be a verdict
            let average = given.reduce(0, +) / Double(given.count)
            return (person, average, given.count)
        }
    }

    private var harshestRater: (person: Person, average: Double, count: Int)? {
        raterAverages.min { $0.average < $1.average }
    }

    private var mostGenerousRater: (person: Person, average: Double, count: Int)? {
        raterAverages.max { $0.average < $1.average }
    }

    private var perfectTenCount: Int {
        let submitters = submitterByOst
        return store.scores.reduce(0) { total, item in
            let (ostID, raters) = item
            return total + raters.filter { $0.value == 10 && submitters[ostID] != $0.key }.count
        }
    }

    private var totalCells: Int { store.people.count * store.leaderboard.count }
    private var filledCells: Int { store.scores.values.reduce(0) { $0 + $1.count } }
    private var coverage: Double {
        totalCells > 0 ? Double(filledCells) / Double(totalCells) : 0
    }

    // MARK: Graph rows

    private var gradingCurveRows: [BarRowData] {
        raterAverages
            .sorted { $0.average > $1.average }
            .map { BarRowData(id: $0.person.id, label: $0.person.name, value: $0.average, detail: "\($0.count) given") }
    }

    private var submitterLeaderboardRows: [BarRowData] {
        submitterAverages.map {
            BarRowData(id: $0.0.id, label: $0.0.name, value: $0.1, detail: "\($0.2) picks")
        }
    }
}

/// One superlative: caption, one big number, one line context. Solid card
/// surface matching roster (glass stays reserved chrome). The number rolls
/// up from zero on first appear and re-rolls to the new figure whenever a
/// live rating streams in; hover lifts the card the same way a roster
/// card does, minus the full glow shader (informational, not playable).
private struct StatTile: View {
    let superlative: String
    let value: String
    let subject: String
    let tint: Color

    @State private var displayValue = "0"
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(superlative)
                .font(.ostMono(10, weight: .medium))
                .foregroundStyle(Theme.textDim)
                .kerning(1.2)
            Text(displayValue)
                .font(.ostMono(34, weight: .bold))
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(subject)
                .font(.ostBody(12))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(ChamferedRect().fill(Theme.cardSurface))
        .overlay(ChamferedRect().stroke(tint.opacity(isHovered ? 0.75 : 0.35), lineWidth: 1.5))
        .shadow(color: tint.opacity(isHovered ? 0.3 : 0), radius: 14, y: 6)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { hovering in
            if hovering, !isHovered { SoundKit.shared.play(.hoverTick) }
            isHovered = hovering
        }
        .onAppear {
            withAnimation(.spring(response: 0.65, dampingFraction: 0.8).delay(0.05)) {
                displayValue = value
            }
        }
        .onChange(of: value) { _, newValue in
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                displayValue = newValue
            }
        }
    }
}

/// One overview figure: big number, small dim label underneath.
private struct OverviewMetric: Identifiable {
    var id: String { label }
    let label: String
    let value: String
}

/// Compact row of top-line totals in a single card, hairline-divided —
/// distinct from the superlative tiles below, which each point at a
/// specific track or person rather than a competition-wide total. Each
/// figure counts up on appear and re-counts on live data changes.
private struct OverviewStripCard: View {
    let metrics: [OverviewMetric]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                OverviewMetricColumn(metric: metric, index: index)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if index < metrics.count - 1 {
                    Rectangle()
                        .fill(Theme.textDim.opacity(0.15))
                        .frame(width: 1)
                        .padding(.vertical, 2)
                }
            }
        }
        .padding(16)
        .background(ChamferedRect().fill(Theme.cardSurface))
        .overlay(ChamferedRect().stroke(Theme.accent.opacity(0.25), lineWidth: 1.5))
    }
}

private struct OverviewMetricColumn: View {
    let metric: OverviewMetric
    let index: Int

    @State private var displayValue = "0"
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(displayValue)
                .font(.ostMono(22, weight: .bold))
                .foregroundStyle(isHovered ? Theme.accent : Theme.textPrimary)
                .contentTransition(.numericText())
            Text(metric.label)
                .font(.ostMono(10, weight: .medium))
                .foregroundStyle(Theme.textDim)
                .kerning(1.0)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .scaleEffect(isHovered ? 1.05 : 1.0, anchor: .leading)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { isHovered = $0 }
        .onAppear {
            withAnimation(Theme.resortAnimation.delay(Double(index) * Theme.revealStagger)) {
                displayValue = metric.value
            }
        }
        .onChange(of: metric.value) { _, newValue in
            withAnimation(Theme.resortAnimation) { displayValue = newValue }
        }
    }
}

private struct BarRowData: Identifiable {
    let id: Int
    let label: String
    let value: Double
    let detail: String
}

/// One ranked horizontal bar: name, 0–10 fill, exact value, count context.
/// Tint reads as a grade band (rust below 6, chrome accent mid, gold 8+) —
/// same three-color language the superlative tiles already use. The fill
/// grows in from zero, staggered by rank, and glides to a new width live
/// as ratings stream in; hover brightens the row and grows the bar slightly.
private struct BarRow: View {
    let data: BarRowData
    let index: Int

    @State private var animatedValue: Double = 0
    @State private var isHovered = false

    private var tint: Color {
        switch data.value {
        case ..<6: Theme.rust
        case 6..<8: Theme.accent
        default: Theme.gold
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(data.label)
                .font(.ostBody(12, weight: isHovered ? .semibold : .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .frame(width: 110, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.bg)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(tint)
                        .brightness(isHovered ? 0.1 : 0)
                        .frame(width: geo.size.width * CGFloat(min(max(animatedValue, 0), 10) / 10))
                }
            }
            .frame(height: isHovered ? 13 : 10)

            Text(String(format: "%.2f", animatedValue))
                .font(.ostMono(12, weight: .bold))
                .foregroundStyle(tint)
                .contentTransition(.numericText(value: animatedValue))
                .frame(width: 44, alignment: .trailing)

            Text(data.detail)
                .font(.ostMono(10))
                .foregroundStyle(Theme.textDim)
                .frame(width: 66, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.textDim.opacity(isHovered ? 0.08 : 0))
        )
        .contentShape(Rectangle())
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovered)
        .onHover { hovering in
            if hovering, !isHovered { SoundKit.shared.play(.hoverTick) }
            isHovered = hovering
        }
        .onAppear {
            withAnimation(Theme.resortAnimation.delay(Double(index) * Theme.revealStagger)) {
                animatedValue = data.value
            }
        }
        .onChange(of: data.value) { _, newValue in
            withAnimation(Theme.resortAnimation) { animatedValue = newValue }
        }
    }
}

/// Ranked bar chart card: mono caption, then one BarRow per entry (already
/// sorted by the caller). Shared by the rater grading curve and the
/// submitter leaderboard so both graphs read as one visual language.
private struct RankedBarChartCard: View {
    let caption: String
    let rows: [BarRowData]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(caption)
                .font(.ostMono(10, weight: .medium))
                .foregroundStyle(Theme.textDim)
                .kerning(0.6)

            if rows.isEmpty {
                Text("Not enough data yet")
                    .font(.ostBody(12))
                    .foregroundStyle(Theme.textDim)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        BarRow(data: row, index: index)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(ChamferedRect().fill(Theme.cardSurface))
        .overlay(ChamferedRect().stroke(Theme.accent.opacity(0.25), lineWidth: 1.5))
    }
}

/// One 1…10 histogram bucket. Grows in from zero, staggered left to right;
/// hover lifts and brightens that single bar and bolds its count.
private struct HistogramBar: View {
    let score: Int
    let count: Int
    let maxCount: Int
    let isMode: Bool
    let index: Int

    @State private var animatedCount: Double = 0
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 6) {
            Text("\(Int(animatedCount.rounded()))")
                .font(.ostMono(9, weight: isHovered ? .bold : .regular))
                .foregroundStyle(isHovered ? Theme.textPrimary : Theme.textDim)
                .contentTransition(.numericText(value: animatedCount))
                .opacity(count > 0 ? 1 : 0.4)
            RoundedRectangle(cornerRadius: 3)
                .fill(isMode ? Theme.accent : Theme.accent.opacity(isHovered ? 0.6 : 0.35))
                .frame(height: max(4, CGFloat(animatedCount) / CGFloat(maxCount) * 120))
                .scaleEffect(x: isHovered ? 1.15 : 1.0, anchor: .bottom)
            Text("\(score)")
                .font(.ostMono(10, weight: .bold))
                .foregroundStyle(isHovered ? Theme.accent : Theme.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
        .onHover { isHovered = $0 }
        .onAppear {
            withAnimation(Theme.resortAnimation.delay(Double(index) * Theme.revealStagger)) {
                animatedCount = Double(count)
            }
        }
        .onChange(of: count) { _, newValue in
            withAnimation(Theme.resortAnimation) { animatedCount = Double(newValue) }
        }
    }
}

/// Full-width score histogram (1…10), self-ratings excluded. Bars scale to
/// the tallest bucket; the mode is tinted chrome accent.
private struct DistributionCard: View {
    let counts: [Int]
    let caption: String

    private var maxCount: Int { max(counts.max() ?? 1, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(caption)
                .font(.ostMono(10, weight: .medium))
                .foregroundStyle(Theme.textDim)
                .kerning(0.6)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(counts.enumerated()), id: \.offset) { i, count in
                    HistogramBar(
                        score: i + 1, count: count, maxCount: maxCount,
                        isMode: count == maxCount, index: i
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(ChamferedRect().fill(Theme.cardSurface))
        .overlay(ChamferedRect().stroke(Theme.accent.opacity(0.25), lineWidth: 1.5))
    }
}
