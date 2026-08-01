// Slice-elimination chrome for the roster's "Slices" sort: the per-slice header
// with its running out-tally, and the side list of knocked-out people.
//
// Every number drawn here is computed in Python (services/elimination.py) and
// arrives on the EliminationBoard — slice bounds, out-counts, places. This file
// owns presentation only: no counting, no threshold logic, no re-ordering.

import SwiftUI

/// Full-width rule between slices: "SLICE 1 · RANKS 50–41" plus one chip per
/// person still standing, showing what this slice cost them and where their
/// running total sits against the threshold.
struct SliceHeader: View {
    let slice: RankSlice
    let threshold: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("SLICE \(slice.index)")
                    .font(.ostMono(11, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(Theme.accent)
                    .fixedSize()
                Text("RANKS \(slice.label)")
                    .font(.ostMono(11, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(Theme.textDim)
                    .fixedSize()
                Rectangle()
                    .fill(Theme.textDim.opacity(0.25))
                    .frame(height: 1)
            }
            if !slice.tallies.isEmpty {
                // Wraps on narrow windows instead of clipping the tail of the field.
                FlowRow(spacing: 6) {
                    ForEach(slice.tallies) { tally in
                        TallyChip(tally: tally, threshold: threshold)
                    }
                }
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

/// One person's standing as of a slice: name, what fell here, and the running
/// out-count against the threshold. Turns rust the slice it finishes them.
private struct TallyChip: View {
    let tally: SliceTally
    let threshold: Int

    private var tint: Color { tally.eliminatedHere ? Theme.rust : Theme.accent }

    var body: some View {
        HStack(spacing: 6) {
            Text(tally.name)
                .font(.ostBody(11, weight: .medium))
                .foregroundStyle(tally.eliminatedHere ? Theme.textPrimary : Theme.textDim)
                .lineLimit(1)
            if tally.outHere > 0 {
                Text("▼\(tally.outHere)")
                    .font(.ostMono(10, weight: .bold))
                    .foregroundStyle(tint)
            }
            Text("\(tally.totalOut)/\(threshold)")
                .font(.ostMono(10, weight: .bold))
                .foregroundStyle(tally.eliminatedHere ? Theme.rust : Theme.textPrimary)
            OutMeter(filled: tally.totalOut, of: threshold, tint: tint)
            if tally.eliminatedHere {
                Text("OUT")
                    .font(.ostMono(9, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(Theme.bg)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(ChamferedRect(cut: 4).fill(Theme.rust))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(ChamferedRect(cut: 6).fill(Theme.bgRaised))
        .overlay(
            ChamferedRect(cut: 6).stroke(
                tint.opacity(tally.eliminatedHere ? 0.85 : 0.25), lineWidth: 1
            )
        )
        .help(tally.eliminatedHere
              ? "\(tally.name) is out — \(tally.totalOut) OSTs down"
              : "\(tally.name): \(tally.remaining) still standing")
    }
}

/// Threshold meter: one pip per life while the field is small enough to read,
/// a proportional bar once the threshold is set high.
private struct OutMeter: View {
    let filled: Int
    let of: Int
    let tint: Color

    private static let pipLimit = 8

    var body: some View {
        if of <= Self.pipLimit {
            HStack(spacing: 2) {
                ForEach(0..<max(of, 1), id: \.self) { index in
                    Capsule()
                        .fill(index < filled ? tint : Theme.textDim.opacity(0.25))
                        .frame(width: 4, height: 8)
                }
            }
        } else {
            Capsule()
                .fill(Theme.textDim.opacity(0.25))
                .frame(width: 34, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(tint)
                        .frame(width: 34 * min(1, Double(filled) / Double(max(of, 1))))
                }
        }
    }
}

/// The side list: everyone knocked out, in finishing order (place 1 on top),
/// with whoever is still standing underneath.
struct EliminationSidebar: View {
    let board: EliminationBoard

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("ELIMINATED", count: board.eliminated.count)
                if board.eliminated.isEmpty {
                    Text("Nobody has lost \(board.threshold) OSTs yet.")
                        .font(.ostBody(11))
                        .foregroundStyle(Theme.textDim)
                } else {
                    VStack(spacing: 6) {
                        ForEach(board.eliminated) { person in
                            EliminationRow(person: person, sliceLabel: label(forSlice: person.sliceIndex))
                        }
                    }
                }

                if !board.survivors.isEmpty {
                    section("STILL IN", count: board.survivors.count)
                    VStack(spacing: 6) {
                        ForEach(board.survivors) { person in
                            SurvivorRow(person: person, threshold: board.threshold)
                        }
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 250)
        .background(ChamferedRect().fill(Theme.cardSurface))
        .overlay(ChamferedRect().stroke(Theme.accent.opacity(0.25), lineWidth: 1.5))
        .clipShape(ChamferedRect())
    }

    private func label(forSlice index: Int) -> String {
        board.slices.first { $0.index == index }?.label ?? "\(index)"
    }

    private func section(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.ostMono(10, weight: .bold))
                .tracking(2)
                .foregroundStyle(Theme.textDim)
            Text("\(count)")
                .font(.ostMono(10, weight: .bold))
                .foregroundStyle(Theme.accent)
            Rectangle().fill(Theme.textDim.opacity(0.2)).frame(height: 1)
        }
    }
}

/// One finished competitor: place badge, name, and the slice that ended them.
private struct EliminationRow: View {
    let person: Elimination
    let sliceLabel: String

    /// Brand metals for the podium (never themed), accent below it.
    private var placeTint: Color {
        switch person.place {
        case 1: Theme.gold
        case 2: Theme.pink
        case 3: Theme.rust
        default: Theme.textDim
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(Self.ordinal(person.place))
                .font(.ostMono(11, weight: .bold))
                .foregroundStyle(person.place <= 3 ? Theme.bg : Theme.textPrimary)
                .frame(width: 34)
                .padding(.vertical, 4)
                .background(
                    ChamferedRect(cut: 5).fill(
                        person.place <= 3 ? placeTint : Theme.bgRaised
                    )
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(person.name)
                    .font(.ostDisplay(12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text("out in \(sliceLabel) · at #\(person.outAtRank)")
                    .font(.ostMono(9))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(ChamferedRect(cut: 7).fill(Theme.bgRaised.opacity(0.6)))
    }

    static func ordinal(_ value: Int) -> String {
        let suffix: String
        switch (value % 10, value % 100) {
        case (_, 11), (_, 12), (_, 13): suffix = "th"
        case (1, _): suffix = "st"
        case (2, _): suffix = "nd"
        case (3, _): suffix = "rd"
        default: suffix = "th"
        }
        return "\(value)\(suffix)"
    }
}

/// Someone who hasn't hit the threshold: how many of their OSTs are still up.
private struct SurvivorRow: View {
    let person: Survivor
    let threshold: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(person.name)
                .font(.ostDisplay(12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(person.remaining) up")
                .font(.ostMono(10, weight: .bold))
                .foregroundStyle(Theme.accent)
            Text("\(person.totalOut)/\(threshold)")
                .font(.ostMono(10))
                .foregroundStyle(Theme.textDim)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(ChamferedRect(cut: 7).fill(Theme.bgRaised.opacity(0.6)))
    }
}

/// Minimal wrapping row (Layout): chips flow onto the next line instead of
/// being clipped. SwiftUI has no built-in wrap for a non-Grid row on macOS 15.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
