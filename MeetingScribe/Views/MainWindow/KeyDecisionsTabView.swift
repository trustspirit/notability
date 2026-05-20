import SwiftUI

struct KeyDecisionsTabView: View {
    let decisions: [String]

    var body: some View {
        if decisions.isEmpty {
            BrandedEmptyState(
                title: "No key decisions",
                systemImage: "arrow.triangle.branch",
                message: "No explicit decisions were detected in this meeting."
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    SectionTitle(text: "\(decisions.count) decision\(decisions.count == 1 ? "" : "s")")
                    VStack(spacing: Spacing.sm) {
                        ForEach(Array(decisions.enumerated()), id: \.offset) { index, decision in
                            DecisionCard(index: index + 1, text: decision)
                        }
                    }
                }
                .padding(Spacing.lg)
            }
        }
    }
}

private struct DecisionCard: View {
    let index: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Text("\(index)")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(BrandColor.accent)
                .frame(width: 28, height: 28)
                .background(BrandColor.accent.opacity(0.12), in: Circle())
            Text(text)
                .font(.system(size: 14))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(Spacing.lg)
        .background(BrandColor.surface, in: RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous)
                .strokeBorder(BrandColor.border, lineWidth: 0.5)
        )
    }
}
