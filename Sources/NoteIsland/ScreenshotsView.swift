import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ScreenshotSelectionIntent {
    static func extendsRange(for modifierFlags: NSEvent.ModifierFlags) -> Bool {
        modifierFlags.contains(.shift)
    }

    @MainActor static func extendsRangeForCurrentEvent() -> Bool {
        extendsRange(for: NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags)
    }

    static func togglesItem(for modifierFlags: NSEvent.ModifierFlags) -> Bool {
        modifierFlags.contains(.command) && !modifierFlags.contains(.shift)
    }
}

enum ScreenshotActionPresentation {
    static func title(_ title: String, count: Int) -> String {
        count > 1 ? "\(title) (\(count))" : title
    }
}

struct ScreenshotsView: View {
    @ObservedObject var screenshots: ScreenshotsStore
    @State private var dropTargeted = false

    var body: some View {
        content
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(NoteColor.sky.color, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                    .padding(10)
                    .overlay {
                        Label("Добавить изображение", systemImage: "square.and.arrow.down")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .padding(.horizontal, 16)
                            .frame(height: 38)
                            .background(IslandTheme.surface, in: Capsule())
                    }
            }
        }
        .overlay(alignment: .bottom) {
            if let error = screenshots.errorMessage, !screenshots.screenshots.isEmpty {
                HStack(spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(NoteColor.peach.color)
                    Text(error)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button(action: screenshots.dismissError) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Закрыть сообщение об ошибке")
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 38)
                .background(IslandTheme.surface.opacity(0.98), in: RoundedRectangle(cornerRadius: 12))
                .padding(12)
            }
        }
        .onDrop(
            of: [UTType.fileURL.identifier, UTType.png.identifier, UTType.tiff.identifier, UTType.image.identifier],
            isTargeted: $dropTargeted,
            perform: handleDrop
        )
        .onAppear { screenshots.activate() }
        .onDisappear { screenshots.deactivate() }
    }

    @ViewBuilder
    private var content: some View {
        if let error = screenshots.errorMessage, screenshots.screenshots.isEmpty {
            VStack(spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(NoteColor.peach.color)
                Text(error)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(IslandTheme.secondary)
                    .multilineTextAlignment(.center)
                Button("Повторить") { screenshots.reload() }
                    .buttonStyle(.borderedProminent)
                    .tint(NoteColor.sky.color)
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if screenshots.screenshots.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 30))
                    .foregroundStyle(NoteColor.sky.color)
                Text("Скриншоты из буфера обмена появятся здесь")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text("Также можно перетащить изображение в это окно")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(IslandTheme.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                ZStack {
                    Grid(horizontalSpacing: ScreenshotGridLayout.spacing, verticalSpacing: ScreenshotGridLayout.spacing) {
                        ForEach(Array(screenshotRows.enumerated()), id: \.offset) { _, row in
                            GridRow {
                                ForEach(row) { item in
                                    screenshotThumbnail(for: item)
                                }
                                ForEach(0..<(ScreenshotGridLayout.columns - row.count), id: \.self) { _ in
                                    Color.clear
                                        .frame(maxWidth: .infinity)
                                        .frame(height: ScreenshotGridLayout.cardHeight)
                                }
                            }
                        }
                    }

                    ScreenshotGridInteraction(
                        items: screenshots.screenshots,
                        isSelected: { screenshots.selectedIDs.contains($0.id) },
                        actionCount: { screenshots.actionItems(containing: $0).count },
                        isCopied: { screenshots.copiedIDs.contains($0.id) },
                        selectAction: { item, extending in
                            screenshots.select(item, extendingSelection: extending)
                        },
                        toggleAction: { screenshots.toggleSelection($0) },
                        prepareActions: { screenshots.prepareActions(for: $0) },
                        dragURLs: { screenshots.dragURLs(containing: $0) },
                        openAction: { screenshots.openSelection(containing: $0) },
                        copyAction: { screenshots.copySelection(containing: $0) },
                        editAction: { screenshots.editSelection(containing: $0) },
                        revealAction: { screenshots.revealSelection(containing: $0) },
                        trashAction: { screenshots.trashSelection(containing: $0) }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity)
                .padding(12)
            }
        }
    }

    private var screenshotRows: [[ScreenshotItem]] {
        stride(from: 0, to: screenshots.screenshots.count, by: 4).map { start in
            Array(screenshots.screenshots[start..<min(start + 4, screenshots.screenshots.count)])
        }
    }

    private func screenshotThumbnail(for item: ScreenshotItem) -> some View {
        ScreenshotThumbnail(
            item: item,
            selected: screenshots.selectedIDs.contains(item.id),
            selectionCount: screenshots.actionItems(containing: item).count,
            actionCount: { screenshots.actionItems(containing: item).count },
            copied: screenshots.copiedIDs.contains(item.id),
            selectAction: { extending in
                screenshots.select(item, extendingSelection: extending)
            },
            prepareActions: { screenshots.prepareActions(for: item) },
            dragURLs: { screenshots.dragURLs(containing: item) },
            openAction: { screenshots.openSelection(containing: item) },
            copyAction: { screenshots.copySelection(containing: item) },
            editAction: { screenshots.editSelection(containing: item) },
            revealAction: { screenshots.revealSelection(containing: item) },
            trashAction: { screenshots.trashSelection(containing: item) }
        )
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                    let url: URL?
                    if let value = value as? URL {
                        url = value
                    } else if let data = value as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else {
                        url = nil
                    }
                    if let url {
                        Task { @MainActor in _ = screenshots.importURLs([url]) }
                    }
                }
            } else if let type = [UTType.png, UTType.tiff, UTType.image]
                .first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
                accepted = true
                provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in
                        if let image = NSImage(data: data),
                           let png = SystemScreenshotLibrary.pngData(from: image) {
                            _ = screenshots.importImageData(png)
                        }
                    }
                }
            }
        }
        return accepted
    }
}

