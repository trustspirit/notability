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
                        Text(.init(summary))
                            .font(.system(size: 15, weight: .regular))
                            .lineSpacing(4)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(Spacing.lg)
        }
    }
}
