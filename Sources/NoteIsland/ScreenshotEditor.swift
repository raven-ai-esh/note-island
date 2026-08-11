import AppKit
import SwiftUI

enum ScreenshotEditorMode: String, CaseIterable {
    case draw
    case erase
    case crop
}

struct ScreenshotStroke {
    var points: [CGPoint]
    let color: NSColor
    let width: CGFloat
}

private struct ScreenshotEditorSnapshot {
    let image: NSImage
    let strokes: [ScreenshotStroke]
    let cropSelection: CGRect?
    let mode: ScreenshotEditorMode
}

@MainActor
final class ScreenshotEditorModel: ObservableObject {
    @Published private(set) var revision = 0
    @Published var mode: ScreenshotEditorMode = .draw { didSet { changed() } }
    @Published var drawColor: NSColor = .systemRed { didSet { changed() } }
    @Published var lineWidth: CGFloat = 6

    private(set) var image: NSImage
    private let originalImage: NSImage
    private(set) var strokes: [ScreenshotStroke] = []
    private(set) var cropSelection: CGRect?
    private var history: [ScreenshotEditorSnapshot] = []

    init?(url: URL) {
        guard let image = NSImage(contentsOf: url) else { return nil }
        self.image = image
        originalImage = image.copy() as? NSImage ?? image
    }

    func beginStroke(at point: CGPoint) {
        saveSnapshot()
        strokes.append(ScreenshotStroke(points: [point], color: drawColor, width: lineWidth))
        changed()
    }

    func appendStrokePoint(_ point: CGPoint) {
        guard !strokes.isEmpty else { return }
        strokes[strokes.count - 1].points.append(point)
        changed()
    }

    func setCropSelection(_ rect: CGRect?) {
        cropSelection = rect?.standardized
        changed()
    }

    func beginCropSelection(at point: CGPoint) {
        saveSnapshot()
        cropSelection = CGRect(origin: point, size: .zero)
        changed()
    }

    func beginErasing(at point: CGPoint) {
        saveSnapshot()
        eraseStrokes(near: point)
    }

    func continueErasing(at point: CGPoint) {
        eraseStrokes(near: point)
    }

    func undo() {
        if let previous = history.popLast() {
            image = previous.image
            strokes = previous.strokes
            cropSelection = previous.cropSelection
            mode = previous.mode
        } else if cropSelection != nil {
            cropSelection = nil
        } else if !strokes.isEmpty {
            strokes.removeLast()
        }
        changed()
    }

    func reset() {
        saveSnapshot()
        image = originalImage.copy() as? NSImage ?? originalImage
        strokes.removeAll()
        cropSelection = nil
        changed()
    }

    func rotate(clockwise: Bool) {
        let flattened = renderedImage()
        saveSnapshot()
        image = Self.rotated(flattened, clockwise: clockwise)
        strokes.removeAll()
        cropSelection = nil
        changed()
    }

    func flipHorizontal() {
        let flattened = renderedImage()
        saveSnapshot()
        image = Self.flippedHorizontally(flattened)
        strokes.removeAll()
        cropSelection = nil
        changed()
    }

