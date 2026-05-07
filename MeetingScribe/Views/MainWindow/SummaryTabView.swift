import SwiftUI

struct SummaryTabView: View {
    let summary: String

    var body: some View {
        ScrollView {
            Text(summary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding()
        }
    }
}
