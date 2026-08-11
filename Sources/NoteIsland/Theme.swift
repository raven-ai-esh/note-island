import SwiftUI

extension NoteColor {
    var color: Color {
        switch self {
        case .lilac: Color(red: 0.72, green: 0.57, blue: 1.00)
        case .mint: Color(red: 0.39, green: 0.91, blue: 0.72)
        case .peach: Color(red: 1.00, green: 0.60, blue: 0.46)
        case .sky: Color(red: 0.38, green: 0.75, blue: 1.00)
        case .lemon: Color(red: 0.98, green: 0.84, blue: 0.36)
        }
    }
}

enum IslandTheme {
    static let background = Color(red: 0.045, green: 0.047, blue: 0.06)
    static let surface = Color.white.opacity(0.075)
    static let secondary = Color.white.opacity(0.57)
}