    func applyCrop() {
        guard let selection = cropSelection?.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)),
              selection.width > 0.02, selection.height > 0.02 else { return }
        let flattened = renderedImage()
        saveSnapshot()
        image = Self.cropped(flattened, normalizedRect: selection)
        strokes.removeAll()
        cropSelection = nil
        mode = .draw
        changed()
    }

    func renderedPNG() -> Data? {
        SystemScreenshotLibrary.pngData(from: renderedImage())
    }

    func renderedImage() -> NSImage {
        let targetSize = imagePixelSize
        return Self.bitmapImage(size: targetSize) {
            image.draw(
                in: NSRect(origin: .zero, size: targetSize),
                from: NSRect(origin: .zero, size: image.size),
                operation: .copy,
                fraction: 1
            )
            for stroke in strokes where !stroke.points.isEmpty {
                let path = NSBezierPath()
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.lineWidth = stroke.width * max(targetSize.width, targetSize.height) / 900
                for (index, point) in stroke.points.enumerated() {
                    let imagePoint = NSPoint(
                        x: point.x * targetSize.width,
                        y: (1 - point.y) * targetSize.height
                    )
                    if index == 0 { path.move(to: imagePoint) } else { path.line(to: imagePoint) }
                }
                stroke.color.setStroke()
                path.stroke()
            }
        }
    }

    private var imagePixelSize: NSSize {
        guard let representation = image.representations.first else { return image.size }
        return NSSize(width: representation.pixelsWide, height: representation.pixelsHigh)
    }

    private func changed() {
        revision &+= 1
    }

    private func saveSnapshot() {
        history.append(ScreenshotEditorSnapshot(
            image: image.copy() as? NSImage ?? image,
            strokes: strokes,
            cropSelection: cropSelection,
            mode: mode
        ))
    }

    private func eraseStrokes(near point: CGPoint) {
        let threshold = max(0.018, lineWidth / 450)
        let oldCount = strokes.count
        strokes.removeAll { stroke in
            guard let first = stroke.points.first else { return false }
            if hypot(first.x - point.x, first.y - point.y) <= threshold { return true }
            for index in 1..<stroke.points.count {
                if Self.distance(
                    from: point,
                    toSegmentFrom: stroke.points[index - 1],
                    to: stroke.points[index]
                ) <= threshold {
                    return true
                }
            }
            return false
        }
        if strokes.count != oldCount { changed() }
    }

    private static func distance(from point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let projection = ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared
        let t = min(max(projection, 0), 1)
        let nearest = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
        return hypot(point.x - nearest.x, point.y - nearest.y)
    }

    private static func rotated(_ source: NSImage, clockwise: Bool) -> NSImage {
        let sourceSize = pixelSize(of: source)
        let resultSize = NSSize(width: sourceSize.height, height: sourceSize.width)
        return bitmapImage(size: resultSize) {
            let transform = NSAffineTransform()
            transform.translateX(by: resultSize.width / 2, yBy: resultSize.height / 2)
            transform.rotate(byDegrees: clockwise ? -90 : 90)
            transform.translateX(by: -sourceSize.width / 2, yBy: -sourceSize.height / 2)
            transform.concat()
            source.draw(in: NSRect(origin: .zero, size: sourceSize))
        }
    }

    private static func flippedHorizontally(_ source: NSImage) -> NSImage {
        let size = pixelSize(of: source)
        return bitmapImage(size: size) {
            let transform = NSAffineTransform()
            transform.translateX(by: size.width, yBy: 0)
            transform.scaleX(by: -1, yBy: 1)
            transform.concat()
            source.draw(in: NSRect(origin: .zero, size: size))
        }
    }

    private static func cropped(_ source: NSImage, normalizedRect: CGRect) -> NSImage {
        let sourceSize = pixelSize(of: source)
        let sourceRect = NSRect(
            x: normalizedRect.minX * sourceSize.width,
            y: (1 - normalizedRect.maxY) * sourceSize.height,
            width: normalizedRect.width * sourceSize.width,
            height: normalizedRect.height * sourceSize.height
        )
        return bitmapImage(size: sourceRect.size) {
            source.draw(
                in: NSRect(origin: .zero, size: sourceRect.size),
                from: sourceRect,
                operation: .copy,
                fraction: 1
            )
        }
    }

    private static func pixelSize(of image: NSImage) -> NSSize {
        guard let representation = image.representations.first else { return image.size }
        return NSSize(width: representation.pixelsWide, height: representation.pixelsHigh)
    }

    private static func bitmapImage(size: NSSize, drawing: () -> Void) -> NSImage {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return NSImage(size: size)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        drawing()
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: NSSize(width: width, height: height))
        result.addRepresentation(bitmap)
        return result
    }
}

