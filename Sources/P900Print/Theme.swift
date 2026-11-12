import SwiftUI

enum ThemeChoice: String, CaseIterable {
    case room, safelight, auto

    var label: String {
        switch self {
        case .room: return "Control Room"
        case .safelight: return "Safelight"
        case .auto: return "Auto (Safelight at night)"
        }
    }
}

struct Palette {
    let bg: Color
    let pane: Color
    let panel: Color
    let tile: Color
    let line: Color
    let accent: Color
    let safelight: Bool

    static let room = Palette(bg: Color(hex: 0x0E1011), pane: Color(hex: 0x0A0C0D), panel: Color(hex: 0x121516),
                              tile: Color(hex: 0x1C2124), line: Color(hex: 0x2A2F33), accent: Color(hex: 0xE5483A),
                              safelight: false)
    static let safelight = Palette(bg: Color(hex: 0x150C0B), pane: Color(hex: 0x0E0807), panel: Color(hex: 0x1B0F0D),
                                   tile: Color(hex: 0x2A1613), line: Color(hex: 0x4A2822), accent: Color(hex: 0xFF5A45),
                                   safelight: true)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
