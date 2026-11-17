import AppKit
import SwiftUI

/// Colors and metrics for the window chrome. The document page itself is always white.
nonisolated enum Theme {
    static let canvas = NSColor(srgbRed: 0xF9 / 255, green: 0xFB / 255, blue: 0xFD / 255, alpha: 1)
    static let toolbarFill = Color(red: 0xED / 255, green: 0xF2 / 255, blue: 0xFA / 255)
    static let primaryText = Color(red: 0x1F / 255, green: 0x1F / 255, blue: 0x1F / 255)
    static let secondaryText = Color(red: 0x44 / 255, green: 0x47 / 255, blue: 0x46 / 255)
    static let hoverFill = Color.black.opacity(0.07)
    static let activeFill = Color(red: 0xD3 / 255, green: 0xE3 / 255, blue: 0xFD / 255)
    static let accent = Color(red: 0x0B / 255, green: 0x57 / 255, blue: 0xD0 / 255)
    static let divider = Color(red: 0xC7 / 255, green: 0xC7 / 255, blue: 0xC7 / 255)
    static let bannerFill = Color(red: 0xFE / 255, green: 0xF7 / 255, blue: 0xE0 / 255)

    static let selection = NSColor(srgbRed: 0xAC / 255, green: 0xCE / 255, blue: 0xF7 / 255, alpha: 1)
    static let rulerTick = NSColor(srgbRed: 0x5F / 255, green: 0x63 / 255, blue: 0x68 / 255, alpha: 1)
    static let rulerMargin = NSColor(srgbRed: 0xE3 / 255, green: 0xE8 / 255, blue: 0xF0 / 255, alpha: 1)
    static let indentMarker = NSColor(srgbRed: 0x1A / 255, green: 0x73 / 255, blue: 0xE8 / 255, alpha: 1)
    static let checkboxFill = NSColor(srgbRed: 0x1A / 255, green: 0x73 / 255, blue: 0xE8 / 255, alpha: 1)

    /// "100%" zoom shows a page at the size a browser does: 96 pixels per inch rather than 72.
    static let baseMagnification: CGFloat = 96.0 / 72.0
    static let zoomLevels: [CGFloat] = [0.5, 0.75, 0.9, 1.0, 1.25, 1.5, 2.0]
}
