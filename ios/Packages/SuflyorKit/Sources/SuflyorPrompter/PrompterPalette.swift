import SwiftUI

/// The Android app's dark palette with one amber accent (`ui/Theme.kt`).
package enum PrompterPalette {
    package static let background = Color(red: 0x0E / 255, green: 0x0E / 255, blue: 0x11 / 255)
    package static let surface = Color(red: 0x17 / 255, green: 0x17 / 255, blue: 0x1B / 255)
    package static let surfaceHigh = Color(red: 0x20 / 255, green: 0x20 / 255, blue: 0x26 / 255)
    package static let text = Color(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF4 / 255)
    package static let textSecondary = Color(red: 0xA1 / 255, green: 0xA1 / 255, blue: 0xAA / 255)
    package static let textMuted = Color(red: 0x6E / 255, green: 0x6E / 255, blue: 0x77 / 255)
    package static let accent = Color(red: 1, green: 0xB0 / 255, blue: 0x20 / 255)
    package static let onAccent = Color(red: 0x24 / 255, green: 0x18 / 255, blue: 0)
    package static let success = Color(red: 0x46 / 255, green: 0xD7 / 255, blue: 0x78 / 255)
    package static let danger = Color(red: 1, green: 0x5A / 255, blue: 0x5A / 255)
}
