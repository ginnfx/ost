// Design tokens — every color, font name, and chamfer size a view uses comes
// from here. Theme.verify() asserts the tokens at launch (DEBUG)
// instead of trusting screenshots.

#if os(macOS)
import AppKit
#endif
import SwiftUI

nonisolated enum MotionMode: String, CaseIterable, Identifiable {
    case minimal, subtle, cinematic

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

nonisolated enum MotionPurpose: Equatable {
    case navigation, detail, reorder, feedback, overlay
}

nonisolated enum Theme {
    // MARK: Color tokens (asserted against these exact hex values)

    // Chrome accent — app UI only: wordmark, active nav pill, primary buttons,
    // focus states. Deliberately SEPARATE from the brand metals below so the
    // chrome can be recolored without touching rank badges or achievement gold.
    //
    // Now user-themable: `accentHex` resolves from UserDefaults (a custom hex
    // wins, else the chosen preset, else the Emerald default). Call sites still
    // read `Theme.accent`/`Theme.accentHex` unchanged; RootView keys its content
    // on the selection so a change re-renders the tree with fresh colors.
    static let presetKey = "themePresetID"
    static let customAccentKey = "customAccentHex"
    static let defaultAccentHex = "#69B58D"

    struct ThemePreset: Identifiable, Hashable {
        let id: String
        let name: String
        let accentHex: String
    }

    static let presets: [ThemePreset] = [
        .init(id: "emerald", name: "Emerald", accentHex: "#69B58D"),
        .init(id: "amber", name: "Amber", accentHex: "#F5A623"),
        .init(id: "magenta", name: "Magenta", accentHex: "#FF3D81"),
        .init(id: "ice", name: "Ice", accentHex: "#4FC3F7"),
        .init(id: "violet", name: "Violet", accentHex: "#8A54D0"),
        .init(id: "coral", name: "Coral", accentHex: "#FF6B4A"),
    ]

    /// True for a well-formed `#RRGGBB` literal (guards the custom accent before
    /// it reaches `Color(hex:)`, which asserts on malformed input in DEBUG).
    static func isValidHex(_ hex: String) -> Bool {
        hex.hasPrefix("#") && hex.count == 7
            && hex.dropFirst().allSatisfy(\.isHexDigit)
    }

    static var accentHex: String {
        let defaults = UserDefaults.standard
        if let custom = defaults.string(forKey: customAccentKey),
           !custom.isEmpty, isValidHex(custom) {
            return custom
        }
        let id = defaults.string(forKey: presetKey) ?? "emerald"
        return presets.first { $0.id == id }?.accentHex ?? defaultAccentHex
    }

    static var accent: Color { Color(hex: accentHex) }

    // Brand metals — reserved for rank badges (1/2/3) and achievement
    // highlights. Never used as the generic chrome accent.
    static let goldHex = "#F2B705"
    static let pinkHex = "#FF3D81"
    static let rustHex = "#E8541E"

    static let gold = Color(hex: goldHex)
    static let pink = Color(hex: pinkHex)
    static let rust = Color(hex: rustHex)

    // Dark UI base (background layers, not brand tokens).
    static let bg = Color(hex: "#17191A")
    static let bgRaised = Color(hex: "#202324")
    static let cardSurface = Color(hex: "#25292A")
    static let separator = Color(hex: "#3A3F40")
    static let textPrimary = Color(hex: "#F1F2EF")
    static let textDim = Color(hex: "#B8BEBC")

    // MARK: Geometry

    static let chamfer: CGFloat = 14          // 45° corner cut, in points
    static let cardAspect: CGFloat = 0.72     // roster card width/height
    static let gridSpacing: CGFloat = 14

    // MARK: Fonts — one typeface everywhere (Spotify Mix), bundled from Fonts/.
    //
    // Spotify Mix ships each weight as a SEPARATE PostScript face, so we select
    // by exact PostScript name per weight (below) rather than by family +
    // .weight(), which only synthesizes when a family lacks that weight. To swap
    // the typeface, drop the new weights into OSTTracker/Fonts/ and update these
    // four names + the weight map in the Font extension.
    static let fontFaces = [
        "SpotifyMix-Regular", "SpotifyMix-Medium", "SpotifyMix-Bold", "SpotifyMix-Black",
    ]

    // MARK: Motion

    static let motionKey = "motionMode"

    static var motionMode: MotionMode {
        MotionMode(rawValue: UserDefaults.standard.string(forKey: motionKey) ?? "subtle") ?? .subtle
    }

    static func motion(_ purpose: MotionPurpose, reduceMotion: Bool = false) -> Animation? {
        guard !reduceMotion else { return nil }
        switch motionMode {
        case .minimal:
            return nil
        case .subtle:
            switch purpose {
            case .navigation: return .easeInOut(duration: 0.18)
            case .detail: return .easeInOut(duration: 0.22)
            case .reorder: return .spring(response: 0.32, dampingFraction: 0.9)
            case .feedback: return .easeOut(duration: 0.12)
            case .overlay: return .easeInOut(duration: 0.2)
            }
        case .cinematic:
            switch purpose {
            case .navigation: return .spring(response: 0.32, dampingFraction: 0.88)
            case .detail: return .spring(response: 0.46, dampingFraction: 0.86)
            case .reorder: return .spring(response: 0.52, dampingFraction: 0.82)
            case .feedback: return .easeOut(duration: 0.16)
            case .overlay: return .easeInOut(duration: 0.32)
            }
        }
    }

    // MARK: Sound and spectrum settings

    static let uiSoundVolume: Float = 0.35    // UI blips sit well under the OST
    /// Controls audio-reactive movement in the player and visualizer.
    static let fxDefaultsKey = "reactiveFXEnabled"
    static let fxIntensityKey = "fxIntensity"
    static let visualizerKey = "playerVisualizerEnabled"

    /// Deterministic per-person accent (golden-ratio hue spacing) for the
    /// discreet rater-identity dots. Same person, same color, every screen.
    static func personAccent(_ id: Int) -> Color {
        Color(
            hue: (Double(id) * 0.618034).truncatingRemainder(dividingBy: 1),
            saturation: 0.55, brightness: 0.9
        )
    }

    /// Register the bundled font files for this process. Explicit CoreText
    /// registration: ATSApplicationFontsPath resolves too late for App.init,
    /// and verify() must be able to run immediately after this.
    @MainActor
    static func registerFonts() {
        guard let fontsDir = Bundle.main.resourceURL?.appending(path: "Fonts") else { return }
        let fonts = (try? FileManager.default.contentsOfDirectory(
            at: fontsDir, includingPropertiesForKeys: nil
        )) ?? []
        for url in fonts where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let reason = (error?.takeRetainedValue()).map(String.init(describing:)) ?? "?"
                print("FONT registration failed for \(url.lastPathComponent): \(reason)")
            }
        }
    }

    /// Launch-time token check: every color token round-trips to its spec hex
    /// and every bundled family resolves. Crashes a DEBUG build loudly rather
    /// than shipping drifted tokens.
    @MainActor
    static func verify() {
        for (color, hex) in [(accent, accentHex), (gold, goldHex), (pink, pinkHex), (rust, rustHex)] {
            #if os(macOS)
            let actual = NSColor(color).hexString
            precondition(actual == hex, "Theme drift: expected \(hex), got \(actual)")
            #else
            let actual = PlatformColor(color).srgbHexString
            precondition(actual == hex, "Theme drift: expected \(hex), got \(actual)")
            #endif
        }
        for face in fontFaces {
            #if os(macOS)
            precondition(NSFont(name: face, size: 12) != nil, "Font face not registered: \(face)")
            #endif
        }
        for preset in presets {
            precondition(isValidHex(preset.accentHex), "Malformed preset hex: \(preset.accentHex)")
        }
        precondition((0...1).contains(uiSoundVolume), "uiSoundVolume out of range")
        print("THEME tokens verified: accent \(accentHex) | faces \(fontFaces.joined(separator: ", "))")
    }
}

