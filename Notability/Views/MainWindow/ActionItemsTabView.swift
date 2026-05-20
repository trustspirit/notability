import SwiftUI

struct ActionItemsTabView: View {
    let items: [ActionItem]
    let onToggle: (UUID) -> Void

    var body: some View {
        if items.isEmpty {
            BrandedEmptyState(
                title: "No action items",
                systemImage: "checkmark.circle",
                message: "Notability didn't detect any follow-up actions in this meeting."
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    SectionTitle(text: "\(items.count) action item\(items.count == 1 ? "" : "s")")
                    VStack(spacing: Spacing.sm) {
                        ForEach(items) { item in
                            ActionItemCard(item: item, onToggle: { onToggle(item.id) })
                        }
                    }
                }
                .padding(Spacing.lg)
            }
        }
    }
}

private struct ActionItemCard: View {
    let item: ActionItem
    let onToggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Button(action: onToggle) {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(item.isCompleted ? BrandColor.success : .secondary)
            }
            .buttonStyle(.plain)
            .help(item.isCompleted ? "Mark incomplete" : "Mark complete")

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(item.description)
                    .font(.system(size: 14))
                    .strikethrough(item.isCompleted, color: .secondary)
                    .foregroundStyle(item.isCompleted ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if item.assignee != nil || item.dueDate != nil {
                    HStack(spacing: Spacing.xs) {
                        if let assignee = item.assignee {
                            Pill(text: assignee, systemImage: "person.fill", tint: BrandColor.accent)
                        }
                        if let due = item.dueDate {
                            Pill(text: due, systemImage: "calendar", tint: BrandColor.warning)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous)
                .fill(hovering ? BrandColor.surface.opacity(1.0) : BrandColor.surface.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous)
                .strokeBorder(item.isCompleted ? BrandColor.success.opacity(0.18) : BrandColor.border, lineWidth: 0.5)
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
