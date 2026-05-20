import SwiftUI

struct TranscriptTabView: View {
    let chunks: [TranscriptChunk]

    var body: some View {
        if chunks.isEmpty {
            BrandedEmptyState(
                title: "No transcript",
                systemImage: "text.bubble",
                message: "Audio capture didn't produce a transcript for this meeting."
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    SectionTitle(text: "\(chunks.count) segment\(chunks.count == 1 ? "" : "s")")
                    LazyVStack(alignment: .leading, spacing: Spacing.sm) {
                        ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                            TranscriptRow(timestamp: chunk.timestamp, text: chunk.text)
                        }
                    }
                }
                .padding(Spacing.lg)
            }
        }
    }
}
