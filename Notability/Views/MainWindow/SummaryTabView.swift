import SwiftUI

struct SummaryTabView: View {
    let summary: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                SectionTitle(text: "Summary")
                Card(padding: Spacing.lg) {
                    Text(summary.isEmpty ? "No summary was generated." : summary)
                        .font(.system(size: 15, weight: .regular))
                        .lineSpacing(4)
                        .foregroundStyle(summary.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(Spacing.lg)
        }
    }
}