private struct ScreenshotThumbnail: View {
    let item: ScreenshotItem
    let selected: Bool
    let selectionCount: Int
    let actionCount: () -> Int
    let copied: Bool
    let selectAction: (Bool) -> Void
    let prepareActions: () -> Void
    let dragURLs: () -> [URL]
    let openAction: () -> Void
    let copyAction: () -> Void
    let editAction: () -> Void
    let revealAction: () -> Void
    let trashAction: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            GeometryReader { geometry in
                ZStack {
                    Color.white.opacity(0.05)
                    if let image = NSImage(contentsOf: item.url) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    } else {
                        Image(systemName: "photo")
                            .foregroundStyle(IslandTheme.secondary)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 88)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(
                        selected ? NoteColor.sky.color : Color.white.opacity(0.1),
                        lineWidth: selected ? 2.5 : 0.75
                    )
            }

            Image(systemName: copied ? "checkmark" : "ellipsis")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(Color.black.opacity(0.62), in: Circle())
            .padding(5)
            .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Скриншот \(item.createdAt.formatted())")
        .accessibilityValue(selected ? "Выбрано" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { selectAction(false) }
    }
}

private struct ScreenshotActionMenuButton: NSViewRepresentable {
    let selectionCount: Int
    let actionCount: () -> Int
    let copied: Bool
    let prepareActions: () -> Void
    let openAction: () -> Void
    let copyAction: () -> Void
    let editAction: () -> Void
    let revealAction: () -> Void
    let trashAction: () -> Void

    func makeNSView(context: Context) -> ScreenshotActionMenuNSButton {
        ScreenshotActionMenuNSButton()
    }

    func updateNSView(_ button: ScreenshotActionMenuNSButton, context: Context) {
        button.selectionCount = selectionCount
        button.actionCount = actionCount
        button.copied = copied
        button.prepareActions = prepareActions
        button.openAction = openAction
        button.copyAction = copyAction
        button.editAction = editAction
        button.revealAction = revealAction
        button.trashAction = trashAction
    }
}

