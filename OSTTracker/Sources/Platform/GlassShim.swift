// iOS stand-in for GlowEffectKit's macOS liquid-glass API, so the shared view
// layer compiles on iOS. Renders a material-backed fill instead of real glass;
// visual parity is a later pass. macOS keeps using GlowEffectKit unchanged.

#if os(iOS)

import SwiftUI

public struct GlassStyle: Sendable {
    var tint: Color = .clear
    var interactive: Bool = false

    public static let regular = GlassStyle()

    public func tint(_ color: Color) -> GlassStyle {
        var style = self
        style.tint = color
        return style
    }

    public func interactive() -> GlassStyle {
        var style = self
        style.interactive = true
        return style
    }
}

public struct GlassShape: Shape {
    public enum Kind {
        case rect(CGFloat)
        case circle
        case capsule
    }

    public var kind: Kind

    public static let circle = GlassShape(kind: .circle)
    public static let capsule = GlassShape(kind: .capsule)
    public static let rect = GlassShape(kind: .rect(12))

    public func path(in rect: CGRect) -> Path {
        switch kind {
        case .circle: Path(ellipseIn: rect)
        case .capsule: Path(roundedRect: rect, cornerRadius: rect.height / 2)
        case .rect(let radius): Path(roundedRect: rect, cornerRadius: radius)
        }
    }
}

public extension View {
    @ViewBuilder
    func glassEffect(_ style: GlassStyle = .regular, in shape: GlassShape) -> some View {
        shape.fill(.ultraThinMaterial)
            .overlay(shape.fill(style.tint.opacity(style.interactive ? 0.35 : 0.2)))
            .clipShape(shape)
    }

    @ViewBuilder
    func glassEffect(_ style: GlassStyle = .regular, in shape: some Shape) -> some View {
        shape.fill(.ultraThinMaterial)
            .overlay(shape.fill(style.tint.opacity(0.2)))
            .clipShape(shape)
    }

    func glassEffectID(_ id: String, in shape: some Shape) -> some View { self }
}

#endif  // os(iOS)