// MARK: - Semantic fonts

nonisolated extension Font {
    /// Pick the Spotify Mix PostScript face for a weight (real weights, no synthesis).
    private static func spotifyMix(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        let face: String
        switch weight {
        case .black, .heavy: face = "SpotifyMix-Black"
        case .bold: face = "SpotifyMix-Bold"
        case .semibold, .medium: face = "SpotifyMix-Medium"
        default: face = "SpotifyMix-Regular"
        }
        return .custom(face, size: size)
    }

    /// The "OST TRACKER" wordmark — heaviest weight for a punchy brand mark.
    static func ostWordmark(_ size: CGFloat, weight: Font.Weight = .black) -> Font {
        spotifyMix(size, weight)
    }

    /// Titles, headers, section labels.
    static func ostDisplay(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        spotifyMix(size, weight)
    }

    /// Running text.
    static func ostBody(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        spotifyMix(size, weight)
    }

    /// Numbers on screen: scores, ranks, timers — tabular digits so columns align.
    static func ostMono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        spotifyMix(size, weight).monospacedDigit()
    }
}

// MARK: - Hex plumbing

nonisolated extension Color {
    /// sRGB "#RRGGBB" literal. Fails loudly on malformed input in DEBUG.
    init(hex: String) {
        var value: UInt64 = 0
        let scanned = Scanner(string: String(hex.dropFirst())).scanHexInt64(&value)
        assert(scanned && hex.hasPrefix("#") && hex.count == 7, "Bad hex literal: \(hex)")
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

#if os(macOS)
nonisolated extension NSColor {
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(
            format: "#%02X%02X%02X",
            Int(round(c.redComponent * 255)),
            Int(round(c.greenComponent * 255)),
            Int(round(c.blueComponent * 255))
        )
    }
}
#endif
