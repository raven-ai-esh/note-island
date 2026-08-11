import AppKit
import Combine
import CryptoKit
import Foundation
import UniformTypeIdentifiers

struct ScreenshotItem: Identifiable, Equatable, Sendable {
    var id: String { url.standardizedFileURL.path }
    let url: URL
    let createdAt: Date
    let fileSize: Int64
}

@MainActor
protocol ScreenshotLibraryProviding: AnyObject {
    var directory: URL { get }
    func screenshots() throws -> [ScreenshotItem]
    @discardableResult func storePNG(_ data: Data) throws -> ScreenshotItem
    @discardableResult func importImage(at url: URL) throws -> ScreenshotItem
    func replace(_ url: URL, withPNG data: Data) throws
    @discardableResult func trash(_ url: URL) throws -> URL?
}

@MainActor
protocol ScreenshotPasteboardProviding: AnyObject {
    var changeCount: Int { get }
    func readImagePNG() -> Data?
    func writeImages(at urls: [URL]) -> Bool
}

@MainActor
protocol ScreenshotEditorPresenting: AnyObject {
    func open(imageURL: URL)
    func present(
        imageURL: URL,
        onSave: @escaping (Data) -> Void,
        onCopy: @escaping (Data) -> Void
    )
}

@MainActor
protocol ScreenshotFileRevealing: AnyObject {
    func reveal(_ urls: [URL])
}

@MainActor
final class SystemScreenshotEditorPresenter: ScreenshotEditorPresenting {
    private var controllers: [UUID: ScreenshotEditorWindowController] = [:]
    private var previewControllers: [UUID: ScreenshotPreviewWindowController] = [:]
    var activePreviewWindow: NSWindow? { previewControllers.values.first?.window }
    var activePreviewWindows: [NSWindow] { previewControllers.values.compactMap(\.window) }
    var activeEditorWindows: [NSWindow] { controllers.values.compactMap(\.window) }

    func open(imageURL: URL) {
        let id = UUID()
        guard let controller = ScreenshotPreviewWindowController(
            imageURL: imageURL,
            onClose: { [weak self] in self?.previewControllers[id] = nil }
        ) else { return }
        previewControllers[id] = controller
        controller.showWindow()
    }

    func present(
        imageURL: URL,
        onSave: @escaping (Data) -> Void,
        onCopy: @escaping (Data) -> Void
    ) {
        let id = UUID()
        let controller = ScreenshotEditorWindowController(
            imageURL: imageURL,
            onSave: onSave,
            onCopy: onCopy,
            onClose: { [weak self] in self?.controllers[id] = nil }
        )
        controllers[id] = controller
        controller.showWindow()
    }
}

