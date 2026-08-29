import Foundation

/// Recovers block structure from the Markdown summary the note generator
/// returns, so the summary tab can lay each block out instead of printing the
/// markers.
///
/// The parsing is `AttributedString`'s, not ours: with `.full` interpretation
/// every run carries a `PresentationIntent` naming the block it belongs to and
/// the blocks it is nested inside. That matters because the model's output is
/// only as predictable as a prompt can make it — earlier versions of this view
/// recognised `**bold**` headers and two-space indentation by hand, and the
/// day the model switched to `## headers` the markers reached the user as
/// literal text. Anything CommonMark defines now renders; nothing falls through
/// to raw.
///
/// `PresentationIntent.components` is ordered innermost-first, so the first
/// component names this block and each list component above it is one level of
/// nesting. That is how `depth` is counted, rather than by measuring leading
/// spaces, which is only ever a guess at what the model meant.
enum SummaryMarkdown {

    enum Block: Equatable {
        case heading(level: Int, text: AttributedString)
        case paragraph(AttributedString)
        /// `depth` is 1 for a top-level item. `ordinal` is non-nil only for
        /// ordered lists, where it is the number the model actually wrote.
        case listItem(depth: Int, ordinal: Int?, text: AttributedString)
        case quote(AttributedString)
        case code(String)
        case thematicBreak

        var text: AttributedString {
            switch self {
            case .heading(_, let text), .paragraph(let text), .quote(let text):
                return text
            case .listItem(_, _, let text):
                return text
            case .code(let source):
                return AttributedString(source)
            case .thematicBreak:
                return AttributedString()
            }
        }
    }

    private static let options = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: true,
        interpretedSyntax: .full,
        failurePolicy: .returnPartiallyParsedIfPossible
    )

    static func blocks(from markdown: String) -> [Block] {
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        // A summary that fails to parse must still reach the user. Falling back
        // to one paragraph per line shows the text unstyled; returning nothing
        // would show an empty tab where their notes should be.
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return paragraphsPerLine(of: markdown)
        }
        let blocks = group(parsed)
        return blocks.isEmpty ? paragraphsPerLine(of: markdown) : blocks
    }

    /// Runs sharing the identity of their innermost intent belong to one block.
    private static func group(_ attributed: AttributedString) -> [Block] {
        var blocks: [Block] = []
        var currentIntent: PresentationIntent?
        var currentIdentity: Int?
        var currentText = AttributedString()
        var started = false

        func flush() {
            defer {
                currentText = AttributedString()
                currentIntent = nil
                currentIdentity = nil
            }
            guard started else { return }
            if let intent = currentIntent {
                if let block = makeBlock(intent: intent, text: currentText) { blocks.append(block) }
            } else if !trimmingNewlines(currentText).characters.isEmpty {
                // No intent at all is not something `.full` produces, but text
                // without one is still the user's summary and must not vanish.
                blocks.append(.paragraph(trimmingNewlines(currentText)))
            }
        }

        for run in attributed.runs {
            let intent = run.presentationIntent
            let identity = intent?.components.first?.identity
            if !started || identity != currentIdentity {
                flush()
                currentIntent = intent
                currentIdentity = identity
                started = true
            }
            currentText.append(attributed[run.range])
        }
        flush()

        return blocks
    }

    private static func makeBlock(intent: PresentationIntent, text: AttributedString) -> Block? {
        var listDepth = 0
        var ordinal: Int?
        var innermostListIsOrdered = false
        var isQuote = false

        for component in intent.components {
            switch component.kind {
            case .header(let level):
                let trimmed = trimmingNewlines(text)
                return trimmed.characters.isEmpty ? nil : .heading(level: level, text: trimmed)
            case .thematicBreak:
                return .thematicBreak
            case .codeBlock:
                return .code(String(text.characters))
            case .listItem(let number):
                // Innermost-first, so the first one seen is this block's own.
                if ordinal == nil { ordinal = number }
            case .orderedList:
                if listDepth == 0 { innermostListIsOrdered = true }
                listDepth += 1
            case .unorderedList:
                listDepth += 1
            case .blockQuote:
                isQuote = true
            default:
                break
            }
        }

        let trimmed = trimmingNewlines(text)
        guard !trimmed.characters.isEmpty else { return nil }

        if listDepth > 0 {
            return .listItem(depth: listDepth, ordinal: innermostListIsOrdered ? ordinal : nil, text: trimmed)
        }
        if isQuote {
            return .quote(trimmed)
        }
        // The note prompt asks for `**논의 사항**` section headers, which
        // CommonMark calls a bold paragraph. Promoting it keeps that format
        // working alongside the `## 논의 사항` the model actually tends to emit,
        // so both render the same way and neither shows its markers.
        if isEntirelyBold(trimmed) {
            return .heading(level: 2, text: withoutInlineIntents(trimmed))
        }
        return .paragraph(trimmed)
    }

    private static func isEntirelyBold(_ text: AttributedString) -> Bool {
        guard !text.characters.isEmpty else { return false }
        return text.runs.allSatisfy { run in
            let isBlank = String(text[run.range].characters).trimmingCharacters(in: .whitespaces).isEmpty
            return isBlank || run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
    }

    /// A promoted header carries its own weight from the view, so the bold that
    /// made it a header in the first place would only double up.
    private static func withoutInlineIntents(_ text: AttributedString) -> AttributedString {
        var result = text
        for range in result.runs.map(\.range) {
            result[range].inlinePresentationIntent = nil
        }
        return result
    }

    private static func trimmingNewlines(_ text: AttributedString) -> AttributedString {
        var result = text
        while let index = result.characters.indices.first, result.characters[index].isNewline {
            result.removeSubrange(index..<result.characters.index(after: index))
        }
        while let index = result.characters.indices.last, result.characters[index].isNewline {
            result.removeSubrange(index..<result.characters.index(after: index))
        }
        return result
    }

    private static func paragraphsPerLine(of markdown: String) -> [Block] {
        markdown
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { .paragraph(AttributedString($0)) }
    }
}
