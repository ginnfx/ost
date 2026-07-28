// The two signature shapes: chamfered (45°-cut) card corners — straight
// diagonal segments, never arcs — and the diamond rank badge.

import SwiftUI

/// Rectangle with 45° diagonal-cut corners. `cut` is the leg length of each
/// corner triangle, so the diagonal is exactly 45° by construction.
nonisolated struct ChamferedRect: Shape, InsettableShape {
    var cut: CGFloat = Theme.chamfer
    var insetAmount: CGFloat = 0

    nonisolated func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let c = min(cut, min(r.width, r.height) / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX + c, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + c))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
        p.addLine(to: CGPoint(x: r.maxX - c, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - c))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        p.closeSubpath()
        return p
    }

    nonisolated func inset(by amount: CGFloat) -> ChamferedRect {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

/// Rank badge: a square rotated 45° expressed as an explicit path so stroke
/// joins stay crisp at any size.
nonisolated struct Diamond: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        p.closeSubpath()
        return p
    }
}

/// Diamond badge with the rank number in mono. Top-3 get the brand metals:
/// gold, pink, rust; everyone else gets the dark surface.
struct DiamondBadge: View {
    let rank: Int?
    var size: CGFloat = 34

    private var fill: Color {
        switch rank {
        case 1: Theme.gold
        case 2: Theme.pink
        case 3: Theme.rust
        default: Theme.bgRaised
        }
    }

    private var textColor: Color {
        (rank ?? 99) <= 3 ? Theme.bg : Theme.textPrimary
    }

    var body: some View {
        ZStack {
            Diamond()
                .fill(fill)
            Diamond()
                .stroke(Theme.textPrimary.opacity(0.25), lineWidth: 1)
            Text(rank.map(String.init) ?? "–")
                .font(.ostMono(size * 0.34, weight: .bold))
                .foregroundStyle(textColor)
        }
        .frame(width: size, height: size)
    }
}
