import AppKit
import CoreText
import SwiftUI

struct IslandView: View {
    @ObservedObject var store: NoteStore
    @ObservedObject var translator: TranslatorStore
    @ObservedObject var meetings: MeetingsStore
    @ObservedObject var recordings: RecordingsStore
    @ObservedObject var screenshots: ScreenshotsStore
    @ObservedObject var presentation: IslandPresentationState
    @State private var isEditingBody = false
    let setExpanded: (Bool) -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if presentation.isExpanded {
                expandedView
                    .opacity(presentation.editorOpacity)
            } else {
                compactView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(IslandTheme.background)
        .clipShape(islandShape)
        .overlay {
            islandShape
                .stroke(Color.white.opacity(0.11), lineWidth: 0.75)
        }
    }

    private var islandShape: UnevenRoundedRectangle {
        let radius: CGFloat = presentation.isWindowExpanded ? 28 : 22
        return UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: radius,
            bottomTrailingRadius: radius,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    private var compactView: some View {
        Button {
            setExpanded(true)
        } label: {
            HStack(spacing: 0) {
                glowingNoteDot
                    .padding(.leading, 14)
                Spacer(minLength: 0)
            }
            .frame(
                width: presentation.compactWidth,
                height: presentation.topInset > 0 ? presentation.topInset : 32
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Раскрыть \(presentation.mode.title.lowercased())")
    }

    private var glowingNoteDot: some View {
        let color: Color = switch presentation.mode {
        case .notes: store.selectedNote?.color.color ?? NoteColor.lilac.color
        case .translator: NoteColor.mint.color
        case .meetings: NoteColor.peach.color
        case .recordings: Color.red
        case .screenshots: NoteColor.sky.color
        }
        return Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.9), radius: 6)
            .offset(y: -2)
    }

    private var expandedView: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))

            Group {
                if presentation.mode == .notes {
                    HStack(spacing: 0) {
                        sidebar
                            .frame(width: 182)
                        Divider().overlay(Color.white.opacity(0.08))
                        editor
                    }
                } else if presentation.mode == .translator {
                    TranslatorView(translator: translator, presentation: presentation)
                } else if presentation.mode == .meetings {
                    MeetingsView(meetings: meetings)
                } else if presentation.mode == .recordings {
                    RecordingsView(recordings: recordings)
                } else {
                    ScreenshotsView(screenshots: screenshots)
                }
            }
            .frame(height: 330)
        }
        .frame(width: 560)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(IslandMode.allCases, id: \.self) { mode in
                    Button {
                        presentation.selectMode(mode)
                    } label: {
                        if presentation.mode == mode {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Label(mode.title, systemImage: mode.symbol)
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: presentation.mode.symbol)
                        .foregroundStyle(modeAccentColor)
                    Text("note island")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(IslandTheme.secondary)
                }
                .foregroundStyle(.white)
            }
            .menuStyle(.borderlessButton)
            .tint(.white)
            .fixedSize()
            .accessibilityLabel("Выбрать режим Note Island")

            Spacer()

            Text(presentation.mode.shortcutTitle)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(IslandTheme.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(IslandTheme.surface, in: Capsule())

            Button {
                setExpanded(false)
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(IslandIconButtonStyle())
            .accessibilityLabel("Свернуть")

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(IslandIconButtonStyle())
            .accessibilityLabel("Скрыть")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(height: 58)
    }

    private var modeAccentColor: Color {
        switch presentation.mode {
        case .notes: NoteColor.lilac.color
        case .translator: NoteColor.mint.color
        case .meetings: NoteColor.peach.color
        case .recordings: Color.red
        case .screenshots: NoteColor.sky.color
        }
    }

    private var sidebar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(IslandTheme.secondary)
                TextField("Поиск", text: $store.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(IslandTheme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .padding(.horizontal, 12)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(store.visibleNotes) { note in
                        NoteRow(
                            note: note,
                            isSelected: store.selectedID == note.id,
                            selectAction: { store.select(note.id) },
                            togglePinAction: { store.togglePin(note.id) },
                            deleteAction: { store.delete(note.id) }
                        )
                    }
                }
                .padding(.horizontal, 8)
            }

            Button {
                store.addNote()
            } label: {
                Label("Новая заметка", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.black.opacity(0.82))
            .background(NoteColor.lilac.color, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .padding(12)
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private var editor: some View {
        if let note = store.selectedNote {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    HStack(spacing: 7) {
                        ForEach(NoteColor.allCases, id: \.self) { color in
                            Button {
                                store.setColor(color, for: note.id)
                            } label: {
                                Circle()
                                    .fill(color.color)
                                    .frame(width: 13, height: 13)
                                    .overlay {
                                        if note.color == color {
                                            Circle().stroke(.white, lineWidth: 2)
                                                .padding(-3)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Изменить цвет")
                        }
                    }

                    Spacer()

                    Button {
                        store.togglePin(note.id)
                    } label: {
                        Image(systemName: note.isPinned ? "pin.fill" : "pin")
                    }
                    .buttonStyle(IslandIconButtonStyle())
                    .accessibilityLabel(note.isPinned ? "Открепить" : "Закрепить")

                    Button(role: .destructive) {
                        store.delete(note.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(IslandIconButtonStyle())
                    .accessibilityLabel("Удалить заметку")
                }
                .padding(.bottom, 18)

                TextField("Название", text: titleBinding(for: note))
                    .textFieldStyle(.plain)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(IslandTheme.secondary)
                    .padding(.top, 5)

                SynchronousTextView(
                    text: bodyBinding(for: note),
                    isEditing: $isEditingBody,
                    focusRequestID: presentation.bodyFocusRequestID,
                    rendersMarkdown: true
                )
                    .padding(.top, 12)
            }
            .padding(20)
        } else {
            ContentUnavailableView(
                "Заметок не найдено",
                systemImage: "note.text",
                description: Text("Создайте новую заметку или измените запрос")
            )
            .foregroundStyle(.white)
        }
    }

    private func titleBinding(for note: Note) -> Binding<String> {
        Binding(
            get: { store.selectedNote?.title ?? note.title },
            set: { store.updateSelected(title: $0) }
        )
    }

    private func bodyBinding(for note: Note) -> Binding<String> {
        Binding(
            get: { store.selectedNote?.body ?? note.body },
            set: { store.updateSelected(body: $0) }
        )
    }
}

final class MarkdownTextView: NSTextView {
    override func mouseDown(with event: NSEvent) {
        guard let layoutManager,
              let textContainer,
              let textStorage,
              textStorage.length > 0 else {
            super.mouseDown(with: event)
            return
        }
        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x
        point.y -= textContainerOrigin.y
        let glyphIndex = layoutManager.glyphIndex(
            for: point,
            in: textContainer,
            fractionOfDistanceThroughGlyph: nil
        )
        guard glyphIndex < layoutManager.numberOfGlyphs else {
            super.mouseDown(with: event)
            return
        }
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        )
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard glyphRect.insetBy(dx: -4, dy: -3).contains(point),
              characterIndex < textStorage.length,
              let rangeValue = textStorage.attribute(
                .markdownTaskToggleRange,
                at: characterIndex,
                effectiveRange: nil
              ) as? NSValue else {
            super.mouseDown(with: event)
            return
        }

        guard toggleTask(at: rangeValue.rangeValue) else {
            super.mouseDown(with: event)
            return
        }
    }

    @discardableResult
    func toggleTask(at markerRange: NSRange) -> Bool {
        guard let textStorage,
              NSMaxRange(markerRange) <= textStorage.length else { return false }
        let marker = (string as NSString).substring(with: markerRange)
        let replacement: String
        if let checkedRange = marker.range(of: #"\[[xX]\]"#, options: .regularExpression) {
            replacement = marker.replacingCharacters(in: checkedRange, with: "[ ]")
        } else if let uncheckedRange = marker.range(of: "[ ]") {
            replacement = marker.replacingCharacters(in: uncheckedRange, with: "[x]")
        } else {
            return false
        }

        guard shouldChangeText(in: markerRange, replacementString: replacement) else { return false }
        textStorage.replaceCharacters(in: markerRange, with: replacement)
        didChangeText()
        return true
    }
}

struct SynchronousTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isEditing: Bool
    let focusRequestID: Int
    var appendsNewlineOnFocus = true
    var accessibilityLabel = "Текст заметки"
    var rendersMarkdown = false

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isEditing: $isEditing, rendersMarkdown: rendersMarkdown)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = rendersMarkdown
            ? MarkdownTextView(frame: .zero)
            : NSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.layoutManager?.delegate = rendersMarkdown ? context.coordinator : nil
        textView.string = text
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        if rendersMarkdown {
            Self.configureSourceEditingBehavior(for: textView)
        }
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        let font = LiveMarkdownStyler.bodyFont
        let paragraphStyle = LiveMarkdownStyler.baseParagraphStyle
        textView.textColor = Self.resolvedTextColor(
            isEditing: isEditing,
            rendersMarkdown: rendersMarkdown
        )
        textView.insertionPointColor = .white
        textView.font = font
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes = LiveMarkdownStyler.typingAttributes
        textView.textContainerInset = NSSize(width: 0, height: 3)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.setAccessibilityLabel(accessibilityLabel)
        context.coordinator.refreshMarkdown(in: textView)

        scrollView.documentView = textView
        context.coordinator.applyFocusRequest(
            focusRequestID,
            to: textView,
            sourceText: text,
            appendsNewline: appendsNewlineOnFocus
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isEditing = $isEditing
        context.coordinator.rendersMarkdown = rendersMarkdown
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.layoutManager?.delegate = rendersMarkdown ? context.coordinator : nil
        let displayText = context.coordinator.displayText(for: text)
        if textView.string != displayText {
            textView.string = displayText
        }
        if !textView.hasMarkedText() {
            textView.textColor = Self.resolvedTextColor(
                isEditing: isEditing,
                rendersMarkdown: rendersMarkdown
            )
            context.coordinator.refreshMarkdown(in: textView)
        }
        context.coordinator.applyFocusRequest(
            focusRequestID,
            to: textView,
            sourceText: text,
            appendsNewline: appendsNewlineOnFocus
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSLayoutManagerDelegate {
        var text: Binding<String>
        var isEditing: Binding<Bool>
        var rendersMarkdown: Bool
        private var handledFocusRequestID = 0
        private var hasPendingAutomaticNewline = false
        private var isRefreshingMarkdown = false

        init(text: Binding<String>, isEditing: Binding<Bool>, rendersMarkdown: Bool) {
            self.text = text
            self.isEditing = isEditing
            self.rendersMarkdown = rendersMarkdown
        }

        func textDidBeginEditing(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            refreshMarkdown(in: textView)
        }

        func textDidEndEditing(_ notification: Notification) {
            isEditing.wrappedValue = false
            guard let textView = notification.object as? NSTextView else { return }
            refreshMarkdown(in: textView, revealActiveParagraph: false)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            refreshMarkdown(in: textView)
        }

        func applyFocusRequest(
            _ requestID: Int,
            to textView: NSTextView,
            sourceText: String,
            appendsNewline: Bool
        ) {
            guard requestID > 0, requestID != handledFocusRequestID else { return }
            handledFocusRequestID = requestID
            let appendBuffer = appendsNewline
                ? SynchronousTextView.automaticAppendBuffer(for: sourceText)
                : sourceText
            hasPendingAutomaticNewline = appendBuffer != sourceText
            textView.string = appendBuffer
            refreshMarkdown(in: textView, revealActiveParagraph: false)
            let cursorPosition = (textView.string as NSString).length
            DispatchQueue.main.async {
                guard let window = textView.window else { return }
                window.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: cursorPosition, length: 0))
                textView.scrollRangeToVisible(NSRange(location: cursorPosition, length: 0))
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            hasPendingAutomaticNewline = false
            let hasMarkedText = textView.hasMarkedText()
            if !hasMarkedText {
                textView.textColor = NSColor.white.withAlphaComponent(0.88)
            }
            isEditing.wrappedValue = true
            text.wrappedValue = textView.string
            if rendersMarkdown, !hasMarkedText {
                refreshMarkdown(in: textView)
            }
        }

        func refreshMarkdown(
            in textView: NSTextView,
            revealActiveParagraph: Bool = true
        ) {
            guard rendersMarkdown,
                  !textView.hasMarkedText(),
                  !isRefreshingMarkdown else { return }
            isRefreshingMarkdown = true
            defer { isRefreshingMarkdown = false }
            let activeParagraph = revealActiveParagraph
                ? activeParagraphRange(in: textView)
                : nil
            LiveMarkdownStyler.apply(
                to: textView,
                activeParagraphRange: activeParagraph
            )
        }

        private func activeParagraphRange(in textView: NSTextView) -> NSRange? {
            guard textView.window?.firstResponder === textView,
                  !textView.string.isEmpty else { return nil }
            let text = textView.string as NSString
            let selection = textView.selectedRange()
            let location = min(selection.location, text.length)
            return text.paragraphRange(for: NSRange(location: location, length: 0))
        }

        func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
            properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
            characterIndexes charIndexes: UnsafePointer<Int>,
            font aFont: NSFont,
            forGlyphRange glyphRange: NSRange
        ) -> Int {
            guard let storage = layoutManager.textStorage,
                  glyphRange.length > 0 else { return 0 }
            var renderedGlyphs = Array(
                UnsafeBufferPointer(start: glyphs, count: glyphRange.length)
            )
            var renderedProperties = Array(
                UnsafeBufferPointer(start: props, count: glyphRange.length)
            )
            let renderedCharacterIndexes = Array(
                UnsafeBufferPointer(start: charIndexes, count: glyphRange.length)
            )

            for index in 0..<glyphRange.length {
                let characterIndex = renderedCharacterIndexes[index]
                guard characterIndex < storage.length else { continue }
                if storage.attribute(
                    .markdownHiddenGlyph,
                    at: characterIndex,
                    effectiveRange: nil
                ) != nil {
                    renderedProperties[index].insert(.null)
                }
                if let replacement = storage.attribute(
                    .markdownReplacementGlyph,
                    at: characterIndex,
                    effectiveRange: nil
                ) as? String,
                   let character = replacement.utf16.first {
                    var unicodeCharacter = character
                    var replacementGlyph = CGGlyph()
                    if CTFontGetGlyphsForCharacters(
                        aFont as CTFont,
                        &unicodeCharacter,
                        &replacementGlyph,
                        1
                    ) {
                        renderedGlyphs[index] = replacementGlyph
                    }
                }
            }

            renderedGlyphs.withUnsafeBufferPointer { glyphBuffer in
                renderedProperties.withUnsafeBufferPointer { propertyBuffer in
                    renderedCharacterIndexes.withUnsafeBufferPointer { characterBuffer in
                        layoutManager.setGlyphs(
                            glyphBuffer.baseAddress!,
                            properties: propertyBuffer.baseAddress!,
                            characterIndexes: characterBuffer.baseAddress!,
                            font: aFont,
                            forGlyphRange: glyphRange
                        )
                    }
                }
            }
            return glyphRange.length
        }

        func displayText(for sourceText: String) -> String {
            hasPendingAutomaticNewline
                ? SynchronousTextView.automaticAppendBuffer(for: sourceText)
                : sourceText
        }
    }

    static func automaticAppendBuffer(for sourceText: String) -> String {
        guard !sourceText.isEmpty, !sourceText.hasSuffix("\n") else { return sourceText }
        return sourceText + "\n"
    }

    static func resolvedTextColor(isEditing: Bool, rendersMarkdown: Bool) -> NSColor {
        isEditing || rendersMarkdown
            ? NSColor.white.withAlphaComponent(0.88)
            : NSColor.clear
    }

    static func configureSourceEditingBehavior(for textView: NSTextView) {
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
    }
}

private struct NoteRow: View {
    let note: Note
    let isSelected: Bool
    let selectAction: () -> Void
    let togglePinAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: selectAction) {
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(note.color.color)
                        .frame(width: 4, height: 30)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text(note.displayTitle)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                            if note.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(note.color.color)
                            }
                        }
                        Text(note.body.isEmpty ? "Пустая заметка" : note.body)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(IslandTheme.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu { noteActions } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 32)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel("Действия с заметкой")
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .frame(height: 48)
        .background(
            isSelected ? Color.white.opacity(0.11) : .clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .contextMenu { noteActions }
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var noteActions: some View {
        Button(action: selectAction) {
            Label("Открыть", systemImage: "note.text")
        }
        Button(action: togglePinAction) {
            Label(note.isPinned ? "Открепить" : "Закрепить", systemImage: note.isPinned ? "pin.slash" : "pin")
        }
        Divider()
        Button(role: .destructive, action: deleteAction) {
            Label("Удалить", systemImage: "trash")
        }
    }
}

struct IslandIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? .white : IslandTheme.secondary)
            .background(IslandTheme.surface, in: Circle())
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
    }
}
