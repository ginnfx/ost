// Multiplatform prep (macOS-only today). This app ships macOS-only: it spawns a
// local Python/FastAPI sidecar (SidecarProcess) which iOS forbids. The intended
// iOS path is a LAN companion — the Mac keeps hosting the sidecar bound to the
// local network and an iOS client pairs over the same HTTP/WS contract. To make
// that port cheap later, AppKit-specific types are funneled through the aliases
// below and the few AppKit call sites are `#if os(macOS)`-guarded with
// `// TODO(iOS):` markers. Nothing here changes macOS behavior.

import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
#else
import UIKit
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
#endif

extension PlatformColor {
    /// sRGB "#RRGGBB" for a resolved platform color. Used by the theme token
    /// round-trip check and the Settings custom-accent picker.
    var srgbHexString: String {
        #if os(macOS)
        let c = usingColorSpace(.sRGB) ?? self
        return String(
            format: "#%02X%02X%02X",
            Int(round(c.redComponent * 255)),
            Int(round(c.greenComponent * 255)),
            Int(round(c.blueComponent * 255))
        )
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
        #endif
    }
}
