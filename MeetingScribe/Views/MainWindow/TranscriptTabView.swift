import SwiftUI

struct TranscriptTabView: View {
    let chunks: [TranscriptChunk]

    var body: some View {
        if chunks.isEmpty {
            ContentUnavailableView("No transcript", systemImage: "text.bubble")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                        HStack(alignment: .top, spacing: 8) {
                            Text(formatTimestamp(chunk.timestamp))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .trailing)
                                .padding(.top, 1)
                            Text(chunk.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding()
            }
        }
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return "\(m):\(String(format: "%02d", s))"
    }
}