final class ScreenshotActionMenuNSButton: NSButton {
    var selectionCount = 1
    var actionCount: (() -> Int)?
    var copied = false
    var prepareActions: () -> Void = {}
    var openAction: () -> Void = {}
    var copyAction: () -> Void = {}
    var editAction: () -> Void = {}
    var revealAction: () -> Void = {}
    var trashAction: () -> Void = {}
    var clickCoordinator = ScreenshotClickCoordinator.shared

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Действия со скриншотом")
        imagePosition = .imageOnly
        contentTintColor = .white
        toolTip = "Действия со скриншотом"
        setAccessibilityLabel("Действия со скриншотом")
        target = self
        action = #selector(showActions)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        layer?.cornerRadius = 13
    }

    required init?(coder: NSCoder) { nil }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        addMenuItem(actionTitle("Открыть"), symbol: "photo", selector: #selector(openSelected), to: menu)
        addMenuItem(
            copied ? "Скопировано" : actionTitle("Скопировать"),
            symbol: copied ? "checkmark" : "doc.on.doc",
            selector: #selector(copySelected),
            to: menu
        )
        addMenuItem(actionTitle("Редактировать"), symbol: "pencil.and.outline", selector: #selector(editSelected), to: menu)
        addMenuItem(actionTitle("Показать в Finder"), symbol: "folder", selector: #selector(revealSelected), to: menu)
        menu.addItem(.separator())
        addMenuItem(actionTitle("Удалить"), symbol: "trash", selector: #selector(trashSelected), to: menu)
        return menu
    }

    func prepareAndBuildMenu() -> NSMenu {
        clickCoordinator.cancelPendingSelection()
        prepareActions()
        selectionCount = actionCount?() ?? selectionCount
        return buildMenu()
    }

    @objc func showActions() {
        let menu = prepareAndBuildMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.minX, y: bounds.minY - 2), in: self)
    }

    private func actionTitle(_ title: String) -> String {
        ScreenshotActionPresentation.title(title, count: selectionCount)
    }

    private func addMenuItem(_ title: String, symbol: String, selector: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.target = self
        menu.addItem(item)
    }

    @objc private func openSelected() { openAction() }
    @objc private func copySelected() { copyAction() }
    @objc private func editSelected() { editAction() }
    @objc private func revealSelected() { revealAction() }
    @objc private func trashSelected() { trashAction() }
}

enum ScreenshotDragPayload {
    static func pasteboardItems(for urls: [URL]) -> [NSPasteboardItem] {
        urls.map { url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            return item
        }
    }

    static func draggingItems(for urls: [URL], frame: NSRect) -> [NSDraggingItem] {
        zip(urls, pasteboardItems(for: urls)).enumerated().map { index, pair in
            let (url, pasteboardItem) = pair
            let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
            let offset = CGFloat(index) * 3
            draggingItem.setDraggingFrame(
                frame.offsetBy(dx: offset, dy: -offset),
                contents: NSImage(contentsOf: url)
            )
            return draggingItem
        }
    }
}

enum ScreenshotGridLayout {
    static let columns = 4
    static let spacing: CGFloat = 9
    static let cardHeight: CGFloat = 88
    static let actionButtonSize: CGFloat = 36

    static func cardWidth(containerWidth: CGFloat) -> CGFloat {
        max(0, (containerWidth - CGFloat(columns - 1) * spacing) / CGFloat(columns))
    }

    static func itemIndex(at point: CGPoint, containerWidth: CGFloat, itemCount: Int) -> Int? {
        guard point.x >= 0, point.y >= 0, containerWidth > 0 else { return nil }
        let width = cardWidth(containerWidth: containerWidth)
        guard width > 0 else { return nil }
        let columnStride = width + spacing
        let rowStride = cardHeight + spacing
        let column = Int(point.x / columnStride)
        let row = Int(point.y / rowStride)
        guard column >= 0, column < columns else { return nil }
        guard point.x - CGFloat(column) * columnStride <= width else { return nil }
        guard point.y - CGFloat(row) * rowStride <= cardHeight else { return nil }
        let index = row * columns + column
        return index < itemCount ? index : nil
    }

    static func cardFrame(index: Int, containerWidth: CGFloat) -> CGRect {
        let width = cardWidth(containerWidth: containerWidth)
        let column = index % columns
        let row = index / columns
        return CGRect(
            x: CGFloat(column) * (width + spacing),
            y: CGFloat(row) * (cardHeight + spacing),
            width: width,
            height: cardHeight
        )
    }
}

