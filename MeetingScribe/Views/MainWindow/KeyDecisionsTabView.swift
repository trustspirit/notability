import SwiftUI

struct KeyDecisionsTabView: View {
    let decisions: [String]

    var body: some View {
        if decisions.isEmpty {
            ContentUnavailableView("No key decisions", systemImage: "arrow.triangle.branch")
        } else {
            List(Array(decisions.enumerated()), id: \.offset) { _, decision in
                Label(decision, systemImage: "checkmark.diamond.fill")
                    .textSelection(.enabled)
                    .padding(.vertical, 2)
            }
        }
    }
}
