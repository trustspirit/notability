import AppKit
import SwiftUI

struct TranscriptTabView: View {
    let chunks: [TranscriptChunk]
    @State private var copied = false

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
                    HStack(alignment: .firstTextBaseline) {
                        SectionTitle(text: "\(chunks.count) segment\(chunks.count == 1 ? "" : "s")")
                        Spacer()
                        Button(action: copyAll) {
                            Label(copied ? "Copied" : "Copy all", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(copied)
                        .help("Copy the entire transcript to the clipboard")
                    }
                    LazyVStack(alignment: .leading, spacing: Spacing.sm) {
                        ForEach(chunks.identifiedRows()) { row in
                            TranscriptRow(chunk: row.chunk)
                        }
                    }
                }
                .padding(Spacing.lg)
                .overlayScrollerStyle()
            }
        }
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(chunks.formattedForCopy(), forType: .string)
        withAnimation(.easeInOut(duration: 0.15)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.easeInOut(duration: 0.15)) { copied = false }
        }
    }
}
