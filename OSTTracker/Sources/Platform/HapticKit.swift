#if os(iOS)
import UIKit

// Thin wrapper around UIKit feedback generators, mirroring SoundKit's role for
// audio. Call sites stay identical on both platforms — just wrap in #if os(iOS).
enum HapticKit {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}
#endif