@MainActor
final class SystemScreenshotFileRevealer: ScreenshotFileRevealing {
    func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

@MainActor
final class SystemScreenshotPasteboard: ScreenshotPasteboardProviding {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    func readImagePNG() -> Data? {
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    func writeImages(at urls: [URL]) -> Bool {
        let images = urls.compactMap(NSImage.init(contentsOf:))
        guard images.count == urls.count, !images.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects(images)
    }
}

@MainActor
final class SystemScreenshotLibrary: ScreenshotLibraryProviding {
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func screenshots() throws -> [ScreenshotItem] {
        let keys: Set<URLResourceKey> = [.contentTypeKey, .creationDateKey, .fileSizeKey, .isRegularFileKey]
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        .compactMap { url in
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true,
                  values?.contentType?.conforms(to: .image) == true else { return nil }
            return ScreenshotItem(
                url: url,
                createdAt: values?.creationDate ?? .distantPast,
                fileSize: Int64(values?.fileSize ?? 0)
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func storePNG(_ data: Data) throws -> ScreenshotItem {
        guard NSImage(data: data) != nil else { throw ScreenshotLibraryError.invalidImage }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let existingURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        for existingURL in existingURLs where existingURL.pathExtension.lowercased() == "png" {
            guard let existingData = try? Data(contentsOf: existingURL) else { continue }
            let existingDigest = SHA256.hash(data: existingData).map { String(format: "%02x", $0) }.joined()
            if existingDigest == digest { return try item(for: existingURL) }
        }
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("capture-\(timestamp)-\(UUID().uuidString).png")
        try data.write(to: url, options: .atomic)
        return try item(for: url)
    }

    @discardableResult
    func importImage(at url: URL) throws -> ScreenshotItem {
        guard let image = NSImage(contentsOf: url),
              let data = Self.pngData(from: image) else { throw ScreenshotLibraryError.invalidImage }
        return try storePNG(data)
    }

    func replace(_ url: URL, withPNG data: Data) throws {
        guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              NSImage(data: data) != nil else { throw ScreenshotLibraryError.invalidImage }
        try data.write(to: url, options: .atomic)
    }

    @discardableResult
    func trash(_ url: URL) throws -> URL? {
        guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else {
            throw ScreenshotLibraryError.outsideLibrary
        }
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return resultingURL as URL?
    }

    private func item(for url: URL) throws -> ScreenshotItem {
        let values = try url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
        return ScreenshotItem(
            url: url,
            createdAt: values.creationDate ?? Date(),
            fileSize: Int64(values.fileSize ?? 0)
        )
    }

    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NoteIsland/Screenshots", isDirectory: true)
    }
}

enum ScreenshotLibraryError: LocalizedError {
    case invalidImage
    case outsideLibrary

    var errorDescription: String? {
        switch self {
        case .invalidImage: "Это не поддерживаемое изображение."
        case .outsideLibrary: "Нельзя удалить файл за пределами библиотеки Note Island."
        }
    }
}

@MainActor
final class ScreenshotsStore: ObservableObject {
    @Published private(set) var screenshots: [ScreenshotItem] = []
    @Published private(set) var selectedIDs: Set<String> = []
    @Published private var primarySelectedID: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var copiedID: String?
    @Published private(set) var copiedIDs: Set<String> = []
    @Published private(set) var isDropTargeted = false

    private let library: ScreenshotLibraryProviding
    private let pasteboard: ScreenshotPasteboardProviding
    private let editorPresenter: ScreenshotEditorPresenting
    private let fileRevealer: ScreenshotFileRevealing
    private var lastPasteboardChange: Int
    private var timer: AnyCancellable?
    private var selectionAnchorID: String?

    var selectedID: String? {
        get { primarySelectedID }
        set { setSingleSelection(id: newValue) }
    }

    init(
        library: ScreenshotLibraryProviding = SystemScreenshotLibrary(),
        pasteboard: ScreenshotPasteboardProviding = SystemScreenshotPasteboard(),
        editorPresenter: ScreenshotEditorPresenting = SystemScreenshotEditorPresenter(),
        fileRevealer: ScreenshotFileRevealing = SystemScreenshotFileRevealer()
    ) {
        self.library = library
        self.pasteboard = pasteboard
        self.editorPresenter = editorPresenter
        self.fileRevealer = fileRevealer
        lastPasteboardChange = pasteboard.changeCount
        reload()
        startClipboardMonitoring()
    }

    var selectedScreenshot: ScreenshotItem? {
        screenshots.first(where: { $0.id == selectedID })
    }

    var selectedScreenshots: [ScreenshotItem] {
        screenshots.filter { selectedIDs.contains($0.id) }
    }

    func open(_ item: ScreenshotItem) {
        guard let current = currentItem(matching: item) else { return }
        selectedID = current.id
        editorPresenter.open(imageURL: current.url)
    }

    func prepareActions(for item: ScreenshotItem) {
        guard let current = currentItem(matching: item),
              !selectedIDs.contains(current.id) else { return }
        setSingleSelection(id: current.id)
    }

    func actionItems(containing item: ScreenshotItem) -> [ScreenshotItem] {
        guard let current = currentItem(matching: item) else { return [] }
        return selectedIDs.contains(current.id) ? selectedScreenshots : [current]
    }

    func openSelection(containing item: ScreenshotItem) {
        for target in actionItems(containing: item) {
            editorPresenter.open(imageURL: target.url)
        }
    }

    func dragURLs(containing item: ScreenshotItem) -> [URL] {
        actionItems(containing: item).map(\.url)
    }

    func select(_ item: ScreenshotItem, extendingSelection: Bool = false) {
        guard let current = currentItem(matching: item) else { return }
        guard extendingSelection else {
            setSingleSelection(id: current.id)
            return
        }
        let anchorID = selectionAnchorID ?? primarySelectedID ?? current.id
        guard let anchorIndex = screenshots.firstIndex(where: { $0.id == anchorID }),
              let itemIndex = screenshots.firstIndex(where: { $0.id == current.id }) else {
            setSingleSelection(id: current.id)
            return
        }
        let bounds = min(anchorIndex, itemIndex)...max(anchorIndex, itemIndex)
        selectedIDs = Set(bounds.map { screenshots[$0].id })
        primarySelectedID = current.id
        selectionAnchorID = anchorID
    }

    func toggleSelection(_ item: ScreenshotItem) {
        guard let current = currentItem(matching: item) else { return }
        if selectedIDs.remove(current.id) != nil {
            if primarySelectedID == current.id {
                primarySelectedID = screenshots.first(where: { selectedIDs.contains($0.id) })?.id
            }
            selectionAnchorID = primarySelectedID
            return
        }
        selectedIDs.insert(current.id)
        primarySelectedID = current.id
        selectionAnchorID = current.id
    }

    private func currentItem(matching item: ScreenshotItem) -> ScreenshotItem? {
        screenshots.first(where: { $0.id == item.id })
    }

    func activate() {
        reload()
        captureClipboardIfChanged()
    }

    func deactivate() {}

    func reload() {
        do {
            let updated = try library.screenshots()
            screenshots = updated
            errorMessage = nil
            let validIDs = Set(updated.map(\.id))
            let retainedSelection = selectedIDs.intersection(validIDs)
            if retainedSelection.isEmpty {
                setSingleSelection(id: updated.first?.id)
            } else {
                selectedIDs = retainedSelection
                if primarySelectedID.map({ !retainedSelection.contains($0) }) ?? true {
                    primarySelectedID = updated.first(where: { retainedSelection.contains($0.id) })?.id
                }
                if selectionAnchorID.map({ !validIDs.contains($0) }) ?? true {
                    selectionAnchorID = primarySelectedID
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            screenshots = []
            setSingleSelection(id: nil)
        }
    }

    func captureClipboardIfChanged() {
        let currentChange = pasteboard.changeCount
        guard currentChange != lastPasteboardChange else { return }
        lastPasteboardChange = currentChange
        guard let data = pasteboard.readImagePNG() else { return }
        do {
            let item = try library.storePNG(data)
            reload()
            selectedID = item.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copySelected() {
        copy(selectedScreenshots)
    }

    func copy(_ item: ScreenshotItem) {
        copy([item])
    }

    func copySelection(containing item: ScreenshotItem) {
        copy(actionItems(containing: item))
    }

    private func copy(_ items: [ScreenshotItem]) {
        guard !items.isEmpty else { return }
        guard pasteboard.writeImages(at: items.map(\.url)) else {
            errorMessage = "Не удалось скопировать выбранные скриншоты."
            return
        }
        errorMessage = nil
        lastPasteboardChange = pasteboard.changeCount
        copiedIDs = Set(items.map(\.id))
        copiedID = items.count == 1 ? items[0].id : nil
        let copied = copiedIDs
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard self?.copiedIDs == copied else { return }
            self?.copiedIDs = []
            self?.copiedID = nil
        }
    }

    func editSelected() {
        edit(selectedScreenshots, preserveSelection: true)
    }

    func edit(_ item: ScreenshotItem) {
        selectedID = item.id
        edit([item], preserveSelection: false)
    }

    func editSelection(containing item: ScreenshotItem) {
        edit(actionItems(containing: item), preserveSelection: true)
    }

    private func edit(_ items: [ScreenshotItem], preserveSelection: Bool) {
        for item in items {
            presentEditor(for: item, preserveSelection: preserveSelection)
        }
    }

    private func presentEditor(for item: ScreenshotItem, preserveSelection: Bool) {
        editorPresenter.present(
            imageURL: item.url,
            onSave: { [weak self] data in
                guard let self else { return }
                do {
                    try self.library.replace(item.url, withPNG: data)
                    self.reload()
                    if !preserveSelection { self.selectedID = item.id }
                } catch {
                    self.errorMessage = error.localizedDescription
                }
            },
            onCopy: { [weak self] data in
                guard let self else { return }
                do {
                    let temporary = FileManager.default.temporaryDirectory
                        .appendingPathComponent("note-island-editor-\(UUID().uuidString).png")
                    try data.write(to: temporary, options: .atomic)
                    _ = self.pasteboard.writeImages(at: [temporary])
                    self.lastPasteboardChange = self.pasteboard.changeCount
                    try? FileManager.default.removeItem(at: temporary)
                } catch {
                    self.errorMessage = error.localizedDescription
                }
            }
        )
    }

    func trashSelected() {
        trash(selectedScreenshots)
    }

    func trash(_ item: ScreenshotItem) {
        trash([item])
    }

    func trashSelection(containing item: ScreenshotItem) {
        trash(actionItems(containing: item))
    }

    private func trash(_ items: [ScreenshotItem]) {
        guard !items.isEmpty else { return }
        var failures: [String] = []
        for item in items {
            do {
                try library.trash(item.url)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        reload()
        if !failures.isEmpty {
            errorMessage = Array(Set(failures)).sorted().joined(separator: "\n")
        }
    }

    func reveal(_ item: ScreenshotItem) {
        fileRevealer.reveal([item.url])
    }

    func revealSelection(containing item: ScreenshotItem) {
        fileRevealer.reveal(actionItems(containing: item).map(\.url))
    }

    func importURLs(_ urls: [URL]) -> Bool {
        var imported = false
        for url in urls {
            do {
                let item = try library.importImage(at: url)
                selectedID = item.id
                imported = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        if imported { reload() }
        return imported
    }

    func importImageData(_ data: Data) -> Bool {
        do {
            let item = try library.storePNG(data)
            reload()
            selectedID = item.id
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func setDropTargeted(_ value: Bool) {
        isDropTargeted = value
    }

    func dismissError() {
        errorMessage = nil
    }

    private func startClipboardMonitoring() {
        timer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.captureClipboardIfChanged() }
    }

    private func setSingleSelection(id: String?) {
        primarySelectedID = id
        selectedIDs = id.map { [$0] } ?? []
        selectionAnchorID = id
    }
}
