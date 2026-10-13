import SwiftUI

/// Quiet placeholders used while the first local/cloud snapshot is loading.
/// It keeps empty data states from looking like a real empty library.
struct LoadingSkeleton: View {
    enum Style: Equatable { case list, cards }
    var rows = 3
    var style: Style = .list

    var body: some View {
        Group {
            if style == .cards {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(0..<rows, id: \.self) { _ in card }
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(0..<rows, id: \.self) { _ in listRow }
                }
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 8).fill(Theme.bgRaised).aspectRatio(1, contentMode: .fit)
            Capsule().fill(Theme.bgRaised).frame(height: 13)
            Capsule().fill(Theme.bgRaised).frame(width: 84, height: 10)
        }
        .padding(10)
        .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 10))
    }

    private var listRow: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 7).fill(Theme.bgRaised).frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 8) {
                Capsule().fill(Theme.bgRaised).frame(width: 180, height: 12)
                Capsule().fill(Theme.bgRaised).frame(width: 112, height: 10)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 9))
    }
}
