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

private struct MarkdownBody: View {
    let text: String

    private enum Line {
        case header(String)
        case bullet(String, indent: Int)
        case paragraph(String)
        case blank
    }

    private var lines: [Line] {
        text.components(separatedBy: .newlines).map { raw in
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { return .blank }

            let indent = raw.prefix(while: { $0 == " " }).count
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // Header: line is exactly **text** with nothing outside the markers
            if trimmed.hasPrefix("**"), trimmed.hasSuffix("**"),
               trimmed.count > 4,
               !trimmed.dropFirst(2).dropLast(2).contains("**") {
                return .header(String(trimmed.dropFirst(2).dropLast(2)))
            }

            if trimmed.hasPrefix("- ") {
                return .bullet(String(trimmed.dropFirst(2)), indent: indent)
            }

            return .paragraph(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                switch line {
                case .blank:
                    Spacer().frame(height: 6)

                case .header(let text):
                    Text(text)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.top, index == 0 ? 0 : 14)
                        .padding(.bottom, 5)

                case .bullet(let content, let indent):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(indent > 2 ? "◦" : "•")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 10, alignment: .center)
                        // LocalizedStringKey handles inline **bold** within bullets
                        Text(.init(content))
                            .font(.system(size: 14))
                            .lineSpacing(3)
                            .foregroundStyle(.primary)
                    }
                    .padding(.leading, indent > 2 ? 20 : 0)
                    .padding(.vertical, 2)

                case .paragraph(let text):
                    Text(.init(text))
                        .font(.system(size: 15))
                        .lineSpacing(4)
                        .foregroundStyle(.primary)
                        .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}