private struct ScreenshotGridInteraction: NSViewRepresentable {
    let items: [ScreenshotItem]
    let isSelected: (ScreenshotItem) -> Bool
    let actionCount: (ScreenshotItem) -> Int
    let isCopied: (ScreenshotItem) -> Bool
    let selectAction: (ScreenshotItem, Bool) -> Void
    let toggleAction: (ScreenshotItem) -> Void
    let prepareActions: (ScreenshotItem) -> Void
    let dragURLs: (ScreenshotItem) -> [URL]
    let openAction: (ScreenshotItem) -> Void
    let copyAction: (ScreenshotItem) -> Void
    let editAction: (ScreenshotItem) -> Void
    let revealAction: (ScreenshotItem) -> Void
    let trashAction: (ScreenshotItem) -> Void

    func makeNSView(context: Context) -> ScreenshotGridInteractionNSView {
        ScreenshotGridInteractionNSView()
    }

    func updateNSView(_ view: ScreenshotGridInteractionNSView, context: Context) {
        view.items = items
        view.isSelected = isSelected
        view.actionCount = actionCount
        view.isCopied = isCopied
        view.selectAction = selectAction
        view.toggleAction = toggleAction
        view.prepareActions = prepareActions
        view.dragURLs = dragURLs
        view.openAction = openAction
        view.copyAction = copyAction
        view.editAction = editAction
        view.revealAction = revealAction
        view.trashAction = trashAction
    }
}

final class ScreenshotGridInteractionNSView: NSView, NSDraggingSource {
    var items: [ScreenshotItem] = []
    var isSelected: (ScreenshotItem) -> Bool = { _ in false }
    var actionCount: (ScreenshotItem) -> Int = { _ in 1 }
    var isCopied: (ScreenshotItem) -> Bool = { _ in false }
    var selectAction: (ScreenshotItem, Bool) -> Void = { _, _ in }
    var toggleAction: (ScreenshotItem) -> Void = { _ in }
    var prepareActions: (ScreenshotItem) -> Void = { _ in }
    var dragURLs: (ScreenshotItem) -> [URL] = { _ in [] }
    var openAction: (ScreenshotItem) -> Void = { _ in }
    var copyAction: (ScreenshotItem) -> Void = { _ in }
    var editAction: (ScreenshotItem) -> Void = { _ in }
    var revealAction: (ScreenshotItem) -> Void = { _ in }
    var trashAction: (ScreenshotItem) -> Void = { _ in }
    var clickCoordinator = ScreenshotClickCoordinator.shared

    private var mouseDownPoint: CGPoint?
    private var mouseDownItem: ScreenshotItem?
    private var pendingSingleSelection = false
    private var pendingActionMenu = false
    private var startedDrag = false
    private var activeMenuItem: ScreenshotItem?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        clickCoordinator.cancelPendingSelection()
        let point = convert(event.locationInWindow, from: nil)
        guard let (index, item) = item(at: point) else {
            resetMouseState()
            return
        }
        mouseDownPoint = point
        mouseDownItem = item
        startedDrag = false
        pendingActionMenu = actionButtonContains(point, itemIndex: index)
        if pendingActionMenu {
            pendingSingleSelection = false
            return
        }
        if event.clickCount == 2 {
            pendingSingleSelection = false
            return
        }
        if ScreenshotSelectionIntent.extendsRange(for: event.modifierFlags) {
            pendingSingleSelection = false
            selectAction(item, true)
        } else if ScreenshotSelectionIntent.togglesItem(for: event.modifierFlags) {
            pendingSingleSelection = false
            toggleAction(item)
        } else if isSelected(item), actionCount(item) > 1 {
            pendingSingleSelection = true
        } else {
            pendingSingleSelection = false
            selectAction(item, false)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !pendingActionMenu, !startedDrag, let mouseDownPoint, let mouseDownItem else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) >= 3 else { return }
        let urls = dragURLs(mouseDownItem)
        guard !urls.isEmpty else { return }
        pendingSingleSelection = false
        startedDrag = true
        let itemIndex = items.firstIndex(where: { $0.id == mouseDownItem.id }) ?? 0
        let session = beginDraggingSession(
            with: ScreenshotDragPayload.draggingItems(
                for: urls,
                frame: ScreenshotGridLayout.cardFrame(index: itemIndex, containerWidth: bounds.width)
            ),
            event: event,
            source: self
        )
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let item = mouseDownItem else {
            resetMouseState()
            return
        }
        if pendingActionMenu && !startedDrag {
            showActions(for: item)
        } else if event.clickCount == 2 && !startedDrag {
            openAction(item)
        } else if pendingSingleSelection && !startedDrag {
            clickCoordinator.schedulePendingSelection { [weak self] in
                self?.selectAction(item, false)
            }
        }
        resetMouseState()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        clickCoordinator.cancelPendingSelection()
        let point = convert(event.locationInWindow, from: nil)
        guard let (_, item) = item(at: point) else { return nil }
        prepareActions(item)
        activeMenuItem = item
        return buildMenu(for: item)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    private func item(at point: CGPoint) -> (Int, ScreenshotItem)? {
        guard let index = ScreenshotGridLayout.itemIndex(
            at: point,
            containerWidth: bounds.width,
            itemCount: items.count
        ) else { return nil }
        return (index, items[index])
    }

