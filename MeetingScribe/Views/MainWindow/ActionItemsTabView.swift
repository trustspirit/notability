import SwiftUI

struct ActionItemsTabView: View {
    let items: [ActionItem]
    let onToggle: (UUID) -> Void

    var body: some View {
        if items.isEmpty {
            ContentUnavailableView("No action items", systemImage: "checkmark.circle")
        } else {
            List(items) { item in
                HStack(alignment: .top, spacing: 8) {
                    Button {
                        onToggle(item.id)
                    } label: {
                        Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.isCompleted ? .green : .secondary)
                            .imageScale(.large)
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.description)
                            .strikethrough(item.isCompleted)
                        HStack(spacing: 12) {
                            if let assignee = item.assignee {
                                Label(assignee, systemImage: "person.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let due = item.dueDate {
                                Label(due, systemImage: "calendar")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}
