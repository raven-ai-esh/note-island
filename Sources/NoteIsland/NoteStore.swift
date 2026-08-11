import Combine
import Foundation

@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var notes: [Note]
    @Published var selectedID: Note.ID?
    @Published var query = ""

    private let persistenceURL: URL?

    init(persistenceURL: URL? = NoteStore.defaultPersistenceURL()) {
        self.persistenceURL = persistenceURL
        if let persistenceURL,
           let data = try? Data(contentsOf: persistenceURL),
           let decoded = try? JSONDecoder().decode([Note].self, from: data) {
            notes = decoded
            selectedID = decoded.sorted(by: Self.sortNotes).first?.id
        } else {
            notes = []
            selectedID = nil
        }
    }

    var visibleNotes: [Note] {
        let sorted = notes.sorted(by: Self.sortNotes)
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return sorted }
        return sorted.filter {
            $0.title.localizedCaseInsensitiveContains(normalizedQuery)
                || $0.body.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    var selectedNote: Note? {
        guard let selectedID else { return nil }
        return notes.first(where: { $0.id == selectedID })
    }

    @discardableResult
    func addNote(now: Date = Date()) -> Note.ID {
        let palette = NoteColor.allCases
        let color = palette[notes.count % palette.count]
        let note = Note(color: color, createdAt: now, updatedAt: now)
        notes.append(note)
        selectedID = note.id
        query = ""
        persist()
        return note.id
    }

    func updateSelected(title: String? = nil, body: String? = nil, now: Date = Date()) {
        guard let selectedID, let index = notes.firstIndex(where: { $0.id == selectedID }) else { return }
        if let title { notes[index].title = title }
        if let body { notes[index].body = body }
        notes[index].updatedAt = now
        persist()
    }

    func select(_ id: Note.ID) {
        guard notes.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    func togglePin(_ id: Note.ID, now: Date = Date()) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].isPinned.toggle()
        notes[index].updatedAt = now
        persist()
    }

    func setColor(_ color: NoteColor, for id: Note.ID, now: Date = Date()) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].color = color
        notes[index].updatedAt = now
        persist()
    }

    func delete(_ id: Note.ID) {
        notes.removeAll(where: { $0.id == id })
        if selectedID == id {
            selectedID = notes.sorted(by: Self.sortNotes).first?.id
        }
        persist()
    }

    func exportSnapshot() throws -> Data {
        try JSONEncoder().encode(notes)
    }

    private func persist() {
        guard let persistenceURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(notes)
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            NSLog("NoteIsland could not save notes: %@", error.localizedDescription)
        }
    }

    private static func sortNotes(_ lhs: Note, _ rhs: Note) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
        return lhs.updatedAt > rhs.updatedAt
    }

    nonisolated private static func defaultPersistenceURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("NoteIsland", isDirectory: true)
            .appendingPathComponent("notes.json")
    }
}