    private func actionButtonContains(_ point: CGPoint, itemIndex: Int) -> Bool {
        let frame = ScreenshotGridLayout.cardFrame(index: itemIndex, containerWidth: bounds.width)
        return point.x >= frame.maxX - ScreenshotGridLayout.actionButtonSize
            && point.x <= frame.maxX
            && point.y >= frame.minY
            && point.y <= frame.minY + ScreenshotGridLayout.actionButtonSize
    }

    private func showActions(for item: ScreenshotItem) {
        prepareActions(item)
        activeMenuItem = item
        let index = items.firstIndex(where: { $0.id == item.id }) ?? 0
        let frame = ScreenshotGridLayout.cardFrame(index: index, containerWidth: bounds.width)
        buildMenu(for: item).popUp(
            positioning: nil,
            at: NSPoint(x: frame.maxX - 26, y: frame.minY + ScreenshotGridLayout.actionButtonSize),
            in: self
        )
    }

    private func buildMenu(for item: ScreenshotItem) -> NSMenu {
        let count = actionCount(item)
        let menu = NSMenu()
        addMenuItem(ScreenshotActionPresentation.title("Открыть", count: count), selector: #selector(openSelected), to: menu)
        addMenuItem(
            isCopied(item) ? "Скопировано" : ScreenshotActionPresentation.title("Скопировать", count: count),
            selector: #selector(copySelected),
            to: menu
        )
        addMenuItem(ScreenshotActionPresentation.title("Редактировать", count: count), selector: #selector(editSelected), to: menu)
        addMenuItem(ScreenshotActionPresentation.title("Показать в Finder", count: count), selector: #selector(revealSelected), to: menu)
        menu.addItem(.separator())
        addMenuItem(ScreenshotActionPresentation.title("Удалить", count: count), selector: #selector(trashSelected), to: menu)
        return menu
    }

    private func addMenuItem(_ title: String, selector: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func resetMouseState() {
        mouseDownPoint = nil
        mouseDownItem = nil
        pendingSingleSelection = false
        pendingActionMenu = false
        startedDrag = false
    }

    @objc private func openSelected() {
        if let activeMenuItem { openAction(activeMenuItem) }
    }

    @objc private func copySelected() {
        if let activeMenuItem { copyAction(activeMenuItem) }
    }

    @objc private func editSelected() {
        if let activeMenuItem { editAction(activeMenuItem) }
    }

    @objc private func revealSelected() {
        if let activeMenuItem { revealAction(activeMenuItem) }
    }

    @objc private func trashSelected() {
        if let activeMenuItem { trashAction(activeMenuItem) }
    }
}

private struct ScreenshotDragInteraction: NSViewRepresentable {
    let accessibilityLabel: String
    let selected: Bool
    let selectionCount: Int
    let actionCount: () -> Int
    let copied: Bool
    let selectAction: (Bool) -> Void
    let prepareActions: () -> Void
    let dragURLs: () -> [URL]
    let openAction: () -> Void
    let copyAction: () -> Void
    let editAction: () -> Void
    let revealAction: () -> Void
    let trashAction: () -> Void

    func makeNSView(context: Context) -> ScreenshotDragInteractionNSView {
        ScreenshotDragInteractionNSView()
    }

    func updateNSView(_ view: ScreenshotDragInteractionNSView, context: Context) {
        view.accessibilityText = accessibilityLabel
        view.selected = selected
        view.selectionCount = selectionCount
        view.actionCount = actionCount
        view.copied = copied
        view.selectAction = selectAction
        view.prepareActions = prepareActions
        view.dragURLs = dragURLs
        view.openAction = openAction
        view.copyAction = copyAction
        view.editAction = editAction
        view.revealAction = revealAction
        view.trashAction = trashAction
    }
}

final class ScreenshotDragInteractionNSView: NSView, NSDraggingSource {
    var accessibilityText = "Скриншот" { didSet { setAccessibilityLabel(accessibilityText) } }
    var selected = false { didSet { setAccessibilityValue(selected ? "Выбрано" : "") } }
    var selectionCount = 1
    var actionCount: (() -> Int)?
    var copied = false
    var selectAction: (Bool) -> Void = { _ in }
    var prepareActions: () -> Void = {}
    var dragURLs: () -> [URL] = { [] }
    var openAction: () -> Void = {}
    var copyAction: () -> Void = {}
    var editAction: () -> Void = {}
    var revealAction: () -> Void = {}
    var trashAction: () -> Void = {}
    var clickCoordinator = ScreenshotClickCoordinator.shared

    private var mouseDownPoint: CGPoint?
    private var pendingSingleSelection = false
    private var startedDrag = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        clickCoordinator.cancelPendingSelection()
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        startedDrag = false
        if event.clickCount == 2 {
            pendingSingleSelection = false
            return
        }
        if ScreenshotSelectionIntent.extendsRange(for: event.modifierFlags) {
            pendingSingleSelection = false
            selectAction(true)
        } else if selected && selectionCount > 1 {
            pendingSingleSelection = true
        } else {
            pendingSingleSelection = false
            selectAction(false)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !startedDrag, let mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) >= 3 else { return }
        let urls = dragURLs()
        guard !urls.isEmpty else { return }
        pendingSingleSelection = false
        startedDrag = true
        let session = beginDraggingSession(
            with: ScreenshotDragPayload.draggingItems(for: urls, frame: bounds),
            event: event,
            source: self
        )
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 && !startedDrag {
            openAction()
        } else if pendingSingleSelection && !startedDrag {
            clickCoordinator.schedulePendingSelection { [weak self] in
                self?.selectAction(false)
            }
        }
        mouseDownPoint = nil
        pendingSingleSelection = false
        startedDrag = false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        clickCoordinator.cancelPendingSelection()
        prepareActions()
        selectionCount = actionCount?() ?? selectionCount
        let menu = NSMenu()
        addMenuItem(actionTitle("Открыть"), selector: #selector(openSelected), to: menu)
        addMenuItem(copied ? "Скопировано" : actionTitle("Скопировать"), selector: #selector(copySelected), to: menu)
        addMenuItem(actionTitle("Редактировать"), selector: #selector(editSelected), to: menu)
        addMenuItem(actionTitle("Показать в Finder"), selector: #selector(revealSelected), to: menu)
        menu.addItem(.separator())
        addMenuItem(actionTitle("Удалить"), selector: #selector(trashSelected), to: menu)
        return menu
    }

    override func accessibilityPerformPress() -> Bool {
        selectAction(false)
        return true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    private func actionTitle(_ title: String) -> String {
        ScreenshotActionPresentation.title(title, count: selectionCount)
    }

    private func addMenuItem(_ title: String, selector: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func openSelected() { openAction() }
    @objc private func copySelected() { copyAction() }
    @objc private func editSelected() { editAction() }
    @objc private func revealSelected() { revealAction() }
    @objc private func trashSelected() { trashAction() }
}

@MainActor
final class ScreenshotClickCoordinator {
    static let shared = ScreenshotClickCoordinator(delay: NSEvent.doubleClickInterval)

    private let delay: TimeInterval
    private var pendingWorkItem: DispatchWorkItem?
    private var pendingAction: (() -> Void)?

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func schedulePendingSelection(_ action: @escaping () -> Void) {
        cancelPendingSelection()
        pendingAction = action
        let workItem = DispatchWorkItem { [weak self] in
            self?.performPendingSelection()
        }
        pendingWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func cancelPendingSelection() {
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        pendingAction = nil
    }

    func performPendingSelection() {
        let action = pendingAction
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        pendingAction = nil
        action?()
    }
}