@MainActor
final class ScreenshotEditorWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(
        imageURL: URL,
        onSave: @escaping (Data) -> Void,
        onCopy: @escaping (Data) -> Void,
        onClose: @escaping () -> Void = {}
    ) {
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Редактор скриншота — Note Island"
        window.minSize = NSSize(width: 720, height: 520)
        window.center()
        if let model = ScreenshotEditorModel(url: imageURL) {
            window.contentView = NSHostingView(
                rootView: ScreenshotEditorView(
                    model: model,
                    onSave: onSave,
                    onCopy: onCopy,
                    close: { [weak window] in window?.performClose(nil) }
                )
            )
        }
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

@MainActor
final class ScreenshotPreviewWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init?(imageURL: URL, onClose: @escaping () -> Void = {}) {
        guard let image = NSImage(contentsOf: imageURL) else { return nil }
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Скриншот — Note Island"
        window.minSize = NSSize(width: 520, height: 360)
        window.center()
        window.contentView = NSHostingView(rootView: ScreenshotPreviewView(image: image))
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

private struct ScreenshotPreviewView: View {
    let image: NSImage

    var body: some View {
        GeometryReader { geometry in
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .padding(18)
        .background(Color(nsColor: NSColor(calibratedWhite: 0.055, alpha: 1)))
    }
}

private struct ScreenshotEditorView: View {
    @ObservedObject var model: ScreenshotEditorModel
    let onSave: (Data) -> Void
    let onCopy: (Data) -> Void
    let close: () -> Void
    @State private var didSave = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScreenshotEditingCanvas(model: model)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.35))
        }
        .background(Color(nsColor: NSColor(calibratedWhite: 0.06, alpha: 1)))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                editorToolButton(.draw, symbol: "pencil.tip", label: "Рисовать")
                editorToolButton(.erase, symbol: "eraser", label: "Ластик")
                editorToolButton(.crop, symbol: "crop", label: "Обрезать")
            }
            .padding(3)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            if model.mode == .draw {
                ColorPicker(
                    "Цвет",
                    selection: Binding(
                        get: { Color(nsColor: model.drawColor) },
                        set: { model.drawColor = NSColor($0) }
                    )
                )
                .labelsHidden()
                Slider(value: $model.lineWidth, in: 2...24)
                    .frame(width: 90)
            } else if model.mode == .crop {
                Button("Применить обрезку") { model.applyCrop() }
                    .disabled(model.cropSelection == nil)
            }

            Divider().frame(height: 24)
            Button { model.rotate(clockwise: false) } label: { Image(systemName: "rotate.left") }
            Button { model.rotate(clockwise: true) } label: { Image(systemName: "rotate.right") }
            Button { model.flipHorizontal() } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
            Button("Сбросить") { model.reset() }

            Spacer()
            Button {
                if let data = model.renderedPNG() { onCopy(data) }
            } label: {
                Label("Копировать", systemImage: "doc.on.doc")
            }
            Button {
                if let data = model.renderedPNG() {
                    onSave(data)
                    didSave = true
                }
            } label: {
                Label(didSave ? "Сохранено" : "Сохранить", systemImage: didSave ? "checkmark" : "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
            Button("Закрыть", action: close)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .frame(height: 54)
    }

    private func editorToolButton(_ mode: ScreenshotEditorMode, symbol: String, label: String) -> some View {
        Button {
            model.mode = mode
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(model.mode == mode ? Color.white : Color.white.opacity(0.68))
                .frame(width: 32, height: 26)
                .background(
                    model.mode == mode ? NoteColor.sky.color : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

private struct ScreenshotEditingCanvas: NSViewRepresentable {
    @ObservedObject var model: ScreenshotEditorModel

    func makeNSView(context: Context) -> ScreenshotCanvasNSView {
        ScreenshotCanvasNSView(model: model)
    }

    func updateNSView(_ view: ScreenshotCanvasNSView, context: Context) {
        _ = model.revision
        view.model = model
        view.needsDisplay = true
    }
}

@MainActor
private final class ScreenshotCanvasNSView: NSView {
    var model: ScreenshotEditorModel
    private var cropStart: CGPoint?

    init(model: ScreenshotEditorModel) {
        self.model = model
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(calibratedWhite: 0.035, alpha: 1).setFill()
        bounds.fill()
        let rect = imageRect
        NSColor.black.withAlphaComponent(0.55).setFill()
        rect.fill()
        model.image.draw(in: rect)

        for stroke in model.strokes where !stroke.points.isEmpty {
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.lineWidth = stroke.width
            for (index, point) in stroke.points.enumerated() {
                let viewPoint = denormalize(point, in: rect)
                if index == 0 { path.move(to: viewPoint) } else { path.line(to: viewPoint) }
            }
            stroke.color.setStroke()
            path.stroke()
        }

        if let selection = model.cropSelection {
            let cropRect = denormalize(selection, in: rect)
            NSColor.white.withAlphaComponent(0.12).setFill()
            cropRect.fill()
            let border = NSBezierPath(rect: cropRect)
            border.setLineDash([7, 5], count: 2, phase: 0)
            border.lineWidth = 2
            NSColor.white.setStroke()
            border.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard imageRect.contains(point), let normalized = normalize(point, in: imageRect) else { return }
        if model.mode == .draw {
            model.beginStroke(at: normalized)
        } else if model.mode == .erase {
            model.beginErasing(at: normalized)
        } else {
            cropStart = normalized
            model.beginCropSelection(at: normalized)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let normalized = normalize(point, in: imageRect, clamped: true) else { return }
        if model.mode == .draw {
            model.appendStrokePoint(normalized)
        } else if model.mode == .erase {
            model.continueErasing(at: normalized)
        } else if let cropStart {
            model.setCropSelection(CGRect(
                x: cropStart.x,
                y: cropStart.y,
                width: normalized.x - cropStart.x,
                height: normalized.y - cropStart.y
            ))
        }
    }

    override func mouseUp(with event: NSEvent) {
        cropStart = nil
    }

    private var imageRect: CGRect {
        let available = bounds.insetBy(dx: 28, dy: 28)
        guard model.image.size.width > 0, model.image.size.height > 0 else { return available }
        let scale = min(available.width / model.image.size.width, available.height / model.image.size.height)
        let size = CGSize(width: model.image.size.width * scale, height: model.image.size.height * scale)
        return CGRect(
            x: available.midX - size.width / 2,
            y: available.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func normalize(_ point: CGPoint, in rect: CGRect, clamped: Bool = false) -> CGPoint? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        var result = CGPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
        if clamped {
            result.x = min(max(result.x, 0), 1)
            result.y = min(max(result.y, 0), 1)
        } else if !(0...1).contains(result.x) || !(0...1).contains(result.y) {
            return nil
        }
        return result
    }

    private func denormalize(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
    }

    private func denormalize(_ normalized: CGRect, in rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX + normalized.minX * rect.width,
            y: rect.minY + normalized.minY * rect.height,
            width: normalized.width * rect.width,
            height: normalized.height * rect.height
        )
    }
}
