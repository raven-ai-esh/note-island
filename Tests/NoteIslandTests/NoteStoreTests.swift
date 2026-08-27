import XCTest
import AppKit
import CoreText
import SwiftUI
@testable import NoteIsland

@MainActor
final class NoteStoreTests: XCTestCase {
    func testEditorPanelCanBecomeKeyForTextInput() {
        let panel = IslandPanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.styleMask.contains(.nonactivatingPanel))
    }

    func testAutomaticAppendBufferMovesCursorToNewLineWithoutDuplicatingIt() {
        XCTAssertEqual(SynchronousTextView.automaticAppendBuffer(for: "Первая строка"), "Первая строка\n")
        XCTAssertEqual(SynchronousTextView.automaticAppendBuffer(for: "Первая строка\n"), "Первая строка\n")
        XCTAssertEqual(SynchronousTextView.automaticAppendBuffer(for: ""), "")
    }

    func testMarkdownVisibilityDoesNotDuplicateTranslatorMirrorText() {
        XCTAssertEqual(
            SynchronousTextView.resolvedTextColor(isEditing: false, rendersMarkdown: false),
            NSColor.clear
        )
        XCTAssertGreaterThan(
            SynchronousTextView.resolvedTextColor(isEditing: false, rendersMarkdown: true).alphaComponent,
            0.8
        )
        XCTAssertGreaterThan(
            SynchronousTextView.resolvedTextColor(isEditing: true, rendersMarkdown: false).alphaComponent,
            0.8
        )
    }

    func testLiveMarkdownStylesCommonSyntaxWithoutChangingStoredSource() throws {
        let source = """
        # Заголовок
        Текст с **жирным**, *курсивом*, ~~зачёркнутым~~ и `кодом`.
        - [x] Готовая задача
        > Цитата
        [Ссылка](https://example.com)
        """

        let styled = LiveMarkdownStyler.attributedString(for: source)

        XCTAssertEqual(styled.string, source)
        let nsSource = source as NSString
        let headingRange = nsSource.range(of: "Заголовок")
        let boldRange = nsSource.range(of: "жирным")
        let italicRange = nsSource.range(of: "курсивом")
        let strikeRange = nsSource.range(of: "зачёркнутым")
        let codeRange = nsSource.range(of: "кодом")
        let taskRange = nsSource.range(of: "Готовая задача")
        let linkRange = nsSource.range(of: "Ссылка")

        let headingFont = try XCTUnwrap(styled.attribute(.font, at: headingRange.location, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(headingFont.pointSize, LiveMarkdownStyler.bodyFont.pointSize)
        XCTAssertTrue(NSFontManager.shared.traits(of: headingFont).contains(.boldFontMask))

        let boldFont = try XCTUnwrap(styled.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask))
        let italicFont = try XCTUnwrap(styled.attribute(.font, at: italicRange.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: italicFont).contains(.italicFontMask))
        XCTAssertEqual(
            styled.attribute(.strikethroughStyle, at: strikeRange.location, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )

        let codeFont = try XCTUnwrap(styled.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: codeFont).contains(.fixedPitchFontMask))
        XCTAssertNotNil(styled.attribute(.backgroundColor, at: codeRange.location, effectiveRange: nil))
        XCTAssertEqual(
            styled.attribute(.strikethroughStyle, at: taskRange.location, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )
        XCTAssertEqual(
            styled.attribute(.underlineStyle, at: linkRange.location, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )
    }

    func testCollapsedMarkdownHidesLinkDestinationAndUsesRenderedListMarkers() throws {
        let source = """
        - [Документация](https://example.com/very/long/path)
        - Пункт
        - [ ] Задача
        - [x] Готово
        """
        let styled = LiveMarkdownStyler.attributedString(for: source)
        let text = source as NSString
        let linkLabel = text.range(of: "Документация")
        let linkDestination = text.range(of: "https://example.com/very/long/path")
        let bullet = text.range(of: "- Пункт")
        let uncheckedTask = text.range(of: "- [ ] Задача")
        let checkedTask = text.range(of: "- [x] Готово")

        XCTAssertNil(styled.attribute(.markdownHiddenGlyph, at: linkLabel.location, effectiveRange: nil))
        XCTAssertNotNil(styled.attribute(.markdownHiddenGlyph, at: linkDestination.location, effectiveRange: nil))
        XCTAssertEqual(
            styled.attribute(.markdownReplacementGlyph, at: bullet.location, effectiveRange: nil) as? String,
            "•"
        )
        XCTAssertEqual(
            styled.attribute(.markdownReplacementGlyph, at: uncheckedTask.location, effectiveRange: nil) as? String,
            "□"
        )
        XCTAssertEqual(
            styled.attribute(.markdownReplacementGlyph, at: checkedTask.location, effectiveRange: nil) as? String,
            "☑"
        )
        XCTAssertNotNil(
            styled.attribute(.markdownTaskToggleRange, at: uncheckedTask.location, effectiveRange: nil)
        )
        let paragraph = try XCTUnwrap(
            styled.attribute(.paragraphStyle, at: bullet.location, effectiveRange: nil) as? NSParagraphStyle
        )
        XCTAssertGreaterThan(paragraph.firstLineHeadIndent, 0)
        XCTAssertGreaterThan(paragraph.headIndent, paragraph.firstLineHeadIndent)
        XCTAssertNil(
            styled.attribute(
                .markdownHiddenGlyph,
                at: bullet.location + 1,
                effectiveRange: nil
            ),
            "Rendered list marker must retain one visible gap before its content"
        )
    }

    func testActiveMarkdownParagraphRevealsSourceForEditing() {
        let source = "[Документация](https://example.com)\n- [ ] Другая строка"
        let text = source as NSString
        let linkParagraph = text.paragraphRange(for: text.range(of: "Документация"))

        let styled = LiveMarkdownStyler.attributedString(
            for: source,
            activeParagraphRange: linkParagraph
        )

        let destination = text.range(of: "https://example.com")
        let task = text.range(of: "- [ ] Другая строка")
        XCTAssertNil(styled.attribute(.markdownHiddenGlyph, at: destination.location, effectiveRange: nil))
        XCTAssertEqual(
            styled.attribute(.markdownReplacementGlyph, at: task.location, effectiveRange: nil) as? String,
            "□"
        )
    }

    func testUncheckedTaskReplacementHasARealGlyphInEditorFont() {
        var character = "□".utf16.first!
        var glyph = CGGlyph()

        XCTAssertTrue(
            CTFontGetGlyphsForCharacters(
                LiveMarkdownStyler.bodyFont as CTFont,
                &character,
                &glyph,
                1
            )
        )
        XCTAssertNotEqual(glyph, 0)
    }

    func testLayoutManagerActuallyCollapsesHiddenMarkdownGlyphs() {
        let source = "[Короткая ссылка](https://example.com/a/very/long/destination/that/would/wrap)"
        let textView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 190, height: 120))
        let coordinator = SynchronousTextView.Coordinator(
            text: .constant(source),
            isEditing: .constant(false),
            rendersMarkdown: true
        )
        textView.delegate = coordinator
        textView.layoutManager?.delegate = coordinator
        textView.string = source
        textView.textContainer?.containerSize = NSSize(width: 190, height: 1_000)
        textView.textContainer?.widthTracksTextView = true

        LiveMarkdownStyler.apply(to: textView)
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return XCTFail("Missing TextKit stack")
        }
        layoutManager.ensureLayout(for: textContainer)

        let destinationLocation = (source as NSString).range(of: "https://").location
        let hiddenGlyph = layoutManager.glyphIndexForCharacter(at: destinationLocation)
        XCTAssertTrue(layoutManager.propertyForGlyph(at: hiddenGlyph).contains(.null))
        XCTAssertLessThan(layoutManager.usedRect(for: textContainer).height, 35)
    }

    func testRenderedTaskCheckboxClickTogglesRawMarkdownAndUndo() {
        var source = "- [ ] Проверить"
        var isEditing = false
        let textView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 260, height: 80))
        let coordinator = SynchronousTextView.Coordinator(
            text: Binding(get: { source }, set: { source = $0 }),
            isEditing: Binding(get: { isEditing }, set: { isEditing = $0 }),
            rendersMarkdown: true
        )
        textView.delegate = coordinator
        textView.layoutManager?.delegate = coordinator
        textView.allowsUndo = true
        textView.string = source
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = textView
        LiveMarkdownStyler.apply(to: textView)
        let markerRange = (source as NSString).range(of: "- [ ] ")

        XCTAssertTrue(textView.toggleTask(at: markerRange))
        XCTAssertEqual(source, "- [x] Проверить")
        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(
            textView.textStorage?.attribute(.markdownReplacementGlyph, at: 0, effectiveRange: nil) as? String,
            "☑"
        )

        window.undoManager?.undo()
        XCTAssertEqual(textView.string, "- [ ] Проверить")
        XCTAssertEqual(source, "- [ ] Проверить")
    }

    func testFencedCodeRemainsMonospacedAndDoesNotRenderInnerMarkdown() throws {
        let source = """
        ```swift
        let text = "**не жирный**"
        ```
        """
        let styled = LiveMarkdownStyler.attributedString(for: source)
        let innerRange = (source as NSString).range(of: "не жирный")
        let font = try XCTUnwrap(styled.attribute(.font, at: innerRange.location, effectiveRange: nil) as? NSFont)

        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.fixedPitchFontMask))
        XCTAssertFalse(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        XCTAssertNotNil(styled.attribute(.backgroundColor, at: innerRange.location, effectiveRange: nil))
    }

    func testApplyingLiveMarkdownPreservesCaretAndSelection() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        textView.string = "# Заголовок\nТекст с **жирным**"
        let selection = NSRange(location: 16, length: 5)
        textView.setSelectedRange(selection)

        LiveMarkdownStyler.apply(to: textView)

        XCTAssertEqual(textView.string, "# Заголовок\nТекст с **жирным**")
        XCTAssertEqual(textView.selectedRange(), selection)
    }

    func testDraggingSelectionWithinParagraphDoesNotRepeatedlyRestyleMarkdown() {
        let source = "Первый **абзац** для выделения\nВторой [абзац](https://example.com)"
        let textView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 160))
        let coordinator = SynchronousTextView.Coordinator(
            text: .constant(source),
            isEditing: .constant(true),
            rendersMarkdown: true
        )
        textView.delegate = coordinator
        textView.layoutManager?.delegate = coordinator
        textView.string = source
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = textView
        window.makeFirstResponder(textView)

        textView.setSelectedRange(NSRange(location: 2, length: 0))
        coordinator.refreshMarkdown(in: textView)
        let initialApplications = coordinator.markdownApplicationCount
        for length in 1...20 {
            textView.setSelectedRange(NSRange(location: 2, length: length))
            coordinator.textViewDidChangeSelection(
                Notification(name: NSTextView.didChangeSelectionNotification, object: textView)
            )
        }

        XCTAssertEqual(coordinator.markdownApplicationCount, initialApplications)

        let secondParagraph = (source as NSString).range(of: "Второй").location
        textView.setSelectedRange(NSRange(location: secondParagraph, length: 3))
        coordinator.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: textView)
        )
        XCTAssertEqual(coordinator.markdownApplicationCount, initialApplications + 1)
    }

    func testUnrelatedViewUpdatePreservesMarkdownColorsWithoutRestyling() throws {
        let source = "Открыть [документацию](https://example.com)"
        let textView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 100))
        let coordinator = SynchronousTextView.Coordinator(
            text: .constant(source),
            isEditing: .constant(false),
            rendersMarkdown: true
        )
        textView.delegate = coordinator
        textView.string = source
        coordinator.refreshMarkdown(in: textView, revealActiveParagraph: false)
        let linkLocation = (source as NSString).range(of: "документацию").location
        let colorBefore = try XCTUnwrap(
            textView.textStorage?.attribute(.foregroundColor, at: linkLocation, effectiveRange: nil) as? NSColor
        )
        let initialApplications = coordinator.markdownApplicationCount

        SynchronousTextView.synchronizePresentation(
            in: textView,
            coordinator: coordinator,
            displayText: source,
            isEditing: true,
            rendersMarkdown: true
        )

        let colorAfter = try XCTUnwrap(
            textView.textStorage?.attribute(.foregroundColor, at: linkLocation, effectiveRange: nil) as? NSColor
        )
        XCTAssertEqual(colorAfter, colorBefore)
        XCTAssertNotEqual(colorAfter, NSColor.white.withAlphaComponent(0.88))
        XCTAssertEqual(coordinator.markdownApplicationCount, initialApplications)
    }

    func testIncompleteMarkdownStaysEditableAndRepeatedStylingIsStable() throws {
        let source = "#\nНезакрытые **жирный и `код"
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        textView.string = source
        textView.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))

        LiveMarkdownStyler.apply(to: textView)
        LiveMarkdownStyler.apply(to: textView)

        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(textView.selectedRange().location, (source as NSString).length)
        let boldLocation = (source as NSString).range(of: "жирный").location
        let font = try XCTUnwrap(textView.textStorage?.attribute(.font, at: boldLocation, effectiveRange: nil) as? NSFont)
        XCTAssertFalse(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        XCTAssertNil(textView.textStorage?.attribute(.backgroundColor, at: boldLocation, effectiveRange: nil))
    }

    func testMarkdownSourceEditorPreservesHorizontalRuleAndLiteralPunctuation() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        SynchronousTextView.configureSourceEditingBehavior(for: textView)

        XCTAssertFalse(textView.isAutomaticDashSubstitutionEnabled)
        XCTAssertFalse(textView.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(textView.isAutomaticTextReplacementEnabled)
        XCTAssertFalse(textView.isAutomaticSpellingCorrectionEnabled)
        XCTAssertFalse(textView.smartInsertDeleteEnabled)

        textView.insertText("-", replacementRange: NSRange(location: 0, length: 0))
        textView.insertText("-", replacementRange: NSRange(location: 1, length: 0))
        textView.insertText("-", replacementRange: NSRange(location: 2, length: 0))
        XCTAssertEqual(textView.string, "---")

        LiveMarkdownStyler.apply(to: textView)
        XCTAssertEqual(textView.string, "---")
        XCTAssertEqual(
            textView.textStorage?.attribute(.strikethroughStyle, at: 1, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )
    }

    func testMarkdownAttributeRefreshDoesNotReplaceRawTextUndoAction() {
        final class UndoProbe: NSObject {
            var didUndo = false
        }

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        textView.allowsUndo = true
        textView.string = "**текст**"
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = textView
        let probe = UndoProbe()
        window.undoManager?.registerUndo(withTarget: probe) { target in
            target.didUndo = true
        }

        LiveMarkdownStyler.apply(to: textView)
        window.undoManager?.undo()

        XCTAssertTrue(probe.didUndo)
        XCTAssertEqual(textView.string, "**текст**")
    }

    func testLiveMarkdownUpdatesBindingAndFormattingOnSameEditPass() throws {
        var source = "Обычный текст"
        var isEditing = false
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        textView.string = "# Новый заголовок"
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        let coordinator = SynchronousTextView.Coordinator(
            text: Binding(get: { source }, set: { source = $0 }),
            isEditing: Binding(get: { isEditing }, set: { isEditing = $0 }),
            rendersMarkdown: true
        )

        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        XCTAssertEqual(source, "# Новый заголовок")
        XCTAssertTrue(isEditing)
        XCTAssertEqual(textView.selectedRange().location, (source as NSString).length)
        let headingLocation = (source as NSString).range(of: "Новый").location
        let font = try XCTUnwrap(textView.textStorage?.attribute(.font, at: headingLocation, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(font.pointSize, LiveMarkdownStyler.bodyFont.pointSize)
    }

    func testLiveMarkdownWaitsForInputMethodCompositionBeforeRestyling() throws {
        var source = ""
        var isEditing = false
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        textView.setMarkedText(
            "# Заголовок",
            selectedRange: NSRange(location: 11, length: 0),
            replacementRange: NSRange(location: 0, length: 0)
        )
        XCTAssertTrue(textView.hasMarkedText())
        let coordinator = SynchronousTextView.Coordinator(
            text: Binding(get: { source }, set: { source = $0 }),
            isEditing: Binding(get: { isEditing }, set: { isEditing = $0 }),
            rendersMarkdown: true
        )

        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        XCTAssertTrue(textView.hasMarkedText())
        let headingLocation = (textView.string as NSString).range(of: "Заголовок").location
        let composingFont = textView.textStorage?.attribute(.font, at: headingLocation, effectiveRange: nil) as? NSFont
        XCTAssertLessThanOrEqual(composingFont?.pointSize ?? 0, LiveMarkdownStyler.bodyFont.pointSize)

        textView.unmarkText()
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        let renderedFont = try XCTUnwrap(textView.textStorage?.attribute(.font, at: headingLocation, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(renderedFont.pointSize, LiveMarkdownStyler.bodyFont.pointSize)
        XCTAssertEqual(source, "# Заголовок")
    }

    func testLiveMarkdownIsVisibleOnInitialEditorFrame() throws {
        let source = "# Markdown\nТекст с **акцентом**"
        let markdownBitmap = try render(
            SynchronousTextView(
                text: .constant(source),
                isEditing: .constant(false),
                focusRequestID: 0,
                appendsNewlineOnFocus: false,
                rendersMarkdown: true
            ),
            size: NSSize(width: 320, height: 140)
        )
        let plainBitmap = try render(
            SynchronousTextView(
                text: .constant(source),
                isEditing: .constant(false),
                focusRequestID: 0,
                appendsNewlineOnFocus: false,
                rendersMarkdown: false
            ),
            size: NSSize(width: 320, height: 140)
        )

        var changedPixels = 0
        for x in 0..<min(markdownBitmap.pixelsWide, plainBitmap.pixelsWide) {
            for y in 0..<min(markdownBitmap.pixelsHigh, plainBitmap.pixelsHigh) {
                guard let markdown = markdownBitmap.colorAt(x: x, y: y),
                      let plain = plainBitmap.colorAt(x: x, y: y) else { continue }
                let delta = abs(markdown.redComponent - plain.redComponent)
                    + abs(markdown.greenComponent - plain.greenComponent)
                    + abs(markdown.blueComponent - plain.blueComponent)
                if delta > 0.12 { changedPixels += 1 }
            }
        }
        XCTAssertGreaterThan(changedPixels, 150)
    }

    func testCompactWidthAddsBreathingRoomAroundNotchAndDot() {
        XCTAssertEqual(IslandScreenGeometry.compactWidth(notchWidth: nil), 244)
        XCTAssertEqual(IslandScreenGeometry.compactWidth(notchWidth: 200), 260)
    }

    func testPanelFrameAttachesToFullTopEdgeOfEveryConnectedScreen() {
        XCTAssertFalse(NSScreen.screens.isEmpty)
        let panel = IslandPanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        for screen in NSScreen.screens {
            for height: CGFloat in [280, 388, 620] {
                let size = NSSize(width: 560, height: height)
                let frame = IslandScreenGeometry.frame(screenFrame: screen.frame, size: size)
                panel.setFrame(frame, display: false)
                XCTAssertEqual(panel.frame.maxY, screen.frame.maxY, accuracy: 0.001)
                XCTAssertEqual(panel.frame.midX, screen.frame.midX, accuracy: 0.001)
                XCTAssertEqual(panel.screen?.frame, screen.frame)
            }
        }
    }

    func testExpandedHeightTracksVerticalDragInBothDirections() {
        XCTAssertEqual(
            IslandExpandedGeometry.height(
                startingAt: 388,
                verticalTranslation: 120,
                maximumHeight: 900
            ),
            508
        )
        XCTAssertEqual(
            IslandExpandedGeometry.height(
                startingAt: 388,
                verticalTranslation: -80,
                maximumHeight: 900
            ),
            308
        )
    }

    func testExpandedHeightClampsToSafeMinimumAndVisibleScreenBottom() {
        XCTAssertEqual(
            IslandExpandedGeometry.height(
                startingAt: 388,
                verticalTranslation: -400,
                maximumHeight: 900
            ),
            IslandExpandedGeometry.minimumHeight
        )
        XCTAssertEqual(
            IslandExpandedGeometry.height(
                startingAt: 388,
                verticalTranslation: 800,
                maximumHeight: 720
            ),
            720
        )
        XCTAssertEqual(
            IslandExpandedGeometry.maximumHeight(
                screenFrame: NSRect(x: 0, y: 0, width: 1440, height: 900),
                visibleFrame: NSRect(x: 0, y: 60, width: 1440, height: 815)
            ),
            840
        )
    }

    func testCompactIslandRendersRoundedBottomCornerAndVisibleLeftDot() throws {
        let store = NoteStore(persistenceURL: nil)
        let noteID = store.addNote(now: Date(timeIntervalSince1970: 100))
        store.setColor(.sky, for: noteID, now: Date(timeIntervalSince1970: 100))
        let presentation = IslandPresentationState()
        presentation.topInset = 32
        presentation.compactWidth = 228

        let bitmap = try render(
            IslandView(
                store: store,
                translator: TranslatorStore(credentials: TestTranslationCredentials()),
                meetings: MeetingsStore(provider: TestCalendarProvider()),
                recordings: RecordingsStore(capture: TestRecordingCapture(), directory: testMediaDirectory()),
                screenshots: ScreenshotsStore(library: TestScreenshotLibrary(), pasteboard: TestScreenshotPasteboard()),
                presentation: presentation,
                setExpanded: { _ in },
                dismiss: {}
            ),
            size: NSSize(width: 228, height: 32)
        )

        let scale = CGFloat(bitmap.pixelsWide) / 228
        let corner = try color(in: bitmap, x: 0, y: 0)
        let center = try color(in: bitmap, x: Int(114 * scale), y: Int(2 * scale))
        let cornerBrightness = corner.redComponent + corner.greenComponent + corner.blueComponent
        let centerBrightness = center.redComponent + center.greenComponent + center.blueComponent
        XCTAssertGreaterThan(cornerBrightness, centerBrightness + 0.2)
        let hasColoredDot = (Int(8 * scale)..<Int(32 * scale)).contains { x in
            (Int(4 * scale)..<Int(28 * scale)).contains { y in
                guard let pixel = bitmap.colorAt(x: x, y: y) else { return false }
                let channels = [pixel.redComponent, pixel.greenComponent, pixel.blueComponent]
                return channels.max()! - channels.min()! > 0.2 && channels.max()! > 0.45
            }
        }
        XCTAssertTrue(hasColoredDot)
    }

    func testExpandedIslandRendersBodyOnInitialDisplayPass() throws {
        let timestamp = Date(timeIntervalSince1970: 100)
        let bodyStore = NoteStore(persistenceURL: nil)
        bodyStore.addNote(now: timestamp)
        bodyStore.updateSelected(body: "Мгновенно видимый текст", now: timestamp)
        let emptyStore = NoteStore(persistenceURL: nil)
        emptyStore.addNote(now: timestamp)
        emptyStore.updateSelected(body: "", now: timestamp)
        let presentation = IslandPresentationState()
        presentation.isExpanded = true
        presentation.isWindowExpanded = true
        presentation.editorOpacity = 1
        presentation.topInset = 32

        let bodyBitmap = try render(
            IslandView(
                store: bodyStore,
                translator: TranslatorStore(credentials: TestTranslationCredentials()),
                meetings: MeetingsStore(provider: TestCalendarProvider()),
                recordings: RecordingsStore(capture: TestRecordingCapture(), directory: testMediaDirectory()),
                screenshots: ScreenshotsStore(library: TestScreenshotLibrary(), pasteboard: TestScreenshotPasteboard()),
                presentation: presentation,
                setExpanded: { _ in },
                dismiss: {}
            ),
            size: NSSize(width: 560, height: 388)
        )
        let emptyBitmap = try render(
            IslandView(
                store: emptyStore,
                translator: TranslatorStore(credentials: TestTranslationCredentials()),
                meetings: MeetingsStore(provider: TestCalendarProvider()),
                recordings: RecordingsStore(capture: TestRecordingCapture(), directory: testMediaDirectory()),
                screenshots: ScreenshotsStore(library: TestScreenshotLibrary(), pasteboard: TestScreenshotPasteboard()),
                presentation: presentation,
                setExpanded: { _ in },
                dismiss: {}
            ),
            size: NSSize(width: 560, height: 388)
        )

        var changedPixels = 0
        let scale = CGFloat(bodyBitmap.pixelsWide) / 560
        for x in Int(200 * scale)..<Int(550 * scale) {
            for y in Int(80 * scale)..<Int(250 * scale) {
                guard let bodyPixel = bodyBitmap.colorAt(x: x, y: y),
                      let emptyPixel = emptyBitmap.colorAt(x: x, y: y) else { continue }
                let delta = abs(bodyPixel.redComponent - emptyPixel.redComponent)
                    + abs(bodyPixel.greenComponent - emptyPixel.greenComponent)
                    + abs(bodyPixel.blueComponent - emptyPixel.blueComponent)
                if delta > 0.12 { changedPixels += 1 }
            }
        }
        XCTAssertGreaterThan(changedPixels, 80)
    }

    func testNewNoteIsSelectedAndPersisted() throws {
        let url = temporaryURL()
        let store = NoteStore(persistenceURL: url)

        let id = store.addNote(now: Date(timeIntervalSince1970: 100))
        store.updateSelected(title: "Идея", body: "Сделать остров заметок", now: Date(timeIntervalSince1970: 110))

        XCTAssertEqual(store.selectedID, id)
        XCTAssertEqual(store.selectedNote?.title, "Идея")
        XCTAssertEqual(store.selectedNote?.body, "Сделать остров заметок")
        let reloaded = NoteStore(persistenceURL: url)
        XCTAssertTrue(reloaded.notes.contains(where: { $0.id == id && $0.title == "Идея" }))
    }

    func testSearchMatchesTitleAndBodyCaseInsensitively() {
        let store = NoteStore(persistenceURL: nil)
        store.addNote()
        store.updateSelected(title: "Покупки", body: "Молоко и хлеб")

        store.query = "ХЛЕБ"

        XCTAssertEqual(store.visibleNotes.map(\.title), ["Покупки"])
    }

    func testPinnedNotesSortBeforeRecentlyUpdatedNotes() {
        let store = NoteStore(persistenceURL: nil)
        let firstID = store.addNote(now: Date(timeIntervalSince1970: 100))
        let secondID = store.addNote(now: Date(timeIntervalSince1970: 200))
        store.updateSelected(title: "Свежая", now: Date(timeIntervalSince1970: 210))
        store.togglePin(firstID, now: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(store.visibleNotes.first?.id, firstID)
        XCTAssertEqual(store.visibleNotes.last?.id, secondID)
    }

    func testDeleteSelectsRemainingNoteAndSupportsEmptyState() {
        let store = NoteStore(persistenceURL: nil)
        let originalID = store.addNote()
        let secondID = store.addNote()

        store.delete(secondID)
        XCTAssertEqual(store.selectedID, originalID)
        store.delete(originalID)

        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertNil(store.selectedID)
        XCTAssertTrue(store.visibleNotes.isEmpty)
    }

    func testItemScopedMenuActionsTargetClickedNoteInsteadOfCurrentSelection() {
        let store = NoteStore(persistenceURL: nil)
        let firstID = store.addNote(now: Date(timeIntervalSince1970: 100))
        let clickedID = store.addNote(now: Date(timeIntervalSince1970: 200))
        store.select(firstID)

        store.togglePin(clickedID, now: Date(timeIntervalSince1970: 210))
        XCTAssertEqual(store.selectedID, firstID)
        XCTAssertTrue(store.notes.first(where: { $0.id == clickedID })?.isPinned == true)

        store.select(clickedID)
        XCTAssertEqual(store.selectedID, clickedID)

        store.select(firstID)
        store.delete(clickedID)
        XCTAssertEqual(store.selectedID, firstID)
        XCTAssertFalse(store.notes.contains(where: { $0.id == clickedID }))
    }

    func testEmptyStateSurvivesRelaunch() {
        let url = temporaryURL()
        let store = NoteStore(persistenceURL: url)
        store.addNote()
        store.delete(store.selectedID!)

        let reloaded = NoteStore(persistenceURL: url)

        XCTAssertTrue(reloaded.notes.isEmpty)
        XCTAssertNil(reloaded.selectedID)
    }

    func testFreshStoreStartsEmptyWithoutWelcomeNote() {
        let store = NoteStore(persistenceURL: nil)

        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertNil(store.selectedID)
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("notes.json")
    }

    private func testMediaDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func render<V: View>(_ view: V, size: NSSize) throws -> NSBitmapImageRep {
        let testBackground = Color(red: 1, green: 0, blue: 0)
        let hostingView = NSHostingView(rootView: ZStack { testBackground; view })
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw NSError(domain: "NoteIslandTests", code: 1)
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        return bitmap
    }

    private func color(in bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> NSColor {
        guard let color = bitmap.colorAt(x: x, y: y) else {
            throw NSError(domain: "NoteIslandTests", code: 2)
        }
        return color
    }
}

private final class TestTranslationCredentials: TranslationCredentialStoring {
    private var values: [TranslationEngine: String] = [:]

    func value(for engine: TranslationEngine) -> String? {
        values[engine]
    }

    func setValue(_ value: String?, for engine: TranslationEngine) -> Bool {
        values[engine] = value
        return true
    }
}
