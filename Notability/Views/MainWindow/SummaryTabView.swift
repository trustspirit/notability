import SwiftUI

struct SummaryTabView: View {
    let summary: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                SectionTitle(text: "Summary")
                Card(padding: Spacing.lg) {
                    if summary.isEmpty {
                        Text("No summary was generated.")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        MarkdownBody(text: summary)
                    }
                }
            }
            .padding(Spacing.lg)
        }
    }
}

/// Lays out the blocks `SummaryMarkdown` recovers.
///
/// The parsing lives there rather than here so it can be tested without a view,
/// and so this file only decides how each block looks.
private struct MarkdownBody: View {
    let text: String

    private var blocks: [SummaryMarkdown.Block] { SummaryMarkdown.blocks(from: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(for: block, isFirst: index == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: SummaryMarkdown.Block, isFirst: Bool) -> some View {
        switch block {
        case .heading(let level, let text):
            // Levels below the section headers the prompt asks for still need to
            // read as headers, just quieter ones.
            Text(styled(text, size: level <= 2 ? 15 : 14, weight: .semibold))
                .padding(.top, isFirst ? 0 : 14)
                .padding(.bottom, 5)

        case .paragraph(let text):
            Text(styled(text, size: 15))
                .lineSpacing(4)
                .padding(.vertical, 2)

        case .listItem(let depth, let ordinal, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker(depth: depth, ordinal: ordinal))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, alignment: .trailing)
                Text(styled(text, size: 14))
                    .lineSpacing(3)
            }
            .padding(.leading, CGFloat(depth - 1) * 20)
            .padding(.vertical, 2)

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(.secondary.opacity(0.35))
                    .frame(width: 2)
                Text(styled(text, size: 14))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
            .padding(.vertical, 4)

        case .code(let source):
            Text(source.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 13, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.vertical, 4)

        case .thematicBreak:
            Divider().padding(.vertical, 8)
        }
    }

    private func marker(depth: Int, ordinal: Int?) -> String {
        if let ordinal { return "\(ordinal)." }
        return depth > 1 ? "◦" : "•"
    }

    /// Turns the inline intents the parser preserved into fonts SwiftUI draws.
    ///
    /// Done here rather than relying on `Text` to interpret the intents itself,
    /// so the base size and weight of each block are the ones this file chose
    /// and bold means "one step heavier than that", not a fixed weight.
    private func styled(_ text: AttributedString, size: CGFloat, weight: Font.Weight = .regular) -> AttributedString {
        var result = text
        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            let isBold = intent.contains(.stronglyEmphasized)
            let design: Font.Design = intent.contains(.code) ? .monospaced : .default
            var font = Font.system(size: size, weight: isBold ? .semibold : weight, design: design)
            if intent.contains(.emphasized) { font = font.italic() }
            result[run.range].font = font
        }
        return result
    }
}
