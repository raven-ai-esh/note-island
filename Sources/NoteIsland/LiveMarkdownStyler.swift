import AppKit

extension NSAttributedString.Key {
    static let markdownHiddenGlyph = NSAttributedString.Key("NoteIsland.MarkdownHiddenGlyph")
    static let markdownReplacementGlyph = NSAttributedString.Key("NoteIsland.MarkdownReplacementGlyph")
    static let markdownTaskToggleRange = NSAttributedString.Key("NoteIsland.MarkdownTaskToggleRange")
}

@MainActor
enum LiveMarkdownStyler {
    private static let bodyColor = NSColor.white.withAlphaComponent(0.88)
    private static let secondaryColor = NSColor.white.withAlphaComponent(0.42)
    private static let accentColor = NSColor(
        calibratedRed: 0.66,
        green: 0.49,
        blue: 1,
        alpha: 1
    )
    private static let linkColor = NSColor(
        calibratedRed: 0.38,
        green: 0.74,
        blue: 1,
        alpha: 1
    )

    static var bodyFont: NSFont {
        roundedFont(size: 14, weight: .regular)
    }

    static var baseParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        style.paragraphSpacing = 2
        return style
    }

    static var typingAttributes: [NSAttributedString.Key: Any] {
        [
            .font: bodyFont,
            .foregroundColor: bodyColor,
            .paragraphStyle: baseParagraphStyle
        ]
    }

    static func apply(to textView: NSTextView, activeParagraphRange: NSRange? = nil) {
        guard let storage = textView.textStorage else { return }
        let source = textView.string
        let styled = attributedString(for: source, activeParagraphRange: activeParagraphRange)
        let selections = textView.selectedRanges

        storage.beginEditing()
        if storage.length > 0 {
            styled.enumerateAttributes(
                in: NSRange(location: 0, length: styled.length),
                options: []
            ) { attributes, range, _ in
                storage.setAttributes(attributes, range: range)
            }
        }
        storage.endEditing()

        textView.typingAttributes = typingAttributes
        textView.selectedRanges = selections.map { value in
            let range = value.rangeValue
            let location = min(range.location, storage.length)
            let length = min(range.length, storage.length - location)
            return NSValue(range: NSRange(location: location, length: length))
        }
        if storage.length > 0 {
            textView.layoutManager?.invalidateGlyphs(
                forCharacterRange: NSRange(location: 0, length: storage.length),
                changeInLength: 0,
                actualCharacterRange: nil
            )
        }
    }

    static func attributedString(
        for source: String,
        activeParagraphRange: NSRange? = nil
    ) -> NSAttributedString {
        let fullRange = NSRange(location: 0, length: (source as NSString).length)
        let result = NSMutableAttributedString(
            string: source,
            attributes: typingAttributes
        )
        guard fullRange.length > 0 else { return result }

        let fencedCodeRanges = fencedCodeRanges(in: source)
        styleStructuralMarkdown(in: source, result: result, excluding: fencedCodeRanges)
        styleInlineMarkdown(in: source, result: result, excluding: fencedCodeRanges)
        styleFencedCode(in: source, result: result, ranges: fencedCodeRanges)
        applyCollapsedPresentation(
            in: source,
            result: result,
            fencedCodeRanges: fencedCodeRanges,
            activeParagraphRange: activeParagraphRange
        )
        return result
    }

    private static func applyCollapsedPresentation(
        in source: String,
        result: NSMutableAttributedString,
        fencedCodeRanges: [NSRange],
        activeParagraphRange: NSRange?
    ) {
        let sourceText = source as NSString

        for match in matches(#"(?m)^(#{1,6})([ \t]+)([^\n]*)"#, in: source)
            where canCollapse(match.range, activeParagraphRange: activeParagraphRange)
                && !intersects(match.range, any: fencedCodeRanges) {
            let content = match.range(at: 3)
            hide(
                NSRange(location: match.range.location, length: content.location - match.range.location),
                in: result
            )
        }

        for match in matches(#"(?m)^([ \t]*>[ \t]?)([^\n]*)"#, in: source)
            where canCollapse(match.range, activeParagraphRange: activeParagraphRange)
                && !intersects(match.range, any: fencedCodeRanges) {
            replaceStructuralMarker(
                in: match.range(at: 1),
                source: sourceText,
                with: "▌",
                result: result
            )
        }

        for match in matches(#"(?m)^([ \t]*[-+*][ \t]+\[([ xX])\][ \t]+)([^\n]*)"#, in: source)
            where canCollapse(match.range, activeParagraphRange: activeParagraphRange)
                && !intersects(match.range, any: fencedCodeRanges) {
            let marker = match.range(at: 1)
            let checked = sourceText.substring(with: match.range(at: 2)).lowercased() == "x"
            let replacementIndex = replaceStructuralMarker(
                in: marker,
                source: sourceText,
                with: checked ? "☑" : "□",
                result: result
            )
            if let replacementIndex {
                result.addAttribute(
                    .markdownTaskToggleRange,
                    value: NSValue(range: marker),
                    range: NSRange(location: replacementIndex, length: 1)
                )
            }
        }

        for match in matches(#"(?m)^([ \t]*[-+*][ \t]+)(?!\[[ xX]\][ \t]+)([^\n]*)"#, in: source)
            where canCollapse(match.range, activeParagraphRange: activeParagraphRange)
                && !intersects(match.range, any: fencedCodeRanges) {
            _ = replaceStructuralMarker(
                in: match.range(at: 1),
                source: sourceText,
                with: "•",
                result: result
            )
        }

        for match in matches(#"(?m)^([ \t]*\d+[.)])([ \t]+)([^\n]*)"#, in: source)
            where canCollapse(match.range, activeParagraphRange: activeParagraphRange)
                && !intersects(match.range, any: fencedCodeRanges) {
            hideAllButLastCharacter(match.range(at: 2), in: result)
        }

        let delimiterPatterns: [(String, Int)] = [
            (#"\*\*(?=\S)(.+?\S)\*\*"#, 2),
            (#"__(?=\S)(.+?\S)__"#, 2),
            (#"(?<!\*)\*(?=\S)([^*\n]*?\S)\*(?!\*)"#, 1),
            (#"(?<!_)_(?=\S)([^_\n]*?\S)_(?!_)"#, 1),
            (#"~~(?=\S)(.+?\S)~~"#, 2),
            (#"`([^`\n]+)`"#, 1)
        ]
        for (pattern, delimiterLength) in delimiterPatterns {
            for match in matches(pattern, in: source)
                where canCollapse(match.range, activeParagraphRange: activeParagraphRange)
                    && !intersects(match.range, any: fencedCodeRanges) {
                hide(NSRange(location: match.range.location, length: delimiterLength), in: result)
                hide(
                    NSRange(location: NSMaxRange(match.range) - delimiterLength, length: delimiterLength),
                    in: result
                )
            }
        }

        for match in matches(#"!?\[([^\]\n]+)\]\(([^)\n]+)\)"#, in: source)
            where canCollapse(match.range, activeParagraphRange: activeParagraphRange)
                && !intersects(match.range, any: fencedCodeRanges) {
            let label = match.range(at: 1)
            hide(
                NSRange(location: match.range.location, length: label.location - match.range.location),
                in: result
            )
            hide(
                NSRange(location: NSMaxRange(label), length: NSMaxRange(match.range) - NSMaxRange(label)),
                in: result
            )
        }

        for fencedRange in fencedCodeRanges {
            let fragment = sourceText.substring(with: fencedRange) as NSString
            var localLocation = 0
            while localLocation < fragment.length {
                let lineRange = fragment.lineRange(for: NSRange(location: localLocation, length: 0))
                let line = fragment.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
                let globalLineRange = NSRange(
                    location: fencedRange.location + lineRange.location,
                    length: lineRange.length
                )
                if (line.hasPrefix("```") || line.hasPrefix("~~~")),
                   canCollapse(globalLineRange, activeParagraphRange: activeParagraphRange) {
                    var visibleLength = lineRange.length
                    while visibleLength > 0 {
                        let character = fragment.character(at: lineRange.location + visibleLength - 1)
                        if character == 10 || character == 13 {
                            visibleLength -= 1
                        } else {
                            break
                        }
                    }
                    hide(
                        NSRange(location: globalLineRange.location, length: visibleLength),
                        in: result
                    )
                }
                localLocation = NSMaxRange(lineRange)
            }
        }
    }

    @discardableResult
    private static func replaceStructuralMarker(
        in markerRange: NSRange,
        source: NSString,
        with replacement: String,
        result: NSMutableAttributedString
    ) -> Int? {
        guard markerRange.length > 0 else { return nil }
        let marker = source.substring(with: markerRange) as NSString
        var localIndex = 0
        while localIndex < marker.length,
              CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(marker.character(at: localIndex))!) {
            localIndex += 1
        }
        guard localIndex < marker.length else { return nil }
        let replacementIndex = markerRange.location + localIndex
        hide(markerRange, in: result)
        result.removeAttribute(
            .markdownHiddenGlyph,
            range: NSRange(location: replacementIndex, length: 1)
        )
        result.addAttribute(
            .markdownReplacementGlyph,
            value: replacement,
            range: NSRange(location: replacementIndex, length: 1)
        )
        if markerRange.length > 1 {
            let trailingIndex = NSMaxRange(markerRange) - 1
            let trailingCharacter = source.character(at: trailingIndex)
            if CharacterSet.whitespaces.contains(UnicodeScalar(trailingCharacter)!) {
                result.removeAttribute(
                    .markdownHiddenGlyph,
                    range: NSRange(location: trailingIndex, length: 1)
                )
            }
        }
        return replacementIndex
    }

    private static func hide(_ range: NSRange, in result: NSMutableAttributedString) {
        guard range.location != NSNotFound, range.length > 0 else { return }
        result.addAttribute(.markdownHiddenGlyph, value: true, range: range)
    }

    private static func hideAllButLastCharacter(
        _ range: NSRange,
        in result: NSMutableAttributedString
    ) {
        guard range.location != NSNotFound, range.length > 1 else { return }
        hide(NSRange(location: range.location, length: range.length - 1), in: result)
    }

    private static func canCollapse(_ range: NSRange, activeParagraphRange: NSRange?) -> Bool {
        guard let activeParagraphRange else { return true }
        return NSIntersectionRange(range, activeParagraphRange).length == 0
    }

    private static func styleStructuralMarkdown(
        in source: String,
        result: NSMutableAttributedString,
        excluding excludedRanges: [NSRange]
    ) {
        for match in matches(#"(?m)^(#{1,6})([ \t]+)([^\n]*)"#, in: source)
            where !intersects(match.range, any: excludedRanges) {
            let markerRange = match.range(at: 1)
            let contentRange = match.range(at: 3)
            let level = min(markerRange.length, 6)
            let sizes: [CGFloat] = [24, 21, 18, 16, 15, 14]
            result.addAttributes([
                .font: roundedFont(size: sizes[level - 1], weight: .bold),
                .foregroundColor: bodyColor,
                .paragraphStyle: headingParagraphStyle(level: level)
            ], range: match.range)
            result.addAttributes([
                .foregroundColor: accentColor.withAlphaComponent(0.52),
                .font: roundedFont(size: max(11, sizes[level - 1] - 3), weight: .semibold)
            ], range: markerRange)
            if contentRange.length == 0 {
                result.addAttribute(.foregroundColor, value: secondaryColor, range: markerRange)
            }
        }

        for match in matches(#"(?m)^([ \t]*>[ \t]?)([^\n]*)"#, in: source)
            where !intersects(match.range, any: excludedRanges) {
            result.addAttributes([
                .foregroundColor: NSColor.white.withAlphaComponent(0.72),
                .paragraphStyle: indentedParagraphStyle(indent: 15, spacing: 4)
            ], range: match.range)
            result.addAttributes([
                .foregroundColor: accentColor,
                .font: roundedFont(size: 14, weight: .bold)
            ], range: match.range(at: 1))
        }

        for match in matches(#"(?m)^([ \t]*[-+*][ \t]+\[([ xX])\][ \t]+)([^\n]*)"#, in: source)
            where !intersects(match.range, any: excludedRanges) {
            let marker = match.range(at: 1)
            let content = match.range(at: 3)
            let checked = (source as NSString).substring(with: match.range(at: 2)).lowercased() == "x"
            result.addAttribute(
                .paragraphStyle,
                value: indentedParagraphStyle(indent: 18, spacing: 2),
                range: match.range
            )
            result.addAttribute(
                .foregroundColor,
                value: checked ? NSColor.systemGreen : accentColor,
                range: marker
            )
            if checked, content.length > 0 {
                result.addAttributes([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: NSColor.white.withAlphaComponent(0.54)
                ], range: content)
            }
        }

        let listPatterns = [
            #"(?m)^([ \t]*[-+*][ \t]+)(?!\[[ xX]\][ \t]+)([^\n]*)"#,
            #"(?m)^([ \t]*\d+[.)][ \t]+)([^\n]*)"#
        ]
        for pattern in listPatterns {
            for match in matches(pattern, in: source)
                where !intersects(match.range, any: excludedRanges) {
                result.addAttribute(
                    .paragraphStyle,
                    value: indentedParagraphStyle(indent: 18, spacing: 2),
                    range: match.range
                )
                result.addAttributes([
                    .foregroundColor: accentColor,
                    .font: roundedFont(size: 14, weight: .semibold)
                ], range: match.range(at: 1))
            }
        }

        for match in matches(#"(?m)^[ \t]*(?:-{3,}|\*{3,}|_{3,})[ \t]*$"#, in: source)
            where !intersects(match.range, any: excludedRanges) {
            result.addAttributes([
                .foregroundColor: NSColor.white.withAlphaComponent(0.26),
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .strikethroughStyle: NSUnderlineStyle.single.rawValue
            ], range: match.range)
        }
    }

    private static func styleInlineMarkdown(
        in source: String,
        result: NSMutableAttributedString,
        excluding excludedRanges: [NSRange]
    ) {
        styleDelimited(
            pattern: #"\*\*(?=\S)(.+?\S)\*\*"#,
            markerLength: 2,
            trait: .boldFontMask,
            in: source,
            result: result,
            excluding: excludedRanges
        )
        styleDelimited(
            pattern: #"__(?=\S)(.+?\S)__"#,
            markerLength: 2,
            trait: .boldFontMask,
            in: source,
            result: result,
            excluding: excludedRanges
        )
        styleDelimited(
            pattern: #"(?<!\*)\*(?=\S)([^*\n]*?\S)\*(?!\*)"#,
            markerLength: 1,
            trait: .italicFontMask,
            in: source,
            result: result,
            excluding: excludedRanges
        )
        styleDelimited(
            pattern: #"(?<!_)_(?=\S)([^_\n]*?\S)_(?!_)"#,
            markerLength: 1,
            trait: .italicFontMask,
            in: source,
            result: result,
            excluding: excludedRanges
        )

        for match in matches(#"~~(?=\S)(.+?\S)~~"#, in: source)
            where !intersects(match.range, any: excludedRanges) {
            result.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor.white.withAlphaComponent(0.58)
            ], range: match.range(at: 1))
            dimDelimiters(of: match.range, length: 2, in: result)
        }

        for match in matches(#"!?\[([^\]\n]+)\]\(([^)\n]+)\)"#, in: source)
            where !intersects(match.range, any: excludedRanges) {
            result.addAttributes([
                .foregroundColor: linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: match.range(at: 1))
            result.addAttribute(.foregroundColor, value: secondaryColor, range: match.range(at: 2))
            let full = match.range
            let label = match.range(at: 1)
            let destination = match.range(at: 2)
            result.addAttribute(
                .foregroundColor,
                value: secondaryColor,
                range: NSRange(location: full.location, length: label.location - full.location)
            )
            result.addAttribute(
                .foregroundColor,
                value: secondaryColor,
                range: NSRange(
                    location: NSMaxRange(label),
                    length: destination.location - NSMaxRange(label)
                )
            )
            result.addAttribute(
                .foregroundColor,
                value: secondaryColor,
                range: NSRange(location: NSMaxRange(destination), length: NSMaxRange(full) - NSMaxRange(destination))
            )
        }

        for match in matches(#"`([^`\n]+)`"#, in: source)
            where !intersects(match.range, any: excludedRanges) {
            result.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.92),
                .backgroundColor: NSColor.white.withAlphaComponent(0.09)
            ], range: match.range)
            dimDelimiters(of: match.range, length: 1, in: result)
        }
    }

    private static func styleDelimited(
        pattern: String,
        markerLength: Int,
        trait: NSFontTraitMask,
        in source: String,
        result: NSMutableAttributedString,
        excluding excludedRanges: [NSRange]
    ) {
        for match in matches(pattern, in: source)
            where !intersects(match.range, any: excludedRanges) {
            addFontTrait(trait, to: match.range(at: 1), in: result)
            dimDelimiters(of: match.range, length: markerLength, in: result)
        }
    }

    private static func styleFencedCode(
        in source: String,
        result: NSMutableAttributedString,
        ranges: [NSRange]
    ) {
        let sourceNSString = source as NSString
        for range in ranges {
            let paragraph = indentedParagraphStyle(indent: 10, spacing: 4)
            paragraph.tailIndent = -10
            result.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.82),
                .backgroundColor: NSColor.white.withAlphaComponent(0.07),
                .paragraphStyle: paragraph
            ], range: range)

            let fragment = sourceNSString.substring(with: range) as NSString
            var localLocation = 0
            while localLocation < fragment.length {
                let lineRange = fragment.lineRange(for: NSRange(location: localLocation, length: 0))
                let line = fragment.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
                if line.hasPrefix("```") || line.hasPrefix("~~~") {
                    result.addAttributes([
                        .foregroundColor: accentColor.withAlphaComponent(0.62),
                        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
                    ], range: NSRange(location: range.location + lineRange.location, length: lineRange.length))
                }
                localLocation = NSMaxRange(lineRange)
            }
        }
    }

    private static func fencedCodeRanges(in source: String) -> [NSRange] {
        let text = source as NSString
        var ranges: [NSRange] = []
        var location = 0
        var fenceStart: Int?
        var fenceMarker: Character?

        while location < text.length {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let line = text.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            let marker = line.first
            let isFence = (line.hasPrefix("```") || line.hasPrefix("~~~"))

            if isFence, let marker {
                if let start = fenceStart, marker == fenceMarker {
                    ranges.append(NSRange(location: start, length: NSMaxRange(lineRange) - start))
                    fenceStart = nil
                    fenceMarker = nil
                } else if fenceStart == nil {
                    fenceStart = lineRange.location
                    fenceMarker = marker
                }
            }
            location = NSMaxRange(lineRange)
        }

        if let start = fenceStart {
            ranges.append(NSRange(location: start, length: text.length - start))
        }
        return ranges
    }

    private static func addFontTrait(
        _ trait: NSFontTraitMask,
        to range: NSRange,
        in result: NSMutableAttributedString
    ) {
        guard range.location != NSNotFound, range.length > 0 else { return }
        var replacements: [(NSRange, NSFont)] = []
        result.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            let font = value as? NSFont ?? bodyFont
            let manager = NSFontManager.shared
            var converted = manager.convert(font, toHaveTrait: trait)
            if trait.contains(.italicFontMask),
               !manager.traits(of: converted).contains(.italicFontMask) {
                let weight: NSFont.Weight = manager.traits(of: font).contains(.boldFontMask)
                    ? .semibold
                    : .regular
                converted = manager.convert(
                    NSFont.systemFont(ofSize: font.pointSize, weight: weight),
                    toHaveTrait: .italicFontMask
                )
            }
            replacements.append((subrange, converted))
        }
        for (subrange, font) in replacements {
            result.addAttribute(.font, value: font, range: subrange)
        }
    }

    private static func dimDelimiters(
        of range: NSRange,
        length: Int,
        in result: NSMutableAttributedString
    ) {
        guard range.length >= length * 2 else { return }
        result.addAttribute(
            .foregroundColor,
            value: secondaryColor,
            range: NSRange(location: range.location, length: length)
        )
        result.addAttribute(
            .foregroundColor,
            value: secondaryColor,
            range: NSRange(location: NSMaxRange(range) - length, length: length)
        )
    }

    private static func headingParagraphStyle(level: Int) -> NSParagraphStyle {
        let style = baseParagraphStyle.mutableCopy() as! NSMutableParagraphStyle
        style.paragraphSpacingBefore = level <= 2 ? 8 : 5
        style.paragraphSpacing = level <= 2 ? 6 : 4
        return style
    }

    private static func indentedParagraphStyle(indent: CGFloat, spacing: CGFloat) -> NSMutableParagraphStyle {
        let style = baseParagraphStyle.mutableCopy() as! NSMutableParagraphStyle
        style.firstLineHeadIndent = 4
        style.headIndent = indent + 4
        style.paragraphSpacing = spacing
        return style
    }

    private static func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let system = NSFont.systemFont(ofSize: size, weight: weight)
        return system.fontDescriptor.withDesign(.rounded)
            .flatMap { NSFont(descriptor: $0, size: size) }
            ?? system
    }

    private static func matches(_ pattern: String, in source: String) -> [NSTextCheckingResult] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(location: 0, length: (source as NSString).length)
        return expression.matches(in: source, range: range)
    }

    private static func intersects(_ range: NSRange, any excludedRanges: [NSRange]) -> Bool {
        excludedRanges.contains { NSIntersectionRange(range, $0).length > 0 }
    }
}
