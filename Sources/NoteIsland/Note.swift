import Foundation

struct Note: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var body: String
    var color: NoteColor
    var isPinned: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = "Новая мысль",
        body: String = "",
        color: NoteColor = .lilac,
        isPinned: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.color = color
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Без названия" : trimmed
    }
}

enum NoteColor: String, Codable, CaseIterable, Sendable {
    case lilac
    case mint
    case peach
    case sky
    case lemon
}
